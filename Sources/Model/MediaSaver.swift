import AVFoundation
import CoreLocation
import Photos
import UIKit

/// A saved capture: a photo library asset or a file in a Files folder (MediaStore uri / file path).
enum MediaRef: Equatable {
    case asset(String)
    case file(URL)
}

/// MediaOutputHelper + ImageSaver + MainActivity.setupPreviewImage(): writes captures to the
/// chosen location and finds / shows the last one.
enum MediaSaver {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Internal-storage fallback (Environment.DIRECTORY_DCIM) when the library can't be written.
    static var internalFolder: URL {
        let url = documents.appendingPathComponent("DCIM", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "png"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Saves a JPEG or moves a recorded movie; `completion(ref, toast)` runs on the main queue.
    static func save(photo data: Data? = nil, video file: URL? = nil, location: CLLocation?, to target: SaveLocation,
                     completion: @escaping (MediaRef?, String?) -> Void) {
        let isPhoto = data != nil
        let name = randomMediaName(isPhoto: isPhoto) + (isPhoto ? ".jpg" : "." + (file?.pathExtension ?? "mov"))

        func toFolder(_ folder: URL, toast: String?) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = uniqueURL(folder.appendingPathComponent(name))
                if let data {
                    try data.write(to: dest, options: .atomic)
                } else if let file {
                    try FileManager.default.moveItem(at: file, to: dest)
                }
                DispatchQueue.main.async { completion(.file(dest), toast) }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, isPhoto ? "The photo could not be saved" : "An error occurred creating the video file")
                }
            }
        }

        switch target {
        case .folder(let path):
            toFolder(URL(fileURLWithPath: path, isDirectory: true), toast: nil)
        case .library, .album:
            let fallback = "An error occurred, save folder changed to internal storage"
            requestLibraryAccess { granted in
                guard granted else { return toFolder(internalFolder, toast: fallback) }
                var placeholder: PHObjectPlaceholder?
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    if let data {
                        request.addResource(with: .photo, data: data, options: options)
                    } else if let file {
                        request.addResource(with: .video, fileURL: file, options: options)
                    }
                    request.creationDate = Date()
                    request.location = location
                    placeholder = request.placeholderForCreatedAsset
                    if case .album(let id, _) = target,
                       let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
                       let placeholder {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }) { success, _ in
                    if success, let id = placeholder?.localIdentifier {
                        if let file { try? FileManager.default.removeItem(at: file) }
                        DispatchQueue.main.async { completion(.asset(id), nil) }
                    } else {
                        toFolder(internalFolder, toast: fallback)
                    }
                }
            }
        }
    }

    /// handleStoragePermission(): read/write access to the library (partial access counts).
    static func requestLibraryAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited: completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in completion(s == .authorized || s == .limited) }
        default:
            let add = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            completion(add == .authorized)
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var i = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base)_\(i).\(ext)")
            i += 1
        }
        return candidate
    }

    // MARK: last captured media

    /// getLatestMediaId(): newest photo (or video) in the library, or in the chosen folder.
    static func latest(isPhoto: Bool, in target: SaveLocation) -> MediaRef? {
        if case .folder(let path) = target {
            let exts = isPhoto ? photoExtensions : videoExtensions
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)) ?? []
            return urls.filter { exts.contains($0.pathExtension.lowercased()) }
                .max { modified($0) < modified($1) }
                .map(MediaRef.file)
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: isPhoto ? .image : .video, options: options).firstObject.map { .asset($0.localIdentifier) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Glide circleCrop() thumbnail for the last-media button.
    static func thumbnail(_ ref: MediaRef, completion: @escaping (UIImage?) -> Void) {
        let size = CGSize(width: 150, height: 150)
        switch ref {
        case .asset(let id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return completion(nil) }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                DispatchQueue.main.async { completion(image) }
            }
        case .file(let url):
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = size
                generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                    DispatchQueue.main.async { completion(image.map { UIImage(cgImage: $0) }) }
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: size)
                    DispatchQueue.main.async { completion(image) }
                }
            }
        }
    }

    /// showLastMediaPreview(): a local file the system previewer can open.
    static func previewURL(_ ref: MediaRef, completion: @escaping (URL?) -> Void) {
        switch ref {
        case .file(let url):
            completion(url)
        case .asset(let id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return completion(nil) }
            let resources = PHAssetResource.assetResources(for: asset)
            let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
            guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else {
                return completion(nil)
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-preview", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(resource.originalFilename)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: options) { error in
                DispatchQueue.main.async { completion(error == nil ? dest : nil) }
            }
        }
    }

    // MARK: albums for "Save photos and videos to"

    static func userAlbums() -> [(id: String, title: String)] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [(String, String)] = []
        result.enumerateObjects { c, _, _ in
            if c.canPerform(.addContent) { albums.append((c.localIdentifier, c.localizedTitle ?? "")) }
        }
        return albums.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    static func createAlbum(_ title: String, completion: @escaping (String?) -> Void) {
        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges({
            placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title).placeholderForCreatedAssetCollection
        }) { success, _ in
            DispatchQueue.main.async { completion(success ? placeholder?.localIdentifier : nil) }
        }
    }
}
