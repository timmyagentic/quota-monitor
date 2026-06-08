import AppKit
import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Update window controller lifecycle")
struct UpdateWindowControllerTests {

    @Test
    func windowCloseRunsLifecycleCallback() {
        var didClose = false
        let controller = UpdateWindowController(
            state: UpdateWindowState(),
            onWindowClosed: { didClose = true })

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification))

        #expect(didClose == true)
    }
}
