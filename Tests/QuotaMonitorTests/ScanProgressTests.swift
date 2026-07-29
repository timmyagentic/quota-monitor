import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Scan progress")
struct ScanProgressTests {

    @Test("aggregates provider progress for the menu-bar progress bar")
    func aggregateProviderProgress() {
        let progress = AppEnvironment.aggregateScanProgress(
            [
                "codex": ScanProviderProgress(
                    completedFiles: 2,
                    totalFiles: 5,
                    currentFile: "codex-rollout.jsonl"),
                "claude": ScanProviderProgress(
                    completedFiles: 1,
                    totalFiles: 3,
                    currentFile: nil),
            ],
            phase: .indexing)

        #expect(progress.phase == .indexing)
        #expect(progress.completedFiles == 3)
        #expect(progress.totalFiles == 8)
        #expect(progress.currentFile == "codex-rollout.jsonl")
        #expect(abs((progress.fraction ?? 0) - 0.375) < 0.0001)
    }

    @Test("unknown totals keep a determinate count but no fraction")
    func aggregateUnknownTotal() {
        let progress = AppEnvironment.aggregateScanProgress(
            [
                "codex": ScanProviderProgress(
                    completedFiles: 0,
                    totalFiles: 0,
                    currentFile: nil)
            ],
            phase: .discovering)

        #expect(progress.phase == .discovering)
        #expect(progress.completedFiles == 0)
        #expect(progress.totalFiles == 0)
        #expect(progress.currentFile == nil)
        #expect(progress.fraction == nil)
    }

    @Test("only launch and onboarding scans use the detailed progress row")
    func detailedProgressIsReservedForInitialScans() {
        #expect(AppEnvironment.scanPresentation(forTrigger: "launch") == .detailedProgress)
        #expect(AppEnvironment.scanPresentation(forTrigger: "onboarding") == .detailedProgress)

        for trigger in ["manual", "popover", "claude-file-watch",
                        "claude-file-watch-trailing", "history-root-change"] {
            #expect(
                AppEnvironment.scanPresentation(forTrigger: trigger) == .compactActivity,
                "Expected \(trigger) to use compact scan feedback")
        }
    }
}
