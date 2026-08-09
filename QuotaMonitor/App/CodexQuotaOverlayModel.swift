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
    let resetAt: Date
    let severity: Severity
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
            resetAt: window.resetAt,
            severity: severity)
    }
}

struct CodexQuotaOverlayResetCreditsPresentation: Equatable {
    let availableCount: Int
    let expirations: [Date]

    static func make(
        snapshot: CodexResetCreditsSnapshot?,
        fallbackAvailableCount: Int?
    ) -> CodexQuotaOverlayResetCreditsPresentation? {
        if let snapshot, snapshot.availableCount > 0 {
            return CodexQuotaOverlayResetCreditsPresentation(
                availableCount: snapshot.availableCount,
                expirations: Array(snapshot.credits.prefix(3).map(\.expiresAt)))
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
        candidates.first {
            $0.ownerPID == processIdentifier
                && $0.layer == 0
                && $0.alpha > 0.01
                && $0.bounds.width >= minimumWindowSize.width
                && $0.bounds.height >= minimumWindowSize.height
        }
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
    static let windowIdentifier = "codex-quota-overlay"
    static let detailsWindowIdentifier = "codex-quota-overlay-details"
    private static let legacyAccountRowTrailingOffset: CGFloat = 432
    private static let bottomInset: CGFloat = 12
    private static let detailsLeftInset: CGFloat = 12
    private static let detailsRightOffset: CGFloat = 476
    private static let detailsGap: CGFloat = 8
    private static let detailsTopInset: CGFloat = 12

    /// Preserve the established injected-widget slot immediately before the
    /// account-row help control. The native overlay is wider because it shows
    /// both rolling windows, so anchor its trailing edge instead of placing it
    /// directly after the account name.
    static func frame(in codexWindowFrame: CGRect) -> CGRect {
        frame(in: codexWindowFrame, width: size.width)
    }

    static func frame(
        in codexWindowFrame: CGRect,
        presentation: CodexQuotaOverlayPresentation
    ) -> CGRect {
        let visibleWindowCount = [presentation.fiveHour, presentation.weekly]
            .compactMap { $0 }
            .count
        let width = visibleWindowCount == 1
            ? singleWindowWidth
            : size.width
        return frame(in: codexWindowFrame, width: width)
    }

    private static func frame(
        in codexWindowFrame: CGRect,
        width: CGFloat
    ) -> CGRect {
        let trailingX = min(
            codexWindowFrame.minX + legacyAccountRowTrailingOffset,
            codexWindowFrame.maxX - bottomInset)
        return CGRect(
            x: trailingX - width,
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

        var height: CGFloat = 28
        if presentation.isCached {
            height += 22
        }
        height += CGFloat(windowCount) * 66
        height += CGFloat(max(0, windowCount - 1)) * 17

        if let resetCredits {
            height += 21 + 14
            if !resetCredits.expirations.isEmpty {
                height += 8
                height += CGFloat(resetCredits.expirations.count) * 14
                height += CGFloat(max(0, resetCredits.expirations.count - 1)) * 6
            } else {
                height += 20
            }
        }

        // Every absolute timestamp in the card uses local time, so keep the
        // same explanatory footer the previous inline widget provided.
        height += 22
        return ceil(max(104, height))
    }

    static func detailsFrame(
        in codexWindowFrame: CGRect,
        contentHeight: CGFloat
    ) -> CGRect {
        let summaryFrame = frame(in: codexWindowFrame)
        let width = min(
            detailsRightOffset - detailsLeftInset,
            max(1, codexWindowFrame.width - detailsLeftInset * 2))
        let originY = summaryFrame.maxY + detailsGap
        let availableHeight = max(
            1,
            codexWindowFrame.maxY - originY - detailsTopInset)
        return CGRect(
            x: codexWindowFrame.minX + detailsLeftInset,
            y: originY,
            width: width,
            height: min(contentHeight, availableHeight))
    }

    static func isOverlayWindowIdentifier(_ rawValue: String?) -> Bool {
        rawValue == windowIdentifier || rawValue == detailsWindowIdentifier
    }
}
