import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex sidebar quota target validation")
struct CodexSidebarQuotaTargetTests {
    @Test("selects only the expected app renderer on a loopback websocket")
    func selectsExpectedRenderer() {
        let targets = [
            CodexSidebarQuotaTarget(
                id: "devtools",
                type: "page",
                url: "devtools://devtools/bundled/inspector.html",
                webSocketDebuggerURL: "ws://127.0.0.1:55321/devtools/page/devtools"),
            CodexSidebarQuotaTarget(
                id: "remote",
                type: "page",
                url: "app://-/index.html",
                webSocketDebuggerURL: "ws://192.168.1.8:55321/devtools/page/remote"),
            CodexSidebarQuotaTarget(
                id: "codex",
                type: "page",
                url: "app://-/index.html",
                webSocketDebuggerURL: "ws://127.0.0.1:55321/devtools/page/codex")
        ]

        #expect(CodexSidebarQuotaTarget.selectValidated(from: targets)?.id == "codex")
    }

    @Test("rejects non-app pages and non-loopback websocket hosts")
    func rejectsUnsafeTargets() {
        let web = CodexSidebarQuotaTarget(
            id: "web",
            type: "page",
            url: "https://chatgpt.com/",
            webSocketDebuggerURL: "ws://127.0.0.1:55321/devtools/page/web")
        let wildcard = CodexSidebarQuotaTarget(
            id: "wildcard",
            type: "page",
            url: "app://-/index.html",
            webSocketDebuggerURL: "ws://0.0.0.0:55321/devtools/page/wildcard")
        let unexpectedAppPage = CodexSidebarQuotaTarget(
            id: "unexpected",
            type: "page",
            url: "app://settings/index.html",
            webSocketDebuggerURL: "ws://127.0.0.1:55321/devtools/page/unexpected")

        #expect(CodexSidebarQuotaTarget.selectValidated(
            from: [web, wildcard, unexpectedAppPage]) == nil)
    }
}

@Suite("Codex sidebar quota endpoint ownership")
struct CodexSidebarQuotaEndpointValidatorTests {
    @Test("accepts exactly one listener owned by the running Codex process")
    func acceptsMatchingListener() {
        #expect(CodexSidebarQuotaEndpointValidator.listenerBelongsToCodex(
            lsofOutput: "p4012\n",
            applicationPID: 4012))
    }

    @Test("rejects a different or ambiguous listener")
    func rejectsUnexpectedListener() {
        #expect(!CodexSidebarQuotaEndpointValidator.listenerBelongsToCodex(
            lsofOutput: "p9000\n",
            applicationPID: 4012))
        #expect(!CodexSidebarQuotaEndpointValidator.listenerBelongsToCodex(
            lsofOutput: "p4012\np9000\n",
            applicationPID: 4012))
    }
}

@Suite("Codex sidebar quota renderer")
struct CodexSidebarQuotaRendererTests {
    @Test("payload uses the native bridge and reversible sidebar DOM")
    func rendererContract() {
        let source = CodexSidebarQuotaRenderer.source

        #expect(source.contains("account/rateLimits/read"))
        #expect(source.contains("account/rateLimits/updated"))
        #expect(source.contains("window.electronBridge"))
        #expect(source.contains("aside.app-shell-left-panel"))
        #expect(source.contains("data-testid='app-shell-floating-left-panel'"))
        #expect(source.contains("--color-token-side-bar-background"))
        #expect(source.contains("MutationObserver"))
        #expect(source.contains("ResizeObserver"))
        #expect(source.contains("cleanup"))
    }

    @Test("payload is wrapped as a CDP Runtime.evaluate expression")
    func evaluateRequest() throws {
        let request = CodexSidebarQuotaRenderer.evaluateRequest(id: 42)
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"id\":42"))
        #expect(json.contains("Runtime.evaluate"))
        #expect(json.contains("returnByValue"))
    }
}

@MainActor
@Suite("Codex sidebar quota setting")
struct CodexSidebarQuotaSettingTests {
    @Test("new renderer injection remains off even when the legacy overlay was enabled")
    func explicitOptInAfterLegacyOverlay() {
        let suite = "test.codex-sidebar-quota.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "settings.codexAttachedCapsuleEnabled")

        let initial = SettingsStore(defaults: defaults)
        #expect(initial.codexSidebarQuotaEnabled == false)

        initial.codexSidebarQuotaEnabled = true
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaEnabled == true)
    }
}
