import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Dashboard trend series")
struct DashboardTrendSeriesTests {

    @Test("7-day chart domain includes the complete final day across DST")
    func sevenDayChartDomainIncludesCompleteFinalDayAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let first = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 2)))
        let days = try (0..<7).map { offset in
            try #require(calendar.date(
                byAdding: .day,
                value: offset,
                to: first))
        }
        let expectedTrailingBoundary = try #require(calendar.date(
            byAdding: .day,
            value: 1,
            to: days[6]))

        let domain = try #require(TrendChartDomain.domain(
            for: days,
            calendar: calendar))

        #expect(domain.lowerBound == first)
        #expect(domain.upperBound == expectedTrailingBoundary)
    }

    @Test("model trend collapse preserves non-top usage in Other")
    func modelTrendCollapsePreservesOtherUsage() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = (1...9).map { index in
            DailyBreakdownPoint(
                date: day,
                provider: "codex",
                key: "model-\(index)",
                label: "Model \(index)",
                valueUSD: Double(index),
                tokens: Int64(100 - index))
        }

        let collapsed = TrendSeriesBuilder.collapsedModelSeries(
            raw, topLimit: 8, otherLabel: "Other")
        let other = collapsed.first { $0.key == TrendSeriesBuilder.otherKey }

        #expect(collapsed.count == 9)
        #expect(other?.label == "Other")
        #expect(other?.tokens == 91)
        #expect(collapsed.reduce(Int64(0)) { $0 + $1.tokens }
                == raw.reduce(Int64(0)) { $0 + $1.tokens })
    }
}
