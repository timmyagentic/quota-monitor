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
}
