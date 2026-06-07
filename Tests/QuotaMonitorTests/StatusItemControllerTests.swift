import AppKit
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Status item popover window")
struct StatusItemControllerTests {

    @Test("Popover window can appear above full-screen Spaces")
    func popoverWindowCanJoinFullScreenSpaces() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.collectionBehavior = []
        window.level = .normal

        StatusItemController.configurePopoverWindowForMenuBarPresentation(window)

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.hidesOnDeactivate == false)
        #expect(window.level == .popUpMenu)
    }

    @Test("Offscreen full-screen menu-bar anchors are normalized to the top edge")
    func offscreenFullscreenAnchorUsesTopEdge() {
        let origin = StatusItemController.menuBarPopoverOrigin(
            windowSize: NSSize(width: 400, height: 560),
            anchorRect: NSRect(x: 1_338, y: -59, width: 100, height: 24),
            screenFrame: NSRect(x: 0, y: 0, width: 2_048, height: 1_152),
            statusBarThickness: 24)

        #expect(origin.x == 1_188)
        #expect(origin.y == 568)
    }

    @Test("Popover origin stays inside the screen horizontally")
    func popoverOriginStaysInsideScreen() {
        let origin = StatusItemController.menuBarPopoverOrigin(
            windowSize: NSSize(width: 400, height: 560),
            anchorRect: NSRect(x: 2_000, y: 1_128, width: 100, height: 24),
            screenFrame: NSRect(x: 0, y: 0, width: 2_048, height: 1_152),
            statusBarThickness: 24)

        #expect(origin.x == 1_640)
        #expect(origin.y == 568)
    }
}
