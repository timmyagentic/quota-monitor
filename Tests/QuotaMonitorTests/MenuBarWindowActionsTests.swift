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
            activateForWindow: { events.append("activate") },
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openDashboard()

        #expect(events == ["activate", "request:dashboard", "refresh"])
    }

    @Test
    func settingsUsesExplicitRequest() {
        var events: [String] = []
        let actions = MenuBarWindowActions(
            activateForWindow: { events.append("activate") },
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openSettings()

        #expect(events == ["activate", "request:settings"])
    }

    @Test
    func onboardingUsesExplicitRequest() {
        var events: [String] = []
        let actions = MenuBarWindowActions(
            activateForWindow: { events.append("activate") },
            requestWindow: { events.append("request:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openOnboarding()

        #expect(events == ["activate", "request:onboarding"])
    }
}
