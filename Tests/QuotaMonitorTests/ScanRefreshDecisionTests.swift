import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Post-scan refresh decisions")
struct ScanRefreshDecisionTests {

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

    @Test("Explicit no-op refresh recomputes time-dependent summaries")
    func explicitNoOpRefreshesSummaries() {
        for trigger in ["manual", "popover", "qa"] {
            let decision = AppEnvironment.scanRefreshDecision(
                didChangeReadModel: false,
                trigger: trigger,
                hasMenuBarSnapshot: true,
                isDashboardVisible: true)

            #expect(decision == ScanRefreshDecision(
                refreshMenuBar: true,
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

    @Test("Read-model changes refresh both visible summary surfaces")
    func changedScanRefreshesVisibleDashboard() {
        let decision = AppEnvironment.scanRefreshDecision(
            didChangeReadModel: true,
            trigger: "claude-file-watch",
            hasMenuBarSnapshot: true,
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

    @Test("Deferred source observability survives provider report merging")
    func deferredSourcesMergeWithoutBecomingImportErrors() {
        let firstDeferredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let codex = ImportEngine.ScanReport(
            scannedFiles: 1,
            changedFiles: 1,
            importedSessions: 0,
            importedEvents: 0,
            importedRateLimitSamples: 0,
            errors: [],
            deferredSources: [
                ImportEngine.ScanReport.DeferredSource(
                    provider: "codex",
                    sourcePath: "/codex/stuck.jsonl",
                    sessionId: "stuck",
                    reason: "boundary_changed",
                    consecutiveCount: 4,
                    firstDeferredAt: firstDeferredAt,
                    checkpointBytes: 843_500,
                    currentBytes: 47_537_329,
                    isPersistent: true)
            ])

        let merged = AppEnvironment.mergeScanReports(codex, .empty)

        #expect(merged.errors.isEmpty)
        #expect(merged.deferredSourceCount == 1)
        #expect(merged.consecutiveDeferredCount == 4)
        #expect(merged.firstDeferredAt == firstDeferredAt)
        #expect(merged.persistentDeferredSourceCount == 1)
        #expect(merged.hasPersistentDeferredSources)
        #expect(!merged.didChangeReadModel)
    }

    @Test("Claude-only scans retain an unresolved Codex deferral")
    func scopedScanRetainsUnscannedProviderDeferral() {
        let previous = deferredCodexReport()
        let claude = ImportEngine.ScanReport(
            scannedFiles: 1,
            changedFiles: 0,
            importedSessions: 0,
            importedEvents: 0,
            importedRateLimitSamples: 0,
            errors: [])

        let displayed = AppEnvironment.preservingUnscannedDeferrals(
            current: claude,
            previous: previous,
            scannedProviders: ["claude"],
            enabledProviders: ["codex", "claude"])

        #expect(displayed.deferredSources == previous.deferredSources)
        #expect(displayed.scannedFiles == 1)
    }

    @Test("A Codex scan owns and clears its previous deferral")
    func scannedProviderClearsResolvedDeferral() {
        let displayed = AppEnvironment.preservingUnscannedDeferrals(
            current: .empty,
            previous: deferredCodexReport(),
            scannedProviders: ["codex"],
            enabledProviders: ["codex", "claude"])

        #expect(displayed.deferredSources.isEmpty)
    }

    @Test("Disabling Codex drops its stale deferral")
    func disabledProviderClearsDeferral() {
        let displayed = AppEnvironment.preservingUnscannedDeferrals(
            current: .empty,
            previous: deferredCodexReport(),
            scannedProviders: ["claude"],
            enabledProviders: ["claude"])

        #expect(displayed.deferredSources.isEmpty)
    }

    @Test("Codex rebuild retry delay confirms stability then backs off")
    func codexRebuildRetryDelayPolicy() {
        let changed = deferredCodexReport(
            reason: "head_changed", consecutiveCount: 1)
        let incomplete = deferredCodexReport(
            reason: "incomplete_tail", consecutiveCount: 5)
        let longIncomplete = deferredCodexReport(
            reason: "incomplete_tail", consecutiveCount: 100)
        let missing = deferredCodexReport(
            reason: "source_missing", consecutiveCount: 5)

        #expect(AppEnvironment.codexRebuildFollowUpDelay(
            for: changed.deferredSources)
            == ImportEngine.defaultRebuildStabilityInterval + 0.5)
        #expect(AppEnvironment.codexRebuildFollowUpDelay(
            for: incomplete.deferredSources) == 40)
        #expect(AppEnvironment.codexRebuildFollowUpDelay(
            for: longIncomplete.deferredSources) == 300)
        #expect(AppEnvironment.codexRebuildFollowUpDelay(
            for: missing.deferredSources) == 40)
        #expect(AppEnvironment.codexRebuildFollowUpDelay(for: []) == nil)
        #expect(AppEnvironment.codexRebuildScanFailureBackoff(
            consecutiveFailureCount: 1) == 5)
        #expect(AppEnvironment.codexRebuildScanFailureBackoff(
            consecutiveFailureCount: 4) == 40)
        #expect(AppEnvironment.codexRebuildScanFailureBackoff(
            consecutiveFailureCount: 100) == 300)
    }

    @Test("Only Codex recovery scans re-arm after a scan-level failure")
    func codexRebuildFailureRearmPolicy() {
        #expect(AppEnvironment.shouldRearmCodexRebuildAfterScanFailure(
            codexWasRequested: true,
            trigger: "codex-rebuild-follow-up",
            previousReport: nil))
        #expect(!AppEnvironment.shouldRearmCodexRebuildAfterScanFailure(
            codexWasRequested: false,
            trigger: "codex-rebuild-follow-up",
            previousReport: nil))
        #expect(!AppEnvironment.shouldRearmCodexRebuildAfterScanFailure(
            codexWasRequested: true,
            trigger: "manual",
            previousReport: nil))
        #expect(AppEnvironment.shouldRearmCodexRebuildAfterScanFailure(
            codexWasRequested: true,
            trigger: "manual",
            previousReport: deferredCodexReport()))
    }

    private func deferredCodexReport(
        reason: String = "boundary_changed",
        consecutiveCount: Int = 4
    ) -> ImportEngine.ScanReport {
        ImportEngine.ScanReport(
            scannedFiles: 1,
            changedFiles: 1,
            importedSessions: 0,
            importedEvents: 0,
            importedRateLimitSamples: 0,
            errors: [],
            deferredSources: [
                ImportEngine.ScanReport.DeferredSource(
                    provider: "codex",
                    sourcePath: "/codex/stuck.jsonl",
                    sessionId: "stuck",
                    reason: reason,
                    consecutiveCount: consecutiveCount,
                    firstDeferredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    checkpointBytes: 843_500,
                    currentBytes: 47_537_329,
                    isPersistent: consecutiveCount >= 3)
            ])
    }
}

@MainActor
@Suite("Codex rebuild follow-up scheduling")
struct CodexRebuildFollowUpSchedulingTests {
    @Test("A deferred Codex scan arms one automatic follow-up")
    func deferredScanSchedulesFollowUp() {
        let env = AppEnvironment(startBackgroundTasks: false)
        let report = ImportEngine.ScanReport(
            scannedFiles: 1,
            changedFiles: 1,
            importedSessions: 0,
            importedEvents: 0,
            importedRateLimitSamples: 0,
            errors: ["rebuild did not commit"],
            deferredSources: [
                ImportEngine.ScanReport.DeferredSource(
                    provider: "codex",
                    sourcePath: "/codex/stuck.jsonl",
                    sessionId: "stuck",
                    reason: "head_changed",
                    consecutiveCount: 1,
                    firstDeferredAt: Date(),
                    checkpointBytes: 100,
                    currentBytes: 200,
                    isPersistent: false)
            ])

        env.updateCodexRebuildFollowUp(
            report: report, codexWasScanned: true)

        #expect(env._codexRebuildFollowUpIsScheduledForTest)
        #expect(env._codexRebuildFollowUpFailureCountForTest == 1)
        env.cancelCodexRebuildFollowUp()
        #expect(!env._codexRebuildFollowUpIsScheduledForTest)
        #expect(env._codexRebuildFollowUpFailureCountForTest == 0)
    }

    @Test("A scan-level failure re-arms one bounded follow-up")
    func scanLevelFailureRearmsFollowUp() {
        let env = AppEnvironment(startBackgroundTasks: false)

        env.rearmCodexRebuildFollowUpAfterScanFailure(previousReport: nil)
        env.rearmCodexRebuildFollowUpAfterScanFailure(previousReport: nil)

        #expect(env._codexRebuildFollowUpIsScheduledForTest)
        #expect(env._codexRebuildFollowUpFailureCountForTest == 2)

        env.updateCodexRebuildFollowUp(
            report: .empty, codexWasScanned: true)
        #expect(!env._codexRebuildFollowUpIsScheduledForTest)
        #expect(env._codexRebuildFollowUpFailureCountForTest == 0)
    }

    @Test("An unrelated provider scan does not alter Codex scheduling")
    func unrelatedScanDoesNotScheduleFollowUp() {
        let env = AppEnvironment(startBackgroundTasks: false)

        env.updateCodexRebuildFollowUp(
            report: .empty, codexWasScanned: false)

        #expect(!env._codexRebuildFollowUpIsScheduledForTest)
    }
}
