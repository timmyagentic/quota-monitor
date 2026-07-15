import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Codex tier preference import")
struct CodexTierPreferenceImportTests {

    @Test("rollout-only scan persists turn IDs and explicit tier preferences")
    func rolloutOnlyScanPersistsTurnIdAndTierPreference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qm-codex-tier-import-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent(
            "custom-codex-home",
            isDirectory: true)
        let sessions = codexHome.appendingPathComponent(
            "sessions/2026/07/15",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true)

        let rollout = sessions.appendingPathComponent(
            "rollout-2026-07-15T00-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        try #"""
        {"timestamp":"2026-07-15T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/codex-tier-import"}}
        {"timestamp":"2026-07-15T00:00:01.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
        {"timestamp":"2026-07-15T00:00:02.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-priority"}}
        {"timestamp":"2026-07-15T00:00:03.000Z","type":"turn_context","payload":{"turn_id":"turn-priority","model":"gpt-5.5"}}
        {"timestamp":"2026-07-15T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":25,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}
        {"timestamp":"2026-07-15T00:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-priority"}}
        {"timestamp":"2026-07-15T00:00:06.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"flex"}}}
        {"timestamp":"2026-07-15T00:00:07.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-flex"}}
        {"timestamp":"2026-07-15T00:00:08.000Z","type":"turn_context","payload":{"turn_id":"turn-flex","model":"gpt-5.5"}}
        {"timestamp":"2026-07-15T00:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55}}}}
        """#
        .appending("\n")
        .write(to: rollout, atomically: true, encoding: .utf8)

        let logsDatabase = codexHome.appendingPathComponent("logs_2.sqlite")
        #expect(!FileManager.default.fileExists(atPath: logsDatabase.path))

        let database = try DatabaseManager(
            url: root.appendingPathComponent("quotamonitor.sqlite"))
        let report = try await ImportEngine(
            database: database,
            codexHome: codexHome
        ).performScan()

        #expect(report.changedFiles == 1)
        #expect(report.importedEvents == 2)
        #expect(report.errors.isEmpty)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT codex_turn_id, codex_service_tier_preference
                FROM usage_events
                WHERE session_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                ORDER BY timestamp
                """)
        }
        let persisted = rows.map { row in
            (
                row["codex_turn_id"] as String?,
                row["codex_service_tier_preference"] as String?
            )
        }
        #expect(persisted.map(\.0) == ["turn-priority", "turn-flex"])
        #expect(persisted.map(\.1) == ["priority", "flex"])
        #expect(!FileManager.default.fileExists(atPath: logsDatabase.path))
    }
}
