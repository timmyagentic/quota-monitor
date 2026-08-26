import Testing
@testable import QuotaMonitor

@Suite("Post-scan refresh decisions")
struct ScanRefreshDecisionTests {

    @Test("only explicit scan triggers request no-change summary fallbacks")
    func explicitScanTriggersRequestFallbacks() {
        for trigger in ["manual", "popover", "qa"] {
            #expect(AppEnvironment.scanTriggerRefreshesWithoutChanges(trigger))
        }
        for trigger in ["launch", "onboarding", "claude-file-watch"] {
            #expect(!AppEnvironment.scanTriggerRefreshesWithoutChanges(trigger))
        }
    }

    @Test("Background no-op scan keeps populated summaries untouched")
    func backgroundNoOpScanSkipsSummaryRefreshes() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            trigger: "claude-file-watch",
            hasMenuBarSnapshot: true,
            isDashboardVisible: true)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: false,
            refreshDashboard: false))
    }

    @Test("No-op scan fills a missing first menu snapshot")
    func noOpScanFillsMissingMenuSnapshot() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            trigger: "launch",
            hasMenuBarSnapshot: false,
            isDashboardVisible: false)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: true,
            refreshDashboard: false))
    }

    @Test("No-op scan requests a retry while the first snapshot is missing")
    func noOpScanRequestsMissingFirstSnapshotRetry() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            trigger: "launch",
            hasMenuBarSnapshot: false,
            isDashboardVisible: false)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: true,
            refreshDashboard: false))
    }

    @Test("Visible Dashboard fills a missing first menu snapshot through one route")
    func visibleDashboardFillsMissingMenuSnapshot() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: false,
            trigger: "launch",
            hasMenuBarSnapshot: false,
            isDashboardVisible: true)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: false,
            refreshDashboard: true))
    }

    @Test("Explicit no-op refresh chooses one visible Dashboard summary path")
    func explicitNoOpRefreshesSummaries() {
        for trigger in ["manual", "popover", "qa"] {
            let decision = AppEnvironment.scanRefreshDecision(
                didChangeReadModel: false,
                trigger: trigger,
                hasMenuBarSnapshot: true,
                isDashboardVisible: true)

            #expect(decision == ScanRefreshDecision(
                refreshMenuBar: false,
                refreshDashboard: true))
        }
    }

    @Test("Read-model changes refresh menu only while Dashboard is hidden")
    func changedScanSkipsHiddenDashboard() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: true,
            trigger: "claude-file-watch",
            hasMenuBarSnapshot: true,
            isDashboardVisible: false)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: true,
            refreshDashboard: false))
    }

    @Test("Read-model changes choose one visible Dashboard summary path")
    func changedScanRefreshesVisibleDashboard() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: true,
            trigger: "claude-file-watch",
            hasMenuBarSnapshot: true,
            isDashboardVisible: true)

        #expect(decision == ScanRefreshDecision(
            refreshMenuBar: false,
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
