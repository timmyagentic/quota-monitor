import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Claude provider quota visibility")
struct ClaudeProviderQuotaVisibilityTests {
    private let resetAt = Date(timeIntervalSince1970: 1_777_000_000)

    private func window(_ usedPercent: Double) -> ClaudeUsageSnapshot.Window {
        ClaudeUsageSnapshot.Window(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDuration: 604_800)
    }

    private func snapshot(
        fiveHour: ClaudeUsageSnapshot.Window? = nil,
        staleFiveHour: ClaudeUsageSnapshot.Window? = nil,
        sevenDay: ClaudeUsageSnapshot.Window? = nil,
        sevenDayOpus: ClaudeUsageSnapshot.Window? = nil,
        sevenDaySonnet: ClaudeUsageSnapshot.Window? = nil
    ) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_776_900_000),
            tier: "max5x",
            fiveHour: fiveHour,
            staleFiveHour: staleFiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet)
    }

    @Test("Sonnet-only quota keeps Claude card on OAuth rows even at 0 percent")
    func sonnetOnlyQuotaKeepsOAuthRowsAtZeroPercent() {
        let usage = snapshot(sevenDaySonnet: window(0))

        #expect(ClaudeProviderQuotaVisibility.hasRenderableOAuthRows(usage))
        #expect(ClaudeProviderQuotaVisibility.hasRenderableModelQuota(usage.sevenDaySonnet))
    }

    @Test("missing Sonnet-only quota is not renderable")
    func missingSonnetOnlyQuotaIsNotRenderable() {
        let usage = snapshot(sevenDay: window(12), sevenDaySonnet: nil)

        #expect(ClaudeProviderQuotaVisibility.hasRenderableOAuthRows(usage))
        #expect(!ClaudeProviderQuotaVisibility.hasRenderableModelQuota(usage.sevenDaySonnet))
    }

    @Test("empty OAuth snapshot falls back to local Claude rows")
    func emptyOAuthSnapshotFallsBack() {
        let usage = snapshot()

        #expect(!ClaudeProviderQuotaVisibility.hasRenderableOAuthRows(usage))
    }
}
