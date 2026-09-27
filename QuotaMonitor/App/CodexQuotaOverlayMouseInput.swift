import AppKit
import SwiftUI

/// Keep the pointer in screen coordinates while the containing NSPanel moves.
/// SwiftUI's global gesture space belongs to that moving window.
struct CodexQuotaOverlayMouseInput: NSViewRepresentable {
    var onPress: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onRelease: (CGPoint, CGSize) -> Void
    var onCancel: () -> Void
    var onResetPosition: () -> Void

    func makeNSView(context: Context) -> CodexQuotaOverlayMouseView {
        CodexQuotaOverlayMouseView()
    }

    func updateNSView(_ view: CodexQuotaOverlayMouseView, context: Context) {
        view.onPress = onPress
        view.onMove = onMove
        view.onRelease = onRelease
        view.onCancel = onCancel
        view.onResetPosition = onResetPosition
    }
}

final class CodexQuotaOverlayMouseView: NSView {
    var onPress: (CGPoint) -> Void = { _ in }
    var onMove: (CGPoint) -> Void = { _ in }
    var onRelease: (CGPoint, CGSize) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    var onResetPosition: () -> Void = {}
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private var pressLocation: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let location = mouseLocation()
        pressLocation = location
        onPress(location)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressLocation != nil else { return }
        onMove(mouseLocation())
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressLocation else { return }
        pressLocation = nil
        let location = mouseLocation()
        onRelease(location, CGSize(width: location.x - start.x, height: location.y - start.y))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, pressLocation != nil {
            pressLocation = nil
            onCancel()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: L10n.codexOverlayResetPosition,
            action: #selector(resetPosition), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func resetPosition() { onResetPosition() }
}
