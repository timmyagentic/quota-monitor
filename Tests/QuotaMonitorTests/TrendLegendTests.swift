import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Trend model legend hierarchy")
struct TrendLegendTests {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ model: String, tier: TrendSpeedTier?, tokens: Int64,
                       dayOffset: Double = 0) -> DailyBreakdownPoint {
        DailyBreakdownPoint(date: day.addingTimeInterval(dayOffset * 86_400),
            provider: "codex", key: tier.map { TrendSpeedTier.seriesKey(modelID: model, tier: $0) } ?? model,
            label: model, valueUSD: 0, tokens: tokens, modelID: model, speedTier: tier)
    }

    @Test("model parents sum every day and tier while children keep the window share")
    func parentsPreserveTotalsAndShares() throws {
        let series = [point("Astra", tier: .ultrafast, tokens: 30),
                      point("Astra", tier: .standard, tokens: 20),
                      point("Astra", tier: .fast, tokens: 10),
                      point("Astra", tier: .standard, tokens: 20, dayOffset: 1),
                      point("Sol", tier: .standard, tokens: 20)]
        let rows = TrendLegendBuilder.rows(for: series, grouping: .model)
        #expect(rows.map(\.label) == ["Astra", "Sol"])
        #expect(rows.map(\.tokens) == [80, 20])
        #expect(rows.map(\.percent) == [0.8, 0.2])
        #expect(rows.allSatisfy { $0.speedTier == nil })
        let astra = try #require(rows.first)
        #expect(astra.children.compactMap(\.speedTier) == [.standard, .fast, .ultrafast])
        #expect(astra.children.map(\.tokens) == [40, 10, 30])
        #expect(astra.children.map(\.percent) == [0.4, 0.1, 0.3])
        #expect(astra.children.reduce(Int64(0)) { $0 + $1.tokens } == astra.tokens)
        #expect(rows.last?.children.count == 1)
    }

    @Test("untiered models and Other stay flat and zero rows cannot create empty groups")
    func untieredAndEmptyRows() {
        let other = DailyBreakdownPoint(date: day, provider: TrendSeriesBuilder.otherKey,
            key: TrendSeriesBuilder.otherKey, label: "Other", valueUSD: 0, tokens: 15)
        let rows = TrendLegendBuilder.rows(for: [point("Claude", tier: nil, tokens: 35),
            point("Zero", tier: .fast, tokens: 0), other], grouping: .model)
        #expect(rows.map(\.tokens) == [35, 15])
        #expect(rows.allSatisfy { $0.children.isEmpty })
        #expect(rows.reduce(Int64(0)) { $0 + $1.tokens } == 50)
        #expect(TrendLegendBuilder.rows(for: [], grouping: .model).isEmpty)
    }

    @Test("provider grouping keeps a flat legend and refreshed windows replace totals")
    func providersAndRefresh() {
        let provider = [DailyBreakdownPoint(date: day, provider: "codex", key: "codex",
            label: "Codex", valueUSD: 0, tokens: 60),
            DailyBreakdownPoint(date: day, provider: "claude", key: "claude",
            label: "Claude", valueUSD: 0, tokens: 40)]
        let rows = TrendLegendBuilder.rows(for: provider, grouping: .provider)
        #expect(rows.map(\.key) == ["codex", "claude"])
        #expect(rows.map(\.percent) == [0.6, 0.4])
        #expect(rows.allSatisfy { $0.children.isEmpty && $0.speedTier == nil })
        let refreshed = TrendLegendBuilder.rows(for: [point("Sol", tier: .flex, tokens: 5)], grouping: .model)
        #expect(refreshed.count == 1)
        #expect(refreshed.first?.tokens == 5)
        #expect(refreshed.first?.percent == 1)
        #expect(refreshed.first?.children.first?.speedTier == .flex)
    }
}
