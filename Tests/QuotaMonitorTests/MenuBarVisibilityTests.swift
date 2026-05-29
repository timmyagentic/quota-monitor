import Foundation
import Testing
@testable import QuotaMonitor

/// Pure geometry for "is the status item actually on screen". Fails OPEN:
/// only strong signals (no frame, no screen, zero width, entirely
/// off-screen horizontally) count as clipped, so a partially-overlapping
/// item is treated as visible rather than falsely forcing the Dock
/// fallback.
@Suite("Menu-bar visibility evaluator")
struct MenuBarVisibilityTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test
    func visibleWhenInsideScreen() {
        let button = CGRect(x: 1200, y: 876, width: 60, height: 24)
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: button, hostScreenFrame: screen) == .visible)
    }

    @Test
    func clippedWhenNoFrame() {
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: nil, hostScreenFrame: screen) == .clipped)
    }

    @Test
    func clippedWhenNoScreen() {
        let button = CGRect(x: 1200, y: 876, width: 60, height: 24)
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: button, hostScreenFrame: nil) == .clipped)
    }

    @Test
    func clippedWhenZeroWidth() {
        let button = CGRect(x: 1200, y: 876, width: 0, height: 24)
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: button, hostScreenFrame: screen) == .clipped)
    }

    @Test
    func clippedWhenEntirelyLeftOfScreen() {
        // AppKit parks an overflowed item off the left edge.
        let button = CGRect(x: -120, y: 876, width: 60, height: 24)
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: button, hostScreenFrame: screen) == .clipped)
    }

    @Test
    func clippedWhenEntirelyRightOfScreen() {
        let button = CGRect(x: 1500, y: 876, width: 60, height: 24)
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: button, hostScreenFrame: screen) == .clipped)
    }

    @Test
    func visibleWhenPartiallyOverlapping() {
        // Fail open: partial overlap is treated as visible.
        let button = CGRect(x: -30, y: 876, width: 60, height: 24)
        #expect(MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: button, hostScreenFrame: screen) == .visible)
    }
}
