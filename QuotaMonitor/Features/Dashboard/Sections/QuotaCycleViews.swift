import SwiftUI
import Charts

struct QuotaCycleTimingView: View {
    @Environment(LocalizationStore.self) private var localization
    let cycle: QuotaCycle?
    let resetAt: Date
    let duration: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if resetAt > context.date {
                Text(caption(now: context.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(explanation)
            }
        }
    }

    private func caption(now: Date) -> String {
        if let cycle {
            guard let start = cycle.start else { return L10n.cycleStartUnresolved }
            let elapsed = Self.duration(now.timeIntervalSince(start))
            switch cycle.basis {
            case .estimated: return L10n.cycleElapsedEstimated(elapsed)
            case .observedRollover: return L10n.cycleElapsedObserved(elapsed)
            case .observedChange:
                let upper = Self.duration(now.timeIntervalSince(cycle.possibleStart ?? start))
                return L10n.cycleElapsedRange(elapsed + "–" + upper)
            case .unresolved: return L10n.cycleStartUnresolved
            }
        }
        guard let duration, duration > 0 else { return L10n.cycleStartUnresolved }
        let elapsed = duration - resetAt.timeIntervalSince(now)
        guard elapsed >= 0 else { return L10n.cycleStartUnresolved }
        return L10n.cycleElapsedEstimated(Self.duration(elapsed))
    }

    private var explanation: String {
        let basisText: String = switch cycle?.basis ?? .estimated {
        case .estimated: L10n.cycleEstimatedExplanation
        case .observedRollover: L10n.cycleObservedExplanation
        case .observedChange: L10n.cycleChangedExplanation
        case .unresolved: L10n.cycleUnresolvedExplanation
        }
        guard let cycle else { return basisText }
        var lines = [basisText]
        if let start = cycle.start {
            lines.append(L10n.cycleStartAt(LocalizedDateFormatting.string(from: start, style: .mediumDateShortTime)))
        }
        lines.append(L10n.cycleSampleAt(LocalizedDateFormatting.string(
            from: cycle.observation.capturedAt, style: .mediumDateShortTime)))
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return L10n.cycleDuration(days: minutes / 1440, hours: minutes % 1440 / 60,
                                  minutes: minutes % 60)
    }
}

struct QuotaCycleMetricsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization
    let usage: QuotaCycleUsage?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Text(L10n.cycleLocalUsage).font(.caption.weight(.medium))
                    Spacer()
                    if let usage, usage.cycle.isCurrent(at: context.date),
                       let start = usage.cycle.start,
                       usage.cycle.basis != .observedChange {
                        let fraction = min(1, max(0, context.date.timeIntervalSince(start)
                            / usage.cycle.observation.resetAt.timeIntervalSince(start)))
                        Text(L10n.cycleTimeProgress(fraction.formatted(.percent.precision(.fractionLength(0))),
                                                   estimated: usage.cycle.basis == .estimated))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let usage, usage.cycle.isCurrent(at: context.date), usage.cycle.start != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        metric(L10n.kpiTokens, value: usage.tokens.formatted(
                            .number.notation(.compactName).precision(.fractionLength(0...1))
                                .locale(settings.tokenFormatLocale)))
                        metric(L10n.cacheHitRateTitle, value: usage.cacheUsage.hitRate?
                            .formatted(.percent.precision(.fractionLength(1))) ?? "—")
                        metric(L10n.cycleAPIValue, value: usage.valueUSD.formatted(.currency(code: "USD")))
                    }
                    Text(usage.cycle.basis == .observedChange
                         ? L10n.cyclePartialScope : L10n.cycleLocalScope)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if usage.eventCount == 0 {
                        Text(L10n.cycleNoLocalRecords).font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.cycleNoCurrentWindow)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuotaCycleChart: View {
    @Environment(LocalizationStore.self) private var localization
    @Environment(SettingsStore.self) private var settings
    let usages: [QuotaCycleUsage]
    let bucket: String
    let visibleProviders: Set<String>
    @State private var selectedHour: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let active = usages.filter {
                $0.cycle.observation.bucket == bucket
                    && visibleProviders.contains($0.cycle.observation.provider)
                    && $0.cycle.isCurrent(at: context.date) && $0.cycle.start != nil
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.cycleCumulativeExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                if active.isEmpty {
                    Text(L10n.cycleNoCurrentWindow)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 245)
                } else {
                    Chart {
                        ForEach(active) { usage in
                            ForEach(usage.points) { point in
                                LineMark(
                                    x: .value(L10n.cycleHoursAxis,
                                              point.date.timeIntervalSince(usage.cycle.start!) / 3600),
                                    y: .value(L10n.kpiTokens, Double(point.tokens)),
                                    series: .value("Provider", usage.cycle.observation.provider))
                                    .foregroundStyle(DashboardTheme.providerColor(usage.cycle.observation.provider))
                                    .interpolationMethod(.stepEnd)
                            }
                        }
                        if let selectedHour {
                            RuleMark(x: .value(L10n.cycleHoursAxis, selectedHour))
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                    .chartXAxisLabel(L10n.cycleHoursAxis)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let tokens = value.as(Double.self) {
                                    Text(tokens.formatted(.number.notation(.compactName)
                                        .locale(settings.tokenFormatLocale)))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: 0...(bucket == "primary" ? 5.0 : 168.0))
                    .chartXSelection(value: $selectedHour)
                    .frame(height: 245)
                    ForEach(active) { usage in
                        HStack(spacing: 8) {
                            Circle().fill(DashboardTheme.providerColor(usage.cycle.observation.provider))
                                .frame(width: 7, height: 7)
                            Text(DashboardTheme.providerLabel(usage.cycle.observation.provider))
                            QuotaCycleTimingView(cycle: usage.cycle,
                                                resetAt: usage.cycle.observation.resetAt,
                                                duration: usage.cycle.observation.duration)
                            Spacer()
                            let point = selectedPoint(usage)
                            Text((point?.tokens ?? usage.tokens).formatted(.number.notation(.compactName)
                                .locale(settings.tokenFormatLocale)))
                                .monospacedDigit()
                            Text((point?.valueUSD ?? usage.valueUSD).formatted(.currency(code: "USD")))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                    Text(L10n.cycleLocalScope).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedPoint(_ usage: QuotaCycleUsage) -> QuotaCycleUsage.Point? {
        guard let selectedHour, let start = usage.cycle.start else { return nil }
        let date = start.addingTimeInterval(selectedHour * 3600)
        return usage.points.last { $0.date <= date }
    }
}
