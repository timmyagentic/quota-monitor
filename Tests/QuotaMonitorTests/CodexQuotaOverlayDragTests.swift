import AppKit
import Testing
@testable import QuotaMonitor

@Suite("Quota overlay screen-coordinate dragging")
struct CodexQuotaOverlayDragTests {
    @Test("A compact drop restores the full readout without shifting its origin")
    func compactDrop() throws {
        let host = CGRect(x: -1200, y: 200, width: 1200, height: 800)
        let widths: [(CGFloat, CGFloat)] = [(88, 148), (164, 248)]
        for (compactWidth, fullWidth) in widths {
            let drop = CGRect(x: -700, y: 450, width: compactWidth, height: 28)
            let position = try #require(CodexQuotaOverlayLayout.manualPosition(
                for: drop, in: host, restoredWidth: fullWidth))
            let metric = CodexQuotaOverlayMetric(percent: 20, usedPercent: 20,
                remainingPercent: 80, displayMode: .used, resetAt: .distantFuture, severity: .healthy)
            let presentation = CodexQuotaOverlayPresentation(
                fiveHour: fullWidth == 248 ? metric : nil, weekly: metric, isCached: false)
            let restored = try #require(CodexQuotaOverlayLayout.summaryPlacement(
                in: host, presentation: presentation, header: nil, manualPosition: position))
            #expect(abs(restored.frame.minX - drop.minX) < 0.001)
            #expect(abs(restored.frame.minY - drop.minY) < 0.001)
            #expect(restored.frame.width == fullWidth)
        }
    }

    @Test("Header discovery and quota changes cannot interrupt an active drag")
    func activeDragOwnsPlacement() {
        let drag = CodexQuotaOverlaySummaryPlacement(
            frame: CGRect(x: 200, y: 300, width: 88, height: 28), compact: true)
        let unavailable = CodexQuotaOverlayPresentation(fiveHour: nil, weekly: nil, isCached: false)
        #expect(CodexQuotaOverlayLayout.summaryPlacement(
            in: CGRect(x: 0, y: 0, width: 1200, height: 800),
            presentation: unavailable, header: nil, activeDrag: drag) == drag)
    }

    @Test("Repeated moves follow screen points even as their containing panel moves")
    @MainActor
    func nativeMovesAndFinalRelease() throws {
        let panel = CodexQuotaOverlayPanel(contentRect: CGRect(x: 200, y: 200, width: 148, height: 28),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = CodexQuotaOverlayMouseView(frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.contentView = view
        let start = panel.frame
        let press = CGPoint(x: 230, y: 214)
        var pointer = press
        var observed: [CGPoint] = []
        var translation: CGSize?
        view.mouseLocation = { pointer }
        view.onPress = { observed.append($0) }
        view.onMove = { point in
            observed.append(point)
            panel.setFrame(CodexQuotaOverlayDragFramePolicy.frame(from: start,
                pressLocation: press, currentLocation: point,
                in: CGRect(x: 0, y: 0, width: 1200, height: 800)), display: false)
        }
        view.onRelease = { point, delta in observed.append(point); translation = delta }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 30, y: 14),
                modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown))
        for offset: CGFloat in [40, 80, 140, 90] {
            pointer = CGPoint(x: press.x + offset, y: press.y + offset / 2)
            view.mouseDragged(with: try event(.leftMouseDragged))
            #expect(panel.frame.minX == start.minX + offset)
            #expect(panel.frame.minY == start.minY + offset / 2)
        }
        // A final mouse-up sample is distinct from the previous drag event.
        pointer = CGPoint(x: press.x + 110, y: press.y + 70)
        view.mouseUp(with: try event(.leftMouseUp))
        #expect(observed.last == pointer)
        #expect(translation == CGSize(width: 110, height: 70))
        let count = observed.count
        view.mouseDragged(with: try event(.leftMouseDragged))
        #expect(observed.count == count)
    }

    @Test("Removing the input view cancels a press instead of saving a drop")
    @MainActor
    func detachCancelsPress() throws {
        let view = CodexQuotaOverlayMouseView()
        var cancelled = 0
        var released = 0
        view.onCancel = { cancelled += 1 }
        view.onRelease = { _, _ in released += 1 }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        view.viewWillMove(toWindow: nil)
        view.mouseUp(with: event)
        #expect(cancelled == 1)
        #expect(released == 0)
    }
}
