import AppKit
import SwiftUI
import Observation

final class CodexQuotaOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class CodexQuotaOverlayViewState {
    var compact = false
    var width = CodexQuotaOverlayLayout.size.width
    var isExpanded = false
    var dragPhase = CodexQuotaOverlayDragPhase.idle
}

enum CodexQuotaOverlayPalette {
    static func color(_ metric: CodexQuotaOverlayMetric) -> Color {
        switch metric.severity {
        case .healthy: Color(red: 0.36, green: 0.49, blue: 0.76)
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct CodexQuotaOverlayView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var holdTask: Task<Void, Never>?
    @State private var jiggleForward = false

    let state: CodexQuotaOverlayViewState
    let onHoverChanged: (Bool) -> Void
    let onResetPosition: () -> Void
    let onActivate: () -> Void
    let onPressBegan: (CGPoint) -> Void
    let onDragBegan: (CGPoint) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let onDragCancelled: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date,
                refreshFailed: environment.rateLimitsRefreshFailed)

            // Keep the input surface alive when the readout changes to hold/drag text.
            ZStack {
                summaryContent(presentation)
            }
            .padding(.horizontal, 8)
            .frame(
                width: state.width,
                height: CodexQuotaOverlayLayout.size.height)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering || state.isExpanded ? 0.055 : 0.015))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                CodexQuotaOverlayMouseInput(onPress: beginPress, onMove: dragChanged,
                    onRelease: dragEnded, onCancel: cancelInteraction,
                    onResetPosition: onResetPosition,
                    onHoverChanged: { hovering in
                        isHovering = hovering
                        onHoverChanged(hovering)
                    })
                    .accessibilityHidden(true)
            }
            .onDisappear(perform: cancelInteraction)
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

    @ViewBuilder
    private func summaryContent(
        _ presentation: CodexQuotaOverlayPresentation
    ) -> some View {
        switch state.dragPhase {
        case .pressing:
            Text(L10n.codexOverlayHoldToMove)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityLabel(L10n.codexOverlayHoldToMove)
        case .ready, .dragging:
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(
                        reduceMotion ? 0 : (jiggleForward ? 3 : -3)))
                    .offset(x: reduceMotion ? 0 : (jiggleForward ? 0.8 : -0.8))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.11)
                                .repeatForever(autoreverses: true),
                        value: jiggleForward)
                Text(L10n.codexOverlayReadyToMove)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.codexOverlayReadyToMove)
        case .idle:
            quotaContent(presentation)
        }
    }

    @ViewBuilder
    private func quotaContent(_ presentation: CodexQuotaOverlayPresentation) -> some View {
        HStack(spacing: 6) {
            if state.compact && presentation.isCached {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text(L10n.codexOverlayStale).foregroundStyle(.secondary)
            } else if presentation.hasQuota {
                let dual = presentation.fiveHour != nil && presentation.weekly != nil
                if presentation.isCached {
                    if let metric = presentation.weekly ?? presentation.fiveHour { quotaRing(metric) }
                    Text(staleReadout(presentation))
                        .font(.system(size: 11).monospacedDigit())
                        .layoutPriority(1)
                } else if state.compact, let fiveHour = presentation.fiveHour, let weekly = presentation.weekly {
                    Text(L10n.codexOverlayDualCompact(fiveHour: fiveHour.percent, weekly: weekly.percent,
                        used: fiveHour.displayMode == .used))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .layoutPriority(1)
                } else {
                    if let metric = presentation.fiveHour {
                        readout(metric, weekly: false, abbreviated: dual || state.compact)
                    }
                    if dual { Text("·").foregroundStyle(.tertiary) }
                    if let metric = presentation.weekly {
                        readout(metric, weekly: true, abbreviated: dual || state.compact)
                    }
                }
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                Text(state.compact ? L10n.codexOverlayUnavailableShort : L10n.codexOverlayUnavailableCompact)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func readout(_ metric: CodexQuotaOverlayMetric, weekly: Bool, abbreviated: Bool) -> some View {
        HStack(spacing: 6) {
            if !state.compact {
                quotaRing(metric)
            }
            let label = L10n.codexOverlayReadoutLabel(weekly: weekly, used: metric.displayMode == .used,
                abbreviated: abbreviated, omitPeriod: state.compact && state.width == CodexQuotaOverlayLayout.compactWidth)
            Text("\(Text(label)) \(Text("\(metric.percent)%").font(.system(size: 13, weight: .medium).monospacedDigit()))")
                .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((weekly ? L10n.quotaCardTitle7d : L10n.quotaCardTitle5h) + ", " + metric.localizedPercentLabel)
    }

    private func quotaRing(_ metric: CodexQuotaOverlayMetric) -> some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.10), lineWidth: 1.5)
            Circle().trim(from: 0, to: CGFloat(metric.percent) / 100)
                .stroke(CodexQuotaOverlayPalette.color(metric), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }

    private func staleReadout(_ presentation: CodexQuotaOverlayPresentation) -> String {
        let values = [(false, presentation.fiveHour), (true, presentation.weekly)].compactMap { weekly, metric -> String? in
            guard let metric else { return nil }
            return L10n.codexOverlayReadoutLabel(weekly: weekly, used: metric.displayMode == .used,
                abbreviated: true, omitPeriod: false) + " \(metric.percent)%"
        }
        return (values + [L10n.codexOverlayStale]).joined(separator: " · ")
    }

    private func dragChanged(_ location: CGPoint) {
        guard state.dragPhase.isUnlocked else { return }
        state.dragPhase = .dragging
        onDragChanged(location)
    }

    private func dragEnded(_ location: CGPoint, translation: CGSize) {
        holdTask?.cancel()
        holdTask = nil
        let action = CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: state.dragPhase, translation: translation)
        // Mouse-up can contain movement that was coalesced out of drag events.
        if action == .finishDrag { onDragChanged(location) }
        resetVisualState()
        if action == .finishDrag { onDragEnded() } else { onDragCancelled() }
        if action == .activateDetails { onActivate() }
    }

    private func beginPress(_ location: CGPoint) {
        state.dragPhase = .pressing
        onPressBegan(location)
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: CodexQuotaOverlayDragInteractionPolicy.holdDuration)
            guard !Task.isCancelled, state.dragPhase == .pressing else { return }
            state.dragPhase = .ready
            onDragBegan(NSEvent.mouseLocation)
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.11).repeatForever(autoreverses: true)) {
                jiggleForward = true
            }
        }
    }

    private func cancelInteraction() {
        holdTask?.cancel()
        holdTask = nil
        if state.dragPhase != .idle { onDragCancelled() }
        resetVisualState()
    }

    private func resetVisualState() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.dragPhase = .idle
            jiggleForward = false
        }
    }

}

struct CodexQuotaOverlayDetailsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization
    var onHoverChanged: (Bool) -> Void = { _ in }

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
                    .stroke(.primary.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
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
                    .padding(.vertical, 8)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func quotaWindow(
        title: String,
        metric: CodexQuotaOverlayMetric,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(metric.percent)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(metric.severity == .healthy ? Color.primary : CodexQuotaOverlayPalette.color(metric))
                    .accessibilityLabel(metric.localizedPercentLabel)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule().fill(CodexQuotaOverlayPalette.color(metric))
                        .frame(width: geometry.size.width * CGFloat(metric.percent) / 100)
                }
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel(metric.localizedPercentLabel)

            HStack(spacing: 4) {
                Text(resetCountdown(for: metric, now: now))
                Spacer(minLength: 8)
                Text(CodexQuotaOverlayTimeFormatting.localDateTime(
                    metric.resetAt))
            }
            .font(.system(size: 10).monospacedDigit())
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
