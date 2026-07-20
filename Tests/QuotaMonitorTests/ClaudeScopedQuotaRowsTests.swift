import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Claude model-scoped weekly quota rows", .serialized)
struct ClaudeScopedQuotaRowsTests {
    private let resetAt = Date(timeIntervalSince1970: 1_777_600_000)

    private func window(_ usedPercent: Double) -> ClaudeUsageSnapshot.Window {
        .init(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDuration: 7 * 86400)
    }

    private func snapshot(
        opus: Double? = nil,
        sonnet: Double? = nil,
        scoped: [ClaudeUsageSnapshot.WeeklyScopedLimit] = []
    ) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000),
            tier: "max20x",
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: opus.map { window($0) },
            sevenDaySonnet: sonnet.map { window($0) },
            weeklyScoped: scoped)
    }

    @Test("structured Fable remains visible at 0%; legacy rows keep noise filter")
    func fableAtZeroStillVisible() {
        let fable = ClaudeUsageSnapshot.WeeklyScopedLimit(
            key: "fable",
            window: window(0))
        let rows = ClaudeScopedQuotaRows.visibleRows(
            for: snapshot(opus: 0.4, sonnet: 0.6, scoped: [fable]))

        #expect(rows.map(\.key) == ["fable", "sonnet"])
        #expect(rows.first?.displayName == "Fable 5")
        #expect(rows.first?.window.usedPercent == 0)
    }

    @Test("legacy model-only noise does not activate the OAuth branch")
    func legacyNoiseDoesNotActivateOAuthBranch() {
        let snap = snapshot(opus: 0.5, sonnet: 0.4)

        #expect(ClaudeScopedQuotaRows.visibleRows(for: snap).isEmpty)
        #expect(!snap.hasRenderableQuotaWindow)
    }

    @Test("visible legacy and zero-percent structured rows activate the OAuth branch")
    func visibleModelRowsActivateOAuthBranch() {
        let legacy = snapshot(opus: 0.6)
        let structured = snapshot(scoped: [
            .init(key: "fable", window: window(0)),
        ])

        #expect(legacy.hasRenderableQuotaWindow)
        #expect(structured.hasRenderableQuotaWindow)
    }

    @Test("structured entry wins over duplicate legacy model field")
    func structuredEntryWinsOverLegacyDuplicate() {
        let structuredOpus = ClaudeUsageSnapshot.WeeklyScopedLimit(
            key: "opus",
            displayName: "Opus",
            window: window(11))
        let snap = snapshot(opus: 99, scoped: [structuredOpus])

        let rows = ClaudeScopedQuotaRows.visibleRows(for: snap)
        let persisted = ClaudeScopedQuotaRows.persistedRows(for: snap)

        #expect(rows.count == 1)
        #expect(rows.first?.key == "opus")
        #expect(rows.first?.window.usedPercent == 11)
        #expect(persisted.count == 1)
        #expect(persisted.first?.limitName == "scoped:Opus")
        #expect(persisted.first?.window.usedPercent == 11)
    }

    @Test("Fable aliases normalize to the stable database key")
    func fableAliasesNormalize() {
        let canonical = ClaudeUsageSnapshot.WeeklyScopedLimit.canonicalKey
        #expect(canonical("Fable") == "fable")
        #expect(canonical("Fable 5") == "fable")
        #expect(canonical("Claude Fable 5") == "fable")
    }

    @Test("Fable weekly title is bilingual")
    func fableTitleIsBilingual() {
        let english = LocalizationTestSupport.withLanguage(.english) {
            L10n.quotaCardTitle7dModel("Fable 5")
        }
        let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            L10n.quotaCardTitle7dModel("Fable 5")
        }

        #expect(english == "7-day · Fable 5")
        #expect(chinese == "7 天 · Fable 5")
    }
}
