import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Window cross-link actions")
struct WindowCrossLinkActionsTests {

    @Test
    func dashboardToSettingsActivatesAndOpensSettings() {
        var events: [String] = []
        let actions = WindowCrossLinkActions(
            activateForWindow: { events.append("activate") },
            openWindow: { events.append("open:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openSettingsFromDashboard()

        #expect(events == ["activate", "open:settings"])
    }

    @Test
    func settingsToDashboardActivatesOpensAndRefreshesDashboard() {
        var events: [String] = []
        let actions = WindowCrossLinkActions(
            activateForWindow: { events.append("activate") },
            openWindow: { events.append("open:\($0)") },
            refreshDashboard: { events.append("refresh") })

        actions.openDashboardFromSettings()

        #expect(events == ["activate", "open:dashboard", "refresh"])
    }

    @Test
    func toolbarTooltipsDescribeIconDestinations() {
        #expect(L10n.openSettingsTooltip.contains(L10n.settingsWindowTitle))
        #expect(L10n.openDashboardTooltip.contains(L10n.dashboardTitle))
        #expect(L10n.openSettingsTooltip != L10n.openSettings)
        #expect(L10n.openDashboardTooltip != L10n.openDashboard)
    }
}
