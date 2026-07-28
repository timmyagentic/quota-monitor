import AppKit
import Foundation
import Observation

/// Installs the quota surface inside Codex's own renderer.
///
/// The integration is intentionally opt-in and loopback-only. It never edits
/// ChatGPT.app: when Codex is not running, it starts the signed installed app
/// with a local DevTools endpoint, validates the renderer target, then evaluates
/// the reversible payload in that renderer.
@MainActor
final class CodexSidebarQuotaController {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex"
    ]
    private static let debuggingPort = 55_321
    private static let retryNanoseconds: UInt64 = 2_000_000_000

    private let settings: SettingsStore
    private let workspace: NSWorkspace
    private let session: URLSession
    private var lifecycleTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var enabled = false
    private var launchedForCurrentOptIn = false

    init(
        settings: SettingsStore = .shared,
        workspace: NSWorkspace = .shared,
        session: URLSession? = nil
    ) {
        self.settings = settings
        self.workspace = workspace
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 5
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func start() {
        observeSetting()
    }

    func stop() {
        enabled = false
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        Task { [weak self] in
            await self?.evaluateOnce(CodexSidebarQuotaRenderer.cleanupExpression)
        }
    }

    private func observeSetting() {
        withObservationTracking {
            let nextEnabled = settings.codexSidebarQuotaEnabled
            apply(enabled: nextEnabled)
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observeSetting()
            }
        }
    }

    private func apply(enabled nextEnabled: Bool) {
        guard nextEnabled != enabled else { return }
        enabled = nextEnabled
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil

        if nextEnabled {
            launchedForCurrentOptIn = false
            lifecycleTask = Task { [weak self] in
                await self?.maintainInjection()
            }
        } else {
            launchedForCurrentOptIn = false
            lifecycleTask = Task { [weak self] in
                await self?.evaluateOnce(CodexSidebarQuotaRenderer.cleanupExpression)
            }
        }
    }

    private func maintainInjection() async {
        while enabled, !Task.isCancelled {
            do {
                if let target = try await validatedTarget() {
                    try await holdInjection(on: target)
                } else if runningCodexApplication() == nil {
                    try await launchCodexWithDebuggingIfNeeded()
                }
            } catch is CancellationError {
                return
            } catch {
                Log.ui.debug(
                    "Codex sidebar quota unavailable: \(error.localizedDescription, privacy: .public)")
            }

            do {
                try await Task.sleep(nanoseconds: Self.retryNanoseconds)
            } catch {
                return
            }
        }
    }

    private func holdInjection(on target: CodexSidebarQuotaTarget) async throws {
        guard let socketURL = URL(string: target.webSocketDebuggerURL) else {
            throw IntegrationError.invalidSocketURL
        }
        let socket = session.webSocketTask(with: socketURL)
        activeSocket = socket
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if activeSocket === socket {
                activeSocket = nil
            }
        }

        let requestID = 1
        let request = CodexSidebarQuotaRenderer.evaluateRequest(id: requestID)
        let data = try JSONSerialization.data(withJSONObject: request)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        try await waitForResponse(id: requestID, on: socket)
        Log.ui.info("Codex sidebar quota installed in validated renderer")

        // Keep the CDP connection alive. A renderer navigation closes it, which
        // returns control to the retry loop and causes a clean reinjection.
        while enabled, !Task.isCancelled {
            _ = try await socket.receive()
        }
    }

    private func waitForResponse(
        id: Int,
        on socket: URLSessionWebSocketTask
    ) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value):
                data = value
            case .string(let value):
                data = Data(value.utf8)
            @unknown default:
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  object["id"] as? Int == id
            else { continue }
            if object["error"] != nil {
                throw IntegrationError.evaluationFailed
            }
            return
        }
        throw CancellationError()
    }

    private func evaluateOnce(_ expression: String) async {
        do {
            guard let target = try await validatedTarget(),
                  let socketURL = URL(string: target.webSocketDebuggerURL)
            else { return }
            let socket = session.webSocketTask(with: socketURL)
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            let request: [String: Any] = [
                "id": 2,
                "method": "Runtime.evaluate",
                "params": ["expression": expression, "awaitPromise": true]
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            try await waitForResponse(id: 2, on: socket)
        } catch {
            Log.ui.debug(
                "Codex sidebar quota cleanup skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func validatedTarget() async throws -> CodexSidebarQuotaTarget? {
        guard let application = runningCodexApplication(),
              CodexSidebarQuotaEndpointValidator.listenerBelongsToCodex(
                port: Self.debuggingPort,
                applicationPID: application.processIdentifier)
        else { return nil }
        let endpoint = URL(
            string: "http://127.0.0.1:\(Self.debuggingPort)/json/list")!
        let (data, response) = try await session.data(from: endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        let targets = try JSONDecoder().decode(
            [CodexSidebarQuotaTarget].self,
            from: data)
        return CodexSidebarQuotaTarget.selectValidated(from: targets)
    }

    private func runningCodexApplication() -> NSRunningApplication? {
        workspace.runningApplications.first {
            guard let identifier = $0.bundleIdentifier else { return false }
            return Self.supportedBundleIdentifiers.contains(identifier)
        }
    }

    private func launchCodexWithDebuggingIfNeeded() async throws {
        guard !launchedForCurrentOptIn else { return }
        guard let appURL = installedCodexURL() else {
            throw IntegrationError.applicationNotFound
        }
        launchedForCurrentOptIn = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(Self.debuggingPort)"
        ]
        configuration.activates = true
        do {
            _ = try await workspace.openApplication(
                at: appURL,
                configuration: configuration)
            Log.ui.info("Reopened Codex with loopback DevTools for sidebar quota")
        } catch {
            launchedForCurrentOptIn = false
            throw error
        }
    }

    private func installedCodexURL() -> URL? {
        for identifier in Self.supportedBundleIdentifiers {
            if let url = workspace.urlForApplication(
                withBundleIdentifier: identifier),
               Bundle(url: url)?.bundleIdentifier == identifier {
                return url
            }
        }
        return nil
    }
}

private extension CodexSidebarQuotaController {
    enum IntegrationError: LocalizedError {
        case applicationNotFound
        case invalidSocketURL
        case evaluationFailed

        var errorDescription: String? {
            switch self {
            case .applicationNotFound:
                "Codex application is not installed"
            case .invalidSocketURL:
                "Codex returned an invalid DevTools websocket URL"
            case .evaluationFailed:
                "Codex rejected the sidebar renderer payload"
            }
        }
    }
}
