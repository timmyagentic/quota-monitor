import Foundation

// Single-shot client for `codex app-server`.
//
// Lifecycle: launch process → send `initialize` → send one or more requests
// → terminate. We do NOT keep a long-lived process around because:
//   - rate-limit polling is infrequent (every 5 min by default)
//   - shorter-lived process = no zombie risk if the app crashes
//   - simpler reasoning about request/response correlation
//
// If we ever need higher polling frequency or push events, refactor to a long-lived
// actor that owns the Process and demultiplexes by `id`.

actor AppServerClient {

    enum ClientError: Error, CustomStringConvertible {
        case binaryNotFound
        case launchFailed(String)
        case initializeFailed(String)
        case timeout
        case malformedResponse(String)
        case rpcError(JSONRPCError)
        case decodingFailed(String)

        var description: String {
            switch self {
            case .binaryNotFound: return "codex binary not found in PATH"
            case .launchFailed(let s): return "failed to launch codex app-server: \(s)"
            case .initializeFailed(let s): return "initialize failed: \(s)"
            case .timeout: return "app-server did not respond in time"
            case .malformedResponse(let s): return "malformed app-server response: \(s)"
            case .rpcError(let e): return "rpc error \(e.code): \(e.message)"
            case .decodingFailed(let s): return "failed to decode response: \(s)"
            }
        }
    }

    private let binaryPath: String
    private let timeout: Duration

    init(binaryPath: String? = nil, timeout: Duration = .seconds(15)) {
        self.binaryPath = binaryPath ?? Self.resolveBinary() ?? "codex"
        self.timeout = timeout
    }

    private static func resolveBinary() -> String? {
        let env = ProcessInfo.processInfo.environment

        // 1. Explicit override (set in launchctl or via env var).
        if let override = env["CODEX_BINARY"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        // 2. Common install locations. GUI-launched apps inherit a minimal PATH,
        // so we probe well-known bin dirs ourselves.
        let home = env["HOME"] ?? ""
        let candidates = [
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // 3. Fall back to a login shell so we pick up whatever the user's
        // dotfiles add to PATH.
        return discoverViaLoginShell()
    }

    private static func discoverViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v codex"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        } catch {
            return nil
        }
    }

    /// PATH the user's interactive login shell exports, computed once
    /// per process. Captures whatever the user's dotfiles add — nvm,
    /// asdf, rbenv, pyenv, manual prependers — so npm-installed `codex`
    /// can satisfy its `#!/usr/bin/env node` shebang when node lives
    /// under `~/.nvm/versions/node/<v>/bin` (a path we can't hardcode
    /// since `<v>` is dynamic). Symptom of this being missing was the
    /// poller logging `env: node: No such file or directory` and the
    /// menu bar collapsing to the gauge fallback icon forever.
    ///
    /// Spawning a login shell costs ~100-300 ms. `static let` lazily
    /// caches the result; nil means the probe failed and callers fall
    /// back to just the hardcoded extras list.
    static let loginShellPATH: String? = computeLoginShellPATH()

    private static func computeLoginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `printf %s` with no trailing newline keeps the trim trivial.
        // `-ilc` matches discoverViaLoginShell() so we get the same
        // post-rc PATH the user would see in their own terminal.
        process.arguments = ["-ilc", "printf %s \"$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    /// Build the environment we hand to spawned codex processes. Same idea
    /// as `resolveBinary()`'s candidate list: prepend well-known bin dirs
    /// to PATH so `#!/usr/bin/env node` shebangs and child shell-outs work
    /// even when launchd handed us an empty PATH. We also splice in the
    /// user's login-shell PATH so version-managed runtimes (nvm/asdf/…)
    /// that live outside our hardcoded `extras` list are still reachable.
    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
        ]
        let loginParts = (loginShellPATH ?? "").split(separator: ":").map(String.init)
        let existing = env["PATH"] ?? ""
        let existingParts = existing.split(separator: ":").map(String.init)
        let merged = (extras + loginParts + existingParts).reduce(into: [String]()) { acc, dir in
            if !acc.contains(dir) { acc.append(dir) }
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Run `initialize` followed by a single application-level request, then exit.
    func call<Params: Encodable>(method: String, params: Params) async throws -> JSONRPCResponse {
        try await runSession { send, recv in
            // initialize
            try send(JSONRPCRequest(
                id: "init",
                method: "initialize",
                params: InitializeParams(
                    clientInfo: .init(name: "codex-monitor", version: "0.1.0"),
                    protocolVersion: "0.1.0")))

            let initResp = try await recv("init")
            if let err = initResp.error { throw ClientError.initializeFailed(err.message) }

            // application call
            let callId = "call-\(UUID().uuidString.prefix(8))"
            try send(JSONRPCRequest(id: callId, method: method, params: params))
            return try await recv(callId)
        }
    }

    /// Convenience: read rate limits, transparently recovering from the
    /// known `plan_type` decode bug by salvaging the embedded body.
    func readRateLimits() async throws -> RateLimitsPayload {
        let response = try await call(method: "account/rateLimits/read", params: EmptyParams())

        if let result = response.result {
            return try result.decode(as: RateLimitsPayload.self)
        }

        if let err = response.error,
           let body = Self.salvageBodyFromErrorMessage(err.message) {
            do {
                return try JSONDecoder().decode(RateLimitsPayload.self, from: body)
            } catch {
                throw ClientError.decodingFailed(
                    "salvaged body from error.message but failed to decode: \(error)")
            }
        }

        if let err = response.error { throw ClientError.rpcError(err) }
        throw ClientError.malformedResponse("missing both result and error")
    }

    func readAccount() async throws -> AccountReadResult {
        let response = try await call(method: "account/read", params: EmptyParams())
        if let err = response.error { throw ClientError.rpcError(err) }
        guard let result = response.result else {
            throw ClientError.malformedResponse("account/read returned no result")
        }
        return try result.decode(as: AccountReadResult.self)
    }

    // MARK: - Internals

    /// Pull the JSON object that the CLI embeds in its error.message after `body=`.
    /// The body may span multiple lines and contain newlines/quotes, so we use
    /// brace-balance scanning rather than regex.
    static func salvageBodyFromErrorMessage(_ message: String) -> Data? {
        guard let bodyMarkerRange = message.range(of: "body=") else { return nil }
        let tail = message[bodyMarkerRange.upperBound...]
        guard let firstBrace = tail.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var endIndex: String.Index?

        for i in tail[firstBrace...].indices {
            let ch = tail[i]
            if escape { escape = false; continue }
            if inString {
                if ch == "\\" { escape = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { endIndex = i; break }
            default: break
            }
            if endIndex != nil { break }
        }

        guard let end = endIndex else { return nil }
        let jsonSlice = tail[firstBrace...end]
        return String(jsonSlice).data(using: .utf8)
    }

    /// Owns one app-server invocation: spawn, pipe stdin/stdout, give the caller
    /// `send` / `recv` closures, then terminate cleanly.
    private func runSession<R: Sendable>(
        _ body: (
            _ send: (any Encodable) throws -> Void,
            _ recv: (String) async throws -> JSONRPCResponse
        ) async throws -> R
    ) async throws -> R {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server"]
        // GUI-launched apps inherit a near-empty PATH from launchd, which
        // breaks `#!/usr/bin/env node` shebangs (the npm-installed `codex`
        // is a JS script). Augment PATH with the same well-known bin dirs
        // we probe in `resolveBinary()` so node / python / etc. are found
        // when codex shells out. Without this, the child exits before
        // replying to `initialize` and the menu bar shows a misleading
        // "Sign in via codex CLI" forever.
        process.environment = Self.augmentedEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            Log.appServer.debug("launched \(self.binaryPath, privacy: .public) app-server pid=\(process.processIdentifier)")
        }
        catch {
            Log.appServer.error("launch failed: \(String(describing: error), privacy: .public)")
            throw ClientError.launchFailed(String(describing: error))
        }

        // Drain stderr into the logger so codex crashes / shebang failures /
        // auth errors aren't silently swallowed. Without this, "stream ended
        // before id=init" is the only signal the user ever sees.
        Task.detached {
            let handle = stderr.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: 0..<nl)
                    buffer.removeSubrange(0...nl)
                    if line.isEmpty { continue }
                    if let s = String(data: line, encoding: .utf8) {
                        Log.appServer.error("stderr: \(s, privacy: .public)")
                    }
                }
            }
            if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
                Log.appServer.error("stderr: \(s, privacy: .public)")
            }
        }

        // Read stdout line-by-line into a stream of decoded responses.
        let responses = AsyncThrowingStream<JSONRPCResponse, Error> { continuation in
            Task.detached {
                let handle = stdout.fileHandleForReading
                var buffer = Data()
                let decoder = JSONDecoder()
                while true {
                    let chunk: Data
                    do {
                        // availableData blocks; on EOF returns empty.
                        chunk = handle.availableData
                    }
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.subdata(in: 0..<nl)
                        buffer.removeSubrange(0...nl)
                        if line.isEmpty { continue }
                        do {
                            let resp = try decoder.decode(JSONRPCResponse.self, from: line)
                            continuation.yield(resp)
                        } catch {
                            // Ignore lines that aren't JSON-RPC envelopes (logs etc.)
                        }
                    }
                }
                continuation.finish()
            }
        }

        let send: (any Encodable) throws -> Void = { request in
            let data = try JSONEncoder().encode(AnyEncodable(request))
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data([0x0A]))
        }

        let timeoutNanos = self.timeout
        let recv: (String) async throws -> JSONRPCResponse = { wantedId in
            try await withThrowingTaskGroup(of: JSONRPCResponse.self) { group in
                group.addTask {
                    for try await resp in responses where resp.id == wantedId {
                        return resp
                    }
                    throw ClientError.malformedResponse("stream ended before id=\(wantedId)")
                }
                group.addTask {
                    try await Task.sleep(for: timeoutNanos)
                    throw ClientError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }

        defer {
            // Closing stdin politely tells app-server we're done; well-behaved
            // children exit on their own once stdin closes.
            try? stdin.fileHandleForWriting.close()

            // Asynchronous termination. NEVER call process.waitUntilExit() here:
            // it's synchronous and would block the actor forever if the child
            // is wedged. Observed 2026-05-09: a long-lived QuotaMonitor
            // accumulated an orphan `codex app-server --listen stdio://` while
            // every subsequent pollOnce queued behind a deadlocked actor.
            //
            // SIGTERM is sent inline (cheap, just a signal) so the child gets
            // the chance to exit cleanly while the actor returns immediately;
            // a detached task escalates to SIGKILL after 2 s if needed.
            if process.isRunning {
                let handle = SendableProcessRef(process: process)
                process.terminate()
                Task.detached {
                    for _ in 0..<20 { // up to 2 s
                        try? await Task.sleep(for: .milliseconds(100))
                        if !handle.process.isRunning { return }
                    }
                    kill(handle.process.processIdentifier, SIGKILL)
                }
            }
        }

        return try await body(send, recv)
    }
}

/// Process isn't Sendable, but we only need to ferry the reference into a
/// detached escalation task that touches it from one place at a time. Safe
/// because nothing else holds the Process after the actor's defer fires.
private struct SendableProcessRef: @unchecked Sendable {
    let process: Process
}

// Helper structs

struct EmptyParams: Encodable {}

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        self._encode = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}
