import Foundation

/// Window-to-window shortcuts used by regular SwiftUI scenes. The menu-bar
/// popover has its own AppKit router because it is hosted outside a Scene.
struct WindowCrossLinkActions {
    var activateForWindow: @MainActor () -> Void
    var openWindow: @MainActor (String) -> Void
    var refreshDashboard: @MainActor () -> Void

    @MainActor
    static func scene(
        env: AppEnvironment,
        openWindow: @escaping @MainActor (String) -> Void
    ) -> WindowCrossLinkActions {
        WindowCrossLinkActions(
            activateForWindow: { env.activateForWindow() },
            openWindow: openWindow,
            refreshDashboard: { env.refreshDashboard() })
    }

    @MainActor
    func openSettingsFromDashboard() {
        activateForWindow()
        openWindow("settings")
    }

    @MainActor
    func openDashboardFromSettings() {
        activateForWindow()
        openWindow("dashboard")
        refreshDashboard()
    }
}
