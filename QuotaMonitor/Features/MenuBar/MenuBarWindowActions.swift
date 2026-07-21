import Foundation

/// Explicit window actions for the AppKit-hosted menu-bar popover.
///
/// `MenuBarContentView` is mounted inside an `NSHostingController`, not a
/// SwiftUI `Scene`, so it cannot rely on `@Environment(\.openWindow)` having
/// a scene context. These actions route through `WindowManager` by default.
struct MenuBarWindowActions {
    var requestWindow: @MainActor (String) -> Void
    var refreshDashboard: @MainActor () -> Void

    @MainActor
    static func live(env: AppEnvironment) -> MenuBarWindowActions {
        MenuBarWindowActions(
            requestWindow: { WindowManager.shared.show($0) },
            refreshDashboard: { env.refreshDashboard() })
    }

    // `requestWindow` is `WindowManager.show`, which already activates the app
    // and brings the window forward over the popover — so there's no separate
    // activate step here (mirrors the Dashboard/Settings/Help view callers).
    @MainActor
    func openDashboard() {
        requestWindow("dashboard")
        refreshDashboard()
    }

    @MainActor
    func openSettings() {
        requestWindow("settings")
    }

    @MainActor
    func openOnboarding() {
        requestWindow("onboarding")
    }

    @MainActor
    func openWhatsNew() {
        requestWindow("whats-new")
    }
}
