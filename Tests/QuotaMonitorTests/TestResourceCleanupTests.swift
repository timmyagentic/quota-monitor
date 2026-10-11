import Darwin
import Foundation
import Testing

@Suite("Test resource lifecycle")
struct TestResourceCleanupTests {
    private func parent() throws -> URL {
        let url = TestResources.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Close removes exact owned preferences and temporary files, preserving another live scope")
    func closeRemovesOnlyOwnedResources() throws {
        let parent = try parent()
        let first = try TestResourceScope(parent: parent)
        let second = try TestResourceScope(parent: parent)
        defer { try? first.close(); try? second.close() }
        let suite = "TestResourceCleanup.\(UUID().uuidString)"
        let sibling = "TestResourceCleanup.\(UUID().uuidString)"
        TestResources.registerPreferences(suite)
        TestResources.registerPreferences(sibling)
        try first.registerPreferences(suite)
        try second.registerPreferences(sibling)
        let defaults = UserDefaults(suiteName: suite)!
        let other = UserDefaults(suiteName: sibling)!
        defaults.set("owned", forKey: "value")
        other.set("keep", forKey: "value")
        defaults.synchronize()
        other.synchronize()
        let file = first.directory.appendingPathComponent("database.sqlite")
        try Data("temporary".utf8).write(to: file)
        try first.close()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        #expect(!FileManager.default.fileExists(atPath: preferences.path))
        #expect(defaults.string(forKey: "value") == nil)
        #expect(other.string(forKey: "value") == "keep")
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
    }

    @Test("Recovery removes unlocked crash residue and skips active or malformed journals")
    func recoveryHonorsLocksAndValidatesJournal() throws {
        let parent = try parent()
        let active = try TestResourceScope(parent: parent)
        defer { try? active.close() }
        let abandoned = parent.appendingPathComponent("quotamonitor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data().write(to: abandoned.appendingPathComponent("lock"))
        try JSONEncoder().encode([String]()).write(to: abandoned.appendingPathComponent("preferences.json"))
        let invalid = parent.appendingPathComponent("quotamonitor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data().write(to: invalid.appendingPathComponent("lock"))
        try JSONEncoder().encode(["dev.tjzhou.QuotaMonitor"]).write(to: invalid.appendingPathComponent("preferences.json"))
        try TestResourceScope.recover(in: parent)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: active.directory.path))
        #expect(FileManager.default.fileExists(atPath: invalid.path))
        #expect(!TestResourceScope.isTestSuite("dev.tjzhou.QuotaMonitor"))
        #expect(!TestResourceScope.isTestSuite("../\(UUID().uuidString)"))
    }
}
