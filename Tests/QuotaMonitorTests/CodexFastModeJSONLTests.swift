import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Codex Fast Mode JSONL import")
struct CodexFastModeJSONLTests {
    @Test("import scan persists Fast, Standard, and Unknown tiers from rollout markers")
    func importScanPersistsFastStandardAndUnknownTiersFromRolloutMarkers() async throws {
        let database = try Self.makeQuotaMonitorDatabase()
        let codexHome = try Self.makeTemporaryDirectory()
        let sessionsDirectory = codexHome.appending(path: "sessions/2026/06/20", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appending(path: "rollout-2026-06-20T10-00-00-test-session.jsonl")
        try Self.writeCodexRollout(to: rolloutURL)

        let report = try await ImportEngine(database: database, codexHome: codexHome).performScan()
        #expect(report.changedFiles == 1)
        #expect(report.importedEvents == 4)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT turn_id, billing_tier, billing_tier_source, total_tokens
                FROM usage_events
                ORDER BY timestamp ASC, id ASC
                """)
        }

        #expect(rows.map { $0["turn_id"] as String? } == [
            "turn-fast",
            "turn-quick",
            "turn-standard",
            "turn-unknown"
        ])
        #expect(rows.map { $0["billing_tier"] as String } == [
            "fast",
            "fast",
            "standard",
            "unknown"
        ])
        #expect(rows.map { $0["billing_tier_source"] as String } == [
            "jsonl",
            "jsonl",
            "jsonl",
            "missing_marker"
        ])
        #expect(rows.map { $0["total_tokens"] as Int64 } == [1_100, 550, 220, 110])
    }

    @Test("second scan skips unchanged rollout without needing an external database")
    func secondScanSkipsUnchangedRolloutWithoutExternalDatabase() async throws {
        let database = try Self.makeQuotaMonitorDatabase()
        let codexHome = try Self.makeTemporaryDirectory()
        let sessionsDirectory = codexHome.appending(path: "sessions/2026/06/20", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appending(path: "rollout-2026-06-20T10-00-00-test-session.jsonl")
        try Self.writeCodexRollout(to: rolloutURL)

        let engine = ImportEngine(database: database, codexHome: codexHome)
        let first = try await engine.performScan()
        let second = try await engine.performScan()

        #expect(first.changedFiles == 1)
        #expect(first.importedEvents == 4)
        #expect(second.changedFiles == 0)
        #expect(second.importedEvents == 0)

        let tiers = try await database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT billing_tier FROM usage_events
                ORDER BY timestamp ASC, id ASC
                """)
        }
        #expect(tiers == ["fast", "fast", "standard", "unknown"])
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "QuotaMonitorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeQuotaMonitorDatabase() throws -> DatabaseManager {
        let directory = try makeTemporaryDirectory()
        return try DatabaseManager(url: directory.appending(path: "quotamonitor.sqlite"))
    }

    private static func writeCodexRollout(to url: URL) throws {
        try """
        {"timestamp":"2026-06-20T10:00:00.000Z","type":"session_meta","payload":{"id":"test-session","cwd":"/tmp/quota-monitor"}}
        {"timestamp":"2026-06-20T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-fast","fast_mode":true}}
        {"timestamp":"2026-06-20T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100}}}}
        {"timestamp":"2026-06-20T10:03:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-quick","quick_mode":true}}
        {"timestamp":"2026-06-20T10:04:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":450,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":550}}}}
        {"timestamp":"2026-06-20T10:05:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-standard","fast_mode":false}}
        {"timestamp":"2026-06-20T10:06:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":180,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":220}}}}
        {"timestamp":"2026-06-20T10:07:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-unknown"}}
        {"timestamp":"2026-06-20T10:08:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
    }
}
