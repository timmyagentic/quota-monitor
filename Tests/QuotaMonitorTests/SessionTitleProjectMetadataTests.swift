import Foundation
import GRDB
import SQLite3
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

    private func makeSessionRow(
        title: String?,
        projectName: String?
    ) -> SessionRow {
        SessionRow(
            sessionId: UUID().uuidString,
            title: title,
            projectName: projectName,
            cwd: projectName.map { "/Volumes/SamsungDisk/Code/\($0)" },
            agentNickname: nil,
            lastModelId: "gpt-5.5",
            startedAt: nil,
            updatedAt: nil,
            totalValueUSD: 0,
            totalTokens: 0,
            eventCount: 0,
            containsSubagents: false,
            subagentCount: nil,
            hasInferredModel: false)
    }

    private func writeCodexStateDatabase(
        at sqlite: URL,
        id: String,
        title: String,
        cwd: String,
        useWAL: Bool = false
    ) throws {
        try FileManager.default.createDirectory(
            at: sqlite.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let db = try DatabaseQueue(path: sqlite.path)
        if useWAL {
            try db.writeWithoutTransaction { conn in
                _ = try String.fetchOne(conn, sql: "PRAGMA journal_mode = WAL")
            }
        }
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    cwd TEXT NOT NULL
                )
                """)
            try conn.execute(
                sql: "INSERT INTO threads (id, title, cwd) VALUES (?, ?, ?)",
                arguments: [id, title, cwd])
        }
    }

    private func writeCodexStateDatabase(
        codexHome: URL,
        id: String,
        title: String,
        cwd: String,
        useWAL: Bool = false
    ) throws {
        try writeCodexStateDatabase(
            at: stateDatabaseURL(codexHome: codexHome),
            id: id,
            title: title,
            cwd: cwd,
            useWAL: useWAL)
    }

    private func stateDatabaseURL(codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("state_5.sqlite")
    }

    private func rootStateDatabaseURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    private func withExclusiveSQLiteLock<T>(at sqlite: URL, perform body: () throws -> T) throws -> T {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            sqlite.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
            nil)
        guard openCode == SQLITE_OK, let database else {
            let message = database.flatMap(sqlite3_errmsg).map { String(cString: $0) }
                ?? "SQLite result code \(openCode)"
            if let database {
                sqlite3_close(database)
            }
            throw NSError(
                domain: "SessionTitleProjectMetadataTests",
                code: Int(openCode),
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(database) }

        let lockCode = sqlite3_exec(
            database,
            "PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE",
            nil,
            nil,
            nil)
        guard lockCode == SQLITE_OK else {
            throw NSError(
                domain: "SessionTitleProjectMetadataTests",
                code: Int(lockCode),
                userInfo: [
                    NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))
                ])
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        return try body()
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

    @Test("Codex metadata store combines session_index title with state cwd")
    func codexMetadataCombinesSessionIndexTitleWithStateCwd() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sqliteDir = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"检查 git worktree 布局"}
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
                VALUES (
                    's1',
                    '/Volumes/SamsungDisk/Code 你看一下这个文件夹里是不是有很多 git worktree？',
                    '/Volumes/SamsungDisk/Code/quota-monitor'
                )
                """)
        }

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "检查 git worktree 布局")
        #expect(metadata["s1"]?.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
        #expect(metadata["s1"]?.projectName == "quota-monitor")
    }

    @Test("Codex metadata store reads root state database path")
    func codexMetadataReadsRootStateDatabasePath() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"更新 main 并检查未合并 PR"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let db = try DatabaseQueue(path: codexHome.appendingPathComponent("state_5.sqlite").path)
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    cwd TEXT NOT NULL
                )
                """)
            try conn.execute(
                sql: "INSERT INTO threads (id, title, cwd) VALUES (?, ?, ?)",
                arguments: [
                    "s1",
                    "更新 main 并检查未合并 PR 的第一轮很长 prompt",
                    "/Volumes/SamsungDisk/Code/xianyu-seller-agent"
                ])
        }

        let metadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        #expect(metadata["s1"]?.title == "更新 main 并检查未合并 PR")
        #expect(metadata["s1"]?.cwd == "/Volumes/SamsungDisk/Code/xianyu-seller-agent")
        #expect(metadata["s1"]?.projectName == "xianyu-seller-agent")
    }

    @Test("Codex metadata store prefers sqlite state database over root fallback")
    func codexMetadataPrefersPrimaryStateDatabaseOverRootFallback() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try writeCodexStateDatabase(
            at: stateDatabaseURL(codexHome: codexHome),
            id: "s1",
            title: "primary state title should still be ignored",
            cwd: "/Volumes/SamsungDisk/Code/quota-monitor")
        try writeCodexStateDatabase(
            at: rootStateDatabaseURL(codexHome: codexHome),
            id: "s1",
            title: "stale root fallback title should still be ignored",
            cwd: "/Volumes/SamsungDisk/Code/stale-project")

        let metadata = try CodexSessionMetadataStore.loadStateDatabase(codexHome: codexHome)
        #expect(metadata["s1"]?.title == nil)
        #expect(metadata["s1"]?.cwd == "/Volumes/SamsungDisk/Code/quota-monitor")
        #expect(metadata["s1"]?.projectName == "quota-monitor")
    }

    @Test("Codex metadata store reads locked WAL state database cwd")
    func codexMetadataReadsLockedWALStateDatabase() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try writeCodexStateDatabase(
            codexHome: codexHome,
            id: "s1",
            title: "梳理一下现在导入数据的流程是什么样的",
            cwd: "/Volumes/SamsungDisk/Code/emomo",
            useWAL: true)

        let metadata = try withExclusiveSQLiteLock(at: stateDatabaseURL(codexHome: codexHome)) {
            try CodexSessionMetadataStore.loadStateDatabase(codexHome: codexHome)
        }
        #expect(metadata["s1"]?.title == nil)
        #expect(metadata["s1"]?.projectName == "emomo")
    }

    @Test("Codex metadata store reads WAL state database snapshots without sidecars")
    func codexMetadataReadsWALStateDatabaseSnapshotWithoutSidecars() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try writeCodexStateDatabase(
            codexHome: codexHome,
            id: "s1",
            title: "梳理一下现在导入数据的流程是什么样的",
            cwd: "/Volumes/SamsungDisk/Code/emomo",
            useWAL: true)

        let sqlite = stateDatabaseURL(codexHome: codexHome)
        try? FileManager.default.removeItem(atPath: "\(sqlite.path)-wal")
        try? FileManager.default.removeItem(atPath: "\(sqlite.path)-shm")

        let metadata = try CodexSessionMetadataStore.loadStateDatabase(codexHome: codexHome)
        #expect(metadata["s1"]?.title == nil)
        #expect(metadata["s1"]?.projectName == "emomo")
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

    @Test("Claude scan preserves real title matching project when file is unchanged")
    func claudeScanPreservesAmbiguousTitleMatchingProject() async throws {
        let db = try makeDatabase()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-claude-root-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent(
            "-Volumes-SamsungDisk-Code-quota-monitor",
            isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let rollout = projectDir.appendingPathComponent("c-project-title.jsonl")
        try """
        {"type":"ai-title","aiTitle":"quota-monitor","sessionId":"c-project-title"}
        {"type":"user","sessionId":"c-project-title","timestamp":"2026-06-15T10:00:00.000Z","cwd":"/Volumes/SamsungDisk/Code/quota-monitor","message":{"role":"user","content":"review this PR"}}
        {"type":"assistant","sessionId":"c-project-title","timestamp":"2026-06-15T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        let report = try await engine.performScan()
        #expect(report.changedFiles == 0)
        #expect(report.importedSessions == 0)

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 'c-project-title'
                """)
        })
        #expect(row["title"] as String? == "quota-monitor")
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

    @Test("History and Sessions rows route through the shared metadata view")
    func sessionRowsUseSharedProjectMetadataView() throws {
        let sessions = try String(
            contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/Sessions/SessionsView.swift"))
        let history = try String(
            contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/History/HistoryView.swift"))
        let detail = try String(
            contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/Sessions/SessionDetailView.swift"))

        #expect(sessions.contains("SessionRowMetadataView(row: row"))
        #expect(history.contains("SessionRowMetadataView(row: session"))
        #expect(sessions.contains("Text(row.displayTitle)"))
        #expect(history.contains("Text(session.displayTitle)"))
        #expect(detail.contains("Text(detail.header.displayTitle)"))
    }

    @Test("Session display title falls back to project metadata")
    func sessionDisplayTitleFallsBackToProjectMetadata() {
        let titled = makeSessionRow(title: "梳理未合并 PR", projectName: "quota-monitor")
        let projectOnly = makeSessionRow(title: nil, projectName: "xianyu-seller-agent")
        let whitespaceTitle = makeSessionRow(title: "   ", projectName: "emomo")
        let unknown = makeSessionRow(title: nil, projectName: nil)

        #expect(titled.displayTitle == "梳理未合并 PR")
        #expect(projectOnly.displayTitle == "xianyu-seller-agent")
        #expect(whitespaceTitle.displayTitle == "emomo")
        #expect(unknown.displayTitle == L10n.untitledSession)
    }

    @Test("Codex scan persists real title and project metadata")
    func codexScanPersistsTitleAndProjectMetadata() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent(
            "sessions/2026/06/15",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try """
        {"id":"s1","thread_name":"梳理项目现状","updated_at":"2026-06-15T03:01:30Z"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let rollout = sessionsDir.appendingPathComponent(
            "rollout-2026-06-15T11-01-20-s1.jsonl")
        try """
        {"timestamp":"2026-06-15T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/Volumes/SamsungDisk/Code/quota-monitor"}}
        {"timestamp":"2026-06-15T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
        })
        #expect(row["title"] as String? == "梳理项目现状")
        #expect(row["project_name"] as String? == "quota-monitor")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/quota-monitor")
    }

    @Test("Codex scan backfills late session_index titles without reparsing")
    func codexScanBackfillsLateSessionIndexTitle() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent(
            "sessions/2026/04/26",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let rollout = sessionsDir.appendingPathComponent(
            "rollout-2026-04-26T11-49-58-s1.jsonl")
        try """
        {"timestamp":"2026-04-26T03:49:58.543Z","type":"session_meta","payload":{"id":"s1","cwd":"/Volumes/SamsungDisk/Code/emomo"}}
        {"timestamp":"2026-04-26T03:50:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-04-26T03:50:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        let before = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
        })
        #expect(before["title"] as String? == nil)
        #expect(before["project_name"] as String? == "emomo")
        #expect(before["cwd"] as String? == "/Volumes/SamsungDisk/Code/emomo")

        try writeCodexStateDatabase(
            codexHome: codexHome,
            id: "s1",
            title: "first prompt should not become the session title",
            cwd: "/Volumes/SamsungDisk/Code/emomo")
        try """
        {"id":"s1","thread_name":"梳理一下现在导入数据的流程是什么样的","updated_at":"2026-04-26T03:51:00Z"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let secondReport = try await engine.performScan()
        #expect(secondReport.changedFiles == 0)
        #expect(secondReport.importedSessions == 0)

        let after = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
        })
        #expect(after["title"] as String? == "梳理一下现在导入数据的流程是什么样的")
        #expect(after["project_name"] as String? == "emomo")
        #expect(after["cwd"] as String? == "/Volumes/SamsungDisk/Code/emomo")
    }

    @Test("Codex metadata backfill replaces project fallback titles without reparsing")
    func codexBackfillReplacesProjectFallbackTitleWithoutReparsing() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   project_name, cwd, source_path, started_at, updated_at,
                   agent_nickname, agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('s1', 's1', NULL, 'xianyu-seller-agent',
                   NULL, NULL,
                   '/Users/timmy/.codex/sessions/2026/06/16/rollout-s1.jsonl',
                   '2026-06-16T15:14:01Z', '2026-06-16T15:14:31Z',
                   NULL, NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-18T14:27:39Z', '2026-06-18T14:27:39Z', 'codex')
                """)
        }
        try """
        {"id":"s1","thread_name":"更新 main 并梳理 Agent 结构","updated_at":"2026-06-16T15:14:31Z"}
        """.write(
            to: codexHome.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)
        try writeCodexStateDatabase(
            codexHome: codexHome,
            id: "s1",
            title: "first prompt should not become the session title",
            cwd: "/Volumes/SamsungDisk/Code/xianyu-seller-agent")

        let report = try await ImportEngine(database: db, codexHome: codexHome).performScan()
        #expect(report.changedFiles == 0)
        #expect(report.importedSessions == 0)

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
        })
        #expect(row["title"] as String? == "更新 main 并梳理 Agent 结构")
        #expect(row["project_name"] as String? == "xianyu-seller-agent")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/xianyu-seller-agent")
    }

    @Test("Codex scan preserves ambiguous project-matching title without metadata")
    func codexScanPreservesAmbiguousProjectMatchingTitleWithoutMetadata() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO sessions
                  (session_id, root_session_id, parent_session_id, title,
                   project_name, cwd, source_path, started_at, updated_at,
                   agent_nickname, agent_role, last_model_id, latest_plan_type,
                   contains_subagents, created_at, imported_at, provider)
                VALUES
                  ('s-dirty', 's-dirty', NULL, 'quota-monitor',
                   'quota-monitor', '/Volumes/SamsungDisk/Code/quota-monitor',
                   '/Users/timmy/.codex/sessions/2026/06/16/rollout-s-dirty.jsonl',
                   '2026-06-16T15:14:01Z', '2026-06-16T15:14:31Z',
                   NULL, NULL, 'gpt-5.5', NULL, 0,
                   '2026-06-18T14:27:39Z', '2026-06-18T14:27:39Z', 'codex')
                """)
        }

        let report = try await ImportEngine(database: db, codexHome: codexHome).performScan()
        #expect(report.changedFiles == 0)
        #expect(report.importedSessions == 0)

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's-dirty'
                """)
        })
        #expect(row["title"] as String? == "quota-monitor")
        #expect(row["project_name"] as String? == "quota-monitor")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/quota-monitor")
    }

    @Test("Codex reread preserves existing title when thread metadata is unavailable")
    func codexRereadPreservesExistingTitleWithoutThreadMetadata() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent(
            "sessions/2026/06/07",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let rollout = sessionsDir.appendingPathComponent(
            "rollout-2026-06-07T11-39-40-s1.jsonl")
        try """
        {"timestamp":"2026-06-07T03:39:44.339Z","type":"session_meta","payload":{"id":"s1","cwd":"/Volumes/SamsungDisk/Code/quota-monitor"}}
        {"timestamp":"2026-06-07T03:40:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-07T03:40:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        try await db.pool.write { conn in
            try conn.execute(sql: """
                UPDATE sessions
                SET title = '看一下这个项目有哪些没合并的PR'
                WHERE session_id = 's1'
                """)
            try conn.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1
                WHERE session_id = 's1'
                """)
        }

        _ = try await engine.performScan()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's1'
                """)
        })
        #expect(row["title"] as String? == "看一下这个项目有哪些没合并的PR")
        #expect(row["project_name"] as String? == "quota-monitor")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/quota-monitor")
    }

    @Test("Codex scan does not repeatedly reread rollouts that cannot backfill cwd")
    func codexScanDoesNotRepeatNoCwdReread() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent(
            "sessions/2026/06/18",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let rollout = sessionsDir.appendingPathComponent(
            "rollout-2026-06-18T10-00-00-s-no-cwd.jsonl")
        try """
        {"timestamp":"2026-06-18T10:00:00.000Z","type":"session_meta","payload":{"id":"s-no-cwd"}}
        {"timestamp":"2026-06-18T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-18T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        let secondReport = try await engine.performScan()
        #expect(secondReport.changedFiles == 0)
        #expect(secondReport.importedSessions == 0)

        let marker = try await db.pool.read { conn in
            try Int64.fetchOne(conn, sql: """
                SELECT byte_offset
                FROM import_state
                WHERE session_id = 's-no-cwd'
                """)
        }
        #expect(marker == -1)

        let thirdReport = try await engine.performScan()
        #expect(thirdReport.changedFiles == 0)
        #expect(thirdReport.importedSessions == 0)
    }

    @Test("Codex reread preserves ambiguous project-matching title")
    func codexRereadPreservesAmbiguousProjectMatchingTitle() async throws {
        let db = try makeDatabase()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-home-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = codexHome.appendingPathComponent(
            "sessions/2026/06/18",
            isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let rollout = sessionsDir.appendingPathComponent(
            "rollout-2026-06-18T11-00-00-s-project-title.jsonl")
        try """
        {"timestamp":"2026-06-18T11:00:00.000Z","type":"session_meta","payload":{"id":"s-project-title","cwd":"/Volumes/SamsungDisk/Code/项目 空间"}}
        {"timestamp":"2026-06-18T11:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-06-18T11:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """.write(to: rollout, atomically: true, encoding: .utf8)

        let engine = ImportEngine(database: db, codexHome: codexHome)
        _ = try await engine.performScan()

        try await db.pool.write { conn in
            try conn.execute(sql: """
                UPDATE sessions
                SET title = ?, project_name = NULL, cwd = NULL
                WHERE session_id = ?
                """, arguments: ["项目 空间", "s-project-title"])
            try conn.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1
                WHERE session_id = ?
                """, arguments: ["s-project-title"])
        }

        _ = try await engine.performScan()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, project_name, cwd
                FROM sessions
                WHERE session_id = 's-project-title'
                """)
        })
        #expect(row["title"] as String? == "项目 空间")
        #expect(row["project_name"] as String? == "项目 空间")
        #expect(row["cwd"] as String? == "/Volumes/SamsungDisk/Code/项目 空间")
    }
}
