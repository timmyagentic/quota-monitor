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
                    .fill(Color.primary.opacity(isHovering ? 0.035 : 0.018))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        .primary.opacity(isHovering ? 0.12 : 0.055),
                        lineWidth: isHovering ? 0.75 : 0.5)
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.13 : 0),
                radius: isHovering ? 4 : 0,
                y: isHovering ? 1 : 0)
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
        Text(QuotaWindowCompactLabel.segment(
            label: label,
            value: "\(value.percent)%",
            style: settings.menuBarLabelStyle))
            .monospacedDigit()
            .foregroundStyle(metricColor(value))
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

            ViewThatFits(in: .vertical) {
                detailsContent(
                    presentation: presentation,
                    resetCredits: resetCredits,
                    now: context.date)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical) {
                    detailsContent(
                        presentation: presentation,
                        resetCredits: resetCredits,
                        now: context.date)
                }
                .scrollIndicators(.hidden)
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
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

    private func detailsContent(
        presentation: CodexQuotaOverlayPresentation,
        resetCredits: CodexQuotaOverlayResetCreditsPresentation?,
        now: Date
    ) -> some View {
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
                    now: now)
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
                    now: now)
            }

            if let resetCredits {
                Divider()
                    .padding(.vertical, 8)
                resetCreditsSection(
                    resetCredits,
                    now: now)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
