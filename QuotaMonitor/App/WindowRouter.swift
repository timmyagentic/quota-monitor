import AppKit

/// Single seam for opening SwiftUI `Window(id:)` scenes from AppKit
/// contexts (the `AppDelegate` / `StatusItemController`, which have no
/// access to SwiftUI's `openWindow` environment action).
///
/// Implemented with the app's custom `quotamonitor://` URL scheme: a
/// `Window` scene that declares `.handlesExternalEvents(matching: [id])`
/// is opened/activated when the matching URL arrives. This deliberately
/// does NOT rely on a long-lived SwiftUI driver view — a pure menu-bar
/// (`LSUIElement`) app has no always-present SwiftUI scene to host one
/// (the `Window` scenes instantiate lazily on first open, so a driver
/// inside them could never bootstrap the very first onboarding open).
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// Open (or activate) the SwiftUI `Window` scene whose
    /// `handlesExternalEvents` set contains `id`.
    func request(_ id: String) {
        guard let url = URL(string: "quotamonitor://\(id)") else { return }
        NSWorkspace.shared.open(url)
    }
}
