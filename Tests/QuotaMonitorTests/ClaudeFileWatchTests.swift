import Foundation
import Testing
@testable import QuotaMonitor

/// The Claude transcript file-watcher feeds a *Claude-only* scan so that
/// reacting to `~/.claude` writes never triggers Codex's expensive
/// whole-file re-parse. These pin the two pure helpers behind that wiring:
/// which directories get watched, and how a requested provider scope is
/// intersected with the user's enabled providers.
@Suite("Claude file-watch helpers")
struct ClaudeFileWatchTests {

    // MARK: - runScan provider scope

    @Test("nil scope falls back to every enabled provider")
    func nilScopeUsesEnabled() {
        #expect(AppEnvironment.resolveScanProviders(
            requested: nil, enabled: ["codex", "claude"]) == ["codex", "claude"])
    }

    @Test("a requested scope is intersected with the enabled providers")
    func scopeIntersectsEnabled() {
        #expect(AppEnvironment.resolveScanProviders(
            requested: ["claude"], enabled: ["codex", "claude"]) == ["claude"])
    }

    @Test("requesting a disabled provider yields an empty scan scope")
    func disabledRequestedIsEmpty() {
        #expect(AppEnvironment.resolveScanProviders(
            requested: ["claude"], enabled: ["codex"]) == [])
    }

    // MARK: - scan throttle scope

    @Test("nil / empty requested scope buckets into the shared full-scan throttle")
    func throttleKeyAllForFullScan() {
        #expect(AppEnvironment.scanThrottleKey(forRequested: nil) == "all")
        #expect(AppEnvironment.scanThrottleKey(forRequested: []) == "all")
    }

    @Test("a scoped scan gets its own throttle key, independent of the full scan")
    func throttleKeyScopedIsIndependent() {
        let claudeKey = AppEnvironment.scanThrottleKey(forRequested: ["claude"])
        let fullKey = AppEnvironment.scanThrottleKey(forRequested: nil)
        #expect(claudeKey == "claude")
        // The crux of the fix: a Claude-only watcher scan throttles against a
        // different key than the popover's full scan, so frequent ~/.claude
        // writes can't starve Codex imports by tripping the full-scan throttle.
        #expect(claudeKey != fullKey)
    }

    // MARK: - watched directories

    @Test("watches the existing Claude roots under the resolved home")
    func watchesExistingClaudeRoots() {
        let home = URL(fileURLWithPath: "/tmp/qm-home")
        let existing: Set<String> = ["/tmp/qm-home/.claude/projects"]
        let dirs = ClaudeFileWatcher.watchedDirectories(
            home: home, exists: { existing.contains($0) })
        #expect(dirs.map(\.path) == ["/tmp/qm-home/.claude/projects"])
    }

    @Test("watches the newer .config/claude layout too when present")
    func watchesConfigLayout() {
        let home = URL(fileURLWithPath: "/tmp/qm-home")
        let dirs = ClaudeFileWatcher.watchedDirectories(
            home: home, exists: { _ in true })
        #expect(Set(dirs.map(\.path)) == [
            "/tmp/qm-home/.claude/projects",
            "/tmp/qm-home/.config/claude/projects",
        ])
    }

    @Test("watches nothing when no Claude directory exists yet")
    func noClaudeDirectory() {
        let dirs = ClaudeFileWatcher.watchedDirectories(
            home: URL(fileURLWithPath: "/tmp/qm-home"), exists: { _ in false })
        #expect(dirs.isEmpty)
    }

    // MARK: - start() success reporting

    @Test("start() reports failure when there is nothing to watch")
    func startFailsWithNoDirectories() {
        let watcher = ClaudeFileWatcher(directories: []) {}
        // Failure must be reported so the caller doesn't retain a dead watcher
        // and can retry later (e.g. once a transcript directory appears).
        #expect(watcher.start() == false)
    }

    @Test("start() reports success for a real directory and is idempotent")
    func startSucceedsForRealDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qm-fsw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = ClaudeFileWatcher(directories: [dir]) {}
        #expect(watcher.start() == true)
        #expect(watcher.start() == true)  // already running → still success
        watcher.stop()
    }

    @Test("start()/stop() balance the injected security scope for every root")
    func balancesInjectedSecurityScope() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qm-fsw-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // App Store watches bookmark roots and must hold their scope for the
        // stream's lifetime: opened on start(), released on stop().
        let access = RecordingScopeAccess()
        let watcher = ClaudeFileWatcher(
            directories: [dir], securityScopedAccess: access) {}
        #expect(watcher.start() == true)
        #expect(access.events == ["start:\(dir.path)"])
        watcher.stop()
        #expect(access.events == ["start:\(dir.path)", "stop:\(dir.path)"])
    }
}

private final class RecordingScopeAccess:
    SecurityScopedResourceAccessing, @unchecked Sendable
{
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func access(_ url: URL) -> SecurityScopedResourceAccess {
        record("start:\(url.path)")
        return SecurityScopedResourceAccess(url: url, didStart: true) { [weak self] in
            self?.record("stop:\(url.path)")
        }
    }
    private func record(_ event: String) { lock.withLock { recorded.append(event) } }
}

/// A `~/.claude` write that lands while a scan is already running must not be
/// dropped: if the append post-dates the importer's read of that file, that
/// FSEvents notification is the only signal for those bytes. So it's coalesced
/// into exactly one trailing rescan that fires when the in-flight scan ends.
@MainActor
@Suite("Claude file-watch scan coalescing")
struct ClaudeFileWatchCoalescingTests {

    /// Keep `runScan` from touching real services when the trailing rescan
    /// fires: with onboarding marked incomplete it returns at the gate.
    private func withOnboardingIncomplete(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = "onboarding.providersDone"
        let old = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        body()
    }

    @Test("a write during a scan is queued, not dropped")
    func writeDuringScanIsQueued() {
        withOnboardingIncomplete {
            let env = AppEnvironment(startBackgroundTasks: false)
            env.isScanning = true

            env.triggerClaudeFileWatchScan()
            #expect(env._claudeFileWatchScanPendingForTest,
                    "a mid-scan write must be queued as a trailing rescan")
        }
    }

    @Test("multiple writes during a scan coalesce into one trailing rescan")
    func multipleWritesCoalesce() {
        withOnboardingIncomplete {
            let env = AppEnvironment(startBackgroundTasks: false)
            env.isScanning = true
            env.triggerClaudeFileWatchScan()
            env.triggerClaudeFileWatchScan()
            env.triggerClaudeFileWatchScan()
            #expect(env._claudeFileWatchScanPendingForTest)

            // The in-flight scan ends → exactly one trailing rescan is consumed.
            env.isScanning = false
            env.runPendingClaudeFileWatchScanIfNeeded()
            #expect(!env._claudeFileWatchScanPendingForTest,
                    "the queued rescan must be consumed exactly once")
        }
    }

    @Test("no queued rescan stays a no-op")
    func noPendingIsNoop() {
        withOnboardingIncomplete {
            let env = AppEnvironment(startBackgroundTasks: false)
            env.runPendingClaudeFileWatchScanIfNeeded()
            #expect(!env._claudeFileWatchScanPendingForTest)
        }
    }

    @Test("a write inside the throttle window arms a trailing scan, not a drop")
    func throttledWriteArmsTrailingScan() {
        withOnboardingIncomplete {
            let env = AppEnvironment(startBackgroundTasks: false)
            // Pretend a Claude-scope scan just completed.
            env.lastScanAtByScope[AppEnvironment.scanThrottleKey(forRequested: ["claude"])] = Date()
            #expect(!env._claudeFileWatchHasTrailingTaskForTest)

            env.triggerClaudeFileWatchScan()  // write < 5s after the last scan
            #expect(env._claudeFileWatchHasTrailingTaskForTest,
                    "a throttled watcher write must arm a trailing scan, not vanish")
            #expect(!env._claudeFileWatchScanPendingForTest)

            // A second write inside the window coalesces — still one timer.
            env.triggerClaudeFileWatchScan()
            #expect(env._claudeFileWatchHasTrailingTaskForTest)

            env._cancelClaudeFileWatchTrailingTaskForTest()  // don't leak a 5s sleep
        }
    }
}
