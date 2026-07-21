import Foundation
import Testing

@Suite("What's New layout")
struct WhatsNewLayoutTests {
    @Test("Window manager owns a resizable fifth app window")
    func windowManagerWiresShowcase() throws {
        let source = try Self.source(named: "QuotaMonitor/App/WindowManager.swift")
        #expect(source.contains("case \"whats-new\": return L10n.whatsNewWindowTitle"))
        #expect(source.contains("content: WhatsNewView(content: whatsNewContent)"))
        #expect(source.contains("initialContentSize: NSSize(width: 840, height: 680)"))
        #expect(source.contains("minContentSize: NSSize(width: 700, height: 560)"))
        #expect(source.contains("case \"dashboard\", \"settings\", \"whats-new\""))
        #expect(source.contains("onWhatsNewPresentationRequested?()"))
    }

    @Test("Media supports image, video, poster fallback, and reduced motion")
    func mediaLifecycleIsExplicit() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/WhatsNew/WhatsNewMediaView.swift")
        #expect(source.contains("Image(nsImage: image)"))
        #expect(source.contains("private struct WhatsNewAVPlayerView: NSViewRepresentable"))
        #expect(source.contains("let view = AVPlayerView()"))
        #expect(source.contains("view.controlsStyle = .inline"))
        #expect(!source.contains("VideoPlayer("))
        #expect(source.contains("player.isMuted = true"))
        #expect(source.contains("accessibilityReduceMotion"))
        #expect(source.contains("posterOrUnavailable"))
        #expect(source.contains(".onDisappear { tearDownPlayback() }"))
        #expect(source.contains("looper?.disableLooping()"))
        #expect(source.contains("view.player = nil"))
        #expect(source.contains("NSWindow.didResignKeyNotification"))
        #expect(source.contains("NSWindow.willCloseNotification"))
        #expect(source.contains("isWhatsNewWindow(notification.object)"))
    }

    @Test("Permanent reopen entries exist in the menu and Settings")
    func manualReopenIsWired() throws {
        let menu = try Self.source(
            named: "QuotaMonitor/Features/MenuBar/MenuBarContentView.swift")
        let settings = try Self.source(
            named: "QuotaMonitor/Features/Settings/GeneralSettingsTab.swift")
        #expect(menu.contains("windowActions(env).openWhatsNew()"))
        #expect(menu.contains(".accessibilityLabel(L10n.whatsNewMenuItem)"))
        #expect(settings.contains("LabeledContent(L10n.whatsNewSettingsRow)"))
        #expect(settings.contains("WindowManager.shared.show(\"whats-new\")"))
    }

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
