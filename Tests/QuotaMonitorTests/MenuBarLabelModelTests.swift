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
                                 primary: win(five), secondary: win(seven), additional: [])
    }

    private func claudeSnapshot(five: Double?, seven: Double?) -> ClaudeUsageSnapshot {
        func win(_ p: Double?) -> ClaudeUsageSnapshot.Window? {
            p.map { ClaudeUsageSnapshot.Window(usedPercent: $0, resetAt: Date(), windowDuration: 18000) }
        }
        return ClaudeUsageSnapshot(capturedAt: Date(), tier: "pro",
                                   fiveHour: win(five), sevenDay: win(seven),
                                   sevenDayOpus: nil, sevenDaySonnet: nil)
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
    func providerWithNoNumbersDropped() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex"], enabledProviders: ["codex"],
            rateLimits: codexSnapshot(five: nil, seven: nil), claudeUsage: nil,
            displayMode: .used)
        #expect(rows.isEmpty)
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
    func nilSnapshotsYieldNoRows() {
        let rows = MenuBarLabelModel.rows(
            iconProviders: ["codex", "claude"], enabledProviders: ["codex", "claude"],
            rateLimits: nil, claudeUsage: nil, displayMode: .used)
        #expect(rows.isEmpty)
    }
}
