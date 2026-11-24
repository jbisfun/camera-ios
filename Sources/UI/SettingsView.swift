import FossifyCommons
import SwiftUI

/// SettingsActivity.
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette

    @State private var pickQuality = false
    @State private var pickCaptureMode = false
    @State private var pickSaveLocation = false
    @State private var pickFolder = false
    @State private var locationDenied = false
    @State private var location = LocationProvider()

    private static let qualities = [100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50]

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Settings") {
                IconButton(icon: "info.circle") { router.push(.about) }
            }
            ScrollView {
                VStack(spacing: 0) {
                    Text("Color customization").sectionHeader(palette)
                    SettingsItem("Customize colors") { router.push(.customizeColors) }

                    Text("Camera").sectionHeader(palette)
                    SettingsToggle("Shutter sound", isOn: $config.isSoundEnabled)
                    SettingsToggle("Use volume buttons as shutter", isOn: $config.volumeButtonsAsShutter)
                    SettingsToggle("Max screen brightness in preview", isOn: $config.maxBrightness)

                    Text("Saving").sectionHeader(palette)
                    SettingsToggle("Save photo exif metadata", isOn: $config.savePhotoMetadata)
                    SettingsToggle("Save photo and video location", isOn: Binding(
                        get: { config.savePhotoVideoLocation },
                        set: { setSaveLocation($0) }))
                    SettingsToggle("Flip front camera photos horizontally", isOn: $config.flipPhotos)
                    SettingsItem("Save photos and videos to", value: config.saveLocation.title) { pickSaveLocation = true }
                    SettingsItem("Photo compression quality", value: "\(config.photoQuality)%") { pickQuality = true }
                    SettingsItem("Capture mode", value: config.captureMode.title) { pickCaptureMode = true }
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .sheet(isPresented: $pickQuality) {
            RadioDialog(title: nil, items: Self.qualities.map { ($0, "\($0)%") }, selected: config.photoQuality) { config.photoQuality = $0 }
        }
        .sheet(isPresented: $pickCaptureMode) {
            RadioDialog(title: nil, items: CaptureMode.allCases.map { ($0, $0.title) }, selected: config.captureMode) { config.captureMode = $0 }
        }
        .sheet(isPresented: $pickSaveLocation) {
            SaveLocationDialog(current: config.saveLocation, onPick: { config.saveLocation = $0 }, onPickFolder: {
                pickSaveLocation = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pickFolder = true }
            })
        }
        .sheet(isPresented: $pickFolder) {
            let start: String = {
                if case .folder(let path) = config.saveLocation { return path }
                return MediaSaver.documents.path
            }()
            FilePickerDialog(path: start, roots: [StorageRoot(path: MediaSaver.documents.path, title: "Internal")], showFAB: true) { path in
                config.saveLocation = .folder(path: path)
            }
        }
        .sheet(isPresented: $locationDenied) {
            OpenDeviceSettingsDialog(message: "You must allow the app accessing your location, else it won't know it.")
        }
    }

    /// setupSavePhotoVideoLocation(): enabling asks for the location permission first.
    private func setSaveLocation(_ enable: Bool) {
        guard enable else {
            config.savePhotoVideoLocation = false
            return
        }
        location.requestPermission { granted in
            if granted { config.savePhotoVideoLocation = true } else { locationDenied = true }
        }
    }
}

/// "Save photos and videos to": the photo library, one of its albums (or a new one), or a folder in Files.
struct SaveLocationDialog: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let current: SaveLocation
    let onPick: (SaveLocation) -> Void
    let onPickFolder: () -> Void

    @State private var albums: [(id: String, title: String)] = []
    @State private var newAlbum = ""
    @State private var creating = false

    var body: some View {
        DialogFrame(title: "Save photos and videos to") {
            row(.library)
            ForEach(albums, id: \.id) { album in
                row(.album(id: album.id, title: album.title))
            }
            if creating {
                DialogTextField(placeholder: "Album name", text: $newAlbum)
                DialogButtons(okEnabled: !newAlbum.trimmingCharacters(in: .whitespaces).isEmpty) {
                    MediaSaver.createAlbum(newAlbum.trimmingCharacters(in: .whitespaces)) { id in
                        if let id { onPick(.album(id: id, title: newAlbum.trimmingCharacters(in: .whitespaces))) }
                        dismiss()
                    }
                }
            } else {
                Button { creating = true } label: {
                    Label("Create new album", systemImage: "plus").foregroundStyle(palette.primaryColor).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                Button(action: onPickFolder) {
                    let isFolder: Bool = { if case .folder = current { return true }; return false }()
                    RadioRow(title: isFolder ? "Folder: \(current.title)" : "Folder in Files…", on: isFolder)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            MediaSaver.requestLibraryAccess { _ in
                let list = MediaSaver.userAlbums()
                DispatchQueue.main.async { albums = list }
            }
        }
    }

    private func row(_ location: SaveLocation) -> some View {
        Button {
            onPick(location)
            dismiss()
        } label: {
            RadioRow(title: location.title, on: location == current)
        }
        .buttonStyle(.plain)
    }
}

extension AppInfo {
    public static let camera = AppInfo(
        name: "Camera", icon: "camera.fill", upstream: "Camera", port: "camera-ios", policy: "camera",
        faq: [("What photo compression quality should I set?",
               "It depends on your goal. For generic purposes most people advise using 75%-80%, when the image is still really good quality, but the file size is reduced drastically compared to 100%.")]
    )
}
