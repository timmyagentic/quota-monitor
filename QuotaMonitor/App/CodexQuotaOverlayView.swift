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
    @State private var dragPhase = CodexQuotaOverlayDragPhase.idle
    @State private var holdTask: Task<Void, Never>?
    @State private var jiggleForward = false

    let state: CodexQuotaOverlayViewState
    let onResetPosition: () -> Void
    let onActivate: () -> Void
    let onPressBegan: () -> Void
    let onDragBegan: () -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date,
                refreshFailed: environment.rateLimitsRefreshFailed)

            summaryContent(presentation)
            .padding(.horizontal, 8)
            .frame(
                width: state.width,
                height: CodexQuotaOverlayLayout.size.height)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering || state.isExpanded ? 0.055 : 0.015))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        dragChanged(value)
                    }
                    .onEnded { value in
                        dragEnded(value)
                    })
            .contextMenu {
                Button(L10n.codexOverlayResetPosition, action: onResetPosition)
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
        switch dragPhase {
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
            Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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

    private func dragChanged(_ value: DragGesture.Value) {
        switch dragPhase {
        case .idle:
            beginPress()
        case .pressing:
            break
        case .ready:
            dragPhase = .dragging
            onDragChanged()
        case .dragging:
            onDragChanged()
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        let action = CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: dragPhase,
            translation: value.translation)
        resetVisualState()
        onDragEnded()

        switch action {
        case .activateDetails:
            onActivate()
        case .finishDrag, .cancel:
            break
        }
    }

    private func beginPress() {
        dragPhase = .pressing
        onPressBegan()
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(
                for: CodexQuotaOverlayDragInteractionPolicy.holdDuration)
            guard !Task.isCancelled, dragPhase == .pressing else { return }
            dragPhase = .ready
            onDragBegan()
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 0.11)
                    .repeatForever(autoreverses: true)
            ) {
                jiggleForward = true
            }
        }
    }

    private func cancelInteraction() {
        holdTask?.cancel()
        holdTask = nil
        if dragPhase != .idle {
            onDragEnded()
        }
        resetVisualState()
    }

    private func resetVisualState() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragPhase = .idle
            jiggleForward = false
        }
    }

}

struct CodexQuotaOverlayDetailsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization

    let onRefresh: () -> Void
    let onOpenDashboard: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date,
                refreshFailed: environment.rateLimitsRefreshFailed)
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.primary.opacity(0.13), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            HStack {
                Text(L10n.codexOverlayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(environment.isRefreshingRateLimits)
                .help(environment.isRefreshingRateLimits ? L10n.refreshing : L10n.refresh)
                .accessibilityLabel(L10n.refresh)
            }
            .frame(height: 24)
            .padding(.bottom, 12)

            if !presentation.hasQuota {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.codexOverlayUnavailableCompact).font(.system(size: 15, weight: .medium))
                    Text(L10n.codexOverlayEmptyHelp).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(height: 96, alignment: .topLeading)
            }
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

            if presentation.isCached {
                Label(L10n.codexOverlayCachedExplanation, systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 32, alignment: .leading)
            }
            if let resetCredits {
                Divider().padding(.vertical, 8)
                resetCreditsSection(resetCredits, now: now)
            }
            HStack(spacing: 4) {
                Text(updatedLabel(now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(L10n.codexOverlayViewDetails, action: onOpenDashboard)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 26, alignment: .bottom)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func updatedLabel(now: Date) -> String {
        guard let capturedAt = environment.latestRateLimits?.capturedAt else { return L10n.codexOverlayNeverUpdated }
        return L10n.codexOverlayUpdated(minutes: max(0, Int(now.timeIntervalSince(capturedAt) / 60)))
    }

    private func quotaWindow(
        title: String,
        metric: CodexQuotaOverlayMetric,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(metric.percent)%")
                    .font(.system(size: 32, weight: .semibold).monospacedDigit())
                Text(L10n.codexOverlayValueMeaning(used: metric.displayMode == .used))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metric.localizedPercentLabel)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(CodexQuotaOverlayPalette.color(metric))
                        .frame(width: geometry.size.width * CGFloat(metric.percent) / 100)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text(resetCountdown(for: metric, now: now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .help(CodexQuotaOverlayTimeFormatting.localDateTime(metric.resetAt))
        }
        .frame(height: 96, alignment: .topLeading)
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
