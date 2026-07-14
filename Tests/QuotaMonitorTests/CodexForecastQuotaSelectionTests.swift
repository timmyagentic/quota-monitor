import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex forecast quota selection")
struct CodexForecastQuotaSelectionTests {
    @Test("weekly-only live snapshot does not revive stored five-hour data")
    func liveSnapshotWinsAsAWhole() {
        let now = Date(timeIntervalSince1970: 1_784_050_000)
        let weekly = RateLimitSnapshot.Window(
            usedPercent: 64,
            windowDuration: 604_800,
            resetAt: now.addingTimeInterval(5 * 86_400))
        let live = RateLimitSnapshot(
            capturedAt: now,
            planType: "pro",
            primary: nil,
            secondary: weekly,
            additional: [],
            resetCreditsAvailable: nil)
        let stored = CodexQuotaSnapshot(
            primary: storedWindow("primary", usedPercent: 11, now: now),
            secondary: storedWindow("secondary", usedPercent: 3, now: now),
            burn: [:])

        let selection = CodexForecastQuotaSelection.make(
            live: live,
            stored: stored)

        #expect(selection.primary == nil)
        #expect(selection.secondary?.usedPercent == 64)
    }

    @Test("stored snapshot is used only when the live snapshot is absent")
    func storedSnapshotIsWholeFallback() {
        let now = Date(timeIntervalSince1970: 1_784_050_000)
        let stored = CodexQuotaSnapshot(
            primary: storedWindow("primary", usedPercent: 11, now: now),
            secondary: storedWindow("secondary", usedPercent: 3, now: now),
            burn: [:])

        let selection = CodexForecastQuotaSelection.make(
            live: nil,
            stored: stored)

        #expect(selection.primary?.usedPercent == 11)
        #expect(selection.secondary?.usedPercent == 3)
    }

    private func storedWindow(
        _ bucket: String,
        usedPercent: Double,
        now: Date
    ) -> CodexQuotaWindow {
        CodexQuotaWindow(
            bucket: bucket,
            sourceKind: "live",
            planType: "pro",
            sampleAt: now,
            windowStart: nil,
            resetsAt: now.addingTimeInterval(bucket == "primary" ? 18_000 : 604_800),
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent)
    }
}
