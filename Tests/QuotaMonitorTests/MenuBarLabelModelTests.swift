import Foundation
import Testing
@testable import QuotaMonitor

/// Pure row-selection logic for the menu-bar label, extracted from the old
/// `MenuBarLabelView`. Decides which providers show, their 5h/7d percent
/// strings (honoring used-vs-remaining display mode), and the CX/CC tags.
@Suite("Menu-bar label model")
struct MenuBarLabelModelTests {

    private func codexSnapshot(five: Double?, seven: Double?) -> RateLimitSnapshot {
        func win(_ p: Double?) -> RateLimitSnapshot.Window? {
            p.map { RateLimitSnapshot.Window(usedPercent: $0, windowDuration: 18000, resetAt: Date()) }
        }
        return RateLimitSnapshot(capturedAt: Date(), planType: "pro",
                                 primary: win(five), secondary: win(seven),
                                 additional: [], resetCreditsAvailable: nil)
    }

    private func claudeSnapshot(five: Double?, seven: Double?) -> ClaudeUsageSnapshot {
        func win(_ p: Double?) -> ClaudeUsageSnapshot.Window? {
            p.map { ClaudeUsageSnapshot.Window(usedPercent: $0, resetAt: Date(), windowDuration: 18000) }
        }
        return ClaudeUsageSnapshot(capturedAt: Date(), tier: "pro",
                                   fiveHour: win(five), sevenDay: win(seven),
                                   sevenDayOpus: nil, sevenDaySonnet: nil)
    }

    private func codexQuota(five: Double?, seven: Double?) -> CodexQuotaSnapshot {
        func win(_ bucket: String, _ p: Double?) -> CodexQuotaWindow? {
            p.map {
                CodexQuotaWindow(
                    bucket: bucket,
                    sourceKind: "jsonl",
                    planType: "pro",
                    sampleAt: Date(),
                    windowStart: nil,
                    resetsAt: Date().addingTimeInterval(3600),
                    usedPercent: $0,
                    remainingPercent: 100 - $0)
            }
        }
        return CodexQuotaSnapshot(
            primary: win("primary", five),
            secondary: win("secondary", seven),
            burn: [:])
    }

    @Test
    func singleCodexNoTagUsedPercent() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"], enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: 8, seven: 94), claudeUsage: nil,
            displayMode: .used)
        #expect(rows == [.init(tag: "CX", fiveHour: "8%", sevenDay: "94%")])
    }

    @Test
    func remainingModeInverts() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"], enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: 8, seven: 94), claudeUsage: nil,
            displayMode: .remaining)
        #expect(rows == [.init(tag: "CX", fiveHour: "92%", sevenDay: "6%")])
    }

    @Test
    func bothProvidersOrderedCodexFirst() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex", "claude"], enabledProviders: ["codex", "claude"],
            rateLimits: codexSnapshot(five: 10, seven: 20),
            claudeUsage: claudeSnapshot(five: 50, seven: 12),
            displayMode: .used)
        #expect(rows == [
            .init(tag: "CX", fiveHour: "10%", sevenDay: "20%"),
            .init(tag: "CC", fiveHour: "50%", sevenDay: "12%")
        ])
    }

    @Test
    func disabledProviderExcludedEvenIfIconSelected() {
        // Icon intent includes claude but it's not enabled → excluded.
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex", "claude"], enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: 10, seven: 20),
            claudeUsage: claudeSnapshot(five: 50, seven: 12),
            displayMode: .used)
        #expect(rows == [.init(tag: "CX", fiveHour: "10%", sevenDay: "20%")])
    }

    @Test
    func providerWithNoNumbersShowsDashes() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"], enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: nil, seven: nil), claudeUsage: nil,
            displayMode: .used)
        #expect(rows == [.init(tag: "CX", fiveHour: "--", sevenDay: "--")])
    }

    @Test
    func missingWindowShowsDoubleDash() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"], enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: 8, seven: nil), claudeUsage: nil,
            displayMode: .used)
        #expect(rows == [.init(tag: "CX", fiveHour: "8%", sevenDay: "--")])
    }

    @Test
    func nilSnapshotsYieldDashRowsForSelectedProviders() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex", "claude"], enabledProviders: ["codex", "claude"],
            rateLimits: nil, claudeUsage: nil, displayMode: .used)
        #expect(rows == [
            .init(tag: "CX", fiveHour: "--", sevenDay: "--"),
            .init(tag: "CC", fiveHour: "--", sevenDay: "--")
        ])
    }

    @Test
    func noSelectedIconProvidersYieldsNoRowsForGaugeFallback() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: [],
            enabledProviders: ["codex", "claude"],
            rateLimits: codexSnapshot(five: 8, seven: 1),
            claudeUsage: claudeSnapshot(five: 40, seven: 12),
            displayMode: .used)

        #expect(rows.isEmpty)
    }

    @Test
    func codexQuotaSnapshotBackfillsWhenLiveRateLimitsAreMissing() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"],
            enabledProviders: ["codex"],
            rateLimits: nil,
            claudeUsage: nil,
            codexQuota: codexQuota(five: 11, seven: 2),
            displayMode: .used)

        #expect(rows == [.init(tag: "CX", fiveHour: "11%", sevenDay: "2%")])
    }

    @Test
    func liveRateLimitsWinOverDashboardQuotaFallback() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"],
            enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: 8, seven: 1),
            claudeUsage: nil,
            codexQuota: codexQuota(five: 11, seven: 2),
            displayMode: .used)

        #expect(rows == [.init(tag: "CX", fiveHour: "8%", sevenDay: "1%")])
    }
}
