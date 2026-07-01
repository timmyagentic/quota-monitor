import Foundation
import Testing
@testable import QuotaMonitor

@Suite("History root authorization")
struct HistoryRootAuthorizationTests {
    private func freshDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suite = "dev.tjzhou.QuotaMonitor.HistoryRoots.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    @Test("App Store import roots require user-selected bookmarks")
    func appStoreRootsRequireBookmarks() throws {
        let defaults = try freshDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let store = HistoryRootAuthorizationStore(defaults: defaults.defaults)

        let codexHome = SessionScanner.defaultCodexHome(
            distribution: .appStore,
            authorizations: store,
            environment: ["CODEX_HOME": "/tmp/should-not-leak/.codex"],
            arguments: ["QuotaMonitor"])
        let claudeRoots = ClaudeImportEngine.defaultRoots(
            distribution: .appStore,
            authorizations: store,
            environment: [:],
            arguments: ["QuotaMonitor"])

        #expect(codexHome == nil)
        #expect(claudeRoots.isEmpty)
    }

    @Test("Developer ID keeps legacy history auto-discovery")
    func developerIDKeepsLegacyHistoryAutodiscovery() throws {
        let defaults = try freshDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let store = HistoryRootAuthorizationStore(defaults: defaults.defaults)

        let codexHome = SessionScanner.defaultCodexHome(
            distribution: .developerID,
            authorizations: store,
            environment: ["CODEX_HOME": "/tmp/qm-codex-home"],
            arguments: ["QuotaMonitor"])
        let claudeRoots = ClaudeImportEngine.defaultRoots(
            distribution: .developerID,
            authorizations: store,
            environment: ["QUOTAMONITOR_QA_HOME": "/tmp/qm-home"],
            arguments: ["QuotaMonitor"])

        #expect(codexHome?.path == "/tmp/qm-codex-home")
        #expect(claudeRoots.map(\.path) == [
            "/tmp/qm-home/.claude/projects",
            "/tmp/qm-home/.config/claude/projects",
        ])
    }

    @Test("History imports open and close security-scoped root access")
    func historyImportsUseSecurityScopedRootAccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-history-root-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let dbURL = root
            .appendingPathComponent("container", isDirectory: true)
            .appendingPathComponent("quotamonitor.sqlite", isDirectory: false)
        let db = try DatabaseManager(url: dbURL)
        let access = RecordingSecurityScopedResourceAccessing()
        let engine = ImportEngine(
            database: db,
            codexHome: root,
            securityScopedAccess: access)

        _ = try await engine.performScan()

        let events = access.events
        #expect(events == [
            "start:\(root.path)",
            "stop:\(root.path)",
        ])
    }

    @Test("authorizedProviders scopes a scan to providers with granted folders")
    func authorizedProvidersScopesToGrantedFolders() throws {
        let defaults = try freshDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let store = HistoryRootAuthorizationStore(defaults: defaults.defaults)

        // Nothing granted yet → nothing authorized.
        #expect(store.authorizedProviders(from: ["codex", "claude"]).isEmpty)

        // Grant only Codex's folder.
        let codexDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-auth-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexDir) }
        try store.authorize(kind: .codexHome, url: codexDir)

        // Codex is authorized, Claude is not — the scan must keep Codex rather
        // than aborting because Claude's folder is missing (the P2 fix).
        #expect(store.authorizedProviders(from: ["codex", "claude"]) == ["codex"])
        #expect(store.missingRequiredKinds(for: ["codex", "claude"]) == [.claudeProjects])

        // A provider with no folder requirement counts as authorized.
        #expect(store.authorizedProviders(from: ["mystery"]) == ["mystery"])
    }

    @Test("Granting only the alternate Claude config root authorizes Claude")
    func alternateClaudeRootAuthorizesClaude() throws {
        let defaults = try freshDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let store = HistoryRootAuthorizationStore(defaults: defaults.defaults)

        let altDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-auth-claude-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: altDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: altDir) }

        // The optional alternate picker grants only `~/.config/claude/projects`;
        // that alone must authorize Claude even though `.claudeProjects` is unset.
        try store.authorize(kind: .claudeConfigProjects, url: altDir)

        #expect(store.missingRequiredKinds(for: ["claude"]).isEmpty)
        #expect(store.authorizedProviders(from: ["claude"]) == ["claude"])
    }

    @Test("History root store persists selected directory paths")
    func historyRootStorePersistsSelectedPaths() throws {
        let defaults = try freshDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let store = HistoryRootAuthorizationStore(defaults: defaults.defaults)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-selected-codex-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)

        try store.authorize(kind: .codexHome, url: url)

        #expect(store.displayPath(for: .codexHome) == url.path)
        #expect(
            store.resolvedURL(for: .codexHome)?
                .resolvingSymlinksInPath()
                .path
            == url.resolvingSymlinksInPath().path)
    }

    @Test("App Store roots resolve to the authorized bookmarked folders")
    func appStoreRootsResolveToAuthorizedFolders() throws {
        let defaults = try freshDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
        let store = HistoryRootAuthorizationStore(defaults: defaults.defaults)

        let codexDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-\(UUID().uuidString)", isDirectory: true)
        for d in [codexDir, claudeDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { for d in [codexDir, claudeDir] { try? FileManager.default.removeItem(at: d) } }

        try store.authorize(kind: .codexHome, url: codexDir)
        try store.authorize(kind: .claudeProjects, url: claudeDir)

        let codexHome = SessionScanner.defaultCodexHome(
            distribution: .appStore, authorizations: store,
            environment: [:], arguments: ["QuotaMonitor"])
        let claudeRoots = ClaudeImportEngine.defaultRoots(
            distribution: .appStore, authorizations: store,
            environment: [:], arguments: ["QuotaMonitor"])

        #expect(codexHome?.resolvingSymlinksInPath().path
            == codexDir.resolvingSymlinksInPath().path)
        #expect(claudeRoots.map { $0.resolvingSymlinksInPath().path }
            == [claudeDir.resolvingSymlinksInPath().path])
    }

    @Test("ClaudeImportEngine opens and closes security scope for every root")
    func claudeImportBalancesMultiRootScope() async throws {
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-a-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-b-\(UUID().uuidString)", isDirectory: true)
        for r in [rootA, rootB] {
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        }
        defer { for r in [rootA, rootB] { try? FileManager.default.removeItem(at: r) } }
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-db-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("quotamonitor.sqlite", isDirectory: false)
        let db = try DatabaseManager(url: dbURL)
        let access = RecordingSecurityScopedResourceAccessing()
        let engine = ClaudeImportEngine(
            database: db,
            claudeRoots: [rootA, rootB],
            securityScopedAccess: access)

        _ = try await engine.performScan()

        let events = access.events
        let starts = events.filter { $0.hasPrefix("start:") }
        let stops = events.filter { $0.hasPrefix("stop:") }
        // Balanced: every root's scope is opened and closed exactly once.
        #expect(starts.count == 2)
        #expect(stops.count == 2)
        #expect(Set(starts) == ["start:\(rootA.path)", "start:\(rootB.path)"])
        #expect(Set(stops) == ["stop:\(rootA.path)", "stop:\(rootB.path)"])
        // All scopes stay held across the scan: every start precedes every stop.
        let lastStart = events.lastIndex { $0.hasPrefix("start:") } ?? -1
        let firstStop = events.firstIndex { $0.hasPrefix("stop:") } ?? -1
        #expect(lastStart < firstStop)
    }

    @Test("Developer ID non-scoped roots are not treated as scope failures")
    func developerIDScopeStartNotAFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-scope-db-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("quotamonitor.sqlite", isDirectory: false)
        let db = try DatabaseManager(url: dbURL)
        // didStart=false mimics a non-security-scoped (Developer ID) path — must
        // NOT be reported as a failure (default DistributionChannel is not App Store).
        let access = RecordingSecurityScopedResourceAccessing(didStart: false)
        let engine = ClaudeImportEngine(
            database: db, claudeRoots: [root], securityScopedAccess: access)

        let report = try await engine.performScan()
        #expect(report.scopeUnavailable == false)
    }

    @Test("Folder selection is validated against the expected history layout")
    func selectedFolderValidation() {
        let codexDirs: Set<String> = ["/root/.codex/sessions"]
        let codexExists: (URL) -> Bool = { codexDirs.contains($0.path) }
        #expect(HistoryRootKind.codexHome.resolveSelectedFolder(
            URL(fileURLWithPath: "/root/.codex"), directoryExists: codexExists)?.path
            == "/root/.codex")
        // Parent pick resolves down to the .codex child.
        #expect(HistoryRootKind.codexHome.resolveSelectedFolder(
            URL(fileURLWithPath: "/root"), directoryExists: codexExists)?.path
            == "/root/.codex")
        #expect(HistoryRootKind.codexHome.resolveSelectedFolder(
            URL(fileURLWithPath: "/tmp/random"), directoryExists: codexExists) == nil)
        // A fresh, EMPTY `.codex` (no sessions imported yet) is accepted by name.
        #expect(HistoryRootKind.codexHome.resolveSelectedFolder(
            URL(fileURLWithPath: "/home/user/.codex"), directoryExists: { _ in false })?.path
            == "/home/user/.codex")
        // A parent pick resolves to an existing (even empty) `.codex` child.
        let childOnly: Set<String> = ["/home/user/.codex"]
        #expect(HistoryRootKind.codexHome.resolveSelectedFolder(
            URL(fileURLWithPath: "/home/user"),
            directoryExists: { childOnly.contains($0.path) })?.path
            == "/home/user/.codex")

        let claudeDirs: Set<String> = ["/home/.claude/projects"]
        let claudeExists: (URL) -> Bool = { claudeDirs.contains($0.path) }
        #expect(HistoryRootKind.claudeProjects.resolveSelectedFolder(
            URL(fileURLWithPath: "/home/.claude/projects"), directoryExists: claudeExists)?.path
            == "/home/.claude/projects")
        #expect(HistoryRootKind.claudeProjects.resolveSelectedFolder(
            URL(fileURLWithPath: "/home/.claude"), directoryExists: claudeExists)?.path
            == "/home/.claude/projects")
        #expect(HistoryRootKind.claudeConfigProjects.resolveSelectedFolder(
            URL(fileURLWithPath: "/tmp/nope"), directoryExists: claudeExists) == nil)
    }

    @Test("App Store scan-scope helpers gate correctly")
    func appStoreScanScopeHelpers() {
        // Developer ID: never abort, never scoped.
        #expect(AppEnvironment.appStoreScanShouldAbort(isAppStore: false, authorized: []) == false)
        #expect(AppEnvironment.appStoreScanProviders(
            requested: ["codex", "claude"], authorized: [], isAppStore: false)
            == ["codex", "claude"])
        // App Store, nothing authorized → abort.
        #expect(AppEnvironment.appStoreScanShouldAbort(isAppStore: true, authorized: []) == true)
        // App Store, only Codex authorized → scope to Codex, no abort.
        #expect(AppEnvironment.appStoreScanShouldAbort(isAppStore: true, authorized: ["codex"]) == false)
        #expect(AppEnvironment.appStoreScanProviders(
            requested: ["codex", "claude"], authorized: ["codex"], isAppStore: true)
            == ["codex"])
    }
}

private final class RecordingSecurityScopedResourceAccessing:
    SecurityScopedResourceAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private let didStart: Bool

    init(didStart: Bool = true) {
        self.didStart = didStart
    }

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func access(_ url: URL) -> SecurityScopedResourceAccess {
        record("start:\(url.path)")
        return SecurityScopedResourceAccess(url: url, didStart: didStart) { [weak self] in
            self?.record("stop:\(url.path)")
        }
    }

    private func record(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
