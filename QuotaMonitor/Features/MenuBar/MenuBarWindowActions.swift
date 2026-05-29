import Foundation

/// Explicit window actions for the AppKit-hosted menu-bar popover.
///
/// `MenuBarContentView` is mounted inside an `NSHostingController`, not a
/// SwiftUI `Scene`, so it cannot rely on `@Environment(\.openWindow)` having
/// a scene context. These actions route through `WindowRouter` by default.
struct MenuBarWindowActions {
    var activateForWindow: @MainActor () -> Void
    var requestWindow: @MainActor (String) -> Void
    var refreshDashboard: @MainActor () -> Void

    @MainActor
    static func live(env: AppEnvironment) -> MenuBarWindowActions {
        MenuBarWindowActions(
            activateForWindow: { env.activateForWindow() },
            requestWindow: { WindowRouter.shared.request($0) },
            refreshDashboard: { env.refreshDashboard() })
    }

    @MainActor
    func openDashboard() {
        activateForWindow()
        requestWindow("dashboard")
        refreshDashboard()
    }

    @MainActor
    func openSettings() {
        activateForWindow()
        requestWindow("settings")
    }

    @MainActor
    func openOnboarding() {
        activateForWindow()
        requestWindow("onboarding")
    }
}
