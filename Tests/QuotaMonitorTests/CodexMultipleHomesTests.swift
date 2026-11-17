import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Codex multiple history homes")
struct CodexMultipleHomesTests {
    @Test("Additional homes use explicit settings and stay disabled in App Store and QA")
    func additionalHomesRespectDistributionAndQA() throws {
        let suite = "dev.tjzhou.QuotaMonitor.MultipleHomes.\(UUID().uuidString)"
        let defaults = try #require(TestResources.userDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/tmp/qm-bot-home", "/tmp/qm-bot-home", "relative-home"],
                     forKey: "settings.additionalCodexHomes")

        let homes = SessionScanner.additionalCodexHomes(
            distribution: .developerID, defaults: defaults,
            environment: [:], arguments: ["QuotaMonitor"])
        #expect(homes.map(\.path) == ["/tmp/qm-bot-home"])
        #expect(SessionScanner.additionalCodexHomes(
            distribution: .appStore, defaults: defaults,
            environment: [:], arguments: ["QuotaMonitor"]).isEmpty)
        #expect(SessionScanner.additionalCodexHomes(
            distribution: .developerID, defaults: defaults,
            environment: ["QUOTAMONITOR_QA_MODE": "1"],
            arguments: ["QuotaMonitor"]).isEmpty)
    }

    @Test("Duplicate and symlinked homes resolve to one source")
    func uniqueHomesResolveAliases() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        #expect(SessionScanner.uniqueHomes([home, home, alias]) == [home])
    }

    @Test("Desktop and bot histories import once and retain each home's metadata")
    func importsIndependentHomesWithMetadata() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = root.appendingPathComponent("desktop", isDirectory: true)
        let bot = root.appendingPathComponent("bot", isDirectory: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let desktopID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let botID = "11111111-2222-3333-4444-555555555555"
        try writeSession(home: desktop, id: desktopID, title: "Desktop title", input: 100)
        try writeSession(home: bot, id: botID, title: "Bot title", input: 200)
        let db = try DatabaseManager(url: root.appendingPathComponent("quotamonitor.sqlite"))
        let engine = ImportEngine(database: db, codexHome: desktop,
                                  additionalCodexHomes: [bot, desktop, missing])

        let first = try await engine.performScan()
        #expect(first.scannedFiles == 2)
        #expect(first.importedEvents == 2)
        #expect(first.errors.isEmpty)
        let second = try await engine.performScan()
        #expect(second.changedFiles == 0)
        #expect(second.importedEvents == 0)

        let totals = try await db.pool.read { database in
            try Int64.fetchOne(database, sql: "SELECT SUM(total_tokens) FROM usage_events")
        }
        #expect(totals == 320)
        let titles = try await db.pool.read { database in
            try String.fetchAll(database, sql: "SELECT title FROM sessions ORDER BY title")
        }
        #expect(titles == ["Bot title", "Desktop title"])
    }

    @Test("A rollout copied into another home is counted once")
    func copiedRolloutIsCountedOnce() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = root.appendingPathComponent("desktop", isDirectory: true)
        let bot = root.appendingPathComponent("bot", isDirectory: true)
        let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try writeSession(home: desktop, id: id, title: "Shared session", input: 100)
        try FileManager.default.copyItem(at: desktop, to: bot)
        let db = try DatabaseManager(url: root.appendingPathComponent("quotamonitor.sqlite"))
        let engine = ImportEngine(database: db, codexHome: desktop,
                                  additionalCodexHomes: [bot])
        let report = try await engine.performScan()
        #expect(report.scannedFiles == 2)
        #expect(report.importedEvents == 1)
        #expect(report.errors.isEmpty)
        let count = try await db.pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM usage_events")
        }
        #expect(count == 1)
        #expect(try await engine.performScan().importedEvents == 0)
    }

    private func scratchDirectory() throws -> URL {
        let root = TestResources.temporaryDirectory
            .appendingPathComponent("multiple-homes-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(home: URL, id: String, title: String, input: Int) throws {
        let sessions = home.appendingPathComponent("sessions/2026/11/17", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-2026-11-17T00-00-00-\(id).jsonl")
        let lines = #"""
        {"timestamp":"2026-11-17T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/fixture/\#(title)"}}
        {"timestamp":"2026-11-17T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"2026-11-17T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":\#(input + 10)}}}}
        """#
        try (lines + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let metadata = #"{"id":"\#(id)","thread_name":"\#(title)","updated_at":"2026-11-17T00:00:02.000Z"}"#
        try (metadata + "\n").write(to: home.appendingPathComponent("session_index.jsonl"),
                                    atomically: true, encoding: .utf8)
    }
}
