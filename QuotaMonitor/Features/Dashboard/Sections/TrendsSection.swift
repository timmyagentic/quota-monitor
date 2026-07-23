import SwiftUI
import Charts

/// Trends panel: stacked token bars by provider/model plus a daily cache
/// hit-rate rail on the same date range. The summary line still reports spend
/// over today / 7d / 30d so the panel remains useful for both tokens and cost.
struct TrendsSection: View {
    @Environment(SettingsStore.self) private var settings

    let dailyExtended: [DailyPoint]
    let providerBreakdown: [DailyBreakdownPoint]
    let modelBreakdown: [DailyBreakdownPoint]

    @State private var range: TrendRange = .last30d
    @State private var stackBy: TrendStack = .provider
    @State private var selectedDay: Date?

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
                stackedBars
                cacheTrend
                trendLegend
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

    private var stackedBars: some View {
        Chart {
            ForEach(activeSeries) { point in
                BarMark(
                    x: .value(L10n.chartAxisDay, point.date, unit: .day),
                    y: .value(L10n.kpiTokens, point.tokens)
                )
                .foregroundStyle(seriesColor(point))
                .cornerRadius(3)
            }

            if let selection = selectedTrendSelection {
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
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range.axisStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                                centered: true)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int64.self) {
                        Text(compactTokens(v))
                    } else if let d = value.as(Double.self) {
                        Text(compactNumber(d))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedDay)
        .frame(height: 245)
    }

    private var cacheTrend: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(L10n.dailyCacheHitRateTitle)
                        .font(.caption.weight(.semibold))
                } icon: {
                    Circle()
                        .fill(DashboardTheme.cache)
                        .frame(width: 7, height: 7)
                }
                Spacer()
                Text(L10n.cacheHitRateWeightedWindow(
                    period: range.periodLabel,
                    rate: formatCacheHitRate(windowCacheSummary.hitRate)))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .help(L10n.cacheHitRateWeightedHelp)
            }

            Chart {
                ForEach(cacheTrendPoints) { point in
                    LineMark(
                        x: .value(L10n.chartAxisDay, point.date, unit: .day),
                        y: .value(L10n.cacheHitRateTitle, point.rate),
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
                        y: .value(L10n.cacheHitRateTitle, point.rate)
                    )
                    .foregroundStyle(DashboardTheme.cache)
                    .symbolSize(18)
                }

                if let selectedDay {
                    RuleMark(x: .value(L10n.chartAxisDay, selectedDay, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.22))
                }

                if let selectedCacheTrendPoint {
                    PointMark(
                        x: .value(
                            L10n.chartAxisDay,
                            selectedCacheTrendPoint.date,
                            unit: .day),
                        y: .value(
                            L10n.cacheHitRateTitle,
                            selectedCacheTrendPoint.rate)
                    )
                    .foregroundStyle(DashboardTheme.cache)
                    .symbolSize(34)
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: 0.0...1.0)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0.0, 0.5, 1.0]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let rate = value.as(Double.self) {
                            Text(rate.formatted(
                                .percent.precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: $selectedDay)
            .frame(height: 94)

            Text(cacheTrendDetail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - legend + tooltips

    private var trendLegend: some View {
        VStack(spacing: 2) {
            ForEach(legendRows) { row in
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
            Text(selection.date.formatted(.dateTime.month(.abbreviated).day()))
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
        let last7d = lastNDaysUSD(7)
        let last30d = lastNDaysUSD(30)
        let prior30d = priorNDaysUSD(30, offsetDays: 30)

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

    private var windowedDaily: [DailyPoint] {
        Array(dailyExtended.suffix(range.days))
    }

    private var windowCacheSummary: CacheUsageSummary {
        CacheUsageSummary.combined(windowedDaily.map(\.cacheUsage))
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
        let calendar = Calendar.current
        return windowedDaily.first {
            calendar.isDate($0.date, inSameDayAs: selectedDay)
        }
    }

    private var selectedCacheTrendPoint: CacheTrendPoint? {
        guard let selectedDay else { return nil }
        let calendar = Calendar.current
        return cacheTrendPoints.first {
            calendar.isDate($0.date, inSameDayAs: selectedDay)
        }
    }

    private var cacheTrendDetail: String {
        let usage: CacheUsageSummary
        let prefix: String?
        if let selectedCacheDay {
            usage = selectedCacheDay.cacheUsage
            let date = selectedCacheDay.date.formatted(
                .dateTime.month(.abbreviated).day())
            prefix = "\(date) · \(formatCacheHitRate(usage.hitRate))"
        } else {
            usage = windowCacheSummary
            prefix = nil
        }

        guard usage.eligibleInputTokens > 0 else {
            return [prefix, L10n.cacheHitRateUnavailable]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        let detail = L10n.cacheHitRateTokenDetail(
            read: compactTokens(usage.readTokens),
            eligible: compactTokens(usage.eligibleInputTokens))
        return [prefix, detail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var activeSeries: [DailyBreakdownPoint] {
        let calendar = Calendar.current
        let days = Set(windowedDaily.map { calendar.startOfDay(for: $0.date) })
        let raw = (stackBy == .provider ? providerBreakdown : modelBreakdown)
            .filter { days.contains(calendar.startOfDay(for: $0.date)) }

        guard stackBy == .model else { return raw }
        return TrendSeriesBuilder.collapsedModelSeries(raw)
    }

    private var xDomain: ClosedRange<Date> {
        if let domain = TrendChartDomain.domain(
            for: windowedDaily.map(\.date),
            calendar: .current
        ) {
            return domain
        }
        let now = Date()
        return now...now
    }

    private var selectedTrendSelection: TrendSelection? {
        guard let selectedDay else { return nil }
        let calendar = Calendar.current
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

    private var legendRows: [TrendLegendRow] {
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

    private func lastNDaysUSD(_ n: Int) -> Double {
        dailyExtended.suffix(n).reduce(0) { $0 + $1.valueUSD }
    }

    private func priorNDaysUSD(_ n: Int, offsetDays: Int) -> Double {
        let total = dailyExtended.count
        let endIndex = total - offsetDays
        let startIndex = max(0, endIndex - n)
        guard startIndex < endIndex, endIndex <= total else { return 0 }
        return dailyExtended[startIndex..<endIndex].reduce(0) { $0 + $1.valueUSD }
    }

    private var todayUSD: Double {
        dailyExtended.last?.valueUSD ?? 0
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

enum TrendSeriesBuilder {
    static let otherKey = "__other__"

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
    /// Omits days without an eligible-input denominator and assigns a new
    /// series key after every omission. Swift Charts therefore renders a true
    /// gap instead of connecting across missing data or implying a 0% rate.
    static func points(from daily: [DailyPoint]) -> [CacheTrendPoint] {
        var segment = 0
        var previousDayHadRate = false
        return daily.compactMap { day in
            guard let rate = day.cacheUsage.hitRate else {
                previousDayHadRate = false
                return nil
            }
            if !previousDayHadRate {
                segment += 1
            }
            previousDayHadRate = true
            return CacheTrendPoint(date: day.date, rate: rate, segment: segment)
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
