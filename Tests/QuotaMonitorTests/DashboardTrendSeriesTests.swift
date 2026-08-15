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

    @Test("active provider series preserves ordering and local-day filtering across DST")
    func activeProviderSeriesPreservesOrderingAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let day = try #require(calendar.date(
            from: DateComponents(year: 2018, month: 11, day: 4)))
        let interval = try #require(calendar.dateInterval(of: .day, for: day))
        let firstDate = interval.start.addingTimeInterval(12 * 60 * 60)
        let secondDate = interval.start.addingTimeInterval(18 * 60 * 60)
        let outsideDate = interval.end.addingTimeInterval(60 * 60)
        let provider = [
            breakdown(date: firstDate, key: "claude", tokens: 20),
            breakdown(date: secondDate, key: "codex", tokens: 10),
            breakdown(date: outsideDate, key: "outside", tokens: 99),
        ]
        let input = derivationInput(
            daily: [DailyPoint(date: interval.start, valueUSD: 0, tokens: 30)],
            calendar: calendar,
            provider: provider)

        let series = TrendSeriesBuilder.activeSeries(for: input)

        #expect(series.map(\.key) == ["claude", "codex"])
        #expect(series.map(\.date) == [firstDate, secondDate])
        #expect(series.reduce(Int64(0)) { $0 + $1.tokens } == 30)
    }

    @Test("active series retains the partial first day of a rolling window")
    func activeSeriesRetainsPartialFirstRollingDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 16)))
        let days = try (0...30).map { offset in
            try #require(calendar.date(
                byAdding: .day, value: offset, to: first))
        }
        let daily = days.map {
            DailyPoint(date: $0, valueUSD: 1, tokens: 10)
        }
        let provider = days.map {
            breakdown(date: $0, key: "codex", tokens: 10)
        }
        let input = derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider,
            rangeDays: 30)

        let series = TrendSeriesBuilder.activeSeries(for: input)

        #expect(series.count == 31,
                "30 × 24 hours can intersect 31 local calendar dates")
        #expect(series.first?.date == first)
        #expect(series.reduce(Int64(0)) { $0 + $1.tokens } == 310)
    }

    @Test("selected-day scrubbing reuses one active-series derivation")
    func selectedDayScrubbingReusesDerivedSeries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 1)))
        let days = try (0..<30).map { offset in
            try #require(calendar.date(byAdding: .day, value: offset, to: start))
        }
        let daily = days.map {
            DailyPoint(date: $0, valueUSD: 0, tokens: 45)
        }
        let models = days.flatMap { day in
            (1...9).map { index in
                breakdown(
                    date: day,
                    key: "model-\(index)",
                    label: "Model \(index)",
                    tokens: Int64(index))
            }
        }
        let input = derivationInput(
            daily: daily,
            calendar: calendar,
            model: models,
            grouping: .model)
        let derivation = TrendSeriesDerivationCache()

        for selectedDay in days {
            let rows = derivation.series(for: input)
                .filter { calendar.isDate($0.date, inSameDayAs: selectedDay) }
                .sorted { $0.tokens > $1.tokens }
            #expect(rows.count == 9)
            #expect(rows.reduce(Int64(0)) { $0 + $1.tokens } == 45)
        }

        #expect(derivation.derivationCount == 1)
    }

    @Test("series derivation invalidates every relevant dataflow input")
    func seriesDerivationInvalidatesRelevantInputs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 9)))
        let daily = [DailyPoint(date: day, valueUSD: 1, tokens: 45)]
        let provider = [breakdown(date: day, key: "codex", tokens: 45)]
        let models = (1...9).map { index in
            breakdown(
                date: day,
                key: "model-\(index)",
                label: "Model \(index)",
                tokens: Int64(index))
        }
        let derivation = TrendSeriesDerivationCache()

        let initial = derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider,
            model: models,
            grouping: .model)
        let initialSeries = derivation.series(for: initial)
        #expect(initialSeries.first { $0.key == TrendSeriesBuilder.otherKey }?.label == "Other")
        #expect(derivation.derivationCount == 1)

        _ = derivation.series(for: derivationInput(
            daily: [DailyPoint(date: day, valueUSD: 2, tokens: 45)],
            calendar: calendar,
            provider: provider,
            model: models,
            grouping: .model))
        #expect(derivation.derivationCount == 2)

        _ = derivation.series(for: derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider + [breakdown(date: day, key: "claude", tokens: 1)],
            model: models,
            grouping: .model))
        #expect(derivation.derivationCount == 3)

        _ = derivation.series(for: derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider,
            model: models + [breakdown(date: day, key: "model-10", tokens: 46)],
            grouping: .model))
        #expect(derivation.derivationCount == 4)

        _ = derivation.series(for: derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider,
            model: models,
            rangeDays: 7,
            grouping: .model))
        #expect(derivation.derivationCount == 5)

        let providerSeries = derivation.series(for: derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider,
            model: models,
            grouping: .provider))
        #expect(providerSeries.map(\.key) == ["codex"])
        #expect(derivation.derivationCount == 6)

        var changedCalendar = calendar
        changedCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        _ = derivation.series(for: derivationInput(
            daily: daily,
            calendar: changedCalendar,
            provider: provider,
            model: models,
            grouping: .model))
        #expect(derivation.derivationCount == 7)

        let localizedSeries = derivation.series(for: derivationInput(
            daily: daily,
            calendar: calendar,
            provider: provider,
            model: models,
            grouping: .model,
            activeLanguageIdentifier: "zh-Hans",
            otherLabel: "其他"))
        #expect(localizedSeries.first {
            $0.key == TrendSeriesBuilder.otherKey
        }?.label == "其他")
        #expect(derivation.derivationCount == 8)
    }

    @Test("cache trend connects observations without inventing zero percent")
    func cacheTrendConnectsObservationsAndPreservesZeroPercent() {
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
        #expect(points.map(\.segment) == [1, 1, 1])
        #expect(points.map(\.rate) == [0.5, 0, 0.8])
    }

    private func derivationInput(
        daily: [DailyPoint],
        calendar: Calendar,
        provider: [DailyBreakdownPoint] = [],
        model: [DailyBreakdownPoint] = [],
        rangeDays: Int = 30,
        grouping: TrendBreakdownGrouping = .provider,
        activeLanguageIdentifier: String = "en",
        otherLabel: String = "Other"
    ) -> TrendSeriesDerivationInput {
        TrendSeriesDerivationInput(
            dailyExtended: daily,
            providerBreakdown: provider,
            modelBreakdown: model,
            rangeDays: rangeDays,
            grouping: grouping,
            calendar: calendar,
            activeLanguageIdentifier: activeLanguageIdentifier,
            otherLabel: otherLabel)
    }

    private func breakdown(
        date: Date,
        key: String,
        label: String? = nil,
        tokens: Int64
    ) -> DailyBreakdownPoint {
        DailyBreakdownPoint(
            date: date,
            provider: key,
            key: key,
            label: label ?? key,
            valueUSD: Double(tokens) / 100,
            tokens: tokens)
    }
}
