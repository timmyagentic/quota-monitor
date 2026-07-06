import SwiftUI
import Charts

/// Trends panel: stacked token bars by provider/model plus a compact K-line
/// mode over the same daily series. The summary line still reports spend
/// over today / 7d / 30d so the chart remains useful for both tokens and cost.
struct TrendsSection: View {
    @Environment(SettingsStore.self) private var settings

    let dailyExtended: [DailyPoint]
    let providerBreakdown: [DailyBreakdownPoint]
    let modelBreakdown: [DailyBreakdownPoint]

    @State private var range: TrendRange = .last30d
    @State private var stackBy: TrendStack = .provider
    @State private var mode: TrendMode = .bars
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
                chart
                if mode == .bars {
                    trendLegend
                }
                statline
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 14)
    }

    // MARK: - controls

    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            if mode == .bars {
                Picker("", selection: $stackBy) {
                    ForEach(TrendStack.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            Picker("", selection: $mode) {
                ForEach(TrendMode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(TrendRange.allCases) { candidate in
                    Button {
                        range = candidate
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

    @ViewBuilder
    private var chart: some View {
        switch mode {
        case .bars:
            stackedBars
        case .kline:
            kLine
        }
    }

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
        .frame(height: 330)
    }

    private var kLine: some View {
        Chart {
            ForEach(candles) { candle in
                RuleMark(
                    x: .value(L10n.chartAxisDay, candle.midDate, unit: .day),
                    yStart: .value("Low", candle.low),
                    yEnd: .value("High", candle.high)
                )
                .foregroundStyle(candle.color)
                .lineStyle(StrokeStyle(lineWidth: 1.4))

                RectangleMark(
                    x: .value(L10n.chartAxisDay, candle.midDate, unit: .day),
                    yStart: .value("Open", min(candle.open, candle.close)),
                    yEnd: .value("Close", max(candle.open, candle.close)),
                    width: .fixed(range.candleWidth)
                )
                .foregroundStyle(candle.color)
                .cornerRadius(2)
            }

            if let candle = selectedCandle {
                RuleMark(x: .value(L10n.chartAxisDay, candle.midDate, unit: .day))
                    .foregroundStyle(Color.primary.opacity(0.22))
                    .annotation(
                        position: .top,
                        alignment: .center,
                        spacing: 4,
                        overflowResolution: .init(x: .fit, y: .disabled)
                    ) {
                        candleTooltip(candle)
                    }
            }
        }
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
        .chartXSelection(value: $selectedDay)
        .frame(height: 330)
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
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
        )
    }

    private func candleTooltip(_ candle: UsageCandle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candle.label)
                .font(.caption.weight(.semibold))
            Text("O \(compactTokens(candle.open)) · H \(compactTokens(candle.high))")
                .font(.caption2.monospacedDigit())
            Text("L \(compactTokens(candle.low)) · C \(compactTokens(candle.close))")
                .font(.caption2.monospacedDigit())
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

    private var activeSeries: [DailyBreakdownPoint] {
        let calendar = Calendar.current
        let days = Set(windowedDaily.map { calendar.startOfDay(for: $0.date) })
        let raw = (stackBy == .provider ? providerBreakdown : modelBreakdown)
            .filter { days.contains(calendar.startOfDay(for: $0.date)) }

        guard stackBy == .model else { return raw }
        let totals = Dictionary(grouping: raw, by: \.key)
            .mapValues { rows in rows.reduce(Int64(0)) { $0 + $1.tokens } }
        let topKeys = Set(totals
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map(\.key))
        return raw.filter { topKeys.contains($0.key) }
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
            totalTokens: rows.reduce(Int64(0)) { $0 + $1.tokens })
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

    private var candles: [UsageCandle] {
        UsageCandle.build(
            points: windowedDaily,
            bucketDays: range.candleBucketDays)
    }

    private var selectedCandle: UsageCandle? {
        guard let selectedDay, !candles.isEmpty else { return nil }
        return candles.min {
            abs($0.midDate.timeIntervalSince(selectedDay))
            < abs($1.midDate.timeIntervalSince(selectedDay))
        }
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

    var candleBucketDays: Int {
        switch self {
        case .last7d: return 1
        case .last30d: return 2
        case .last90d: return 5
        case .lastYear: return 14
        }
    }

    var candleWidth: CGFloat {
        switch self {
        case .last7d: return 14
        case .last30d: return 10
        case .last90d: return 8
        case .lastYear: return 6
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

private enum TrendMode: CaseIterable, Identifiable {
    case bars
    case kline

    var id: Self { self }

    var label: String {
        switch self {
        case .bars: return L10n.dashboardModeBars
        case .kline: return L10n.dashboardModeKLine
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
}

private struct UsageCandle: Identifiable {
    let id: Date
    let startDate: Date
    let endDate: Date
    let midDate: Date
    let open: Int64
    let high: Int64
    let low: Int64
    let close: Int64
    let label: String

    var color: Color {
        close >= open ? Color.green.opacity(0.86) : DashboardTheme.warning
    }

    static func build(
        points: [DailyPoint],
        bucketDays: Int
    ) -> [UsageCandle] {
        let bucketSize = max(1, bucketDays)
        var out: [UsageCandle] = []
        var index = 0
        while index < points.count {
            let slice = Array(points[index..<min(index + bucketSize, points.count)])
            guard let first = slice.first, let last = slice.last else { break }
            let values = slice.map(\.tokens)
            let mid = first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) / 2)
            let label: String
            if Calendar.current.isDate(first.date, inSameDayAs: last.date) {
                label = first.date.formatted(.dateTime.month(.abbreviated).day())
            } else {
                label = first.date.formatted(.dateTime.month(.abbreviated).day())
                    + " – "
                    + last.date.formatted(.dateTime.month(.abbreviated).day())
            }
            out.append(UsageCandle(
                id: first.date,
                startDate: first.date,
                endDate: last.date,
                midDate: mid,
                open: first.tokens,
                high: values.max() ?? 0,
                low: values.min() ?? 0,
                close: last.tokens,
                label: label))
            index += bucketSize
        }
        return out.filter { candle in
            candle.open > 0 || candle.high > 0 || candle.low > 0 || candle.close > 0
        }
    }
}
