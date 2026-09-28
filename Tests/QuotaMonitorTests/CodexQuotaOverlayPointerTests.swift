import AppKit
import SwiftUI
import Testing
@testable import QuotaMonitor

@Suite("Quota overlay hosted pointer input", .serialized)
@MainActor
struct CodexQuotaOverlayPointerTests {
    @Test("The actual summary keeps its mouse target through a click or held drag", arguments: [false, true])
    func actualSummaryClick(holdToDrag: Bool) async throws {
        let size = CGSize(width: 148, height: 28)
        let suite = "quota-overlay-pointer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, hasExistingAppData: { false })
        let environment = AppEnvironment(startBackgroundTasks: false)
        let state = CodexQuotaOverlayViewState()
        var activated = 0
        var drops = 0
        var hovered: [Bool] = []
        let content = CodexQuotaOverlayView(state: state, onHoverChanged: { hovered.append($0) }, onResetPosition: {},
            onActivate: { activated += 1 }, onPressBegan: { _ in },
            onDragBegan: { _ in }, onDragChanged: { _ in }, onDragEnded: { drops += 1 },
            onDragCancelled: { state.dragPhase = .idle })
            .environment(environment).environment(settings).environment(LocalizationStore.shared)
        let panel = CodexQuotaOverlayPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let target = try #require(host.hitTest(CGPoint(x: 74, y: 14)) as? CodexQuotaOverlayMouseView)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: 74, y: 14), modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        // Use the native hover path while the panel is non-key, as it is over Codex.
        target.updateTrackingAreas()
        #expect(!panel.isKeyWindow)
        #expect(target.trackingAreas.contains { $0.options.contains(.activeAlways) })
        target.mouseEntered(with: try event(.mouseMoved))
        #expect(hovered == [true])
        target.mouseExited(with: try event(.mouseMoved))
        #expect(hovered == [true, false])
        var pointer = CGPoint(x: 250, y: 214)
        target.mouseLocation = { pointer }
        target.mouseDown(with: try event(.leftMouseDown))
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.dragPhase == .pressing)
        #expect(host.hitTest(CGPoint(x: 74, y: 14)) === target)
        if holdToDrag {
            try await Task.sleep(for: .milliseconds(1100))
            host.layoutSubtreeIfNeeded()
            #expect(state.dragPhase == .ready)
            #expect(host.hitTest(CGPoint(x: 74, y: 14)) === target)
            pointer.x += 50
            target.mouseDragged(with: try event(.leftMouseDragged))
            host.layoutSubtreeIfNeeded()
            #expect(state.dragPhase == .dragging)
            #expect(host.hitTest(CGPoint(x: 74, y: 14)) === target)
        }
        target.mouseUp(with: try event(.leftMouseUp))
        #expect(activated == (holdToDrag ? 0 : 1))
        #expect(drops == (holdToDrag ? 1 : 0))
        #expect(state.dragPhase == .idle)
    }

    @Test("Compact and full badges expose a mouse target across their visible bounds", arguments: [88.0, 148.0, 248.0])
    func hostedMouseTarget(width: Double) async throws {
        let size = CGSize(width: width, height: 28)
        let content = Color.clear.frame(width: size.width, height: size.height)
            .overlay {
                CodexQuotaOverlayMouseInput(onPress: { _ in }, onMove: { _ in },
                    onRelease: { _, _ in }, onCancel: {}, onResetPosition: {})
                    .accessibilityHidden(true)
            }
        let panel = CodexQuotaOverlayPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let input = try #require(descendants(of: host).compactMap { $0 as? CodexQuotaOverlayMouseView }.first)
        #expect(input.bounds.size == size)
        for point in [CGPoint(x: 2, y: 2), CGPoint(x: width / 2, y: 14), CGPoint(x: width - 2, y: 26)] {
            #expect(host.hitTest(point) === input)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
