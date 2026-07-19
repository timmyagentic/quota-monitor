import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

/// `ClaudeRolloutParser` got an incremental `fromOffset` parameter in v5
/// so menu-bar scans don't have to re-parse multi-MB rollouts every 5
/// minutes. These tests pin the byte-offset bookkeeping that makes that
/// safe — specifically:
///
///   1. A full read returns `endOffset == file.size` only when the file
///      ends with a newline; a mid-write tail leaves `endOffset` BEFORE
///      the un-terminated last line (so the next scan re-reads it once
///      the writer has finished).
///   2. A second pass starting at the prior `endOffset` parses ONLY the
///      newly appended events, not the whole file.
///   3. The same `(sessionId, message.id)` appearing in both passes
///      surfaces as a `messageId` we can dedup on; the SQL layer's
///      partial unique index handles cross-pass collisions.
@Suite("ClaudeRolloutParser incremental")
struct ClaudeRolloutParserIncrementalTests {

    private func writeRollout(_ jsonl: String) throws -> URL {
        let dir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("qm-claude-incr-\(UUID().uuidString)",
                                 isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    private func assistantLine(
        sid: String, msgId: String,
        ts: String = "2026-05-13T10:00:00.000Z",
        model: String = "claude-opus-4-7",
        input: Int = 100, output: Int = 50
    ) -> String {
        """
        {"type":"assistant","sessionId":"\(sid)","timestamp":"\(ts)","message":\
        {"id":"\(msgId)","model":"\(model)","usage":\
        {"input_tokens":\(input),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":\(output)}}}
        """
    }

    private func makeDatabase() throws -> DatabaseManager {
        let dir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("qm-claude-import-\(UUID().uuidString)",
                                 isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return try DatabaseManager(
            url: dir.appendingPathComponent("quotamonitor.sqlite"))
    }

    private func makeProjectRoot() throws -> (root: URL, project: URL) {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("qm-claude-root-\(UUID().uuidString)",
                                 isDirectory: true)
        let project = root.appendingPathComponent("-repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        return (root, project)
    }

    private func claudeModelCounts(in db: DatabaseManager) async throws -> [String: Int] {
        try await db.pool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT model_id, COUNT(*) AS events
                FROM usage_events
                WHERE provider = 'claude'
                GROUP BY model_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["model_id"] as String, $0["events"] as Int)
            })
        }
    }

    // MARK: - 1. mid-write tail leaves endOffset behind the partial line

    @Test("mid-write tail: endOffset stops at last complete newline")
    func midWriteTail() throws {
        let url = try writeRollout(
            assistantLine(sid: "S1", msgId: "m1") + "\n"
            + assistantLine(sid: "S1", msgId: "m2") + "\n"
            // No trailing newline — simulates mid-write.
            + #"{"type":"assistant","sessionId":"S1","timestamp"#
        )
        let fileSize = try FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as! Int64
        let out = try ClaudeRolloutParser.parse(fileURL: url)
        #expect(out.session != nil)
        #expect(out.session!.events.count == 2)
        #expect(out.endOffset < fileSize,
                "endOffset must skip the un-terminated tail")
    }

    // MARK: - 2. resume from prior offset only sees the appended slice

    @Test("incremental: second pass parses only the appended events")
    func incrementalAppend() throws {
        let url = try writeRollout(
            assistantLine(sid: "S1", msgId: "m1") + "\n"
            + assistantLine(sid: "S1", msgId: "m2") + "\n"
        )
        let pass1 = try ClaudeRolloutParser.parse(fileURL: url, fromOffset: 0)
        #expect(pass1.session?.events.count == 2)

        try append(url,
            assistantLine(sid: "S1", msgId: "m3") + "\n"
            + assistantLine(sid: "S1", msgId: "m4") + "\n")

        let pass2 = try ClaudeRolloutParser.parse(
            fileURL: url, fromOffset: pass1.endOffset)
        // Only the two NEW events — incremental mustn't re-emit m1/m2.
        #expect(pass2.session?.events.count == 2)
        #expect(pass2.session?.events.map { $0.messageId } == ["m3", "m4"])
    }

    @Test("Claude import persists metadata-only ai-title tails")
    func metadataOnlyAiTitleTailUpdatesSessionTitle() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "title-tail"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(sid: sid, msgId: "m1") + "\n")
            .write(to: main, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        try append(main, """
        {"type":"ai-title","sessionId":"\(sid)","timestamp":"2026-05-13T10:01:00.000Z","aiTitle":"Review PR #60 title split"}
        """ + "\n")

        let report = try await engine.performScan()
        #expect(report.changedFiles == 1)
        #expect(report.importedEvents == 0)

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT title, last_model_id, COUNT(usage_events.id) AS events
                FROM sessions
                LEFT JOIN usage_events USING (session_id)
                WHERE sessions.session_id = ?
                GROUP BY sessions.session_id
                """, arguments: [sid])
        })
        #expect(row["title"] as String? == "Review PR #60 title split")
        #expect(row["last_model_id"] as String? == "claude-opus-4-7")
        #expect(row["events"] as Int == 1)
    }

    @Test("Claude import treats timestamp-only non-usage slices as empty")
    func timestampOnlyNonUsageSliceDoesNotCreateSession() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "timestamp-only"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try ("""
        {"type":"user","sessionId":"\(sid)","timestamp":"2026-05-13T10:00:00.000Z","message":{"role":"user","content":"hello"}}
        """ + "\n").write(to: main, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        let report = try await engine.performScan()
        #expect(report.changedFiles == 1)
        #expect(report.importedSessions == 0)
        #expect(report.importedEvents == 0)
        #expect(report.errors.isEmpty)

        let sessionCount = try await db.pool.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM sessions WHERE session_id = ?",
                arguments: [sid]) ?? -1
        }
        #expect(sessionCount == 0)

        let state = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT source_path, session_id, byte_offset
                FROM import_state
                WHERE session_id = ?
                """, arguments: [sid])
        })
        #expect((state["source_path"] as String? ?? "").hasSuffix("/\(sid).jsonl"))
        #expect(state["session_id"] as String? == sid)
        #expect((state["byte_offset"] as Int64? ?? 0) > 0)
    }

    // MARK: - 3. message ids surface so SQL dedup can do cross-pass dedup

    @Test("messageId is propagated for SQL-side dedup")
    func messageIdPropagation() throws {
        let url = try writeRollout(
            assistantLine(sid: "S1", msgId: "abc-123") + "\n")
        let out = try ClaudeRolloutParser.parse(fileURL: url)
        #expect(out.session?.events.first?.messageId == "abc-123")
    }

    @Test("duplicate non-zero message.id keeps the largest streaming snapshot")
    func duplicateMessageIdKeepsLargestSnapshot() throws {
        // One API message, one assistant line per content block: usage
        // snapshots share the message.id and grow in output_tokens while
        // input/cache stay fixed. A smaller replay after the largest row
        // must not lower the complete bill.
        let url = try writeRollout(
            assistantLine(sid: "S1", msgId: "m1", output: 5) + "\n"
            + assistantLine(sid: "S1", msgId: "m1", output: 80) + "\n"
            + assistantLine(sid: "S1", msgId: "m1", output: 350) + "\n"
            + assistantLine(sid: "S1", msgId: "m1", output: 300) + "\n"
            + assistantLine(sid: "S1", msgId: "m2", output: 7) + "\n")
        let out = try ClaudeRolloutParser.parse(fileURL: url)
        let events = try #require(out.session?.events)
        #expect(events.count == 2)
        #expect(events.first?.messageId == "m1")
        #expect(events.first?.outputTokens == 350)
        #expect(events.last?.messageId == "m2")
        #expect(events.last?.outputTokens == 7)
    }

    @Test("duplicate message.id crossing a day boundary emits only a new-day delta")
    func duplicateMessageIdAcrossDayEmitsDelta() throws {
        let url = try writeRollout(
            assistantLine(
                sid: "S1",
                msgId: "m1",
                ts: "2026-06-29T12:00:00.000Z",
                input: 100,
                output: 10
            ) + "\n"
            + assistantLine(
                sid: "S1",
                msgId: "m1",
                ts: "2026-06-30T12:00:00.000Z",
                input: 100,
                output: 50
            ) + "\n"
            + assistantLine(
                sid: "S1",
                msgId: "m1",
                ts: "2026-06-30T12:01:00.000Z",
                input: 100,
                output: 45
            ) + "\n")

        let out = try ClaudeRolloutParser.parse(fileURL: url)
        let events = try #require(out.session?.events)

        #expect(events.count == 2)
        guard events.count == 2 else {
            Issue.record("expected two usage events, got \(events.count)")
            return
        }
        #expect(events[0].timestamp == "2026-06-29T12:00:00.000Z")
        #expect(events[0].inputTokens == 100)
        #expect(events[0].outputTokens == 10)
        #expect(events[1].timestamp == "2026-06-30T12:00:00.000Z")
        #expect(events[1].inputTokens == 0)
        #expect(events[1].outputTokens == 40)
    }

    @Test("cache creation duration split is parsed from usage.cache_creation")
    func cacheCreationDurationSplit() throws {
        let url = try writeRollout(
            """
            {"type":"assistant","sessionId":"S1","timestamp":"2026-05-13T10:00:00.000Z","message":\
            {"id":"cache-split","model":"claude-opus-4-7","usage":\
            {"input_tokens":1,"cache_creation_input_tokens":30,\
            "cache_read_input_tokens":4,"output_tokens":5,\
            "cache_creation":{"ephemeral_1h_input_tokens":20,"ephemeral_5m_input_tokens":10}}}}
            """ + "\n")
        let out = try ClaudeRolloutParser.parse(fileURL: url)
        let event = try #require(out.session?.events.first)

        #expect(event.cacheCreationTokens == 30)
        #expect(event.cacheCreation1hTokens == 20)
        #expect(event.cacheCreation5mTokens == 10)
    }

    // MARK: - 4. resuming past end-of-file is a clean no-op

    @Test("offset >= filesize parses nothing and returns the same offset")
    func offsetPastEnd() throws {
        let url = try writeRollout(assistantLine(sid: "S1", msgId: "m1") + "\n")
        let size = try FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as! Int64
        let out = try ClaudeRolloutParser.parse(fileURL: url, fromOffset: size)
        #expect(out.session == nil)
        #expect(out.endOffset == size)
    }

    @Test("Claude import preserves existing events when a shared-session subagent file is added")
    func sharedSessionSubagentFileDoesNotReplaceMainFileEvents() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "shared-session"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(
            sid: sid, msgId: "main-1",
            model: "claude-opus-4-8",
            input: 10, output: 1
        ) + "\n").write(to: main, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        let subagentDir = project
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("subagents/workflows/wf-1",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: subagentDir, withIntermediateDirectories: true)
        let subagent = subagentDir.appendingPathComponent("agent-a.jsonl")
        // Older timestamp than the main rollout's: the subagent file is
        // imported second and must not drag the session header backwards.
        try (assistantLine(
            sid: sid, msgId: "agent-1",
            ts: "2026-05-13T09:00:00.000Z",
            model: "claude-haiku-4-5-20251001",
            input: 20, output: 2
        ) + "\n").write(to: subagent, atomically: true, encoding: .utf8)

        let report = try await engine.performScan()

        // A new sibling in an already-imported session appends via the
        // unique index — it must NOT trigger a session reset that forces
        // the unchanged main rollout through a full re-read.
        #expect(report.changedFiles == 1)
        #expect(report.importedSessions == 1)

        let counts = try await claudeModelCounts(in: db)
        #expect(counts == [
            "claude-haiku-4-5-20251001": 1,
            "claude-opus-4-8": 1,
        ])

        let session = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT source_path, updated_at, last_model_id, contains_subagents
                FROM sessions
                WHERE session_id = ?
                """, arguments: [sid])
        })
        // source_path stays on the main rollout; the subagent sibling
        // (imported last) must not steal it.
        #expect((session["source_path"] as String).hasSuffix("\(sid).jsonl"))
        // The subagent file's older events must not move updated_at /
        // last_model_id backwards.
        #expect((session["updated_at"] as String) == "2026-05-13T10:00:00.000Z")
        #expect((session["last_model_id"] as String) == "claude-opus-4-8")
        #expect((session["contains_subagents"] as Bool) == true)
    }

    @Test("session-group reset rebuilds unchanged sibling files instead of dropping their events")
    func sessionGroupResetRebuildsSiblings() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "shared-truncate"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(sid: sid, msgId: "main-1", model: "claude-opus-4-8") + "\n"
            + assistantLine(sid: sid, msgId: "main-2", model: "claude-opus-4-8") + "\n")
            .write(to: main, atomically: true, encoding: .utf8)

        let subagentDir = project
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: subagentDir, withIntermediateDirectories: true)
        let subagent = subagentDir.appendingPathComponent("agent-a.jsonl")
        try (assistantLine(
            sid: sid, msgId: "agent-1",
            model: "claude-haiku-4-5-20251001"
        ) + "\n").write(to: subagent, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()
        #expect(try await claudeModelCounts(in: db) == [
            "claude-haiku-4-5-20251001": 1,
            "claude-opus-4-8": 2,
        ])

        // Truncate the main rollout below the consumed offset — that
        // triggers a session reset, which deletes the WHOLE session's rows.
        // The unchanged subagent sibling must be pulled into the rebuild,
        // not skipped (skipping would silently lose its events).
        try (assistantLine(sid: sid, msgId: "main-1", model: "claude-opus-4-8") + "\n")
            .write(to: main, atomically: true, encoding: .utf8)
        let report = try await engine.performScan()

        #expect(report.changedFiles == 2)
        #expect(try await claudeModelCounts(in: db) == [
            "claude-haiku-4-5-20251001": 1,
            "claude-opus-4-8": 1,
        ])
    }

    @Test("nested subagents directories group under the root session")
    func nestedSubagentFileGroupsUnderRootSession() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "shared-nested"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(
            sid: sid, msgId: "main-1", model: "claude-opus-4-8"
        ) + "\n").write(to: main, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        // A subagent of a subagent: `<sid>/subagents/wf-1/agent-a/subagents/`.
        // Deriving the group from the LAST `subagents` component would file
        // this under "agent-a" — an unknown group, so its import would reset
        // the root session and delete the main rollout's rows.
        let nestedDir = project
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("subagents/wf-1/agent-a/subagents",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDir, withIntermediateDirectories: true)
        let nested = nestedDir.appendingPathComponent("agent-b.jsonl")
        try (assistantLine(
            sid: sid, msgId: "agent-b-1",
            model: "claude-haiku-4-5-20251001"
        ) + "\n").write(to: nested, atomically: true, encoding: .utf8)

        let report = try await engine.performScan()

        #expect(report.changedFiles == 1)
        #expect(try await claudeModelCounts(in: db) == [
            "claude-haiku-4-5-20251001": 1,
            "claude-opus-4-8": 1,
        ])
    }

    @Test("a newer usage snapshot arriving in a later scan updates the stored event")
    func crossPassSnapshotUpdatesStoredEvent() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "snapshot-upsert"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(sid: sid, msgId: "m1", output: 5) + "\n")
            .write(to: main, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()
        let initialValue = try await db.pool.read { conn in
            try Double.fetchOne(conn, sql: """
                SELECT value_usd
                FROM usage_events
                WHERE session_id = ?
                """, arguments: [sid]) ?? 0
        }
        #expect(initialValue > 0,
                "Claude importer must price new usage before advancing its offset")

        // The message keeps streaming after the first scan: its final
        // snapshot (complete output count) lands in a later append. The
        // incremental tail read must UPDATE the stored row, not drop the
        // newer values on the unique-index conflict.
        try append(main, assistantLine(sid: sid, msgId: "m1", output: 350) + "\n")
        let report = try await engine.performScan()
        #expect(report.importedEvents == 1)

        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT output_tokens, total_tokens, value_usd
                FROM usage_events
                """)
        }
        #expect(rows.count == 1)
        #expect((rows.first?["output_tokens"] as Int64?) == 350)
        #expect((rows.first?["total_tokens"] as Int64?) == 450)
        let updatedValue = rows.first?["value_usd"] as Double? ?? 0
        #expect(updatedValue > initialValue,
                "updating a priced usage snapshot must update its value in the same scan")

        // Re-emitting an identical row (offset landing mid-message) must
        // stay a no-op: same snapshot again → nothing imported.
        try append(main, assistantLine(sid: sid, msgId: "m1", output: 350) + "\n")
        let noopReport = try await engine.performScan()
        #expect(noopReport.importedEvents == 0)

        // A smaller same-day replay must not lower the stored usage.
        try append(main, assistantLine(sid: sid, msgId: "m1", output: 300) + "\n")
        let lowerReport = try await engine.performScan()
        #expect(lowerReport.importedEvents == 0)
        let count = try await db.pool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM usage_events") ?? -1
        }
        #expect(count == 1)
        let output = try await db.pool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT output_tokens FROM usage_events") ?? -1
        }
        #expect(output == 350)
    }

    @Test("a newer usage snapshot on a later day does not rewrite the earlier day")
    func crossPassSnapshotAcrossDayStoresOnlyDeltaOnLaterDay() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()

        let sid = "snapshot-cross-day"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(
            sid: sid,
            msgId: "m1",
            ts: "2026-06-29T12:00:00.000Z",
            input: 100,
            output: 10
        ) + "\n").write(to: main, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        try append(main, assistantLine(
            sid: sid,
            msgId: "m1",
            ts: "2026-06-30T12:00:00.000Z",
            input: 100,
            output: 50
        ) + "\n")
        let report = try await engine.performScan()
        #expect(report.importedEvents == 1)

        let rows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT timestamp, input_tokens, output_tokens, total_tokens
                FROM usage_events
                WHERE session_id = ?
                ORDER BY timestamp ASC, id ASC
                """, arguments: [sid])
        }

        #expect(rows.count == 2)
        guard rows.count == 2 else {
            Issue.record("expected two stored usage rows, got \(rows.count)")
            return
        }
        #expect((rows[0]["timestamp"] as String?) == "2026-06-29T12:00:00.000Z")
        #expect((rows[0]["input_tokens"] as Int64?) == 100)
        #expect((rows[0]["output_tokens"] as Int64?) == 10)
        #expect((rows[0]["total_tokens"] as Int64?) == 110)
        #expect((rows[1]["timestamp"] as String?) == "2026-06-30T12:00:00.000Z")
        #expect((rows[1]["input_tokens"] as Int64?) == 0)
        #expect((rows[1]["output_tokens"] as Int64?) == 40)
        #expect((rows[1]["total_tokens"] as Int64?) == 40)

        try append(main, assistantLine(
            sid: sid,
            msgId: "m1",
            ts: "2026-06-30T12:01:00.000Z",
            input: 100,
            output: 45
        ) + "\n")
        let lowerReport = try await engine.performScan()
        #expect(lowerReport.importedEvents == 0)

        let stableRows = try await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT timestamp, input_tokens, output_tokens, total_tokens
                FROM usage_events
                WHERE session_id = ?
                ORDER BY timestamp ASC, id ASC
                """, arguments: [sid])
        }

        #expect(stableRows.count == 2)
        guard stableRows.count == 2 else {
            Issue.record("expected two stored usage rows, got \(stableRows.count)")
            return
        }
        #expect((stableRows[1]["timestamp"] as String?) == "2026-06-30T12:00:00.000Z")
        #expect((stableRows[1]["input_tokens"] as Int64?) == 0)
        #expect((stableRows[1]["output_tokens"] as Int64?) == 40)
        #expect((stableRows[1]["total_tokens"] as Int64?) == 40)
    }

    @Test("a failed read after a session reset is retried on the next scan")
    func failedReadAfterSessionResetIsRetried() async throws {
        let db = try makeDatabase()
        let (root, project) = try makeProjectRoot()
        let fm = FileManager.default

        let sid = "shared-error"
        let main = project.appendingPathComponent("\(sid).jsonl")
        try (assistantLine(sid: sid, msgId: "main-1", model: "claude-opus-4-8") + "\n"
            + assistantLine(sid: sid, msgId: "main-2", model: "claude-opus-4-8") + "\n")
            .write(to: main, atomically: true, encoding: .utf8)

        let subagentDir = project
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(
            at: subagentDir, withIntermediateDirectories: true)
        let subagent = subagentDir.appendingPathComponent("agent-a.jsonl")
        try (assistantLine(
            sid: sid, msgId: "agent-1",
            model: "claude-haiku-4-5-20251001"
        ) + "\n").write(to: subagent, atomically: true, encoding: .utf8)

        let engine = ClaudeImportEngine(database: db, claudeRoots: [root])
        _ = try await engine.performScan()

        // Truncate the main rollout (forces a session-group reset) while
        // the subagent sibling is unreadable: the reset deletes its rows
        // and the re-read fails.
        try (assistantLine(sid: sid, msgId: "main-1", model: "claude-opus-4-8") + "\n")
            .write(to: main, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: subagent.path)
        guard !fm.isReadableFile(atPath: subagent.path) else {
            // Running as root — permissions can't make the file unreadable,
            // so the failure path can't be simulated.
            try fm.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: subagent.path)
            return
        }

        let failedReport = try await engine.performScan()
        #expect(failedReport.errors.count == 1)
        #expect(try await claudeModelCounts(in: db) == [
            "claude-opus-4-8": 1,
        ])

        // The file itself is untouched (same size/mtime). Without the
        // import_state invalidation the next scan would skip it and its
        // usage would be lost forever.
        try fm.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: subagent.path)
        let recoveredReport = try await engine.performScan()

        #expect(recoveredReport.errors.isEmpty)
        #expect(try await claudeModelCounts(in: db) == [
            "claude-haiku-4-5-20251001": 1,
            "claude-opus-4-8": 1,
        ])
    }
}
