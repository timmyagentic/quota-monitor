import AppKit
import SwiftUI

final class CodexQuotaOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CodexQuotaOverlayView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let onHoverChanged: (Bool) -> Void
    let onActivate: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date)

            Group {
                if presentation.hasQuota {
                    HStack(spacing: 0) {
                        if let fiveHour = presentation.fiveHour {
                            metric(
                                QuotaWindowCompactLabel.fiveHour,
                                fiveHour)
                                .frame(maxWidth: .infinity)
                        }
                        if presentation.fiveHour != nil,
                           presentation.weekly != nil {
                            Rectangle()
                                .fill(.primary.opacity(0.12))
                                .frame(width: 1, height: 13)
                        }
                        if let weekly = presentation.weekly {
                            metric(
                                QuotaWindowCompactLabel.sevenDay,
                                weekly)
                                .frame(maxWidth: .infinity)
                        }
                        if presentation.isCached {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L10n.codexOverlayCachedStatus)
                        }
                    }
                    .opacity(presentation.isCached ? 0.72 : 1)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(L10n.codexOverlayUnavailableCompact)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(
                width: summaryWidth(for: presentation),
                height: CodexQuotaOverlayLayout.size.height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Material.ultraThin)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.primary.opacity(isHovering ? 0.075 : 0.035))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        .primary.opacity(isHovering ? 0.20 : 0.12),
                        lineWidth: 0.75)
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.13 : 0.075),
                radius: isHovering ? 4 : 2.5,
                y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
                onHoverChanged(hovering)
            }
            .onTapGesture {
                onActivate()
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: isHovering)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(L10n.codexOverlayAccessibilityHint)
            .accessibilityAction {
                onActivate()
            }
            .id(localization.currentLanguage)
        }
    }

    private func metric(
        _ label: String,
        _ value: CodexQuotaOverlayMetric
    ) -> some View {
        HStack(spacing: 3.5) {
            Circle()
                .fill(metricAccent(value))
                .frame(width: 4, height: 4)
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value.percent)%")
                .monospacedDigit()
                .foregroundStyle(metricColor(value))
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 4)
        .lineLimit(1)
    }

    private func summaryWidth(
        for presentation: CodexQuotaOverlayPresentation
    ) -> CGFloat {
        let visibleWindowCount = [presentation.fiveHour, presentation.weekly]
            .compactMap { $0 }
            .count
        return visibleWindowCount == 1
            ? CodexQuotaOverlayLayout.singleWindowWidth
            : CodexQuotaOverlayLayout.size.width
    }

    private func metricColor(_ metric: CodexQuotaOverlayMetric) -> Color {
        switch metric.severity {
        case .healthy:
            .primary.opacity(0.82)
        case .warning:
            .orange
        case .critical:
            .red
        }
    }

    private func metricAccent(_ metric: CodexQuotaOverlayMetric) -> Color {
        QuotaUsageStyle.tintColor(
            forUsedPercent: Double(metric.usedPercent))
    }
}

struct CodexQuotaOverlayDetailsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization

    let onHoverChanged: (Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date)
            let resetCredits = CodexQuotaOverlayResetCreditsPresentation.make(
                snapshot: environment.latestCodexResetCredits,
                fallbackAvailableCount: environment.latestRateLimits?
                    .resetCreditsAvailable,
                now: context.date)

            VStack(alignment: .leading, spacing: 0) {
                Text(Branding.appDisplayName)
                    .font(.headline)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: CodexQuotaOverlayLayout.detailsHeaderHeight,
                        alignment: .topLeading)
                    .accessibilityAddTraits(.isHeader)

                if let fiveHour = presentation.fiveHour {
                    quotaWindow(
                        title: L10n.quotaCardTitle5h,
                        metric: fiveHour,
                        now: context.date)
                }
                if presentation.fiveHour != nil,
                   presentation.weekly != nil {
                    Divider()
                        .padding(.vertical, 7)
                }
                if let weekly = presentation.weekly {
                    quotaWindow(
                        title: L10n.quotaCardTitle7d,
                        metric: weekly,
                        now: context.date)
                }

                if let resetCredits {
                    Divider()
                        .padding(.vertical, 8)
                    resetCreditsSection(
                        resetCredits,
                        now: context.date)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.primary.opacity(0.018))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.primary.opacity(0.13), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover(perform: onHoverChanged)
            .accessibilityElement(children: .contain)
            .id(localization.currentLanguage)
        }
    }

    private func quotaWindow(
        title: String,
        metric: CodexQuotaOverlayMetric,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(quotaTintColor(metric))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(metric.percent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(quotaTintColor(metric))
                    .accessibilityLabel(metric.localizedPercentLabel)
            }

            QuotaUsageProgressBar(
                value: Double(metric.percent) / 100,
                usedPercent: Double(metric.usedPercent),
                accessibilityText: metric.localizedPercentLabel)

            HStack(spacing: 4) {
                Text(resetCountdown(for: metric, now: now))
                Spacer(minLength: 8)
                Text(CodexQuotaOverlayTimeFormatting.localDateTime(
                    metric.resetAt))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func resetCreditsSection(
        _ resetCredits: CodexQuotaOverlayResetCreditsPresentation,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(L10n.codexResetCardsTitle)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(L10n.codexResetCardsAvailable(
                    resetCredits.availableCount))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.blue)
            }

            if resetCredits.expirations.isEmpty {
                Text(L10n.codexResetCardsExpiryUnavailable)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(
                        Array(resetCredits.expirations.enumerated()),
                        id: \.offset
                    ) { _, expiration in
                        HStack(spacing: 8) {
                            Text(CodexQuotaOverlayTimeFormatting.localDateTime(
                                expiration))
                            Spacer(minLength: 8)
                            Text(resetCountdown(to: expiration, now: now))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func quotaTintColor(_ metric: CodexQuotaOverlayMetric) -> Color {
        QuotaUsageStyle.tintColor(
            forUsedPercent: Double(metric.usedPercent))
    }

    private func resetCountdown(
        for metric: CodexQuotaOverlayMetric,
        now: Date
    ) -> String {
        resetCountdown(to: metric.resetAt, now: now)
    }

    private func resetCountdown(to date: Date, now: Date) -> String {
        guard let countdown = CodexQuotaOverlayTimeFormatting.countdown(
            to: date,
            now: now) else {
            return L10n.codexOverlayResetRefreshing
        }
        return L10n.codexOverlayResetsIn(countdown)
    }
}
