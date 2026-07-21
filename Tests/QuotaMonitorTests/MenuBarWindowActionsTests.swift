import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Menu-bar popover window actions")
struct MenuBarWindowActionsTests {

    @Test
    func dashboardUsesExplicitRequestAndRefreshes() {
        var events: [String] = []
        let actions = MenuBarWindowActions(
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openDashboard()

        // Activation is owned by `WindowManager.show` (the live `requestWindow`),
        // so these actions just request the window and refresh.
        #expect(events == ["request:dashboard", "refresh"])
    }

    @Test
    func settingsUsesExplicitRequest() {
        var events: [String] = []
        let actions = MenuBarWindowActions(
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openSettings()

        #expect(events == ["request:settings"])
    }

    @Test
    func onboardingUsesExplicitRequest() {
        var events: [String] = []
        let actions = MenuBarWindowActions(
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openOnboarding()

        #expect(events == ["request:onboarding"])
    }

    @Test
    func whatsNewUsesExplicitRequest() {
        var events: [String] = []
        let actions = MenuBarWindowActions(
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openWhatsNew()

        #expect(events == ["request:whats-new"])
    }
}
