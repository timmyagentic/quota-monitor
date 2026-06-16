import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Session title and project metadata")
struct SessionTitleProjectMetadataTests {
    private func makeDatabase(_ name: String = #function) throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qm-session-metadata-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DatabaseManager(url: dir.appendingPathComponent("quotamonitor.sqlite"))
    }

    private func writeJSONL(_ content: String, name: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "qm-session-metadata-jsonl-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("v11 columns exist and legacy title is reclassified as project metadata")
    func migrationReclassifiesLegacyProjectTitle() throws {
        let db = try makeDatabase()
        try db.pool.write { conn in
            // Insert a legacy-shaped row into the final schema, then call the
            // shared helper directly. A fresh DatabaseManager has already run
            // every migration, so inserting after init cannot prove that v11
            // handled a historical row during migration.
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   project_name, cwd,
                   source_path, started_at, updated_at, agent_nickname,
                   agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('s1', 's1', NULL, 'game_backend_task2',
                   NULL, NULL,
                   '/Users/timmy/.codex/sessions/rollout-s1.jsonl',
                   '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z',
                   NULL, NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z', 'codex')
                """)
            try SessionMetadataMigration.reclassifyLegacyTitles(in: conn)
            let row = try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
            #expect(row?["title"] as String? == nil)
            #expect(row?["project_name"] as String? == "game_backend_task2")
            #expect(row?["cwd"] as String? == nil)
        }
    }

    @Test("Codex parser treats cwd leaf as project metadata, not title")
    func codexParserSeparatesProjectFromTitle() throws {
        let url = try writeJSONL("""
        {"timestamp":"2026-06-15T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/Volumes/SamsungDisk/Code/game_backend_task2"}}
        {"timestamp":"2026-06-15T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """)
        let parsed = try #require(try RolloutParser.parse(fileURL: url))
        #expect(parsed.title == nil)
        #expect(parsed.projectName == "game_backend_task2")
        #expect(parsed.cwd == "/Volumes/SamsungDisk/Code/game_backend_task2")
    }
}
