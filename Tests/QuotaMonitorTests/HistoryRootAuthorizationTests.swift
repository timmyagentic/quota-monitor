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
}

private final class RecordingSecurityScopedResourceAccessing:
    SecurityScopedResourceAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func access(_ url: URL) -> SecurityScopedResourceAccess {
        record("start:\(url.path)")
        return SecurityScopedResourceAccess(url: url) { [weak self] in
            self?.record("stop:\(url.path)")
        }
    }

    private func record(_ event: String) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
