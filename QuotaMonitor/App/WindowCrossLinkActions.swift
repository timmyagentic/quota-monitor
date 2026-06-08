import Foundation

/// Window-to-window shortcuts used by regular SwiftUI scenes. The menu-bar
/// popover has its own AppKit router because it is hosted outside a Scene.
struct WindowCrossLinkActions {
    var openWindow: @MainActor (String) -> Void
    var refreshDashboard: @MainActor () -> Void

    @MainActor
    static func scene(
        env: AppEnvironment,
        openWindow: @escaping @MainActor (String) -> Void
    ) -> WindowCrossLinkActions {
        WindowCrossLinkActions(
            openWindow: openWindow,
            refreshDashboard: { env.refreshDashboard() })
    }

    @MainActor
    func openSettingsFromDashboard() {
        openWindow("settings")
    }

    @MainActor
    func openDashboardFromSettings() {
        openWindow("dashboard")
        refreshDashboard()
    }
}
