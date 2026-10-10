import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Codex request tier observations")
struct CodexRequestTierEvidenceTests {
    struct Fixture {
        let root: URL
        let source: DatabaseQueue
        let body: String
        init(legacy: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("qm-tier-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = try DatabaseQueue(path: root.appendingPathComponent("logs_2.sqlite").path)
            body = legacy ? "message" : "feedback_log_body"
            try source.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL, target TEXT NOT NULL, thread_id TEXT, \(body) TEXT)")
            }
        }
        func append(_ text: String, thread: String? = "thread", target: String = "feedback_tags", ts: Int = 100) throws {
            try source.write { db in
                try db.execute(sql: "INSERT INTO logs(ts, ts_nanos, target, thread_id, \(body)) VALUES (?, 1, ?, ?, ?)", arguments: [ts, target, thread, text])
            }
        }
        func read(_ cursor: CodexRequestTierReader.Cursor? = nil, limit: Int = 2000) throws -> CodexRequestTierReader.Batch {
            try CodexRequestTierReader.read(url: root.appendingPathComponent("logs_2.sqlite"), cursor: cursor, limit: limit)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    func body(_ json: String, turn: String = "turn", model: String = "gpt-6.1-sol") -> String {
        "session{thread_id=thread}:try_run_sampling_request{turn_id=\(turn) model=\(model)}: model=\"\(model)\" tags_json=\(json)"
    }

    @Test(arguments: [false, true])
    func readsBothSchemasAndNormalizesExactRequestField(legacy: Bool) throws {
        let fixture = try Fixture(legacy: legacy)
        defer { fixture.clean() }
        for raw in ["priority", " Fast ", "ultrafast", "default", "flex", "unset", "future"] {
            try fixture.append(body("{\"service_tier\":\"\(raw)\"}"))
        }
        try fixture.append(body("{\"feature.ultrafast_mode\":\"true\"}"))
        try fixture.append(body("{\"service_tier\":null}"))
        let observations = try fixture.read().observations
        #expect(observations.map(\.normalizedTier) == ["priority", "priority", "ultrafast", "default", "flex", "unset", "unknown", "unknown", "unknown"])
        #expect(observations[1].rawTier == " Fast ")
        #expect(observations.allSatisfy { $0.turnID == "turn" && $0.model == "gpt-6.1-sol" && $0.attribution == "unattributed" })
    }

    @Test func rejectsFalsePositivesAndMalformedEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.append("feature.ultrafast_mode=true last_model_response_id=\"response\"")
        try fixture.append(body("{\"service_tier\":\"ultrafast\"}"), target: "other")
        try fixture.append(body("{\"service_tier\":true}"))
        try fixture.append(body("{\"service_tier\":\"ultrafast\""))
        try fixture.append(body("{\"service_tier\":\"priority\"} tags_json={\"service_tier\":\"ultrafast\"}"))
        let batch = try fixture.read()
        #expect(batch.observations.isEmpty)
        #expect(batch.rejectedRows == 3)
        #expect(batch.scannedRows == 4)
    }

    @Test func keepsMixedRequestsChildrenAndMissingScopeUnattributed() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.append(body("{\"service_tier\":\"priority\"}"))
        try fixture.append(body("{\"service_tier\":\"ultrafast\"}"))
        try fixture.append(body("{\"service_tier\":\"ultrafast\"}", turn: "child-turn"), thread: "child")
        try fixture.append("tags_json={\"service_tier\":\"ultrafast\"}", thread: nil)
        try fixture.append("last_model_request_id=\"req\"", thread: nil)
        try fixture.append("last_model_response_id=\"resp\"", thread: nil)
        let observations = try fixture.read().observations
        #expect(observations.count == 4)
        #expect(observations[2].threadID == "child")
        #expect(observations[3].turnID == nil)
        #expect(observations[3].threadID == nil)
        #expect(observations.allSatisfy { $0.attribution == "unattributed" })
    }

    @Test func resumesByIDIncludingLateTimestampsAndCommittedWAL() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.append(body("{\"service_tier\":\"priority\"}"))
        let first = try fixture.read(limit: 1)
        try fixture.append(body("{\"service_tier\":\"ultrafast\"}"), ts: 1)
        let next = try fixture.read(first.cursor)
        #expect(next.observations.count == 1)
        #expect(next.observations.first?.normalizedTier == "ultrafast")
        #expect(next.cursor.generation == first.cursor.generation)
        #expect(try fixture.read(next.cursor).observations.isEmpty)
        let sourceCount = try fixture.source.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM logs") }
        #expect(sourceCount == 2)
    }

    @Test func detectsRewrittenBoundaryAndIDRollback() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.append(body("{\"service_tier\":\"priority\"}"))
        let first = try fixture.read()
        try fixture.source.write { db in
            try db.execute(sql: "UPDATE logs SET feedback_log_body = ? WHERE id = 1", arguments: [body("{\"service_tier\":\"ultrafast\"}")])
        }
        let rewritten = try fixture.read(first.cursor)
        #expect(rewritten.cursor.generation != first.cursor.generation)
        #expect(rewritten.observations.first?.normalizedTier == "ultrafast")
        try fixture.source.write { try $0.execute(sql: "DELETE FROM logs") }
        let empty = try fixture.read(rewritten.cursor)
        #expect(empty.cursor.rowID == 0)
        #expect(empty.cursor.generation != rewritten.cursor.generation)
    }

    @Test func importsWithoutRolloutChangesAndPreservesHistoryThroughPruning() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let manager = try DatabaseManager(url: fixture.root.appendingPathComponent("app.sqlite"))
        try fixture.append(body("{\"service_tier\":\"priority\"}"))
        try fixture.append(body("{\"service_tier\":\"ultrafast\"}"))
        try await manager.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(session_id, root_session_id, source_path, created_at, imported_at, provider)
                VALUES ('saved', 'saved', '/synthetic/missing', '2026-10-10', '2026-10-10', 'codex');
                INSERT INTO usage_events(session_id, timestamp, model_id, input_tokens, total_tokens, value_usd, provider, codex_service_tier_preference)
                VALUES ('saved', '2026-10-10T00:00:00Z', 'gpt-6.1-sol', 100000, 100000, 7.25, 'codex', 'priority');
                """)
        }
        let savedUsage = try await manager.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage_events").map(\.description) }
        let engine = ImportEngine(database: manager, codexHome: fixture.root)
        _ = try await engine.performScan()
        _ = try await engine.performScan()
        try await manager.pool.read { db in
            let observations = try CodexRequestTierEvidence.observations(in: db)
            let usage = try Row.fetchAll(db, sql: "SELECT * FROM usage_events").map(\.description)
            let ultraPrices = try Int.fetchOne(db, sql: "SELECT count(*) FROM pricing_catalog WHERE model_id LIKE '%-ultrafast%'")
            #expect(observations.count == 2)
            #expect(usage == savedUsage)
            #expect(ultraPrices == 0)
        }
        // Dropped/expired source rows do not turn observations into complete coverage.
        try await fixture.source.write { try $0.execute(sql: "DELETE FROM logs WHERE id = 2") }
        _ = try await engine.performScan()
        try await manager.pool.read { db in
            let observations = try CodexRequestTierEvidence.observations(in: db, threadID: "thread")
            #expect(observations.count == 2)
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("logs_2.sqlite"))
        let missing = try await CodexRequestTierImporter.scan(home: fixture.root, database: manager)
        #expect(missing.status == "missing")
        let retainedCount = try await manager.pool.read { try CodexRequestTierEvidence.observations(in: $0).count }
        #expect(retainedCount == 2)
    }

    @Test func parsesJSONStringsAndNeverPromotesUnknownToDefault() {
        let text = body(#"{"service_tier":"ultrafast","other":"brace } and escaped \" quote"}"#)
        #expect(CodexRequestTierReader.tagsJSON(text)?["service_tier"] as? String == "ultrafast")
        #expect(CodexRequestTierEvidence.normalize(nil) == "unknown")
        #expect(CodexRequestTierEvidence.normalize("future") == "unknown")
        #expect(CodexRequestTierEvidence.normalize("ULTRAFAST") == "ultrafast")
    }
    @Test func rejectsDuplicateKeysAndQuotedOrNestedMarkers() {
        for text in [
            body(#"{"service_tier":"priority","service_tier":"ultrafast"}"#),
            body(#"{"service_tier":"priority","service_\u0074ier":"ultrafast"}"#),
            #"message="tags_json={\"service_tier\":\"ultrafast\"}""#,
            #"span{tags_json={"service_tier":"ultrafast"}}: message="nothing""#
        ] {
            #expect(CodexRequestTierReader.tagsJSON(text) == nil)
        }
    }

    @Test func skipsUnrelatedBacklogAndPagesRelevantRows() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.source.write { db in
            for _ in 0..<2100 {
                try db.execute(sql: "INSERT INTO logs(ts, ts_nanos, target) VALUES (1, 0, 'unrelated')")
            }
        }
        for _ in 0..<3 { try fixture.append(body(#"{"service_tier":"ultrafast"}"#)) }
        let first = try fixture.read(limit: 2)
        #expect(first.observations.count == 2)
        #expect(first.scannedRows == 2)
        let next = try fixture.read(first.cursor, limit: 2)
        #expect(next.observations.count == 1)
        #expect(next.cursor.rowID == 2103)
        #expect(try fixture.read(next.cursor).scannedRows == 0)
    }

    @Test func rejectsInvalidExternalColumnValuesWithoutCrashing() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.append(body(#"{"service_tier":"ultrafast"}"#))
        try fixture.source.write { db in
            try db.execute(sql: "UPDATE logs SET ts = 'invalid'")
        }
        #expect(throws: CodexRequestTierReader.ReadError.self) { try fixture.read() }
    }

    @Test func detectsReplacementAndLegacySchemaSwitch() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.append(body(#"{"service_tier":"priority"}"#))
        let first = try fixture.read()
        // Closing before rename avoids producing an impossible mixed WAL fixture.
        try fixture.source.close()
        let path = fixture.root.appendingPathComponent("logs_2.sqlite")
        try FileManager.default.moveItem(at: path, to: fixture.root.appendingPathComponent("old.sqlite"))
        let replacement = try DatabaseQueue(path: path.path)
        try replacement.write { db in
            try db.execute(sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, target TEXT, thread_id TEXT, message TEXT)")
            try db.execute(sql: "INSERT INTO logs VALUES (1, 1, 'feedback_tags', 'child', ?)", arguments: [body(#"{"service_tier":"ultrafast"}"#)])
        }
        let next = try fixture.read(first.cursor)
        #expect(next.cursor.generation != first.cursor.generation)
        #expect(next.cursor.identity != first.cursor.identity)
        #expect(next.cursor.schema != first.cursor.schema)
        #expect(next.observations.first?.normalizedTier == "ultrafast")
    }

    @Test(arguments: ["v24-codex-ultrafast-reread", "v25-withdraw-ultrafast-pricing"])
    func upgradesPreserveExistingUsageAndCheckpoint(migration: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let queue = try DatabaseQueue(path: fixture.root.appendingPathComponent("history.sqlite").path)
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue, upTo: migration)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(session_id, root_session_id, source_path, created_at, imported_at, provider)
                VALUES ('saved', 'saved', '/synthetic/missing', '2026-10-10', '2026-10-10', 'codex');
                INSERT INTO usage_events(session_id, timestamp, model_id, input_tokens, total_tokens, value_usd, provider, codex_turn_id, codex_service_tier_preference)
                VALUES ('saved', '2026-10-10T00:00:00Z', 'gpt-6.1-sol', 100000, 100000, 0.2, 'codex', 'turn', 'priority');
                INSERT INTO import_state(source_path, session_id, file_size, file_mtime_ms, byte_offset, parser_checkpoint, last_imported_at)
                VALUES ('/synthetic/missing', 'saved', 123, 456, 123, X'010203', '2026-10-10');
                """)
        }
        let before = try queue.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM usage_events"), try Row.fetchAll(db, sql: "SELECT * FROM import_state"))
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        let after = try queue.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM usage_events"), try Row.fetchAll(db, sql: "SELECT * FROM import_state"))
        }
        #expect(before.0 == after.0)
        #expect(before.1 == after.1)
    }

    @Test func retriesFailedAtomicCommitAndRecoversDamagedCursor() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let manager = try DatabaseManager(url: fixture.root.appendingPathComponent("app.sqlite"))
        try fixture.append(body(#"{"service_tier":"ultrafast"}"#))
        try await manager.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_cursor BEFORE INSERT ON codex_request_tier_sources BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        do {
            _ = try await CodexRequestTierImporter.scan(home: fixture.root, database: manager)
            Issue.record("Expected atomic transaction to fail")
        } catch {}
        let counts = try await manager.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM codex_request_tier_evidence"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM codex_request_tier_sources"))
        }
        #expect(counts.0 == 0 && counts.1 == 0)
        try await manager.pool.write { try $0.execute(sql: "DROP TRIGGER fail_cursor") }
        let retry = try await CodexRequestTierImporter.scan(home: fixture.root, database: manager)
        #expect(retry.inserted == 1)
        try await manager.pool.write { try $0.execute(sql: "UPDATE codex_request_tier_sources SET cursor = X'00'") }
        let recovery = try await CodexRequestTierImporter.scan(home: fixture.root, database: manager)
        #expect(recovery.inserted == 0)
        #expect(recovery.scanned == 1)
    }

}
