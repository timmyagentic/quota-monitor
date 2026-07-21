import Testing
@testable import QuotaMonitor

@Suite("Post-scan refresh decisions")
struct ScanRefreshDecisionTests {

    @Test("No-op scan keeps populated summaries untouched")
    func noOpScanSkipsSummaryRefreshes() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            hasMenuBarSnapshot: true,
            isMenuBarRefreshInFlight: false,
            isDashboardVisible: true)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: false,
            refreshDashboard: false))
    }

    @Test("No-op scan fills a missing first menu snapshot")
    func noOpScanFillsMissingMenuSnapshot() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            hasMenuBarSnapshot: false,
            isMenuBarRefreshInFlight: false,
            isDashboardVisible: false)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: true,
            refreshDashboard: false))
    }

    @Test("No-op scan does not duplicate an in-flight first snapshot")
    func noOpScanDoesNotDuplicateInFlightSnapshot() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            hasMenuBarSnapshot: false,
            isMenuBarRefreshInFlight: true,
            isDashboardVisible: false)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: false,
            refreshDashboard: false))
    }

    @Test("Read-model changes refresh menu only while Dashboard is hidden")
    func changedScanSkipsHiddenDashboard() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: true,
            hasMenuBarSnapshot: true,
            isMenuBarRefreshInFlight: false,
            isDashboardVisible: false)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: true,
            refreshDashboard: false))
    }

    @Test("Read-model changes refresh both visible summary surfaces")
    func changedScanRefreshesVisibleDashboard() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: true,
            hasMenuBarSnapshot: true,
            isMenuBarRefreshInFlight: false,
            isDashboardVisible: true)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: true,
            refreshDashboard: true))
    }

    @Test("Metadata-only persistence counts as a read-model change")
    func metadataOnlyUpdateChangesReadModel() {
        let report = ImportEngine.ScanReport(
            scannedFiles: 1,
            changedFiles: 0,
            importedSessions: 0,
            importedEvents: 0,
            importedRateLimitSamples: 0,
            updatedSessionMetadata: 1,
            errors: [])

        #expect(report.didChangeReadModel)
    }
}
