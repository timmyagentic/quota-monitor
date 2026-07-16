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

    @Test("Controller honors the update phase's close decision")
    func windowShouldCloseUsesStateDecision() {
        _ = NSApplication.shared
        let state = UpdateWindowState()
        var cancelCount = 0
        state.phase = .extracting
        state.onCancel = { cancelCount += 1 }
        let controller = UpdateWindowController(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)

        #expect(controller.windowShouldClose(window) == false)
        #expect(cancelCount == 0)

        state.phase = .downloading
        #expect(controller.windowShouldClose(window) == true)
        #expect(cancelCount == 1)
    }

    @Test
    func previewLauncherParsesLaunchArguments() throws {
        let qaConfig = Data(#"{"isActive":true}"#.utf8).base64EncodedString()
        let config = try #require(UpdateWindowPreviewLauncher.configuration(arguments: [
            "QuotaMonitor",
            "--quotamonitor-qa-config-base64",
            qaConfig,
            "--quotamonitor-preview-update-window-html",
            "/tmp/notes.html",
            "--quotamonitor-preview-update-window-version",
            "0.2.31",
            "--quotamonitor-preview-current-version=0.2.30",
            "--quotamonitor-preview-locale",
            "zh-Hans"
        ]))

        #expect(config.htmlPath == "/tmp/notes.html")
        #expect(config.newVersion == "0.2.31")
        #expect(config.currentVersion == "0.2.30")
        #expect(config.locale == "zh-Hans")
    }

    @Test
    func previewLauncherIgnoresLaunchArgumentsOutsideLocalQA() {
        let config = UpdateWindowPreviewLauncher.configuration(arguments: [
            "QuotaMonitor",
            "--quotamonitor-preview-update-window-html",
            "/tmp/notes.html"
        ])

        #expect(config == nil)
    }
}
