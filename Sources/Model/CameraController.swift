import AVFoundation
import Observation
import UIKit

/// CameraXPreview: owns the capture session (photo or video use case), flash / torch, lens,
/// resolution, zoom, focus, photo capture and video recording. UI state is only touched on
/// the main queue; the session is configured on its own queue.
@Observable
final class CameraController {
    // MARK: state shown by MainView
    private(set) var isPhotoMode: Bool
    private(set) var isFront: Bool
    private(set) var flash: FlashMode = .off
    private(set) var hasFlash = false
    private(set) var hasFrontAndBack = false
    private(set) var isRecording = false
    private(set) var recordingSeconds = 0
    private(set) var isCapturing = false
    private(set) var photoSize: PhotoSize = .full
    private(set) var videoQuality: VideoQuality = .hd
    private(set) var videoQualities: [VideoQuality] = []
    private(set) var lastMedia: MediaRef?
    private(set) var lastThumbnail: UIImage?
    /// Bumped when a photo is being captured (shutterAnimation()).
    private(set) var shutterTick = 0
    /// Bumped whenever a mode switch completed (onInitPhotoMode / onInitVideoMode).
    private(set) var modeTick = 0

    @ObservationIgnored var onToast: ((String) -> Void)?
    /// Width / height of the full-screen preview, used to crop "full" photos (ViewPort).
    @ObservationIgnored var fullScreenRatio: CGFloat = 9.0 / 19.5
    @ObservationIgnored var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet { previewLayer?.session = session }
    }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored let sounds = MediaSoundHelper()
    @ObservationIgnored let location = LocationProvider()
    @ObservationIgnored private let queue = DispatchQueue(label: "org.fossify.camera.session")
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var photoDelegates: [Int64: PhotoDelegate] = [:]
    @ObservationIgnored private var recordingDelegate: RecordingDelegate?
    @ObservationIgnored private var recordingTimer: Timer?
    @ObservationIgnored private var recordingRequested = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var configuredCaptureMode: CaptureMode?
    @ObservationIgnored private var lastCameraStartTime = Date.distantPast
    @ObservationIgnored private var pendingModeSwitch: DispatchWorkItem?
    @ObservationIgnored private var zoomStart: CGFloat = 1
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let config = Config.shared

    init(photoMode: Bool) {
        isPhotoMode = photoMode
        isFront = Config.shared.lastUsedCameraLens == 0
        sounds.loadSounds()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            if reason == .videoDeviceInUseByAnotherClient {
                self?.onToast?("Camera is in use by another app, please close the app and try again")
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            self?.onToast?("Camera unavailable")
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: lifecycle

    func start() {
        // A changed capture mode (Settings) picks other photo dimensions.
        if !configured || configuredCaptureMode != config.captureMode {
            configured = true
            reconfigure()
        } else {
            queue.async { [session] in if !session.isRunning { session.startRunning() } }
        }
        if config.savePhotoVideoLocation {
            location.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted { self.location.requestLocationUpdates() } else { self.config.savePhotoVideoLocation = false }
            }
        }
    }

    func stop() {
        location.dropLocationUpdates()
        if movieOutput.isRecording { queue.async { [movieOutput] in movieOutput.stopRecording() } }
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private static func findDevice(front: Bool) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        for type in types {
            if let d = AVCaptureDevice.default(type, for: .video, position: front ? .front : .back) { return d }
        }
        return nil
    }

    /// startCamera() / bindCameraUseCases().
    private func reconfigure(switching: Bool = false) {
        let photo = isPhotoMode, front = isFront
        let videoIndex = config.currentSizeIndex(isPhotoCapture: false, isFrontCamera: front)
        let photoIndex = config.currentSizeIndex(isPhotoCapture: true, isFrontCamera: front)
        configuredCaptureMode = config.captureMode
        let maximizeQuality = config.captureMode == .maximizeQuality
        let audioAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        photoSize = PhotoSize.allCases[min(max(photoIndex, 0), PhotoSize.allCases.count - 1)]

        queue.async { [weak self] in
            guard let self else { return }
            let session = self.session
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            guard let device = Self.findDevice(front: front),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.onToast?(switching ? "Switching camera failed" : "An error occurred accessing the camera") }
                return
            }
            session.addInput(input)
            let supportedVideo = VideoQuality.allCases.filter { device.supportsSessionPreset($0.preset) }
            var quality = VideoQuality.hd
            if photo {
                session.sessionPreset = .photo
                if session.canAddOutput(self.photoOutput) { session.addOutput(self.photoOutput) }
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                let dims = device.activeFormat.supportedMaxPhotoDimensions
                func area(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }
                // Minimize latency keeps the standard sizes; maximize quality adds the high resolution ones.
                let pick = maximizeQuality ? dims.max { area($0) < area($1) }
                    : (dims.filter { area($0) <= 12_600_000 }.max { area($0) < area($1) } ?? dims.first)
                if let pick { self.photoOutput.maxPhotoDimensions = pick }
            } else {
                quality = videoIndex >= 0 && videoIndex < supportedVideo.count ? supportedVideo[videoIndex] : .hd
                if session.canSetSessionPreset(quality.preset) { session.sessionPreset = quality.preset } else { session.sessionPreset = .high }
                if session.canAddOutput(self.movieOutput) { session.addOutput(self.movieOutput) }
                if audioAllowed, let mic = AVCaptureDevice.default(for: .audio),
                   let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
                    session.addInput(micInput)
                }
            }
            session.commitConfiguration()

            if (try? device.lockForConfiguration()) != nil {
                // Virtual devices with an ultra wide lens start on the regular 1x lens.
                if device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
                   let wide = device.virtualDeviceSwitchOverVideoZoomFactors.first {
                    device.videoZoomFactor = CGFloat(truncating: wide)
                } else {
                    device.videoZoomFactor = 1
                }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            }
            self.device = device
            if !session.isRunning { session.startRunning() }
            let flashAvailable = device.hasFlash || device.hasTorch
            let both = Self.findDevice(front: true) != nil && Self.findDevice(front: false) != nil

            DispatchQueue.main.async {
                self.videoQualities = supportedVideo
                self.videoQuality = quality
                self.hasFrontAndBack = both
                self.setupRotation(device)
                // setFlashAvailable()
                self.hasFlash = flashAvailable
                self.setFlashlightState(flashAvailable ? FlashMode(rawValue: self.config.flashlightState) ?? .off : .off)
                self.modeTick += 1
                self.setupPreviewImage()
            }
        }
    }

    private func setupRotation(_ device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        if let c = previewLayer?.connection, c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
    }

    // MARK: modes

    func initPhotoMode() { debounceChangeCameraMode(photo: true) }
    func initVideoMode() { debounceChangeCameraMode(photo: false) }

    private func debounceChangeCameraMode(photo: Bool) {
        let run = { [weak self] in
            guard let self else { return }
            if self.isPhotoMode != photo {
                self.isPhotoMode = photo
                self.config.initPhotoMode = photo
                self.reconfigure()
            } else {
                self.modeTick += 1
            }
        }
        let now = Date()
        pendingModeSwitch?.cancel()
        if now.timeIntervalSince(lastCameraStartTime) > 0.5 {
            run()
        } else {
            let item = DispatchWorkItem(block: run)
            pendingModeSwitch = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
        lastCameraStartTime = now
    }

    func toggleFrontBackCamera() {
        isFront.toggle()
        config.lastUsedCameraLens = isFront ? 0 : 1
        reconfigure(switching: true)
    }

    // MARK: flash

    /// handleFlashlightClick(): true when the flash options should be shown (photo mode).
    func handleFlashlightClick() -> Bool {
        if isPhotoMode { return true }
        setFlashlightState(flash == .off ? .on : .off)
        return false
    }

    func setFlashlightState(_ state: FlashMode) {
        var state = state
        let torch: Bool
        if isPhotoMode {
            torch = state == .alwaysOn
        } else {
            torch = state == .on || state == .alwaysOn
            // reset to FLASH_ON for video capture
            if state == .alwaysOn { state = .on }
        }
        queue.async { [weak self] in
            guard let d = self?.device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            let mode: AVCaptureDevice.TorchMode = torch ? .on : .off
            if d.isTorchModeSupported(mode) { d.torchMode = mode }
            d.unlockForConfiguration()
        }
        flash = state
        config.flashlightState = state.rawValue
    }

    // MARK: resolutions

    /// Options of the resolution toggle group and the selected index.
    var resolutionLabels: [String] {
        isPhotoMode ? PhotoSize.allCases.map(\.label) : videoQualities.map(\.label)
    }

    var selectedResolutionIndex: Int {
        isPhotoMode ? photoSize.rawValue : (videoQualities.firstIndex(of: videoQuality) ?? 0)
    }

    var selectedResolutionLabel: String { isPhotoMode ? photoSize.label : videoQuality.label }

    /// showChangeResolution(): true when the toggle group should be shown, else the sizes are cycled.
    func showChangeResolution() -> Bool {
        let count = resolutionLabels.count
        if count > 2 { return true }
        if count >= 2 {
            let current = config.currentSizeIndex(isPhotoCapture: isPhotoMode, isFrontCamera: isFront)
            selectResolution(current >= count - 1 ? 0 : current + 1, changed: true)
        }
        return false
    }

    func selectResolution(_ index: Int, changed: Bool) {
        config.storeSize(isPhotoCapture: isPhotoMode, isFrontCamera: isFront, index: index)
        guard changed else { return }
        if isPhotoMode {
            photoSize = PhotoSize.allCases[min(max(index, 0), PhotoSize.allCases.count - 1)]
        } else {
            if movieOutput.isRecording { queue.async { [movieOutput] in movieOutput.stopRecording() } }
            reconfigure()
        }
    }

    // MARK: zoom and focus

    func beginZoom() { zoomStart = device?.videoZoomFactor ?? 1 }

    /// PinchToZoomOnScaleGestureListener + ZoomCalculator (pinch speed doubled).
    func zoom(scale: CGFloat) {
        let speed = scale > 1 ? 1 + (scale - 1) * 2 : max(0.05, 1 - (1 - scale) * 2)
        let target = zoomStart * speed
        queue.async { [weak self] in
            guard let d = self?.device, (try? d.lockForConfiguration()) != nil else { return }
            let base = d.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
                ? CGFloat(truncating: d.virtualDeviceSwitchOverVideoZoomFactors.first ?? 1) : 1
            let maxZoom = min(d.maxAvailableVideoZoomFactor, base * 10)
            d.videoZoomFactor = min(max(target, d.minAvailableVideoZoomFactor), maxZoom)
            d.unlockForConfiguration()
        }
    }

    /// onSingleTapConfirmed(): focus and meter at the tapped point (auto cancel disabled).
    func focus(at layerPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let p = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        queue.async { [weak self] in
            guard let d = self?.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = p
                d.focusMode = .autoFocus
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                d.exposurePointOfInterest = p
                d.exposureMode = .autoExpose
            }
            d.unlockForConfiguration()
        }
    }

    // MARK: photo

    func tryTakePicture() {
        guard isPhotoMode, session.outputs.contains(photoOutput), !isCapturing else {
            if !isCapturing { onToast?("An error occurred accessing the camera") }
            return
        }
        isCapturing = true
        let settings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) : AVCapturePhotoSettings()
        let mode: AVCaptureDevice.FlashMode = flash == .on ? .on : (flash == .auto ? .auto : .off)
        if photoOutput.supportedFlashModes.contains(mode) { settings.flashMode = mode }
        settings.photoQualityPrioritization = config.captureMode == .maximizeQuality ? .quality : .speed
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = !config.isSoundEnabled
        }

        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let mirror = isFront && config.flipPhotos
        let ratio = photoSize.portraitRatio ?? fullScreenRatio
        let quality = config.photoQuality, keepMetadata = config.savePhotoMetadata
        let loc = config.savePhotoVideoLocation ? location.location : nil
        let target = config.saveLocation
        let id = settings.uniqueID

        let delegate = PhotoDelegate(
            willCapture: { [weak self] in DispatchQueue.main.async { self?.shutterTick += 1 } },
            finished: { [weak self] data in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let self else { return }
                    guard let data, let jpeg = PhotoProcessor.process(data, portraitRatio: ratio, quality: quality, keepMetadata: keepMetadata, location: loc) else {
                        DispatchQueue.main.async {
                            self.photoDelegates[id] = nil
                            self.isCapturing = false
                            self.onToast?("Photo capture failed")
                        }
                        return
                    }
                    MediaSaver.save(photo: jpeg, location: loc, to: target) { ref, toast in
                        self.photoDelegates[id] = nil
                        self.isCapturing = false
                        if let toast { self.onToast?(toast) }
                        if let ref { self.mediaSaved(ref, isPhoto: true) }
                    }
                }
            })
        photoDelegates[id] = delegate
        queue.async { [photoOutput] in
            if let c = photoOutput.connection(with: .video) {
                if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
                if c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = mirror
                }
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: video

    func toggleRecording() {
        if !movieOutput.isRecording && !recordingRequested {
            recordingRequested = true
            if config.isSoundEnabled {
                sounds.playStartVideoRecordingSound { [weak self] in self?.startRecording() }
                onVideoRecordingStarted()
            } else {
                startRecording()
            }
        } else if movieOutput.isRecording {
            queue.async { [movieOutput] in movieOutput.stopRecording() }
        } else {
            // stopped before the start sound finished
            recordingRequested = false
            onVideoRecordingStopped()
        }
    }

    private func startRecording() {
        guard recordingRequested else { return }
        guard !isPhotoMode, session.outputs.contains(movieOutput) else {
            recordingRequested = false
            onVideoRecordingStopped()
            onToast?("An error occurred accessing the camera")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(randomMediaName(isPhoto: false) + ".mov")
        try? FileManager.default.removeItem(at: url)
        let loc = config.savePhotoVideoLocation ? location.location : nil
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let delegate = RecordingDelegate(
            started: { [weak self] in DispatchQueue.main.async { self?.onVideoRecordingStarted() } },
            finished: { [weak self] url, error in DispatchQueue.main.async { self?.recordingFinished(url, error: error) } })
        recordingDelegate = delegate
        queue.async { [movieOutput] in
            movieOutput.metadata = loc.map(PhotoProcessor.movieMetadata)
            if let c = movieOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            movieOutput.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    private func onVideoRecordingStarted() {
        isRecording = true
        guard recordingTimer == nil else { return }
        recordingSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.movieOutput.isRecording else { return }
            let seconds = self.movieOutput.recordedDuration.seconds
            self.recordingSeconds = seconds.isFinite ? Int(seconds) : 0
        }
    }

    private func onVideoRecordingStopped() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingSeconds = 0
        isRecording = false
    }

    private func recordingFinished(_ url: URL, error: Error?) {
        recordingRequested = false
        recordingDelegate = nil
        if config.isSoundEnabled { sounds.playStopVideoRecordingSound() }
        onVideoRecordingStopped()
        let ns = error as NSError?
        let succeeded = error == nil || (ns?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        guard succeeded else {
            try? FileManager.default.removeItem(at: url)
            onToast?(ns?.code == AVError.diskFull.rawValue
                     ? "Video recording failed due to insufficient storage"
                     : "Video recording failed, try using a different resolution")
            return
        }
        let loc = config.savePhotoVideoLocation ? location.location : nil
        MediaSaver.save(video: url, location: loc, to: config.saveLocation) { [weak self] ref, toast in
            if let toast { self?.onToast?(toast) }
            if let ref { self?.mediaSaved(ref, isPhoto: false) }
        }
    }

    // MARK: last media

    private func mediaSaved(_ ref: MediaRef, isPhoto: Bool) {
        lastMedia = ref
        MediaSaver.thumbnail(ref) { [weak self] image in
            if self?.lastMedia == ref { self?.lastThumbnail = image }
        }
    }

    /// setupPreviewImage(isPhoto).
    func setupPreviewImage() {
        let photo = isPhotoMode, target = config.saveLocation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let ref = MediaSaver.latest(isPhoto: photo, in: target) else { return }
            DispatchQueue.main.async { self?.mediaSaved(ref, isPhoto: photo) }
        }
    }
}

extension VideoQuality {
    var preset: AVCaptureSession.Preset {
        switch self {
        case .uhd: return .hd4K3840x2160
        case .fhd: return .hd1920x1080
        case .hd: return .hd1280x720
        case .sd: return .vga640x480
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let willCapture: () -> Void
    let finished: (Data?) -> Void

    init(willCapture: @escaping () -> Void, finished: @escaping (Data?) -> Void) {
        self.willCapture = willCapture
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        finished(error == nil ? photo.fileDataRepresentation() : nil)
    }
}

private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let started: () -> Void
    let finished: (URL, Error?) -> Void

    init(started: @escaping () -> Void, finished: @escaping (URL, Error?) -> Void) {
        self.started = started
        self.finished = finished
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        started()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        finished(outputFileURL, error)
    }
}
