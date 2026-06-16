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

    @Test("Codex metadata store reads session_index thread_name")
    func codexMetadataReadsSessionIndex() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"梳理项目现状","updated_at":"2026-06-15T03:01:30Z"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "梳理项目现状")
    }

    @Test("Codex metadata store prefers threads sqlite title and cwd")
    func codexMetadataPrefersStateDatabase() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sqliteDir = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"older title"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let db = try DatabaseQueue(path: sqliteDir.appendingPathComponent("state_5.sqlite").path)
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    cwd TEXT NOT NULL
                )
                """)
            try conn.execute(sql: """
                INSERT INTO threads (id, title, cwd)
                VALUES ('s1', '真实会话标题', '/Volumes/SamsungDisk/Code/quota-monitor')
                """)
        }

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "真实会话标题")
        #expect(metadata["s1"]?.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
        #expect(metadata["s1"]?.projectName == "quota-monitor")
    }

    @Test("Codex metadata store keeps session_index title when state sqlite is unusable")
    func codexMetadataFallsBackWhenStateDatabaseFails() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sqliteDir = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"session index title"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let db = try DatabaseQueue(path: sqliteDir.appendingPathComponent("state_5.sqlite").path)
        try db.write { conn in
            try conn.execute(sql: "CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
        }

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "session index title")
    }

    @Test("Claude parser uses ai-title as session title and cwd as project metadata")
    func claudeParserSeparatesTitleAndProject() throws {
        let url = try writeJSONL("""
        {"type":"ai-title","aiTitle":"Review PR #59 default setting","sessionId":"c1"}
        {"type":"user","sessionId":"c1","timestamp":"2026-06-15T10:00:00.000Z","cwd":"/Volumes/SamsungDisk/Code/quota-monitor","message":{"role":"user","content":"review this PR"}}
        {"type":"assistant","sessionId":"c1","timestamp":"2026-06-15T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """)
        let parsed = try #require(try ClaudeRolloutParser.parse(fileURL: url).session)
        #expect(parsed.title == "Review PR #59 default setting")
        #expect(parsed.projectName == "quota-monitor")
        #expect(parsed.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
    }

    @Test("Claude incremental scan preserves existing title and project metadata")
    func claudeIncrementalScanPreservesExistingHeaderMetadata() async throws {
        let db = try makeDatabase()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-root-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent(
            "-Volumes-SamsungDisk-Code-quota-monitor",
            isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let rollout = projectDir.appendingPathComponent("c1.jsonl")
        try """
        {"type":"ai-title","aiTitle":"Review PR #59 default setting","sessionId":"c1"}
        {"type":"user","sessionId":"c1","timestamp":"2026-06-15T10:00:00.000Z","cwd":"/Volumes/SamsungDisk/Code/quota-monitor","message":{"role":"user","content":"review this PR"}}
        {"type":"assistant","sessionId":"c1","timestamp":"2026-06-15T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"assistant","sessionId":"c1","timestamp":"2026-06-15T10:02:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":6}}}
        """.utf8))

        _ = try await engine.performScan()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 'c1'
                """)
        })
        #expect(row["title"] as String? == "Review PR #59 default setting")
        #expect(row["project_name"] as String? == "quota-monitor")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/quota-monitor")
    }

    @Test("Session search matches title and project metadata separately")
    func sessionSearchMatchesTitleAndProject() throws {
        let db = try makeDatabase()
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   project_name, cwd, source_path, started_at, updated_at,
                   agent_nickname, agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('s1', 's1', NULL, 'Review PR #59 default setting',
                   'quota-monitor', '/Volumes/SamsungDisk/Code/quota-monitor',
                   NULL, '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z',
                   NULL, NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-15T10:00:00Z', '2026-06-15T10:10:00Z', 'codex')
                """)
            try conn.execute(sql: """
                INSERT INTO usage_events
                  (session_id, timestamp, model_id, input_tokens,
                   cached_input_tokens, output_tokens, reasoning_output_tokens,
                   total_tokens, value_usd, provider, cache_creation_tokens,
                   model_inferred)
                VALUES
                  ('s1', '2026-06-15T10:02:00Z', 'gpt-5.5',
                   10, 0, 5, 0, 15, 0.01, 'codex', 0, 0)
                """)
        }

        let byTitle = try db.pool.read { conn in
            try Aggregator.fetchSessions(db: conn, search: "default setting")
        }
        let byProject = try db.pool.read { conn in
            try Aggregator.fetchSessions(db: conn, search: "quota-monitor")
        }

        #expect(byTitle.first?.title == "Review PR #59 default setting")
        #expect(byTitle.first?.projectName == "quota-monitor")
        #expect(byTitle.first?.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
        #expect(byProject.first?.sessionId == "s1")
    }
}
