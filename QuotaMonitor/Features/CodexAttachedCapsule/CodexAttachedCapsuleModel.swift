import CoreGraphics
import Foundation

struct CodexAttachedCapsulePresentation: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case fresh
        case stale
        case unavailable
    }

    static let maximumFreshAge: TimeInterval = 10 * 60

    let availability: Availability
    let usedPercent: Int?
    let remainingPercent: Int?
    let resetAt: Date?

    init(
        snapshot: RateLimitSnapshot?,
        now: Date = Date(),
        maximumFreshAge: TimeInterval = Self.maximumFreshAge
    ) {
        guard let snapshot, let weekly = snapshot.secondary else {
            availability = .unavailable
            usedPercent = nil
            remainingPercent = nil
            resetAt = nil
            return
        }

        let used = Self.roundedPercent(weekly.usedPercent)
        availability = now.timeIntervalSince(snapshot.capturedAt) > maximumFreshAge
            || weekly.resetAt <= now
            ? .stale
            : .fresh
        usedPercent = used
        remainingPercent = 100 - used
        resetAt = weekly.resetAt
    }

    private static func roundedPercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(0, min(100, value)).rounded())
    }
}

struct CodexWindowInfo: Equatable, Sendable {
    let id: Int
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    let isOnscreen: Bool
}

enum CodexWindowSelector {
    static let minimumSize = CGSize(width: 520, height: 400)

    static func bestWindow(in windows: [CodexWindowInfo]) -> CodexWindowInfo? {
        windows
            .filter {
                $0.layer == 0
                    && $0.alpha > 0.01
                    && $0.isOnscreen
                    && $0.bounds.width >= minimumSize.width
                    && $0.bounds.height >= minimumSize.height
            }
            .max { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height
                    < rhs.bounds.width * rhs.bounds.height
            }
    }
}

enum CodexAttachedCapsuleGeometry {
    static let compactSize = CGSize(width: 108, height: 30)
    static let expandedSize = CGSize(width: 228, height: 166)

    private static let sidebarAnchorFromLeading: CGFloat = 166
    private static let windowBottomInset: CGFloat = 14
    private static let windowHorizontalInset: CGFloat = 8

    static func appKitFrame(
        quartzBounds: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: quartzBounds.minX,
            y: primaryScreenMaxY - quartzBounds.maxY,
            width: quartzBounds.width,
            height: quartzBounds.height)
    }

    static func panelFrame(
        targetWindow: CGRect,
        panelSize: CGSize
    ) -> CGRect {
        let preferredCenterX = targetWindow.minX + min(
            sidebarAnchorFromLeading,
            targetWindow.width / 2)
        let minimumX = targetWindow.minX + windowHorizontalInset
        let maximumX = max(
            minimumX,
            targetWindow.maxX - windowHorizontalInset - panelSize.width)
        let preferredX = preferredCenterX - panelSize.width / 2

        return CGRect(
            x: max(minimumX, min(maximumX, preferredX)),
            y: targetWindow.minY + windowBottomInset,
            width: panelSize.width,
            height: panelSize.height)
    }
}
