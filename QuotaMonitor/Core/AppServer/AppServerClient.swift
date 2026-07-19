import Darwin
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
        case disabledInLocalQA

        var description: String {
            switch self {
            case .binaryNotFound: return "codex binary not found in PATH"
            case .launchFailed(let s): return "failed to launch codex app-server: \(s)"
            case .initializeFailed(let s): return "initialize failed: \(s)"
            case .timeout: return "app-server did not respond in time"
            case .malformedResponse(let s): return "malformed app-server response: \(s)"
            case .rpcError(let e): return "rpc error \(e.code): \(e.message)"
            case .decodingFailed(let s): return "failed to decode response: \(s)"
            case .disabledInLocalQA: return "codex app-server is disabled in local QA"
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
        let isExecutable = FileManager.default.isExecutableFile(atPath:)

        return resolveBinary(
            explicitOverride: env["CODEX_BINARY"],
            home: env["HOME"] ?? "",
            loginShellPath: executable(
                named: "codex",
                inPath: loginShellPATH,
                isExecutable: isExecutable),
            isExecutable: isExecutable)
    }

    static func resolveBinary(
        explicitOverride: String?,
        home: String,
        loginShellPath: @autoclosure () -> String?,
        isExecutable: (String) -> Bool
    ) -> String? {
        // 1. Explicit override (set in launchctl or via env var).
        if let override = explicitOverride, !override.isEmpty, isExecutable(override) {
            return override
        }

        // 2. Prefer the unified first-party ChatGPT bundle before starting an
        // interactive shell. App-only installs should work from a minimal GUI
        // environment even when shell startup is slow or permission-gated.
        for path in chatGPTBundleCandidates(home: home) where isExecutable(path) {
            return path
        }

        // 3. Match the user's terminal when no unified bundle is installed.
        // This still supports version-manager installs (nvm/asdf/bun/etc.).
        if let shellPath = loginShellPath(), !shellPath.isEmpty, isExecutable(shellPath) {
            return shellPath
        }

        // 4. Common CLI locations and the legacy Codex bundle. Preserve the
        // established CLI-before-legacy ordering so a stale legacy app cannot
        // displace the user's working terminal install.
        let candidates = [
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates where isExecutable(path) {
            return path
        }
        return nil
    }

    private static func chatGPTBundleCandidates(home: String) -> [String] {
        [
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
    }

    private static func isDesktopBundleBinary(_ path: String) -> Bool {
        path.hasSuffix("/ChatGPT.app/Contents/Resources/codex")
            || path.hasSuffix("/Codex.app/Contents/Resources/codex")
    }

    static func loginShellPathForEnvironment(
        binaryPath: String,
        discoveredPath: @autoclosure () -> String?
    ) -> String? {
        guard !isDesktopBundleBinary(binaryPath) else { return nil }
        return discoveredPath()
    }

    static func executable(
        named name: String,
        inPath path: String?,
        isExecutable: (String) -> Bool
    ) -> String? {
        guard let path else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs a login-shell probe with a bounded execution deadline and bounded
    /// process-tree cleanup. Shell startup can block on a slow version manager,
    /// inaccessible mount, or a permission-gated PATH entry; quota polling must
    /// still reach the app-bundle fallbacks.
    static func runLoginShellLine(
        shell: String,
        command: String,
        timeout: TimeInterval
    ) -> String? {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("quota-monitor-shell-probe-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            return nil
        }
        defer { try? fileManager.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Keep the shell alive briefly after the probe command so the parent
        // can observe background jobs started by interactive startup files,
        // even when those jobs move into their own process groups.
        let supervisedCommand = """
        \(command)
        __quota_monitor_probe_status=$?
        /bin/sleep 0.05
        exit $__quota_monitor_probe_status
        """
        process.arguments = ["-ilc", supervisedCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            let stdout = try FileHandle(forWritingTo: outputURL)
            defer { try? stdout.close() }
            process.standardOutput = stdout
            try process.run()
            var processTree = ProcessTree(rootProcessID: process.processIdentifier)
            let deadline = Date().addingTimeInterval(timeout)
            let exitedBeforeDeadline = waitForExit(
                process,
                until: deadline,
                processTree: &processTree)
            let terminationStatus = exitedBeforeDeadline ? process.terminationStatus : nil

            // Foundation launches Process in its own process group on macOS.
            // Clean that group even after the shell itself exits: an rc file can
            // leave a background child alive with inherited standard handles.
            stopProcessTree(process, processTree: &processTree)

            guard exitedBeforeDeadline, terminationStatus == 0 else { return nil }
            try stdout.synchronize()
            let data = try Data(contentsOf: outputURL)
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    private struct ProcessTree {
        let rootProcessID: pid_t
        var processIDs: Set<pid_t>
        var processGroupIDs: Set<pid_t>

        init(rootProcessID: pid_t) {
            self.rootProcessID = rootProcessID
            self.processIDs = [rootProcessID]
            self.processGroupIDs = [rootProcessID]
        }

        mutating func refresh() {
            let processInfos = Self.allProcessInfos()
            var foundDescendant = true
            while foundDescendant {
                foundDescendant = false
                for info in processInfos {
                    guard processIDs.contains(info.parentProcessID),
                          !processIDs.contains(info.processID) else { continue }
                    processIDs.insert(info.processID)
                    processGroupIDs.insert(info.processGroupID)
                    foundDescendant = true
                }
            }
        }

        private struct ProcessInfo {
            let processID: pid_t
            let parentProcessID: pid_t
            let processGroupID: pid_t
        }

        private static func allProcessInfos() -> [ProcessInfo] {
            let estimatedCount = max(Int(proc_listallpids(nil, 0)), 1)
            var processIDs = [pid_t](repeating: 0, count: estimatedCount + 32)
            let count = processIDs.withUnsafeMutableBufferPointer { buffer in
                proc_listallpids(
                    buffer.baseAddress,
                    Int32(buffer.count * MemoryLayout<pid_t>.stride))
            }
            guard count > 0 else { return [] }

            return processIDs.prefix(Int(count)).compactMap { processID in
                var info = proc_bsdinfo()
                let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(
                    processID,
                    PROC_PIDTBSDINFO,
                    0,
                    &info,
                    expectedSize) == expectedSize else { return nil }
                return ProcessInfo(
                    processID: pid_t(info.pbi_pid),
                    parentProcessID: pid_t(info.pbi_ppid),
                    processGroupID: pid_t(info.pbi_pgid))
            }
        }
    }

    private static func waitForExit(
        _ process: Process,
        until deadline: Date,
        processTree: inout ProcessTree
    ) -> Bool {
        processTree.refresh()
        while process.isRunning {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
            processTree.refresh()
        }
        return true
    }

    private static func stopProcessTree(
        _ process: Process,
        processTree: inout ProcessTree
    ) {
        processTree.refresh()
        guard signalTargetIsRunning(process, processTree: processTree) else {
            if !process.isRunning {
                process.waitUntilExit()
            }
            return
        }

        sendSignal(SIGTERM, processTree: processTree)
        let termDeadline = Date().addingTimeInterval(0.1)
        while signalTargetIsRunning(process, processTree: processTree),
              Date() < termDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if signalTargetIsRunning(process, processTree: processTree) {
            sendSignal(SIGKILL, processTree: processTree)
            let killDeadline = Date().addingTimeInterval(0.1)
            while signalTargetIsRunning(process, processTree: processTree),
                  Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // Process.isRunning observes and reaps the direct child. Never call the
        // blocking wait while it still reports running after the bounded grace.
        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    private static func signalTargetIsRunning(
        _ process: Process,
        processTree: ProcessTree
    ) -> Bool {
        if process.isRunning { return true }
        for processID in processTree.processIDs where processID != getpid() {
            errno = 0
            if kill(processID, 0) == 0 || errno == EPERM {
                return true
            }
        }
        for processGroupID in processTree.processGroupIDs where processGroupID != getpgrp() {
            errno = 0
            if kill(-processGroupID, 0) == 0 || errno == EPERM {
                return true
            }
        }
        return false
    }

    private static func sendSignal(_ signal: Int32, processTree: ProcessTree) {
        for processGroupID in processTree.processGroupIDs where processGroupID != getpgrp() {
            _ = kill(-processGroupID, signal)
        }
        for processID in processTree.processIDs where processID != getpid() {
            _ = kill(processID, signal)
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
    /// Spawning a login shell normally costs ~100-300 ms. `static let` lazily
    /// caches the result; nil means the bounded probe failed and callers fall
    /// back to the user-local CLI, legacy Codex bundle, and hardcoded extras.
    static let loginShellPATH: String? = computeLoginShellPATH()

    private static func computeLoginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `printf %s` with no trailing newline keeps the trim trivial.
        return runLoginShellLine(
            shell: shell,
            command: "printf %s \"$PATH\"",
            timeout: 2)
    }

    /// Build the environment we hand to spawned codex processes. Same idea
    /// as `resolveBinary()`'s candidate list: prepend well-known bin dirs
    /// to PATH so `#!/usr/bin/env node` shebangs and child shell-outs work
    /// even when launchd handed us an empty PATH. We also splice in the
    /// user's login-shell PATH so version-managed runtimes (nvm/asdf/…)
    /// that live outside our hardcoded `extras` list are still reachable.
    static func augmentedEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        loginShellPath: String? = loginShellPATH
    ) -> [String: String] {
        var env = environment
        if LocalQAEnvironment.isActive(environment: environment, arguments: arguments) {
            let qaHome = LocalQAEnvironment.homeDirectory(
                environment: environment,
                arguments: arguments)
            env["HOME"] = qaHome.path
            env["CODEX_HOME"] = (
                LocalQAEnvironment.codexHomeDirectory(
                    environment: environment,
                    arguments: arguments)
                ?? qaHome.appendingPathComponent(".codex", isDirectory: true)
            ).path
        }

        let home = env["HOME"] ?? NSHomeDirectory()
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
        ]
        let loginParts = (loginShellPath ?? "").split(separator: ":").map(String.init)
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
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            throw ClientError.disabledInLocalQA
        }
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
        let loginShellPath = Self.loginShellPathForEnvironment(
            binaryPath: binaryPath,
            discoveredPath: Self.loginShellPATH)
        process.environment = Self.augmentedEnvironment(loginShellPath: loginShellPath)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            Log.appServer.debug("launched \(self.binaryPath, privacy: .public) app-server pid=\(process.processIdentifier)")
            DeveloperLog.eventRecord(
                "appserver.launch",
                level: .debug,
                category: "appserver",
                provider: "codex",
                result: "success",
                fields: [
                    "binary": .string(self.binaryPath),
                    "pid": .int(Int(process.processIdentifier))
                ])
        }
        catch {
            Log.appServer.error("launch failed: \(String(describing: error), privacy: .public)")
            DeveloperLog.eventRecord(
                "appserver.launch.fail",
                level: .error,
                category: "appserver",
                provider: "codex",
                result: "failure",
                message: String(describing: error),
                fields: [
                    "binary": .string(self.binaryPath),
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
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
                        DeveloperLog.eventRecord(
                            "appserver.stderr",
                            level: .error,
                            category: "appserver",
                            provider: "codex",
                            fields: ["stderr": .string(s)])
                    }
                }
            }
            if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
                Log.appServer.error("stderr: \(s, privacy: .public)")
                DeveloperLog.eventRecord(
                    "appserver.stderr",
                    level: .error,
                    category: "appserver",
                    provider: "codex",
                    fields: ["stderr": .string(s)])
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
