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
    private static let probeNanoseconds: UInt64 = 15_000_000_000

    private let settings: SettingsStore
    private let workspace: NSWorkspace
    private let session: URLSession
    private var lifecycleTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var enabled = false
    private var launchedForCurrentOptIn = false
    private var nextRequestID = 0

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

        try await install(on: socket)
        Log.ui.info("Codex sidebar quota installed in validated renderer")

        // A CDP page-target socket can survive renderer navigation even though
        // the JavaScript context is gone. Probe on a short cadence: a surviving
        // integration renews its self-cleanup lease, while a new context reports
        // `installed: false` and receives the full payload again.
        while enabled, !Task.isCancelled {
            try await Task.sleep(nanoseconds: Self.probeNanoseconds)
            let probe = try await evaluate(
                CodexSidebarQuotaRenderer.probeExpression,
                on: socket)
            if probe.boolValue(named: "installed") != true {
                try await install(on: socket)
                Log.ui.info("Codex sidebar quota reinstalled after renderer navigation")
            }
        }
    }

    private func install(on socket: URLSessionWebSocketTask) async throws {
        let result = try await evaluate(
            CodexSidebarQuotaRenderer.source,
            on: socket)
        guard result.boolValue(named: "installed") == true else {
            throw IntegrationError.evaluationFailed
        }
    }

    private func evaluate(
        _ expression: String,
        on socket: URLSessionWebSocketTask
    ) async throws -> CodexSidebarQuotaCDPResponse.Value {
        nextRequestID += 1
        let requestID = nextRequestID
        let request = CodexSidebarQuotaRenderer.evaluateRequest(
            id: requestID,
            expression: expression)
        let data = try JSONSerialization.data(withJSONObject: request)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        return try await waitForResponse(id: requestID, on: socket)
    }

    private func waitForResponse(
        id: Int,
        on socket: URLSessionWebSocketTask
    ) async throws -> CodexSidebarQuotaCDPResponse.Value {
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
            do {
                if let result = try CodexSidebarQuotaCDPResponse.parse(
                    data,
                    expectedID: id) {
                    return result
                }
            } catch {
                throw IntegrationError.evaluationFailed
            }
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
            _ = try await evaluate(expression, on: socket)
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
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                workspace.openApplication(
                    at: appURL,
                    configuration: configuration
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
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
