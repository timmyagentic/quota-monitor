import SwiftUI
import Charts

/// Trends panel: stacked token bars by provider/model with a cache hit-rate
/// line sharing the same dates. Each selectable range uses an exact trailing
/// N × 24-hour window before its events are bucketed by local-calendar day.
struct TrendsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization
    @Environment(\.calendar) private var calendar

    let trends: DashboardTrendData
    let visibleProviders: Set<String>

    @State private var range: TrendRange = .last30d
    @State private var stackBy: TrendStack = .provider
    @State private var selectedDay: Date?
    @State private var seriesDerivation = TrendSeriesDerivationCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.trendsSectionTitle)
                    .font(.headline)
                Spacer()
            }

            controls

            if windowedDaily.isEmpty || windowedDaily.allSatisfy({ $0.tokens == 0 }) {
                Text(L10n.noData)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                let activeSeries = seriesDerivation.series(
                    for: seriesDerivationInput)
                stackedBars(activeSeries: activeSeries)
                trendLegend(activeSeries: activeSeries)
                statline
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 14)
    }

    // MARK: - controls

    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            Picker("", selection: $stackBy) {
                ForEach(TrendStack.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            HStack(spacing: 5) {
                Circle()
                    .fill(DashboardTheme.cache)
                    .frame(width: 6, height: 6)
                Text(L10n.dailyCacheHitRateTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(TrendRange.allCases) { candidate in
                    Button {
                        range = candidate
                        selectedDay = nil
                    } label: {
                        Text(candidate.label)
                            .font(.caption.weight(range == candidate ? .semibold : .regular))
                            .foregroundStyle(range == candidate ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(range == candidate
                                          ? Color.primary.opacity(0.10)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - chart

    private func stackedBars(
        activeSeries: [DailyBreakdownPoint]
    ) -> some View {
        Chart {
            ForEach(activeSeries) { point in
                BarMark(
                    x: .value(L10n.chartAxisDay, point.date, unit: .day),
                    y: .value(L10n.kpiTokens, Double(point.tokens))
                )
                .foregroundStyle(seriesColor(point))
                .cornerRadius(3)
            }

            ForEach(cacheTrendPoints) { point in
                LineMark(
                    x: .value(L10n.chartAxisDay, point.date, unit: .day),
                    y: .value(
                        L10n.cacheHitRateTitle,
                        cacheRateYValue(point.rate)),
                    series: .value("Cache segment", point.segment)
                )
                .foregroundStyle(DashboardTheme.cache)
                .lineStyle(StrokeStyle(
                    lineWidth: 2,
                    lineCap: .round,
                    lineJoin: .round))
            }

            ForEach(singletonCacheTrendPoints) { point in
                PointMark(
                    x: .value(L10n.chartAxisDay, point.date, unit: .day),
                    y: .value(
                        L10n.cacheHitRateTitle,
                        cacheRateYValue(point.rate))
                )
                .foregroundStyle(DashboardTheme.cache)
                .symbolSize(18)
            }

            if let selectedCacheTrendPoint {
                PointMark(
                    x: .value(
                        L10n.chartAxisDay,
                        selectedCacheTrendPoint.date,
                        unit: .day),
                    y: .value(
                        L10n.cacheHitRateTitle,
                        cacheRateYValue(selectedCacheTrendPoint.rate))
                )
                .foregroundStyle(DashboardTheme.cache)
                .symbolSize(34)
                .accessibilityHidden(true)
            }

            if let selection = selectedTrendSelection(in: activeSeries) {
                RuleMark(x: .value(L10n.chartAxisDay, selection.date, unit: .day))
                    .foregroundStyle(Color.primary.opacity(0.22))
                    .annotation(
                        position: .top,
                        alignment: .center,
                        spacing: 4,
                        overflowResolution: .init(x: .fit, y: .disabled)
                    ) {
                        trendTooltip(selection)
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0.0...chartTokenCeiling)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range.axisStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                                centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(compactNumber(d))
                    }
                }
            }
            AxisMarks(
                position: .leading,
                values: [0.0, chartTokenCeiling / 2.0, chartTokenCeiling]
            ) { value in
                AxisTick()
                    .foregroundStyle(DashboardTheme.cache.opacity(0.45))
                AxisValueLabel {
                    if let scaledValue = value.as(Double.self) {
                        let rate = scaledValue / chartTokenCeiling
                        Text(rate.formatted(
                            .percent.precision(.fractionLength(0))))
                            .foregroundStyle(DashboardTheme.cache)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDay)
        .frame(height: 245)
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                ForEach(accessibleDailyPoints) { day in
                    Text(accessibilityDescription(for: day))
                }
            }
        }
    }

    // MARK: - legend + tooltips

    private func trendLegend(
        activeSeries: [DailyBreakdownPoint]
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(legendRows(for: activeSeries)) { row in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(row.color)
                        .frame(width: 10, height: 10)
                    Text(row.label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(compactTokens(row.tokens))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(row.percent.formatted(.percent.precision(.fractionLength(1))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                )
            }
        }
    }

    private func trendTooltip(_ selection: TrendSelection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedDateFormatting.string(
                from: selection.date,
                style: .monthDay))
                .font(.caption.weight(.semibold))
            Text(compactTokens(selection.totalTokens))
                .font(.callout.monospacedDigit().weight(.semibold))
            ForEach(selection.rows.prefix(4)) { row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.color)
                        .frame(width: 8, height: 8)
                    Text(row.label)
                    Spacer(minLength: 12)
                    Text(compactTokens(row.tokens))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(DashboardTheme.cache)
                    .frame(width: 7, height: 7)
                Text(L10n.cacheHitRateTitle)
                Spacer(minLength: 12)
                Text(formatCacheHitRate(selection.cacheUsage.hitRate))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
        )
    }

    // MARK: - statline

    private var statline: some View {
        let today = todayUSD
        let last7d = trends.last7Days.daily.reduce(0) { $0 + $1.valueUSD }
        let last30d = trends.last30Days.daily.reduce(0) { $0 + $1.valueUSD }
        let prior30d = trends.prior30DayValueUSD

        var parts: [String] = [
            L10n.trendsTodayShort(today.formatted(.currency(code: "USD"))),
            L10n.trends7dShort(last7d.formatted(.currency(code: "USD"))),
            L10n.trends30dShort(last30d.formatted(.currency(code: "USD"))),
        ]
        if prior30d > 0.01 {
            let pct = (last30d - prior30d) / prior30d * 100
            parts.append(L10n.trendsDeltaPriorMonth(percent: pct))
        }
        return HStack {
            Text(parts.joined(separator: " · "))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - derived data

    private var activeWindow: TrendWindowSnapshot {
        trends.window(for: range.rollingWindow)
    }

    private var windowedDaily: [DailyPoint] {
        activeWindow.daily
    }

    private var windowedProviderBreakdown: [DailyBreakdownPoint] {
        activeWindow.providerBreakdown.filter {
            visibleProviders.contains($0.provider)
        }
    }

    private var windowedModelBreakdown: [DailyBreakdownPoint] {
        activeWindow.modelBreakdown.filter {
            visibleProviders.contains($0.provider)
        }
    }

    private var cacheTrendPoints: [CacheTrendPoint] {
        CacheTrendSeriesBuilder.points(from: windowedDaily)
    }

    private var singletonCacheTrendPoints: [CacheTrendPoint] {
        let counts = Dictionary(grouping: cacheTrendPoints, by: \.segment)
            .mapValues(\.count)
        return cacheTrendPoints.filter { counts[$0.segment] == 1 }
    }

    private var selectedCacheDay: DailyPoint? {
        guard let selectedDay else { return nil }
        return windowedDaily.first {
            calendar.isDate($0.date, inSameDayAs: selectedDay)
        }
    }

    private var selectedCacheTrendPoint: CacheTrendPoint? {
        guard let selectedDay else { return nil }
        return cacheTrendPoints.first {
            calendar.isDate($0.date, inSameDayAs: selectedDay)
        }
    }

    private var chartTokenCeiling: Double {
        let maxTokens = windowedDaily.map(\.tokens).max() ?? 0
        return max(Double(maxTokens) * 1.08, 1)
    }

    private func cacheRateYValue(_ rate: Double) -> Double {
        rate * chartTokenCeiling
    }

    private var accessibleDailyPoints: [DailyPoint] {
        windowedDaily.filter {
            $0.tokens > 0 || $0.cacheUsage.hitRate != nil
        }
    }

    private func accessibilityDescription(for day: DailyPoint) -> String {
        let date = LocalizedDateFormatting.string(
            from: day.date,
            style: .monthDay)
        return [
            date,
            "\(L10n.kpiTokens) \(compactTokens(day.tokens))",
            "\(L10n.dailyCacheHitRateTitle) "
                + formatCacheHitRate(day.cacheUsage.hitRate),
        ].joined(separator: " · ")
    }

    private var seriesDerivationInput: TrendSeriesDerivationInput {
        TrendSeriesDerivationInput(
            dailyExtended: windowedDaily,
            providerBreakdown: windowedProviderBreakdown,
            modelBreakdown: windowedModelBreakdown,
            rangeDays: range.days,
            grouping: stackBy.grouping,
            calendar: calendar,
            activeLanguageIdentifier: localization.currentLanguage.rawValue,
            otherLabel: L10n.trendsOtherSeries)
    }

    private var xDomain: ClosedRange<Date> {
        if let domain = TrendChartDomain.domain(
            for: windowedDaily.map(\.date),
            calendar: calendar
        ) {
            return domain
        }
        let now = Date()
        return now...now
    }

    private func selectedTrendSelection(
        in activeSeries: [DailyBreakdownPoint]
    ) -> TrendSelection? {
        guard let selectedDay else { return nil }
        let selectedStart = calendar.startOfDay(for: selectedDay)
        let rows = activeSeries
            .filter { calendar.isDate($0.date, inSameDayAs: selectedStart) }
            .map { point in
                TrendSelection.Row(
                    id: point.id,
                    label: displayLabel(point),
                    color: seriesColor(point),
                    tokens: point.tokens)
            }
            .sorted { $0.tokens > $1.tokens }
        guard !rows.isEmpty else { return nil }
        return TrendSelection(
            date: selectedStart,
            rows: rows,
            totalTokens: rows.reduce(Int64(0)) { $0 + $1.tokens },
            cacheUsage: selectedCacheDay?.cacheUsage ?? .zero)
    }

    private func legendRows(
        for activeSeries: [DailyBreakdownPoint]
    ) -> [TrendLegendRow] {
        let grouped = Dictionary(grouping: activeSeries, by: \.key)
        let total = max(activeSeries.reduce(Int64(0)) { $0 + $1.tokens }, 1)
        return grouped.map { key, rows in
            let first = rows[0]
            let tokens = rows.reduce(Int64(0)) { $0 + $1.tokens }
            return TrendLegendRow(
                key: key,
                label: displayLabel(first),
                color: seriesColor(first),
                tokens: tokens,
                percent: Double(tokens) / Double(total))
        }
        .filter { $0.tokens > 0 }
        .sorted { $0.tokens > $1.tokens }
    }

    private func seriesColor(_ point: DailyBreakdownPoint) -> Color {
        switch stackBy {
        case .provider:
            return DashboardTheme.providerColor(point.key)
        case .model:
            return DashboardTheme.modelColor(point.key)
        }
    }

    private func displayLabel(_ point: DailyBreakdownPoint) -> String {
        switch stackBy {
        case .provider:
            return DashboardTheme.providerLabel(point.key)
        case .model:
            return point.label
        }
    }

    private var todayUSD: Double {
        trends.last30Days.daily.last?.valueUSD ?? 0
    }

    private func compactTokens(_ tokens: Int64) -> String {
        tokens.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(settings.tokenFormatLocale))
    }

    private func compactNumber(_ value: Double) -> String {
        value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(settings.tokenFormatLocale))
    }

    private func formatCacheHitRate(_ rate: Double?) -> String {
        rate?.formatted(.percent.precision(.fractionLength(1))) ?? "—"
    }
}

enum TrendChartDomain {
    static func domain(
        for orderedDates: [Date],
        calendar: Calendar = .current
    ) -> ClosedRange<Date>? {
        guard let first = orderedDates.first,
              let last = orderedDates.last
        else {
            return nil
        }

        guard let firstDay = calendar.dateInterval(of: .day, for: first),
              let lastDay = calendar.dateInterval(of: .day, for: last),
              firstDay.start <= lastDay.start
        else {
            return nil
        }

        return firstDay.start...lastDay.end
    }
}

struct TrendSeriesDerivationInput: Equatable {
    let dailyExtended: [DailyPoint]
    let providerBreakdown: [DailyBreakdownPoint]
    let modelBreakdown: [DailyBreakdownPoint]
    let rangeDays: Int
    let grouping: TrendBreakdownGrouping
    let calendar: Calendar
    let activeLanguageIdentifier: String
    let otherLabel: String
}

final class TrendSeriesDerivationCache {
    private var cachedInput: TrendSeriesDerivationInput?
    private var cachedSeries: [DailyBreakdownPoint] = []
    private(set) var derivationCount = 0

    func series(
        for input: TrendSeriesDerivationInput
    ) -> [DailyBreakdownPoint] {
        guard cachedInput != input else { return cachedSeries }

        let series = TrendSeriesBuilder.activeSeries(for: input)
        cachedInput = input
        cachedSeries = series
        derivationCount += 1
        return series
    }
}

enum TrendSeriesBuilder {
    static let otherKey = "__other__"

    static func activeSeries(
        for input: TrendSeriesDerivationInput
    ) -> [DailyBreakdownPoint] {
        let calendar = input.calendar
        let days = Set(input.dailyExtended.map {
            calendar.startOfDay(for: $0.date)
        })
        let breakdown: [DailyBreakdownPoint]
        switch input.grouping {
        case .provider:
            breakdown = input.providerBreakdown
        case .model:
            breakdown = input.modelBreakdown
        }
        let raw = breakdown.filter {
            days.contains(calendar.startOfDay(for: $0.date))
        }

        guard input.grouping == .model else { return raw }
        return TrendSeriesBuilder.collapsedModelSeries(
            raw,
            otherLabel: input.otherLabel)
    }

    static func collapsedModelSeries(
        _ raw: [DailyBreakdownPoint],
        topLimit: Int = 8,
        otherLabel: String = L10n.trendsOtherSeries
    ) -> [DailyBreakdownPoint] {
        guard topLimit > 0 else {
            return collapseOther(raw, label: otherLabel)
        }
        let totals = Dictionary(grouping: raw, by: \.key)
            .mapValues { rows in rows.reduce(Int64(0)) { $0 + $1.tokens } }
        let topKeys = Set(totals
            .sorted { $0.value > $1.value }
            .prefix(topLimit)
            .map(\.key))
        let topRows = raw.filter { topKeys.contains($0.key) }
        let otherRows = collapseOther(
            raw.filter { !topKeys.contains($0.key) },
            label: otherLabel)
        return (topRows + otherRows).sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func collapseOther(
        _ rows: [DailyBreakdownPoint],
        label: String
    ) -> [DailyBreakdownPoint] {
        let grouped = Dictionary(grouping: rows, by: \.date)
        return grouped.compactMap { date, rows in
            let tokens = rows.reduce(Int64(0)) { $0 + $1.tokens }
            let value = rows.reduce(0) { $0 + $1.valueUSD }
            guard tokens > 0 || value > 0 else { return nil }
            return DailyBreakdownPoint(
                date: date,
                provider: otherKey,
                key: otherKey,
                label: label,
                valueUSD: value,
                tokens: tokens)
        }
    }
}

struct CacheTrendPoint: Identifiable, Equatable {
    let date: Date
    let rate: Double
    let segment: Int

    var id: String {
        "\(segment)-\(date.timeIntervalSinceReferenceDate)"
    }
}

enum CacheTrendSeriesBuilder {
    /// Omits days without an eligible-input denominator while keeping the
    /// observed points in one series. Swift Charts connects adjacent observed
    /// values without inventing a value (especially 0%) for an unavailable day.
    static func points(from daily: [DailyPoint]) -> [CacheTrendPoint] {
        return daily.compactMap { day in
            guard let rate = day.cacheUsage.hitRate else { return nil }
            return CacheTrendPoint(date: day.date, rate: rate, segment: 1)
        }
    }
}

private enum TrendRange: CaseIterable, Identifiable {
    case last7d
    case last30d
    case last90d
    case lastYear

    var id: Self { self }

    var days: Int {
        switch self {
        case .last7d: return 7
        case .last30d: return 30
        case .last90d: return 90
        case .lastYear: return 365
        }
    }

    var rollingWindow: RollingTrendWindow {
        switch self {
        case .last7d: return .last7Days
        case .last30d: return .last30Days
        case .last90d: return .last90Days
        case .lastYear: return .last365Days
        }
    }

    var axisStride: Int {
        switch self {
        case .last7d: return 1
        case .last30d: return 4
        case .last90d: return 14
        case .lastYear: return 45
        }
    }

    var label: String {
        switch self {
        case .last7d: return L10n.dashboardRange7d
        case .last30d: return L10n.dashboardRange30d
        case .last90d: return L10n.dashboardRange90d
        case .lastYear: return L10n.lastYear
        }
    }

    var periodLabel: String {
        switch self {
        case .last7d: return L10n.last7Days
        case .last30d: return L10n.last30Days
        case .last90d: return L10n.last90Days
        case .lastYear: return L10n.lastYear
        }
    }
}

private enum TrendStack: CaseIterable, Identifiable {
    case provider
    case model

    var id: Self { self }

    var grouping: TrendBreakdownGrouping {
        switch self {
        case .provider: return .provider
        case .model: return .model
        }
    }

    var label: String {
        switch self {
        case .provider: return L10n.dashboardStackProvider
        case .model: return L10n.dashboardStackModel
        }
    }
}

private struct TrendLegendRow: Identifiable {
    let key: String
    let label: String
    let color: Color
    let tokens: Int64
    let percent: Double

    var id: String { key }
}

private struct TrendSelection {
    struct Row: Identifiable {
        let id: String
        let label: String
        let color: Color
        let tokens: Int64
    }

    let date: Date
    let rows: [Row]
    let totalTokens: Int64
    let cacheUsage: CacheUsageSummary
}
