import Observation

/// Single seam for opening SwiftUI `Window(id:)` scenes from AppKit
/// contexts (the `AppDelegate` / `StatusItemController`, which have no
/// access to SwiftUI's `openWindow` environment action).
///
/// Producers call `request(_:)`. A long-lived SwiftUI driver view
/// (mounted in `QuotaMonitorApp`) observes `pendingOpen`, performs the
/// real open, then clears it back to nil.
@Observable
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// The window id requested to open ("onboarding" / "dashboard" /
    /// "settings"), or nil when there is nothing pending.
    var pendingOpen: String?

    func request(_ id: String) { pendingOpen = id }
}
