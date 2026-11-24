# camera-ios

[Fossify Camera](https://github.com/FossifyOrg/Camera) re-created for iOS in SwiftUI.

    idl build -c release     # -> build/release/FossifyCamera.ipa (ad-hoc signed; re-sign to install)
    idl install "<device>" FossifyCamera

Ported: AVFoundation photo and video capture with the full-screen portrait preview, Video / Photo tabs (tap or swipe), front/back switch, flash modes off / auto / on / always on (torch; on/off in video), self timer 3 / 5 / 10 s with the upstream countdown beeps and cancel, resolutions (full screen, 16:9, 4:3, 1:1 photo crops; UHD / FHD / HD / SD video) remembered per lens and mode, pinch to zoom, tap to focus and meter, shutter flash, rotating icons, recording time, last-capture thumbnail opening a preview; settings for colors, shutter sound, volume buttons as shutter, max brightness, exif metadata, location, flipping front photos, save location (photo library, an album or a folder in Files), JPEG quality and capture mode.

Differences forced by iOS: the photo shutter sound can only be muted on iOS 18+ (and never where the law requires it); volume buttons as shutter needs iOS 17.2 and also takes the Camera Control button; SD video is 640x480; no capture intents for other apps, lock-screen use or in-app language switch; icons are SF Symbols.

GPL-3.0, like the original.
