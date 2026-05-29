import Foundation
import CoreGraphics

/// Whether the menu-bar status item is actually on screen, or clipped
/// away (notch-left overflow / packed bar / hidden by a menu-bar
/// manager). Pure value type so it can drive unit tests without AppKit.
enum StatusItemVisibility: Equatable {
    case visible
    case clipped
}

/// Pure geometry behind `StatusItemController.currentVisibility()`.
///
/// **Fails open.** Only strong signals count as `.clipped`: a missing
/// frame, a missing host screen, zero width, or a frame lying entirely
/// outside the host screen on the horizontal axis (how AppKit parks an
/// item that doesn't fit left of the notch). A partially-overlapping
/// frame is `.visible` — we would rather occasionally skip the Dock
/// fallback than falsely strand a user who can in fact see their icon.
enum MenuBarVisibilityEvaluator {
    static func evaluate(buttonWindowFrame: CGRect?,
                         hostScreenFrame: CGRect?) -> StatusItemVisibility {
        guard let frame = buttonWindowFrame,
              let screen = hostScreenFrame else { return .clipped }
        if frame.width <= 0 { return .clipped }
        if frame.maxX <= screen.minX || frame.minX >= screen.maxX {
            return .clipped
        }
        return .visible
    }
}
