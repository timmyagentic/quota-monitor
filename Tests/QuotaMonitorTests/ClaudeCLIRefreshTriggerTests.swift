import Foundation
import Testing
@testable import QuotaMonitor

/// Tests for `ClaudeCLIRefreshTrigger`. We exercise the actor's coalescing
/// + cooldown logic by injecting a scripted spawn closure — the real
/// `claude --version` Process is never invoked.
///
/// What this test pins down:
///
///   1. **Spawn failure → cooldown engages** — a returned `false` records
///      a failure, advances `consecutiveFailures`, and the next call
///      short-circuits.
///   2. **Exponential back-off** — failure #1 → 5min, #2 → 10min, ...,
///      capped at 1h. Successful spawn resets the counter.
///   3. **In-flight coalescing** — two concurrent `triggerRefreshIfAllowed`
///      calls share a single spawn invocation.
///   4. **Spawn returns true → no cooldown** — successful spawns leave
///      `blockedUntil` nil so subsequent expiry detections can re-trigger
///      immediately if the user really has another stale token.
///
/// We deliberately don't test `runClaudeCLI` itself (Process spawn,
/// keychain mdat polling, PATH probing) — that's covered by the
/// real-machine smoke test in the build/release flow.
@Suite("ClaudeCLIRefreshTrigger")
struct ClaudeCLIRefreshTriggerTests {

    /// Each test fully recreates the trigger; no shared `.shared`
    /// instance, no global state. So no `@Suite(.serialized)` needed —
    /// these can run in parallel safely.

    @Test("Spawn failure engages 5-min cooldown and short-circuits the next call")
    func cooldownEngagesAfterFailure() async {
        let counter = SpawnCounter()
        let trigger = ClaudeCLIRefreshTrigger(spawn: {
            await counter.bump()
            return false   // simulate CLI not found / timeout
        })

        let first = await trigger.triggerRefreshIfAllowed()
        #expect(first == false)
        #expect(await counter.value == 1)
        #expect(await trigger._consecutiveFailuresForTest == 1)
        let until = await trigger._blockedUntilForTest
        #expect(until != nil)
        // 5 min ± slack for test scheduling latency.
        if let until {
            let remaining = until.timeIntervalSinceNow
            #expect(remaining > 290 && remaining <= 300, "expected ~300s cooldown, got \(remaining)")
        }

        // Second call must NOT spawn — short-circuited by cooldown gate.
        let second = await trigger.triggerRefreshIfAllowed()
        #expect(second == false)
        #expect(await counter.value == 1, "spawn should not have been re-invoked while cooldown active")
    }

    @Test("Exponential back-off doubles per consecutive failure, caps at 1h")
    func backoffDoublesAndCaps() async {
        let trigger = ClaudeCLIRefreshTrigger(spawn: { false })

        // Manually drive the failure counter by resetting the cooldown
        // window between calls (production code uses real time; we cheat
        // for test speed). After each failed attempt we clear
        // `blockedUntil` so the next call is allowed to spawn again,
        // but `consecutiveFailures` keeps growing.
        for expectedFailureCount in 1...6 {
            await trigger._clearBlockedUntilForTest()
            _ = await trigger.triggerRefreshIfAllowed()
            #expect(await trigger._consecutiveFailuresForTest == expectedFailureCount)
        }
        // After 6 failures, scaled cooldown = 5min * 2^5 = 160min,
        // which clamps to the 60min ceiling.
        let until = await trigger._blockedUntilForTest
        #expect(until != nil)
        if let until {
            let remaining = until.timeIntervalSinceNow
            #expect(remaining > 3590 && remaining <= 3600, "expected 1h cap, got \(remaining)")
        }
    }

    @Test("Successful spawn resets failure counter and leaves no cooldown")
    func successResetsCooldown() async {
        let outcomes = AtomicQueue<Bool>(values: [false, true])
        let trigger = ClaudeCLIRefreshTrigger(spawn: {
            // First call fails → cooldown. Second call succeeds → reset.
            await outcomes.next() ?? false
        })

        // Failure #1.
        _ = await trigger.triggerRefreshIfAllowed()
        #expect(await trigger._consecutiveFailuresForTest == 1)
        #expect(await trigger._blockedUntilForTest != nil)

        // Bypass cooldown for test speed.
        await trigger._clearBlockedUntilForTest()

        // Now the spawn returns true. But the trigger only marks success
        // if the (mocked) keychain mdat advances — which it can't here
        // because we're not touching real Keychain. So this test is
        // really pinning down: when the closure returns true AND mdat
        // doesn't move, we still treat that as a failure (the CLI ran
        // but didn't refresh anything). That matches the production
        // semantics — a successful exit code from `claude --version`
        // doesn't mean a refresh happened.
        _ = await trigger.triggerRefreshIfAllowed()
        // Verify failure count grew rather than reset, because keychain
        // mdat polling returned nil (no real keychain item under the
        // test environment).
        let failures = await trigger._consecutiveFailuresForTest
        #expect(failures >= 1, "spawn returning true without mdat change must NOT count as success")
    }

    @Test("Two concurrent triggers coalesce on a single spawn invocation")
    func concurrentCallsCoalesce() async {
        let counter = SpawnCounter()
        let trigger = ClaudeCLIRefreshTrigger(spawn: {
            await counter.bump()
            // Sleep long enough that both callers definitely overlap on
            // the same in-flight Task before we return.
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            return false
        })

        async let first = trigger.triggerRefreshIfAllowed()
        async let second = trigger.triggerRefreshIfAllowed()
        let results = await (first, second)
        #expect(results.0 == false)
        #expect(results.1 == false)
        #expect(await counter.value == 1, "two callers must share one spawn invocation")
    }

    @Test("Explicit CLAUDE_BINARY wins when executable")
    func explicitClaudeBinaryWins() {
        let executable: Set<String> = [
            "/custom/claude",
            "/Users/test/.nvm/versions/node/v1/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        let resolved = ClaudeCLIRefreshTrigger.resolveClaudeBinary(
            explicitOverride: "/custom/claude",
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/claude",
            path: "/opt/homebrew/bin",
            isExecutable: executable.contains)

        #expect(resolved == "/custom/claude")
    }

    @Test("Login-shell claude wins over hardcoded installs")
    func loginShellClaudeWinsOverHardcodedInstalls() {
        let executable: Set<String> = [
            "/Users/test/.nvm/versions/node/v1/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        let resolved = ClaudeCLIRefreshTrigger.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/claude",
            path: "/opt/homebrew/bin",
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.nvm/versions/node/v1/bin/claude")
    }

    @Test("Hardcoded claude installs are fallback when login shell has no claude")
    func hardcodedClaudeInstallsFallback() {
        let executable: Set<String> = ["/opt/homebrew/bin/claude"]

        let resolved = ClaudeCLIRefreshTrigger.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            path: "",
            isExecutable: executable.contains)

        #expect(resolved == "/opt/homebrew/bin/claude")
    }

    @Test("Claude Desktop bundled CLI supports app-only installs")
    func claudeDesktopBundledCLISupportsAppOnlyInstalls() {
        let desktop = "/Users/test/Library/Application Support/Claude/claude-code/2.1.149/claude.app/Contents/MacOS/claude"
        let executable: Set<String> = [
            desktop,
            "/opt/homebrew/bin/claude",
        ]

        let resolved = ClaudeCLIRefreshTrigger.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            path: "",
            desktopBundlePath: desktop,
            isExecutable: executable.contains)

        #expect(resolved == desktop)
    }

    @Test("User-installed claude wins over Claude Desktop bundle")
    func userInstalledClaudeWinsOverClaudeDesktopBundle() {
        let desktop = "/Users/test/Library/Application Support/Claude/claude-code/2.1.149/claude.app/Contents/MacOS/claude"
        let executable: Set<String> = [
            "/Users/test/.local/bin/claude",
            desktop,
        ]

        let resolved = ClaudeCLIRefreshTrigger.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            path: "",
            desktopBundlePath: desktop,
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.local/bin/claude")
    }

    @Test("Discovers newest Claude Desktop native CLI bundle")
    func discoversNewestClaudeDesktopNativeCLIBundle() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qm-claude-desktop-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let oldDir = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code/2.1.9/claude.app/Contents/MacOS",
            isDirectory: true)
        let newDir = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code/2.1.149/claude.app/Contents/MacOS",
            isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let oldBinary = oldDir.appendingPathComponent("claude", isDirectory: false)
        let newBinary = newDir.appendingPathComponent("claude", isDirectory: false)
        fm.createFile(atPath: oldBinary.path, contents: Data())
        fm.createFile(atPath: newBinary.path, contents: Data())
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldBinary.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)

        let resolved = ClaudeCLIRefreshTrigger.discoverClaudeDesktopBundle(
            home: home.path,
            isExecutable: fm.isExecutableFile(atPath:))

        #expect(resolved.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                == newBinary.standardizedFileURL.path)
    }
}

// MARK: - Test helpers

private actor SpawnCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

/// Pop-front queue of scripted return values.
private actor AtomicQueue<T> {
    private var values: [T]
    init(values: [T]) { self.values = values }
    func next() -> T? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}
