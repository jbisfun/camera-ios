import Foundation
import UIKit

/// FLASH_OFF / FLASH_ON / FLASH_AUTO / FLASH_ALWAYS_ON (Constants.kt).
enum FlashMode: Int, CaseIterable {
    case off = 0, on, auto, alwaysOn

    var icon: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        case .alwaysOn: return "flashlight.on.fill"
        }
    }

    /// Order of layout_flash.xml.
    static let photoOrder: [FlashMode] = [.off, .auto, .on, .alwaysOn]
}

/// TimerMode.kt.
enum TimerMode: Int, CaseIterable {
    case off = 0, timer3, timer5, timer10

    var seconds: Int {
        switch self {
        case .off: return 0
        case .timer3: return 3
        case .timer5: return 5
        case .timer10: return 10
        }
    }
}

/// CaptureMode.kt.
enum CaptureMode: Int, CaseIterable {
    case minimizeLatency = 0, maximizeQuality

    var title: String {
        switch self {
        case .minimizeLatency: return "Minimize latency"
        case .maximizeQuality: return "Maximize quality"
        }
    }
}

/// MySize as offered in the resolution toggle group: the full screen size plus the
/// supported 16:9, 4:3 and 1:1 crops of the sensor (sorted like getSupportedResolutions()).
enum PhotoSize: Int, CaseIterable {
    case full = 0, ratio16x9, ratio4x3, square

    /// Width / height of the (portrait) preview and saved photo; nil = the screen's ratio.
    var portraitRatio: CGFloat? {
        switch self {
        case .full: return nil
        case .ratio16x9: return 9.0 / 16.0
        case .ratio4x3: return 3.0 / 4.0
        case .square: return 1
        }
    }

    /// requiresCentering(): 4:3 and 1:1 sit between the top icons and the mode tabs.
    var requiresCentering: Bool { self == .ratio4x3 || self == .square }

    var label: String {
        switch self {
        case .full: return "FULL"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .square: return "1:1"
        }
    }
}

/// VideoQuality.kt (UHD/FHD/HD/SD), mapped to capture session presets.
enum VideoQuality: Int, CaseIterable {
    case uhd = 0, fhd, hd, sd

    var width: Int {
        switch self {
        case .uhd: return 3840
        case .fhd: return 1920
        case .hd: return 1280
        case .sd: return 640
        }
    }

    var height: Int {
        switch self {
        case .uhd: return 2160
        case .fhd: return 1080
        case .hd: return 720
        case .sd: return 480
        }
    }

    var portraitRatio: CGFloat { CGFloat(height) / CGFloat(width) }
    var requiresCentering: Bool { self == .sd }

    var label: String {
        switch self {
        case .uhd: return "UHD"
        case .fhd: return "FHD"
        case .hd: return "HD"
        case .sd: return "SD"
        }
    }
}

/// getRandomMediaName(): IMG_/VID_ + yyyyMMdd_HHmmss.
func randomMediaName(isPhoto: Bool) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd_HHmmss"
    return (isPhoto ? "IMG_" : "VID_") + f.string(from: Date())
}

/// Where captures go ("save_photos"): the photo library (optionally an album) or a folder in Files.
enum SaveLocation: Equatable {
    case library
    case album(id: String, title: String)
    case folder(path: String)

    init(stored: String) {
        if stored.hasPrefix("album:") {
            let rest = stored.dropFirst(6)
            let parts = rest.split(separator: "\n", maxSplits: 1).map(String.init)
            self = parts.count == 2 ? .album(id: parts[0], title: parts[1]) : .library
        } else if stored.hasPrefix("path:") {
            self = .folder(path: String(stored.dropFirst(5)))
        } else {
            self = .library
        }
    }

    var stored: String {
        switch self {
        case .library: return ""
        case .album(let id, let title): return "album:\(id)\n\(title)"
        case .folder(let path): return "path:\(path)"
        }
    }

    /// getLastPart(humanizePath(path)).
    var title: String {
        switch self {
        case .library: return "Photo library"
        case .album(_, let title): return title
        case .folder(let path):
            let docs = MediaSaver.documents.path
            return path == docs ? "Internal" : (path as NSString).lastPathComponent
        }
    }
}
