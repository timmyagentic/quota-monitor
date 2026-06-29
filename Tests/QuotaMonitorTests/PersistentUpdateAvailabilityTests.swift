import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Persistent update availability")
struct PersistentUpdateAvailabilityTests {

    @Test
    func discoveredUpdateRemainsVisibleAfterDismissal() {
        let availability = PersistentUpdateAvailability()

        availability.markAvailable(version: "0.2.36")
        availability.markDismissed()

        #expect(availability.isVisible == true)
        #expect(availability.version == "0.2.36")
        #expect(availability.primaryAction == .install)
    }

    @Test
    func readyToInstallKeepsBadgeWithRelaunchAction() {
        let availability = PersistentUpdateAvailability()

        availability.markAvailable(version: "0.2.36")
        availability.markReadyToInstall()

        #expect(availability.isVisible == true)
        #expect(availability.version == "0.2.36")
        #expect(availability.primaryAction == .installAndRelaunch)
    }

    @Test
    func terminalChoicesClearBadge() {
        let availability = PersistentUpdateAvailability()

        availability.markAvailable(version: "0.2.36")
        availability.clear()

        #expect(availability.isVisible == false)
        #expect(availability.version == nil)
        #expect(availability.primaryAction == nil)
    }
}
