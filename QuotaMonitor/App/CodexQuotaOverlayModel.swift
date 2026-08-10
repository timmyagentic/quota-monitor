import CoreGraphics
import Darwin
import Foundation

struct CodexQuotaOverlayMetric: Equatable {
    enum Severity: Equatable {
        case healthy
        case warning
        case critical
    }

    let percent: Int
    let usedPercent: Int
    let remainingPercent: Int
    let displayMode: SettingsStore.QuotaDisplayMode
    let resetAt: Date
    let severity: Severity

    var localizedPercentLabel: String {
        switch displayMode {
        case .used:
            L10n.codexOverlayUsed(percent)
        case .remaining:
            L10n.codexOverlayRemaining(percent)
        }
    }
}

struct CodexQuotaOverlayPresentation: Equatable {
    let fiveHour: CodexQuotaOverlayMetric?
    let weekly: CodexQuotaOverlayMetric?
    let isCached: Bool

    var hasQuota: Bool {
        fiveHour != nil || weekly != nil
    }

    static func make(
        snapshot: RateLimitSnapshot?,
        displayMode: SettingsStore.QuotaDisplayMode,
        now: Date = Date(),
        staleAfter: TimeInterval = 15 * 60
    ) -> CodexQuotaOverlayPresentation {
        guard let snapshot else {
            return CodexQuotaOverlayPresentation(
                fiveHour: nil,
                weekly: nil,
                isCached: false)
        }

        let fiveHour = snapshot.primary.map {
            metric(window: $0, displayMode: displayMode)
        }
        let weekly = snapshot.secondary.map {
            metric(window: $0, displayMode: displayMode)
        }
        let age = max(0, now.timeIntervalSince(snapshot.capturedAt))
        let containsExpiredWindow = [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .contains { $0.resetAt <= now }

        return CodexQuotaOverlayPresentation(
            fiveHour: fiveHour,
            weekly: weekly,
            isCached: age > staleAfter || containsExpiredWindow)
    }

    private static func metric(
        window: RateLimitSnapshot.Window,
        displayMode: SettingsStore.QuotaDisplayMode
    ) -> CodexQuotaOverlayMetric {
        let usedPercent = min(100, max(0, window.usedPercent))
        let remainingPercent = 100 - usedPercent
        let displayPercent = displayMode.displayPercent(
            forUsedPercent: usedPercent)
        let severity: CodexQuotaOverlayMetric.Severity
        switch window.usedPercent {
        case ..<60:
            severity = .healthy
        case ..<85:
            severity = .warning
        default:
            severity = .critical
        }
        return CodexQuotaOverlayMetric(
            percent: Int(displayPercent.rounded()),
            usedPercent: Int(usedPercent.rounded()),
            remainingPercent: Int(remainingPercent.rounded()),
            displayMode: displayMode,
            resetAt: window.resetAt,
            severity: severity)
    }
}

struct CodexQuotaOverlayResetCreditsPresentation: Equatable {
    let availableCount: Int
    let expirations: [Date]

    static func make(
        snapshot: CodexResetCreditsSnapshot?,
        fallbackAvailableCount: Int?,
        now: Date = Date()
    ) -> CodexQuotaOverlayResetCreditsPresentation? {
        if let snapshot {
            if snapshot.detailStatus == .complete {
                let activeExpirations = snapshot.credits
                    .map(\.expiresAt)
                    .filter { $0 > now }
                let activeCount = min(
                    snapshot.availableCount,
                    activeExpirations.count)
                guard activeCount > 0 else { return nil }
                return CodexQuotaOverlayResetCreditsPresentation(
                    availableCount: activeCount,
                    expirations: Array(
                        activeExpirations.prefix(min(3, activeCount))))
            }
            if snapshot.availableCount > 0 {
                return CodexQuotaOverlayResetCreditsPresentation(
                    availableCount: snapshot.availableCount,
                    expirations: [])
            }
        }
        guard let fallbackAvailableCount, fallbackAvailableCount > 0 else {
            return nil
        }
        return CodexQuotaOverlayResetCreditsPresentation(
            availableCount: fallbackAvailableCount,
            expirations: [])
    }
}

enum CodexQuotaOverlayTimeFormatting {
    static func countdown(to date: Date, now: Date) -> String? {
        let totalMinutes = Int(ceil(date.timeIntervalSince(now) / 60))
        guard totalMinutes > 0 else { return nil }

        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0
                ? "\(days)\(L10n.unitDayShort) \(hours)\(L10n.unitHourShort)"
                : "\(days)\(L10n.unitDayShort)"
        }
        if hours > 0 {
            return minutes > 0
                ? "\(hours)\(L10n.unitHourShort) \(minutes)\(L10n.unitMinuteShort)"
                : "\(hours)\(L10n.unitHourShort)"
        }
        return "\(minutes)\(L10n.unitMinuteShort)"
    }

    static func localDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct CodexWindowCandidate: Equatable {
    let windowNumber: Int
    let ownerPID: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

enum CodexWindowSelectionPolicy {
    static let minimumWindowSize = CGSize(width: 480, height: 320)

    /// `CGWindowListCopyWindowInfo` returns windows front-to-back. Keeping
    /// that order selects the active Codex document when more than one is
    /// open, while the size and layer checks reject Electron helper surfaces.
    static func frontWindow(
        for processIdentifier: pid_t,
        candidates: [CodexWindowCandidate]
    ) -> CodexWindowCandidate? {
        candidates.first { candidate in
            isEligibleWindow(candidate, for: processIdentifier)
        }
    }

    static func trackedWindow(
        for processIdentifier: pid_t,
        lastWindowNumber: Int?,
        codexIsFrontmost: Bool,
        candidates: [CodexWindowCandidate]
    ) -> CodexWindowCandidate? {
        if codexIsFrontmost {
            return frontWindow(
                for: processIdentifier,
                candidates: candidates)
        }
        guard let lastWindowNumber else { return nil }
        return candidates.first { candidate in
            candidate.windowNumber == lastWindowNumber
                && isEligibleWindow(candidate, for: processIdentifier)
        }
    }

    static func isWindow(
        _ upperWindowNumber: Int,
        above lowerWindowNumber: Int,
        candidates: [CodexWindowCandidate]
    ) -> Bool {
        guard let upperIndex = candidates.firstIndex(where: {
            $0.windowNumber == upperWindowNumber
        }), let lowerIndex = candidates.firstIndex(where: {
            $0.windowNumber == lowerWindowNumber
        }) else {
            return false
        }
        return upperIndex < lowerIndex
    }

    private static func isEligibleWindow(
        _ candidate: CodexWindowCandidate,
        for processIdentifier: pid_t
    ) -> Bool {
        candidate.ownerPID == processIdentifier
            && candidate.layer == 0
            && candidate.alpha > 0.01
            && candidate.bounds.width >= minimumWindowSize.width
            && candidate.bounds.height >= minimumWindowSize.height
    }
}

enum CodexQuotaOverlayPlacement: Equatable {
    case hidden
    case foreground
    case background

    var allowsDetails: Bool {
        self == .foreground
    }

    var allowsInteraction: Bool {
        self == .foreground
    }
}

enum CodexQuotaOverlayVisibilityPolicy {
    /// A visible widget may remain attached after Codex loses focus, but a
    /// background Codex window must never summon a new overlay above the app
    /// the user is currently working in.
    static func placement(
        codexIsFrontmost: Bool,
        trackedWindowIsOnScreen: Bool,
        overlayIsVisible: Bool
    ) -> CodexQuotaOverlayPlacement {
        guard trackedWindowIsOnScreen else { return .hidden }
        if codexIsFrontmost {
            return .foreground
        }
        return overlayIsVisible ? .background : .hidden
    }
}

struct CodexDisplayGeometry: Equatable {
    let quartzFrame: CGRect
    let appKitFrame: CGRect
}

enum CodexWindowFrameConverter {
    /// Quartz window coordinates grow downward from each display's top edge;
    /// AppKit coordinates grow upward. Map through the display containing the
    /// largest part of the window so secondary displays and negative origins
    /// behave the same as the primary display.
    static func appKitFrame(
        for quartzWindowFrame: CGRect,
        displays: [CodexDisplayGeometry]
    ) -> CGRect? {
        guard let display = displays.max(by: {
            intersectionArea(quartzWindowFrame, $0.quartzFrame)
                < intersectionArea(quartzWindowFrame, $1.quartzFrame)
        }), intersectionArea(quartzWindowFrame, display.quartzFrame) > 0 else {
            return nil
        }

        let horizontalOffset = quartzWindowFrame.minX - display.quartzFrame.minX
        let verticalOffsetFromTop = quartzWindowFrame.minY - display.quartzFrame.minY
        return CGRect(
            x: display.appKitFrame.minX + horizontalOffset,
            y: display.appKitFrame.maxY
                - verticalOffsetFromTop
                - quartzWindowFrame.height,
            width: quartzWindowFrame.width,
            height: quartzWindowFrame.height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

enum CodexQuotaOverlayLayout {
    static let size = CGSize(width: 132, height: 25)
    static let singleWindowWidth: CGFloat = 84
    static let detailsWidth: CGFloat = 288
    static let detailsHeaderHeight: CGFloat = 27
    static let windowIdentifier = "codex-quota-overlay"
    static let detailsWindowIdentifier = "codex-quota-overlay-details"
    private static let helpControlGap: CGFloat = 34
    // The approved fallback slot ends at 150 pt in the 490 pt reference
    // account row. Store it as a proportion so wider and narrower Codex
    // windows keep the same relative placement.
    private static let fallbackTrailingPositionRatio: CGFloat = 150.0 / 490.0
    private static let bottomInset: CGFloat = 12
    private static let detailsLeftInset: CGFloat = 12
    private static let detailsGap: CGFloat = 6
    private static let detailsTopInset: CGFloat = 12

    /// Prefer the discovered account-row help control. If Accessibility cannot
    /// provide it, preserve the approved 150-of-490 reference placement as a
    /// proportion of the current Codex window width.
    static func frame(
        in codexWindowFrame: CGRect,
        helpControlLeadingX: CGFloat? = nil
    ) -> CGRect {
        frame(
            in: codexWindowFrame,
            width: size.width,
            helpControlLeadingX: helpControlLeadingX)
    }

    static func frame(
        in codexWindowFrame: CGRect,
        presentation: CodexQuotaOverlayPresentation,
        helpControlLeadingX: CGFloat? = nil
    ) -> CGRect {
        let visibleWindowCount = [presentation.fiveHour, presentation.weekly]
            .compactMap { $0 }
            .count
        let width = visibleWindowCount == 1
            ? singleWindowWidth
            : size.width
        return frame(
            in: codexWindowFrame,
            width: width,
            helpControlLeadingX: helpControlLeadingX)
    }

    private static func frame(
        in codexWindowFrame: CGRect,
        width: CGFloat,
        helpControlLeadingX: CGFloat?
    ) -> CGRect {
        let discoveredTrailingX: CGFloat? = helpControlLeadingX.flatMap { leadingX in
            guard leadingX.isFinite,
                  leadingX >= codexWindowFrame.minX,
                  leadingX <= codexWindowFrame.maxX else {
                return nil
            }
            return leadingX - helpControlGap
        }
        let relativeFallbackTrailingX = codexWindowFrame.minX
            + (codexWindowFrame.width * fallbackTrailingPositionRatio).rounded()
        let preferredTrailingX = discoveredTrailingX
            ?? relativeFallbackTrailingX
        let preferredOriginX = preferredTrailingX - width
        let minimumOriginX = codexWindowFrame.minX + bottomInset
        let maximumOriginX = max(
            minimumOriginX,
            codexWindowFrame.maxX - bottomInset - width)
        let originX = max(
            minimumOriginX,
            min(preferredOriginX, maximumOriginX))
        return CGRect(
            x: originX,
            y: codexWindowFrame.minY + bottomInset,
            width: width,
            height: size.height)
    }

    static func detailsContentHeight(
        presentation: CodexQuotaOverlayPresentation,
        resetCredits: CodexQuotaOverlayResetCreditsPresentation?
    ) -> CGFloat {
        let windowCount = [presentation.fiveHour, presentation.weekly]
            .compactMap { $0 }
            .count
        guard windowCount > 0 else { return 0 }

        var height: CGFloat = 24 + detailsHeaderHeight
        // The rendered quota row includes two caption lines, the progress
        // track, and vertical padding. Keep the model height above its actual
        // SwiftUI fitting height so ordinary cards select the static branch.
        height += CGFloat(windowCount) * 46
        height += CGFloat(max(0, windowCount - 1)) * 15

        if let resetCredits {
            height += 17 + 16
            if !resetCredits.expirations.isEmpty {
                height += 3
                height += CGFloat(resetCredits.expirations.count) * 12
                height += CGFloat(max(0, resetCredits.expirations.count - 1)) * 4
            } else {
                height += 16
            }
        }
        return ceil(max(72, height))
    }

    static func detailsFrame(
        in codexWindowFrame: CGRect,
        contentHeight: CGFloat,
        helpControlLeadingX: CGFloat? = nil
    ) -> CGRect {
        let summaryFrame = frame(
            in: codexWindowFrame,
            helpControlLeadingX: helpControlLeadingX)
        let width = min(detailsWidth, max(
            1,
            codexWindowFrame.width - detailsLeftInset * 2))
        let preferredOriginX = summaryFrame.maxX - width
        let minimumOriginX = codexWindowFrame.minX + detailsLeftInset
        let maximumOriginX = codexWindowFrame.maxX - detailsLeftInset - width
        let originY = summaryFrame.maxY + detailsGap
        let availableHeight = max(
            1,
            codexWindowFrame.maxY - originY - detailsTopInset)
        return CGRect(
            x: max(
                minimumOriginX,
                min(preferredOriginX, maximumOriginX)),
            y: originY,
            width: width,
            height: min(contentHeight, availableHeight))
    }

    static func isOverlayWindowIdentifier(_ rawValue: String?) -> Bool {
        rawValue == windowIdentifier || rawValue == detailsWindowIdentifier
    }
}

enum CodexQuotaOverlayInteractionPolicy {
    static func shouldDismissDetails(
        afterMouseDownIn windowIdentifier: String?
    ) -> Bool {
        !CodexQuotaOverlayLayout.isOverlayWindowIdentifier(windowIdentifier)
    }
}
