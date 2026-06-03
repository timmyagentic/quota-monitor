import Foundation

/// Spawns the user's `claude` CLI to refresh expired Claude Code OAuth
/// credentials, then waits for the Keychain item to update. We never
/// touch the OAuth refresh endpoint ourselves — the CLI is the single
/// authoritative writer of `Claude Code-credentials`. See the long
/// rationale on `ClaudeUsageClient` for why this trade-off matters
/// (refresh-token rotation makes split-brain refresh unsafe).
///
/// **Lifecycle.**
///   - Single shared instance (`.shared`). Multiple callers racing on an
///     expired token coalesce on the same in-flight `Task`.
///   - Cooldown gate: after a failed attempt we won't try again for
///     `cooldownAfterFailure` (5 min default, exponential up to 1 h
///     after consecutive failures). Successful refreshes reset the
///     counter.
///   - Per-attempt budget: spawn + wait for Keychain change capped at
///     `attemptTimeout` (~8 s). Captures stdout/stderr to `Log.poller`.
///
/// **Why we watch `kSecAttrModificationDate` instead of just re-reading
/// the file.** CLI ≥ 2.1.x stops mirroring refreshes to disk and only
/// updates the Keychain. Polling the Keychain attribute (not the data)
/// avoids re-prompting the ACL every iteration.
///
/// **Refresh-failure surfaceability.** A returned `false` means "no
/// fresher token is available". The caller (`ClaudeUsageClient`) lets
/// the next HTTP attempt 401 naturally so the existing `lastClaudeUsageError`
/// → `errClaudeUnauthorized` UI hint covers it. We don't need a separate
/// "needs relogin" flag.
actor ClaudeCLIRefreshTrigger {

    static let shared = ClaudeCLIRefreshTrigger()

    /// Per-attempt wall-clock budget. Spawn + wait combined.
    private let attemptTimeout: TimeInterval = 8

    /// Cooldown after a *failed* attempt. Successful attempts have no
    /// cooldown — the user might be hitting refresh in quick succession
    /// (poll + manual refresh + 401 retry).
    private let baseCooldown: TimeInterval = 300       // 5 min
    private let maxCooldown:  TimeInterval = 3600      // 1 h

    /// Set to the time of the last failed attempt + cooldown. While
    /// `Date() < blockedUntil`, `triggerRefreshIfAllowed` short-circuits
    /// to false.
    private var blockedUntil: Date?
    private var consecutiveFailures: Int = 0

    /// Coalesces concurrent callers — if a refresh is already in flight,
    /// new callers `await` its result instead of double-spawning.
    private var inFlight: Task<Bool, Never>?

    /// Test seam for spawning the CLI. Production wires
    /// `Self.runClaudeCLI`. Tests inject a closure that simulates
    /// success / failure / mdat-change without touching the real binary.
    private let spawn: @Sendable () async -> Bool

    init(spawn: @escaping @Sendable () async -> Bool = ClaudeCLIRefreshTrigger.runClaudeCLI) {
        self.spawn = spawn
    }

    /// Returns true if the spawn produced a Keychain mdat change (i.e.
    /// caller should re-read credentials). Returns false on cooldown,
    /// CLI-not-found, timeout, or the CLI completing without touching
    /// the Keychain (which means it had nothing to refresh).
    func triggerRefreshIfAllowed() async -> Bool {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            DeveloperLog.eventRecord(
                "claude_cli.refresh.skip",
                category: "poller",
                provider: "claude",
                result: "skipped",
                fields: ["reason": "local-qa"])
            return false
        }
        if let task = inFlight {
            return await task.value
        }
        if let until = blockedUntil, Date() < until {
            Log.poller.info("claude CLI refresh skipped — cooldown for \(Int(until.timeIntervalSinceNow), privacy: .public)s")
            DeveloperLog.eventRecord(
                "claude_cli.refresh.skip",
                category: "poller",
                provider: "claude",
                result: "skipped",
                fields: [
                    "reason": "cooldown",
                    "remaining_seconds": .int(Int(until.timeIntervalSinceNow)),
                    "blocked_until": .string(ISO8601.fractional.string(from: until))
                ])
            return false
        }
        let task = Task<Bool, Never> { [spawn, attemptTimeout] in
            // Snapshot the Keychain item's mdat *before* spawning so we
            // can detect whether the CLI actually wrote anything. The
            // attribute query doesn't trigger an ACL prompt (we never
            // ask for kSecReturnData here).
            let before = Self.keychainMdat()
            let started = Date()
            Log.poller.info("claude CLI refresh: spawning")
            DeveloperLog.eventRecord("claude_cli.refresh.spawn", category: "poller", provider: "claude")
            let spawnOK = await spawn()
            if !spawnOK {
                Log.poller.error("claude CLI refresh: spawn failed")
                DeveloperLog.eventRecord(
                    "claude_cli.refresh.spawn_fail",
                    level: .error,
                    category: "poller",
                    provider: "claude",
                    result: "failure")
                return false
            }
            // Wait up to (attemptTimeout - elapsed) for mdat to advance.
            let deadline = started.addingTimeInterval(attemptTimeout)
            while Date() < deadline {
                let after = Self.keychainMdat()
                if let after, after != before {
                    let dur = Date().timeIntervalSince(started)
                    Log.poller.info("claude CLI refresh: keychain mdat advanced after \(Int(dur * 1000), privacy: .public)ms")
                    DeveloperLog.eventRecord(
                        "claude_cli.refresh.keychain_advanced",
                        category: "poller",
                        provider: "claude",
                        durationMilliseconds: Int(dur * 1000),
                        result: "success")
                    return true
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
            }
            Log.poller.error("claude CLI refresh: timed out waiting for keychain change")
            DeveloperLog.eventRecord(
                "claude_cli.refresh.timeout",
                level: .error,
                category: "poller",
                provider: "claude",
                result: "timeout",
                fields: ["attempt_timeout_seconds": .double(attemptTimeout)])
            return false
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if result {
            consecutiveFailures = 0
            blockedUntil = nil
        } else {
            consecutiveFailures += 1
            // Exponential back-off: 5min, 10min, 20min, 40min, 1h cap.
            let scale = pow(2.0, Double(consecutiveFailures - 1))
            let cooldown = min(baseCooldown * scale, maxCooldown)
            blockedUntil = Date().addingTimeInterval(cooldown)
            Log.poller.info("claude CLI refresh: cooldown \(Int(cooldown), privacy: .public)s (#\(self.consecutiveFailures, privacy: .public))")
            DeveloperLog.eventRecord(
                "claude_cli.refresh.cooldown",
                category: "poller",
                provider: "claude",
                result: "cooldown",
                fields: [
                    "cooldown_seconds": .int(Int(cooldown)),
                    "failures": .int(self.consecutiveFailures)
                ])
        }
        return result
    }

    /// Read just the modification date of the most recent
    /// `Claude Code-credentials` item without fetching its data
    /// (`kSecReturnData` would prompt the ACL). Returns nil if the item
    /// doesn't exist or any error occurs — both treated as "no change
    /// detectable" by the caller's loop.
    static func keychainMdat() -> Date? {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            return nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return nil
        }
        // Return the newest mdat across all matching items.
        return items.compactMap { $0[kSecAttrModificationDate as String] as? Date }.max()
    }

    /// Run `claude --version` (the cheapest invocation that triggers the
    /// CLI's bootstrap path, which in turn checks token expiry and
    /// refreshes if needed). Captures stdout/stderr to logs.
    ///
    /// Returns true if the process exited cleanly within the per-attempt
    /// budget. The caller separately verifies whether anything actually
    /// changed in the Keychain.
    static func runClaudeCLI() async -> Bool {
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            return false
        }
        // Resolve `claude` from the PATH augmented in the same way
        // `AppServerClient` does — GUI launches inherit launchd's empty
        // PATH otherwise. Inlined rather than importing because the
        // augment helper is private to AppServerClient.
        let env = augmentedEnvironment()
        guard let binary = resolveClaudeBinary(
            explicitOverride: env["CLAUDE_BINARY"],
            home: env["HOME"] ?? NSHomeDirectory(),
            loginShellPath: discoverClaudeViaLoginShell(),
            path: env["PATH"] ?? "",
            desktopBundlePath: discoverClaudeDesktopBundle(
                home: env["HOME"] ?? NSHomeDirectory(),
                isExecutable: FileManager.default.isExecutableFile(atPath:)),
            isExecutable: FileManager.default.isExecutableFile(atPath:))
        else {
            Log.poller.error("claude CLI refresh: `claude` not found on PATH")
            DeveloperLog.eventRecord(
                "claude_cli.binary.not_found",
                level: .error,
                category: "poller",
                provider: "claude",
                result: "failure")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            Log.poller.error("claude CLI refresh: launch failed \(String(describing: error), privacy: .public)")
            DeveloperLog.eventRecord(
                "claude_cli.launch.fail",
                level: .error,
                category: "poller",
                provider: "claude",
                result: "failure",
                message: String(describing: error),
                fields: [
                    "binary": .string(binary),
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
            return false
        }
        // Wait for exit with a hard cap. `Process.waitUntilExit()` is
        // blocking and synchronous — wrap in a detached task so we
        // don't block the actor's executor.
        let exitCode: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus)
            }
        }
        let out = String(data: outPipe.fileHandleForReading.availableData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty {
            Log.poller.debug("claude CLI stdout: \(out, privacy: .public)")
            DeveloperLog.eventRecord(
                "claude_cli.stdout",
                level: .debug,
                category: "poller",
                provider: "claude",
                fields: ["stdout": .string(out)])
        }
        if !err.isEmpty {
            Log.poller.error("claude CLI stderr: \(err, privacy: .public)")
            DeveloperLog.eventRecord(
                "claude_cli.stderr",
                level: .error,
                category: "poller",
                provider: "claude",
                fields: ["stderr": .string(err)])
        }
        DeveloperLog.eventRecord(
            "claude_cli.exit",
            category: "poller",
            provider: "claude",
            result: exitCode == 0 ? "success" : "failure",
            fields: [
                "binary": .string(binary),
                "exit_code": .int(Int(exitCode))
            ])
        return exitCode == 0
    }

    /// Mirror of `AppServerClient.augmentedEnvironment` — duplicated
    /// here to keep the dependency direction one-way (Claude code
    /// shouldn't import AppServer infrastructure). See
    /// `AppServerClient.loginShellPATH` for why we splice in the login
    /// shell's PATH; the rationale (nvm-managed node, etc.) applies
    /// the same way to `claude` since it's also an npm shell script.
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
        let merged = (loginParts + extras + existingParts).reduce(into: [String]()) { acc, dir in
            if !acc.contains(dir) { acc.append(dir) }
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Mirror of `AppServerClient.loginShellPATH` — same reason for the
    /// duplication, same single-spawn-per-process caching via `static
    /// let`.
    private static let loginShellPATH: String? = computeLoginShellPATH()

    private static func computeLoginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
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

    /// Exact `claude` binary the user's login shell would run. This is
    /// stricter than scanning a synthetic PATH because stale global
    /// installs can sit in common hardcoded directories while the
    /// working CLI lives under a version manager.
    private static func discoverClaudeViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v claude"]
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

    /// Probe for an executable `claude`, matching the user's terminal
    /// before common hardcoded install directories.
    static func resolveClaudeBinary(
        explicitOverride: String?,
        home: String,
        loginShellPath: String?,
        path: String,
        desktopBundlePath: String? = nil,
        isExecutable: (String) -> Bool
    ) -> String? {
        if let override = explicitOverride, !override.isEmpty, isExecutable(override) {
            return override
        }
        if let shellPath = loginShellPath, !shellPath.isEmpty, isExecutable(shellPath) {
            return shellPath
        }
        let userCandidates = [
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.cargo/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        for candidate in userCandidates where isExecutable(candidate) {
            return candidate
        }
        if let desktopBundlePath, isExecutable(desktopBundlePath) {
            return desktopBundlePath
        }
        let packageManagerCandidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for candidate in packageManagerCandidates where isExecutable(candidate) {
            return candidate
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Claude Desktop can download a native Claude Code build into
    /// `~/Library/Application Support/Claude/claude-code/<version>/claude.app`.
    /// That covers users who installed the desktop app but never put a
    /// standalone `claude` binary on PATH. The VM copy next to it is an ELF
    /// Linux binary, so only the `.app/Contents/MacOS/claude` path is usable
    /// from QuotaMonitor on macOS.
    static func discoverClaudeDesktopBundle(
        home: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        let root = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Claude/claude-code",
                                    isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return nil }

        let candidates = versions
            .filter { $0.hasDirectoryPath }
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: [.numeric, .caseInsensitive]) == .orderedDescending
            }
            .map {
                $0.appendingPathComponent("claude.app/Contents/MacOS/claude",
                                          isDirectory: false).path
            }

        return candidates.first(where: isExecutable)
    }

    // MARK: - Test inspection

    var _consecutiveFailuresForTest: Int { consecutiveFailures }
    var _blockedUntilForTest: Date? { blockedUntil }
    func _clearBlockedUntilForTest() { blockedUntil = nil }
    func _resetForTest() {
        blockedUntil = nil
        consecutiveFailures = 0
        inFlight = nil
    }
}
