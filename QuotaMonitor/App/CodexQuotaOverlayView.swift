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
    @State private var isHovering = false

    let onHoverChanged: (Bool) -> Void
    let onToggleDetails: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date)

            Group {
                if presentation.hasQuota {
                    HStack(spacing: 6) {
                        if let fiveHour = presentation.fiveHour {
                            metric("5h", fiveHour)
                        }
                        if presentation.fiveHour != nil,
                           presentation.weekly != nil {
                            Rectangle()
                                .fill(.primary.opacity(0.14))
                                .frame(width: 1, height: 11)
                        }
                        if let weekly = presentation.weekly {
                            metric(L10n.codexOverlayWeeklyCompact, weekly)
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
            .padding(.horizontal, 8)
            .frame(
                width: summaryWidth(for: presentation),
                height: CodexQuotaOverlayLayout.size.height)
            .background {
                Capsule()
                    .fill(Material.ultraThin)
                    .overlay {
                        Capsule()
                            .fill(.primary.opacity(isHovering ? 0.09 : 0.055))
                    }
            }
            .overlay {
                Capsule()
                    .stroke(
                        .primary.opacity(isHovering ? 0.18 : 0.11),
                        lineWidth: 0.75)
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.12 : 0.07),
                radius: isHovering ? 3 : 2,
                y: 1)
            .contentShape(Capsule())
            .onHover { hovering in
                isHovering = hovering
                onHoverChanged(hovering)
            }
            .onTapGesture {
                onToggleDetails()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(L10n.codexOverlayAccessibilityHint)
            .accessibilityAction {
                onToggleDetails()
            }
            .id(localization.currentLanguage)
        }
    }

    private func metric(
        _ label: String,
        _ value: CodexQuotaOverlayMetric
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value.percent)%")
                .monospacedDigit()
                .foregroundStyle(metricColor(value))
        }
        .font(.system(size: 10, weight: .semibold))
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
            .primary.opacity(0.78)
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

    private let progressAccent = Color(
        red: 0.94,
        green: 0.46,
        blue: 0.77)

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

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if presentation.isCached {
                        cachedNotice
                            .padding(.bottom, 8)
                    }

                    if let fiveHour = presentation.fiveHour {
                        quotaWindow(
                            title: L10n.quotaCardTitle5h,
                            metric: fiveHour,
                            now: context.date)
                    }
                    if presentation.fiveHour != nil,
                       presentation.weekly != nil {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    if let weekly = presentation.weekly {
                        quotaWindow(
                            title: L10n.quotaCardTitle7d,
                            metric: weekly,
                            now: context.date)
                    }

                    if let resetCredits {
                        Divider()
                            .padding(.vertical, 10)
                        resetCreditsSection(
                            resetCredits,
                            now: context.date)
                    }

                    Text(L10n.codexOverlayLocalTimeNote)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 10)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.primary.opacity(0.025))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.primary.opacity(0.13), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover(perform: onHoverChanged)
            .accessibilityElement(children: .contain)
            .id(localization.currentLanguage)
        }
    }

    private var cachedNotice: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(L10n.codexOverlayDetailsCachedNotice)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }

    private func quotaWindow(
        title: String,
        metric: CodexQuotaOverlayMetric,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(L10n.codexOverlayRemaining(metric.remainingPercent))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 11))

            Text(L10n.codexOverlayUsed(metric.usedPercent))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Text(resetCountdown(for: metric, now: now))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(CodexQuotaOverlayTimeFormatting.localDateTime(
                metric.resetAt))
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.10))
                    Capsule()
                        .fill(progressAccent)
                        .frame(
                            width: geometry.size.width
                                * CGFloat(metric.remainingPercent) / 100)
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel(
                L10n.codexOverlayRemaining(metric.remainingPercent))
        }
    }

    private func resetCreditsSection(
        _ resetCredits: CodexQuotaOverlayResetCreditsPresentation,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.codexResetCardsTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(L10n.codexResetCardsAvailable(
                    resetCredits.availableCount))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if resetCredits.expirations.isEmpty {
                Text(L10n.codexResetCardsExpiryUnavailable)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 6) {
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
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        }
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
