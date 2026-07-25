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

    @Test("chart domain ends at the next day boundary after a midnight DST jump")
    func chartDomainEndsAtNextDayBoundaryAfterMidnightDSTJump() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let day = try #require(calendar.date(
            from: DateComponents(year: 2018, month: 11, day: 4)))
        let dayInterval = try #require(calendar.dateInterval(of: .day, for: day))

        let domain = try #require(TrendChartDomain.domain(
            for: [day],
            calendar: calendar))

        #expect(domain.lowerBound == dayInterval.start)
        #expect(domain.upperBound == dayInterval.end)
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

    @Test("cache trend leaves gaps for unavailable days but preserves zero percent")
    func cacheTrendPreservesGapsAndZeroPercent() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let daily = [
            DailyPoint(
                date: start,
                valueUSD: 0,
                tokens: 10,
                cacheUsage: CacheUsageSummary(
                    readTokens: 5, eligibleInputTokens: 10)),
            DailyPoint(
                date: start.addingTimeInterval(86_400),
                valueUSD: 0,
                tokens: 0),
            DailyPoint(
                date: start.addingTimeInterval(2 * 86_400),
                valueUSD: 0,
                tokens: 10,
                cacheUsage: CacheUsageSummary(
                    readTokens: 0, eligibleInputTokens: 10)),
            DailyPoint(
                date: start.addingTimeInterval(3 * 86_400),
                valueUSD: 0,
                tokens: 10,
                cacheUsage: CacheUsageSummary(
                    readTokens: 8, eligibleInputTokens: 10)),
        ]

        let points = CacheTrendSeriesBuilder.points(from: daily)

        #expect(points.count == 3)
        #expect(points.map(\.segment) == [1, 2, 2])
        #expect(points.map(\.rate) == [0.5, 0, 0.8])
    }
}
