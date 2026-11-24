import FossifyCommons
import Foundation
import Observation

/// Port of the camera Config (SharedPreferences -> UserDefaults); colors live in FossifyCommons.BaseConfig.
/// Kept in its own suite so the upstream key names ("sound", "save_photos", ...) can't collide
/// with other apps inside the launcher.
@Observable
final class Config {
    static let shared = Config()

    @ObservationIgnored private let d = UserDefaults(suiteName: "org.fossify.camera") ?? .standard

    var savePhotos: String { didSet { d.set(savePhotos, forKey: "save_photos") } }
    var isSoundEnabled: Bool { didSet { d.set(isSoundEnabled, forKey: "sound") } }
    var volumeButtonsAsShutter: Bool { didSet { d.set(volumeButtonsAsShutter, forKey: "volume_buttons_as_shutter") } }
    var flipPhotos: Bool { didSet { d.set(flipPhotos, forKey: "flip_photos") } }
    /// CameraSelector.LENS_FACING_FRONT = 0, LENS_FACING_BACK = 1.
    var lastUsedCameraLens: Int { didSet { d.set(lastUsedCameraLens, forKey: "last_used_camera_lens") } }
    var initPhotoMode: Bool { didSet { d.set(initPhotoMode, forKey: "init_photo_mode") } }
    var flashlightState: Int { didSet { d.set(flashlightState, forKey: "flashlight_state") } }
    var backPhotoResIndex: Int { didSet { d.set(backPhotoResIndex, forKey: "back_photo_resolution_index_3") } }
    var backVideoResIndex: Int { didSet { d.set(backVideoResIndex, forKey: "back_video_resolution_index_3") } }
    var frontPhotoResIndex: Int { didSet { d.set(frontPhotoResIndex, forKey: "front_photo_resolution_index_3") } }
    var frontVideoResIndex: Int { didSet { d.set(frontVideoResIndex, forKey: "front_video_resolution_index_3") } }
    var savePhotoMetadata: Bool { didSet { d.set(savePhotoMetadata, forKey: "save_photo_metadata") } }
    var savePhotoVideoLocation: Bool { didSet { d.set(savePhotoVideoLocation, forKey: "save_photo_video_location") } }
    var photoQuality: Int { didSet { d.set(photoQuality, forKey: "photo_quality") } }
    var captureMode: CaptureMode { didSet { d.set(captureMode.rawValue, forKey: "capture_mode") } }
    var maxBrightness: Bool { didSet { d.set(maxBrightness, forKey: "max_brightness") } }
    var timerMode: TimerMode { didSet { d.set(timerMode.rawValue, forKey: "timer_mode") } }

    private init() {
        savePhotos = d.string(forKey: "save_photos") ?? ""
        isSoundEnabled = d.object(forKey: "sound") as? Bool ?? true
        volumeButtonsAsShutter = d.object(forKey: "volume_buttons_as_shutter") as? Bool ?? false
        flipPhotos = d.object(forKey: "flip_photos") as? Bool ?? true
        lastUsedCameraLens = d.object(forKey: "last_used_camera_lens") as? Int ?? 1
        initPhotoMode = d.object(forKey: "init_photo_mode") as? Bool ?? true
        flashlightState = d.object(forKey: "flashlight_state") as? Int ?? FlashMode.off.rawValue
        backPhotoResIndex = d.object(forKey: "back_photo_resolution_index_3") as? Int ?? 0
        backVideoResIndex = d.object(forKey: "back_video_resolution_index_3") as? Int ?? 0
        frontPhotoResIndex = d.object(forKey: "front_photo_resolution_index_3") as? Int ?? 0
        frontVideoResIndex = d.object(forKey: "front_video_resolution_index_3") as? Int ?? 0
        savePhotoMetadata = d.object(forKey: "save_photo_metadata") as? Bool ?? true
        savePhotoVideoLocation = d.object(forKey: "save_photo_video_location") as? Bool ?? false
        photoQuality = d.object(forKey: "photo_quality") as? Int ?? 80
        captureMode = CaptureMode(rawValue: d.integer(forKey: "capture_mode")) ?? .minimizeLatency
        maxBrightness = d.object(forKey: "max_brightness") as? Bool ?? false
        timerMode = TimerMode(rawValue: d.integer(forKey: "timer_mode")) ?? .off
    }

    /// savePhotosFolder getter: a missing folder falls back to the default (the photo library).
    var saveLocation: SaveLocation {
        get {
            let location = SaveLocation(stored: savePhotos)
            if case .folder(let path) = location {
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue { return .library }
            }
            return location
        }
        set { savePhotos = newValue.stored }
    }

    // MARK: MediaSizeStore

    func storeSize(isPhotoCapture: Bool, isFrontCamera: Bool, index: Int) {
        switch (isPhotoCapture, isFrontCamera) {
        case (true, true): frontPhotoResIndex = index
        case (true, false): backPhotoResIndex = index
        case (false, true): frontVideoResIndex = index
        case (false, false): backVideoResIndex = index
        }
    }

    func currentSizeIndex(isPhotoCapture: Bool, isFrontCamera: Bool) -> Int {
        switch (isPhotoCapture, isFrontCamera) {
        case (true, true): return frontPhotoResIndex
        case (true, false): return backPhotoResIndex
        case (false, true): return frontVideoResIndex
        case (false, false): return backVideoResIndex
        }
    }
}
