import AppKit

/// Chooses the Dashboard's first-open size from the usable workspace of the
/// display where the user invoked it. WindowManager still assigns the existing
/// `dashboard` frame-autosave name afterwards, so a remembered user frame wins
/// over every value produced here.
struct DashboardWindowSizingPolicy {
    struct ScreenGeometry: Equatable {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    static let minimumContentSize = NSSize(width: 820, height: 560)
    static let fallbackContentSize = NSSize(width: 980, height: 680)

    // 900pt keeps the compact 53-week heatmap visible without horizontal
    // scrolling; 1180pt gives desktop charts room without approaching the
    // Dashboard content's 1240pt maximum or becoming sprawling on large panels.
    private static let preferredMinimumContentSize = NSSize(width: 900, height: 600)
    private static let preferredMaximumContentSize = NSSize(width: 1180, height: 760)
    private static let widthFraction: CGFloat = 0.68
    private static let heightFraction: CGFloat = 0.72
    private static let screenMargin: CGFloat = 32
    private static let windowChromeAllowance: CGFloat = 52

    static func preferredVisibleFrame(
        pointerLocation: NSPoint,
        screens: [ScreenGeometry],
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        screens.first { $0.frame.contains(pointerLocation) }?.visibleFrame
            ?? fallbackVisibleFrame
            ?? screens.first?.visibleFrame
    }

    static func contentSize(forVisibleFrame visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return fallbackContentSize
        }

        let preferredWidth = clamp(
            visibleFrame.width * widthFraction,
            minimum: preferredMinimumContentSize.width,
            maximum: preferredMaximumContentSize.width)
        let preferredHeight = clamp(
            visibleFrame.height * heightFraction,
            minimum: preferredMinimumContentSize.height,
            maximum: preferredMaximumContentSize.height)

        // Keep a calm perimeter around the first-open window. If a workspace is
        // exceptionally small, the Dashboard's functional minimum wins and
        // AppKit can perform its normal screen constraint.
        let maximumFittingWidth = max(
            minimumContentSize.width,
            visibleFrame.width - screenMargin * 2)
        let maximumFittingHeight = max(
            minimumContentSize.height,
            visibleFrame.height - screenMargin * 2 - windowChromeAllowance)

        return NSSize(
            width: min(preferredWidth, maximumFittingWidth).rounded(),
            height: min(preferredHeight, maximumFittingHeight).rounded())
    }

    static func centeredOrigin(windowFrameSize: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: (visibleFrame.midX - windowFrameSize.width / 2).rounded(),
            y: (visibleFrame.midY - windowFrameSize.height / 2).rounded())
    }

    private static func clamp(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}
