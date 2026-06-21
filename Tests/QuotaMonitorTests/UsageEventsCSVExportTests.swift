import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Usage events CSV export")
struct UsageEventsCSVExportTests {
    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qm-usage-events-csv-export-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseManager(url: dir.appendingPathComponent("quotamonitor.sqlite"))
    }

    @Test("exports turn and billing tier columns after model id")
    func exportsTurnAndBillingTierColumnsAfterModelID() async throws {
        let db = try makeDatabase()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-usage-events-csv-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: output) }

        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   source_path, started_at, updated_at, agent_nickname,
                   agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('csv-session', 'csv-session', NULL, 'CSV Export Session',
                   NULL, '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z',
                   'Codex Agent', NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', 'codex')
                """)
            try conn.execute(sql: """
                INSERT INTO usage_events
                  (session_id, timestamp, model_id,
                   turn_id, billing_tier, billing_tier_source,
                   input_tokens, cached_input_tokens, output_tokens,
                   reasoning_output_tokens, total_tokens, value_usd,
                   provider, cache_creation_tokens, model_inferred)
                VALUES
                  ('csv-session', '2026-06-20T00:01:00Z', 'gpt-5.5',
                   'turn-csv-fast', 'fast', 'jsonl',
                   11, 2, 7, 3, 23, 0.123456,
                   'codex', 0, 0)
                """)
        }

        let count = try await AppEnvironment.writeUsageEventsCSV(database: db, to: output)
        #expect(count == 1)

        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(lines[0] == "id,session_id,timestamp,model_id,turn_id,billing_tier,billing_tier_source,input,cached,output,reasoning,total,value_usd,title,agent")

        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(fields[1...14]) == [
            "csv-session",
            "2026-06-20T00:01:00Z",
            "gpt-5.5",
            "turn-csv-fast",
            "fast",
            "jsonl",
            "11",
            "2",
            "7",
            "3",
            "23",
            "0.123456",
            "CSV Export Session",
            "Codex Agent"
        ])
    }
}
