import CameraKit
import FossifyCommons
import SwiftUI

struct CameraApp: App {
    // The camera screen is portrait-only (screenOrientation="portrait"); settings may rotate.
    @UIApplicationDelegateAdaptor(OrientationLockDelegate.self) private var orientation

    var body: some Scene {
        WindowGroup { CameraRoot() }
    }
}

CameraApp.main()
