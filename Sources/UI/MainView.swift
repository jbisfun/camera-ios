import _QuickLook_SwiftUI
import AVFoundation
import FossifyCommons
import SwiftUI
import UIKit

/// MainActivity: full-screen preview, top option icons (timer, flash, resolution, settings)
/// with their toggle groups, Video / Photo tabs, last media, shutter and lens switch.
struct MainView: View {
    private enum TopOptions { case none, flash, timer, resolution }

    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.scenePhase) private var phase

    @State private var camera: CameraController?
    @State private var permissionDenied = false
    @State private var options = TopOptions.none
    @State private var tabPhoto = true
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var shutterAlpha = 0.0
    @State private var focusPoint: CGPoint?
    @State private var focusTask: Task<Void, Never>?
    @State private var zooming = false
    @State private var degrees = 0.0
    @State private var cameraToggleAngle = 0.0
    @State private var originalBrightness: CGFloat?
    @State private var previewURL: URL?
    @State private var visible = false

    private let topHeight: CGFloat = 56
    private let bottomHeight: CGFloat = 160

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let camera {
                    content(camera, geo: geo)
                } else if permissionDenied {
                    VStack(spacing: 16) {
                        Text("Camera permission is required").foregroundStyle(.white)
                        Button("Go to Settings") { Launcher.openDeviceSettings() }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if camera == nil { CloseAppButton().foregroundStyle(.white).padding(.top, geo.safeAreaInsets.top) }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .quickLookPreview($previewURL)
        .onAppear { visible = true; resume() }
        .onDisappear { visible = false; pause() }
        .onChange(of: phase) { _, new in
            guard visible else { return }
            if new == .active { resume() } else { pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // OrientationEventListener: rotate the icons, the layout stays portrait.
            let new: Double
            switch UIDevice.current.orientation {
            case .landscapeLeft: new = 90
            case .landscapeRight: new = -90
            case .portrait: new = 0
            default: return
            }
            withAnimation(.easeInOut(duration: 0.3)) { degrees = new }
        }
    }

    // MARK: layout

    @ViewBuilder
    private func content(_ camera: CameraController, geo: GeometryProxy) -> some View {
        let insets = geo.safeAreaInsets
        let size = geo.size
        let busy = countdown != nil
        ZStack {
            preview(camera, size: size, insets: insets)

            Color.black.opacity(shutterAlpha).allowsHitTesting(false)

            VStack(spacing: 0) {
                topOptions(camera)
                    .frame(height: topHeight)
                    .padding(.top, insets.top)
                    .opacity(busy ? 0 : 1)
                    .disabled(busy)
                Spacer()
                bottom(camera)
                    .padding(.bottom, insets.bottom + 16)
            }

            if let countdown {
                // timer_text
                Text("\(countdown)")
                    .font(.system(size: 180, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: Color(argb: 0xFF424242), radius: 6, y: 2)
                    .contentTransition(.numericText(countsDown: true))
                    .rotationEffect(.degrees(degrees))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: camera.shutterTick) {
            shutterAlpha = 1
            withAnimation(.linear(duration: 0.5)) { shutterAlpha = 0 }
        }
        .onChange(of: camera.modeTick) {
            tabPhoto = camera.isPhotoMode
            closeOptions()
        }
        .onAppear { camera.fullScreenRatio = size.width / max(size.height, 1) }
        .onChange(of: size) { camera.fullScreenRatio = size.width / max(size.height, 1) }
    }

    /// adjustPreviewView(): the frame of the selected size, centered between the bars for 4:3 / 1:1.
    private func preview(_ camera: CameraController, size: CGSize, insets: EdgeInsets) -> some View {
        let full = camera.isPhotoMode && camera.photoSize == .full
        let ratio = camera.isPhotoMode ? (camera.photoSize.portraitRatio ?? size.width / max(size.height, 1)) : camera.videoQuality.portraitRatio
        let centering = camera.isPhotoMode ? camera.photoSize.requiresCentering : camera.videoQuality.requiresCentering
        let width = size.width
        let height = full ? size.height : min(size.height, width / ratio)
        let top = insets.top + topHeight, bottom = size.height - insets.bottom - bottomHeight
        let centerY = centering ? (top + bottom) / 2 : size.height / 2

        return CameraPreview(controller: camera, volumeButtonsAsShutter: config.volumeButtonsAsShutter, onShutter: shutterPressed)
            .frame(width: width, height: height)
            .overlay {
                if let focusPoint {
                    FocusCircle().position(focusPoint).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                // onTouchPreview() + onSingleTapConfirmed()
                if closeOptions() { return }
                camera.focus(at: value.location)
                showFocus(value.location)
            })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if !zooming {
                        zooming = true
                        closeOptions()
                        camera.beginZoom()
                    }
                    camera.zoom(scale: value.magnification)
                }
                .onEnded { _ in zooming = false })
            .disabled(camera.isCapturing)
            .position(x: size.width / 2, y: centerY)
            .animation(.easeInOut(duration: 0.25), value: height)
    }

    // MARK: top options (layout_top / layout_flash / layout_timer / resolution group)

    @ViewBuilder
    private func topOptions(_ camera: CameraController) -> some View {
        HStack(spacing: 0) {
            CloseAppButton().foregroundStyle(.white)
            switch options {
            case .none:
                if camera.isPhotoMode {
                    optionButton { TimerIcon(mode: config.timerMode) } action: { withAnimation(.easeInOut(duration: 0.15)) { options = .timer } }
                        .transition(.opacity)
                }
                if camera.hasFlash {
                    optionButton { ShadowIcon(systemName: camera.flash.icon) } action: {
                        if camera.handleFlashlightClick() { withAnimation(.easeInOut(duration: 0.15)) { options = .flash } }
                    }
                    .disabled(camera.isCapturing)
                }
                optionButton { ResolutionIcon(label: camera.selectedResolutionLabel) } action: {
                    if camera.showChangeResolution() { withAnimation(.easeInOut(duration: 0.15)) { options = .resolution } }
                }
                .disabled(camera.isCapturing || camera.isRecording)
                optionButton { ShadowIcon(systemName: "gearshape.fill") } action: { router.push(.settings) }
                    .disabled(camera.isRecording)
            case .flash:
                ForEach(FlashMode.photoOrder, id: \.self) { mode in
                    optionButton { ShadowIcon(systemName: mode.icon, checked: camera.flash == mode) } action: {
                        closeOptions()
                        camera.setFlashlightState(mode)
                    }
                }
            case .timer:
                ForEach(TimerMode.allCases, id: \.self) { mode in
                    optionButton { TimerIcon(mode: mode, checked: config.timerMode == mode) } action: {
                        config.timerMode = mode
                        closeOptions()
                    }
                }
            case .resolution:
                let labels = camera.resolutionLabels
                let selected = camera.selectedResolutionIndex
                ForEach(labels.indices, id: \.self) { i in
                    optionButton { ResolutionIcon(label: labels[i], checked: i == selected) } action: {
                        closeOptions()
                        camera.selectResolution(i, changed: i != selected)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func optionButton<Label: View>(@ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .rotationEffect(.degrees(degrees))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedStyle())
    }

    @discardableResult
    private func closeOptions() -> Bool {
        guard options != .none else { return false }
        withAnimation(.easeInOut(duration: 0.15)) { options = .none }
        return true
    }

    // MARK: bottom (mode tabs, recording time, last media, shutter, lens switch)

    private func bottom(_ camera: CameraController) -> some View {
        let busy = countdown != nil
        let hideSides = busy || camera.isRecording
        return VStack(spacing: 8) {
            modeTabs(camera)
                .opacity(busy || camera.isRecording ? 0 : 1)
                .disabled(busy || camera.isRecording)

            Text(camera.recordingSeconds.formattedDuration())
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .opacity(camera.isRecording ? 1 : 0)

            HStack {
                RingButton(action: showLastMediaPreview) {
                    if let image = camera.lastThumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .rotationEffect(.degrees(degrees))
                .opacity(hideSides ? 0 : 1)
                .disabled(hideSides)
                .frame(maxWidth: .infinity)

                ShutterButton(kind: shutterKind(camera), action: shutterPressed)
                    .rotationEffect(.degrees(degrees))
                    .disabled(camera.isCapturing)

                RingButton {
                    withAnimation(.easeInOut(duration: 0.5)) { cameraToggleAngle += 180 }
                    camera.toggleFrontBackCamera()
                } content: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(cameraToggleAngle))
                }
                .rotationEffect(.degrees(degrees))
                .opacity(hideSides || !camera.hasFrontAndBack ? 0 : 1)
                .disabled(hideSides || !camera.hasFrontAndBack || camera.isCapturing)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(Color(argb: 0x2E000000).padding(.bottom, -200))
        .animation(.easeInOut(duration: 0.2), value: hideSides)
    }

    private func shutterKind(_ camera: CameraController) -> ShutterButton.Kind {
        if countdown != nil { return .timerCancel }
        if camera.isPhotoMode { return .photo }
        return camera.isRecording ? .recording : .video
    }

    /// camera_mode_tab: Video | Photo, also switched by swiping.
    private func modeTabs(_ camera: CameraController) -> some View {
        HStack(spacing: 8) {
            tab("Video", selected: !tabPhoto) { selectTab(photo: false) }
            tab("Photo", selected: tabPhoto) { selectTab(photo: true) }
        }
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            let dx = value.translation.width
            guard abs(dx) >= 100 else { return }
            selectTab(photo: dx < 0)
        })
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(selected ? Color(argb: 0xFF606060) : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Color.white : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func selectTab(photo: Bool) {
        guard let camera, photo != tabPhoto else { return }
        tabPhoto = photo
        if photo {
            camera.initPhotoMode()
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        camera.initVideoMode()
                    } else {
                        router.toast = "Audio permission is required"
                        tabPhoto = true
                    }
                }
            }
        }
    }

    // MARK: actions

    private func shutterPressed() {
        guard let camera, visible else { return }
        if countdownTask != nil {
            cancelTimer()
        } else if camera.isPhotoMode {
            closeOptions()
            if config.timerMode == .off {
                camera.tryTakePicture()
            } else {
                scheduleTimer(config.timerMode, camera: camera)
            }
        } else {
            camera.toggleRecording()
        }
    }

    /// scheduleTimer(): count down with a beep each second and the 2 second beep at the end.
    private func scheduleTimer(_ mode: TimerMode, camera: CameraController) {
        countdownTask = Task { @MainActor in
            var playSound = true
            for remaining in stride(from: mode.seconds, to: 0, by: -1) {
                withAnimation { countdown = remaining }
                if playSound && config.isSoundEnabled {
                    if remaining <= 2 {
                        camera.sounds.playTimerCountdown2SecondsSound()
                        playSound = false
                    } else {
                        camera.sounds.playTimerCountdownSound()
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            cancelTimer()
            camera.tryTakePicture()
        }
    }

    private func cancelTimer() {
        camera?.sounds.stopTimerCountdown2SecondsSound()
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func showFocus(_ point: CGPoint) {
        focusPoint = point
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { focusPoint = nil }
        }
    }

    private func showLastMediaPreview() {
        guard let ref = camera?.lastMedia else { return }
        MediaSaver.previewURL(ref) { url in previewURL = url }
    }

    // MARK: lifecycle

    /// onResume(): permissions, camera, FLAG_KEEP_SCREEN_ON, max brightness, portrait lock.
    private func resume() {
        OrientationLock.set(portrait: true)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        UIApplication.shared.isIdleTimerDisabled = true
        if config.maxBrightness, let screen = currentScreen {
            if originalBrightness == nil { originalBrightness = screen.brightness }
            screen.brightness = 1
        }
        if let camera {
            camera.start()
            camera.setupPreviewImage()
        } else if !permissionDenied {
            tryInitCamera()
        }
    }

    /// onPause().
    private func pause() {
        cancelTimer()
        camera?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let originalBrightness, let screen = currentScreen {
            screen.brightness = originalBrightness
            self.originalBrightness = nil
        }
        OrientationLock.set(portrait: false)
    }

    private var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    private func tryInitCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    router.toast = "Camera permission is required"
                    permissionDenied = true
                    return
                }
                MediaSaver.requestLibraryAccess { _ in
                    DispatchQueue.main.async {
                        if config.initPhotoMode {
                            initializeCamera(photo: true)
                        } else {
                            AVCaptureDevice.requestAccess(for: .audio) { audio in
                                DispatchQueue.main.async {
                                    if audio {
                                        initializeCamera(photo: false)
                                    } else {
                                        router.toast = "Audio permission is required"
                                        config.initPhotoMode = true
                                        initializeCamera(photo: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func initializeCamera(photo: Bool) {
        guard camera == nil else { return }
        let controller = CameraController(photoMode: photo)
        controller.onToast = { router.toast = $0 }
        tabPhoto = photo
        camera = controller
        if visible { controller.start() }
    }
}
