import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// End-to-end wiring: a rollout with a `task_started` turn id runs through
/// `ImportEngine.performScan`, its turn id lands in `usage_events`, and the
/// `logs_2.sqlite` priority trace stamps the billing tier — all against a
/// throwaway `codexHome`.
@Suite("Codex billing tier import wiring")
struct CodexBillingTierImportTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-tier-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return try DatabaseManager(url: dir.appendingPathComponent("quotamonitor.sqlite"))
    }

    @Test("performScan persists turn_id and a priority trace stamps tier=priority")
    func endToEndTurnIdAndPriorityTier() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codexhome-\(UUID().uuidString)", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions, withIntermediateDirectories: true)

        let turn = "019f0000-0000-7000-8000-0000000000aa"
        let sessionId = "019f0000-0000-7000-8000-0000000000bb"
        let eventEpoch = 1_783_400_000.0
        let eventTs = ISO8601.fractional.string(
            from: Date(timeIntervalSince1970: eventEpoch))

        let jsonl = """
        {"timestamp":"\(eventTs)","type":"session_meta","payload":{"id":"\(sessionId)","timestamp":"\(eventTs)","cwd":"/tmp/proj"}}
        {"timestamp":"\(eventTs)","type":"event_msg","payload":{"type":"task_started","turn_id":"\(turn)","started_at":1}}
        {"timestamp":"\(eventTs)","type":"turn_context","payload":{"turn_id":"\(turn)","model":"gpt-5.5"}}
        {"timestamp":"\(eventTs)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}

        """
        let rollout = sessions.appendingPathComponent(
            "rollout-2026-07-06T00-00-00-\(sessionId).jsonl")
        try jsonl.write(to: rollout, atomically: true, encoding: .utf8)

        // Trace: this turn ran priority, and the window brackets the event.
        let logsURL = codexHome.appendingPathComponent("logs_2.sqlite")
        let traceQueue = try DatabaseQueue(path: logsURL.path)
        try await traceQueue.write { conn in
            try conn.execute(sql: """
                CREATE TABLE logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts INTEGER NOT NULL,
                    feedback_log_body TEXT
                )
                """)
            try conn.execute(
                sql: "INSERT INTO logs (ts, feedback_log_body) VALUES (?, ?)",
                arguments: [Int64(eventEpoch - 86_400), "warmup line"])
            try conn.execute(
                sql: "INSERT INTO logs (ts, feedback_log_body) VALUES (?, ?)",
                arguments: [Int64(eventEpoch + 86_400),
                            #"request{turn_id=\#(turn)}: {"service_tier":"priority"}"#])
        }

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT codex_turn_id, codex_billing_tier
                FROM usage_events WHERE provider = 'codex'
                """)
        }
        #expect(!rows.isEmpty, "expected at least one imported codex usage event")
        for row in rows {
            #expect((row["codex_turn_id"] as String?) == turn,
                    "delta turn id must be persisted")
            #expect((row["codex_billing_tier"] as String?) == "priority",
                    "priority trace must stamp the tier during the scan")
        }
    }
}
