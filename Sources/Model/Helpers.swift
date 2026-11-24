import AudioToolbox
import AVFoundation
import CoreImage
import CoreLocation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// MediaSoundHelper / MediaActionSound: the countdown beeps ship with the app (res/raw),
/// the video start / stop sounds are the system's camera sounds.
final class MediaSoundHelper {
    private var beep: AVAudioPlayer?
    private var beep2Seconds: AVAudioPlayer?

    func loadSounds() {
        guard beep == nil, let bundle = Bundle.main.url(forResource: "CameraSounds", withExtension: "bundle").flatMap(Bundle.init(url:)) else { return }
        beep = bundle.url(forResource: "beep", withExtension: "mp3").flatMap { try? AVAudioPlayer(contentsOf: $0) }
        beep2Seconds = bundle.url(forResource: "beep_2_secs", withExtension: "mp3").flatMap { try? AVAudioPlayer(contentsOf: $0) }
        beep?.prepareToPlay()
        beep2Seconds?.prepareToPlay()
    }

    func playStartVideoRecordingSound(onPlayComplete: @escaping () -> Void) {
        AudioServicesPlaySystemSoundWithCompletion(1117) { DispatchQueue.main.async(execute: onPlayComplete) }
    }

    func playStopVideoRecordingSound() { AudioServicesPlaySystemSound(1118) }

    func playTimerCountdownSound() {
        if let beep { beep.currentTime = 0; beep.play() } else { AudioServicesPlaySystemSound(1057) }
    }

    func playTimerCountdown2SecondsSound() {
        if let beep2Seconds { beep2Seconds.currentTime = 0; beep2Seconds.play() } else { AudioServicesPlaySystemSound(1057) }
    }

    func stopTimerCountdown2SecondsSound() { beep2Seconds?.stop() }
}

/// SimpleLocationManager: last known location while "Save photo and video location" is on.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var location: CLLocation?
    private var pending: [(Bool) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    var isDenied: Bool {
        let s = manager.authorizationStatus
        return s == .denied || s == .restricted
    }

    /// handlePermission(PERMISSION_ACCESS_FINE_LOCATION).
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if manager.authorizationStatus == .notDetermined {
            pending.append(completion)
            manager.requestWhenInUseAuthorization()
        } else {
            completion(isAuthorized)
        }
    }

    func requestLocationUpdates() {
        if isAuthorized { manager.startUpdatingLocation() }
    }

    func dropLocationUpdates() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last ?? location
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let callbacks = pending
        pending = []
        callbacks.forEach { $0(isAuthorized) }
    }
}

/// ImageSaver / PhotoProcessor: crops to the selected aspect ratio, applies the JPEG quality and
/// keeps or drops the EXIF data (adding GPS when a location is known).
enum PhotoProcessor {
    private static let context = CIContext()

    static func process(_ data: Data, portraitRatio: CGFloat, quality: Int, keepMetadata: Bool, location: CLLocation?) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        var image = CIImage(cgImage: cg).oriented(orientation)
        let extent = image.extent
        // A photo taken in landscape gets the rotated crop.
        let ratio = extent.width > extent.height ? 1 / portraitRatio : portraitRatio
        var crop = extent
        if extent.width / extent.height > ratio {
            crop.size.width = (extent.height * ratio).rounded()
            crop.origin.x = extent.minX + ((extent.width - crop.width) / 2).rounded()
        } else {
            crop.size.height = (extent.width / ratio).rounded()
            crop.origin.y = extent.minY + ((extent.height - crop.height) / 2).rounded()
        }
        image = image.cropped(to: crop)
        guard let output = context.createCGImage(image, from: crop) else { return nil }

        var meta: [CFString: Any] = [:]
        if keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary] {
                if let v = props[key] { meta[key] = v }
            }
            if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = output.width
                exif[kCGImagePropertyExifPixelYDimension] = output.height
                meta[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                meta[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        if let location { meta[kCGImagePropertyGPSDictionary] = gps(location) }
        meta[kCGImagePropertyOrientation] = 1
        meta[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, output, meta as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func gps(_ l: CLLocation) -> [CFString: Any] {
        let utc = TimeZone(identifier: "UTC")!
        let date = DateFormatter(), time = DateFormatter()
        date.timeZone = utc; date.dateFormat = "yyyy:MM:dd"
        time.timeZone = utc; time.dateFormat = "HH:mm:ss.SS"
        return [
            kCGImagePropertyGPSLatitude: abs(l.coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef: l.coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(l.coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef: l.coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude: abs(l.altitude),
            kCGImagePropertyGPSAltitudeRef: l.altitude < 0 ? 1 : 0,
            kCGImagePropertyGPSDateStamp: date.string(from: l.timestamp),
            kCGImagePropertyGPSTimeStamp: time.string(from: l.timestamp),
        ]
    }

    /// FileOutputOptions.setLocation() for movies.
    static func movieMetadata(_ l: CLLocation) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString
        item.value = String(format: "%+09.5f%+010.5f%+.0fCRSWGS_84/", l.coordinate.latitude, l.coordinate.longitude, l.altitude) as NSString
        return [item]
    }
}
