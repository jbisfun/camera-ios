import FossifyCommons
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
    case settings
    case customizeColors
    case about
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []
    var toast: String?

    func push(_ r: Route) { path.append(r) }
}

/// The whole app as one view: the standalone app's window content, and what
/// the launcher presents.
public struct CameraRoot: View {
    @State private var router = Router()

    public init() {}

    public var body: some View {
        RootView()
            .environment(router)
            .environment(Config.shared)
            .fossifyTheme()
    }
}

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            MainView()
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .settings: SettingsView()
                        case .customizeColors: CustomizeColorsView()
                        case .about: AboutView(app: .camera)
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .paletteBackground()
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .toast($router.toast)
    }
}
