import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

#if canImport(SQLite3)
import SQLite3
#endif

@Suite("Codex service tier trace store")
struct CodexServiceTierTraceStoreTests {
    @Test("priority and fast classify as Fast")
    func priorityAndFastClassifyAsFast() throws {
        let databaseURL = try Self.makeLogsDatabase(rows: [
            TraceRow(
                ts: 1_820_000_001,
                tsNanos: 10,
                body: Self.requestTraceBody(turnID: "turn-priority", serviceTier: "priority", model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_002,
                tsNanos: 20,
                body: Self.requestTraceBody(turnID: "turn-fast", serviceTier: "fast", model: "gpt-5.5"))
        ])

        let lookup = try CodexServiceTierTraceStore(databaseURL: databaseURL)
            .loadLookup(start: Date(timeIntervalSince1970: 1_820_000_000),
                        end: Date(timeIntervalSince1970: 1_820_000_010))

        #expect(lookup.available)
        #expect(lookup.classify(turnID: "turn-priority").tier == .fast)
        #expect(lookup.classify(turnID: "turn-priority").source == .trace)
        #expect(lookup.classify(turnID: "turn-fast").tier == .fast)
        #expect(lookup.classify(turnID: "turn-fast").source == .trace)
    }

    @Test("actual default/standard requests classify as Standard and unsupported tiers are not guessed")
    func explicitNonFastRequestClassifiesAsStandard() throws {
        let databaseURL = try Self.makeLogsDatabase(rows: [
            TraceRow(
                ts: 1_820_000_001,
                tsNanos: 10,
                body: Self.requestTraceBody(turnID: "turn-standard", serviceTier: "standard", model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_002,
                tsNanos: 20,
                body: Self.requestTraceBody(turnID: "turn-default", serviceTier: "default", model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_003,
                tsNanos: 30,
                body: Self.requestTraceBody(turnID: "turn-flex", serviceTier: "flex", model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_004,
                tsNanos: 40,
                body: Self.requestTraceBody(turnID: "turn-future", serviceTier: "future-tier", model: "gpt-5.5"))
        ])

        let lookup = try CodexServiceTierTraceStore(databaseURL: databaseURL)
            .loadLookup(start: Date(timeIntervalSince1970: 1_820_000_000),
                        end: Date(timeIntervalSince1970: 1_820_000_010))

        #expect(lookup.classify(turnID: "turn-standard").tier == .standard)
        #expect(lookup.classify(turnID: "turn-standard").source == .trace)
        #expect(lookup.classify(turnID: "turn-default").tier == .standard)
        #expect(lookup.classify(turnID: "turn-default").source == .trace)
        #expect(lookup.classify(turnID: "turn-flex").tier == .unknown)
        #expect(lookup.classify(turnID: "turn-flex").source == .traceUnsupported)
        #expect(lookup.classify(turnID: "turn-future").tier == .unknown)
        #expect(lookup.classify(turnID: "turn-future").source == .traceUnsupported)

        let missing = lookup.classify(turnID: "missing")
        #expect(missing.tier == .standard)
        #expect(missing.source == .trace)
    }

    @Test("request priority wins and completed default tier is ignored")
    func requestPriorityWinsAndCompletedDefaultTierIsIgnored() throws {
        let databaseURL = try Self.makeLogsDatabase(rows: [
            TraceRow(
                ts: 1_820_000_001,
                tsNanos: 10,
                body: Self.requestTraceBody(turnID: "turn-downgraded", serviceTier: "priority", model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_002,
                tsNanos: 20,
                body: Self.responseTraceBody(
                    type: "response.in_progress",
                    turnID: "turn-downgraded",
                    serviceTier: "auto",
                    model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_003,
                tsNanos: 30,
                body: Self.responseTraceBody(turnID: "turn-downgraded", serviceTier: "default", model: "gpt-5.5")),
            TraceRow(
                ts: 1_820_000_004,
                tsNanos: 40,
                body: Self.requestTraceBody(turnID: "turn-request-only", serviceTier: "priority", model: "gpt-5.5"))
        ])

        let lookup = try CodexServiceTierTraceStore(databaseURL: databaseURL)
            .loadLookup(start: Date(timeIntervalSince1970: 1_820_000_000),
                        end: Date(timeIntervalSince1970: 1_820_000_010))

        #expect(lookup.classify(turnID: "turn-downgraded").tier == .fast)
        #expect(lookup.classify(turnID: "turn-downgraded").source == .trace)
        #expect(lookup.classify(turnID: "turn-request-only").tier == .fast)
        #expect(lookup.classify(turnID: "turn-request-only").source == .trace)
    }

    @Test("accidental prefix substrings are ignored in favor of JSON turn id")
    func accidentalPrefixSubstringsAreIgnoredInFavorOfJSONTurnID() throws {
        let body = """
        session_loop:turn{return_id=wrong-return not_turn.id=wrong-dot model=gpt-5.5}:run_sampling_request websocket request:{"type":"response.create","service_tier":"priority","model":"gpt-5.5","turn_id":"turn-json"}
        """
        let databaseURL = try Self.makeLogsDatabase(rows: [
            TraceRow(ts: 1_820_000_001, tsNanos: 10, body: body)
        ])

        let lookup = try CodexServiceTierTraceStore(databaseURL: databaseURL)
            .loadLookup(start: Date(timeIntervalSince1970: 1_820_000_000),
                        end: Date(timeIntervalSince1970: 1_820_000_010))

        #expect(lookup.classify(turnID: "turn-json").tier == .fast)
        #expect(lookup.classify(turnID: "wrong-return").tier == .standard)
        #expect(lookup.classify(turnID: "wrong-dot").tier == .standard)
    }

    @Test("legitimate prefix turn id wins over JSON turn id")
    func legitimatePrefixTurnIDWinsOverJSONTurnID() throws {
        let body = """
        session_loop:turn{turn.id=turn-prefix model=gpt-5.5}:run_sampling_request websocket request:{"type":"response.create","service_tier":"priority","model":"gpt-5.5","turn_id":"turn-json"}
        """
        let databaseURL = try Self.makeLogsDatabase(rows: [
            TraceRow(ts: 1_820_000_001, tsNanos: 10, body: body)
        ])

        let lookup = try CodexServiceTierTraceStore(databaseURL: databaseURL)
            .loadLookup(start: Date(timeIntervalSince1970: 1_820_000_000),
                        end: Date(timeIntervalSince1970: 1_820_000_010))

        #expect(lookup.classify(turnID: "turn-prefix").tier == .fast)
        #expect(lookup.classify(turnID: "turn-prefix").source == .trace)
        #expect(lookup.classify(turnID: "turn-json").tier == .standard)
    }

    @Test("default database URL prefers root logs_2")
    func defaultDatabaseURLPrefersRootLogs2() throws {
        let codexHome = try Self.makeTemporaryDirectory()
        let fallbackDirectory = codexHome.appending(path: "sqlite")
        try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
        let rootDatabase = codexHome.appending(path: "logs_2.sqlite")
        let fallbackDatabase = fallbackDirectory.appending(path: "logs_2.sqlite")
        _ = FileManager.default.createFile(atPath: rootDatabase.path, contents: Data())
        _ = FileManager.default.createFile(atPath: fallbackDatabase.path, contents: Data())

        #expect(CodexServiceTierTraceStore.defaultDatabaseURL(codexHome: codexHome) == rootDatabase)

        try FileManager.default.removeItem(at: rootDatabase)

        #expect(CodexServiceTierTraceStore.defaultDatabaseURL(codexHome: codexHome) == fallbackDatabase)
    }

    @Test("missing database returns unavailable from default lookup")
    func missingDatabaseReturnsUnavailableFromDefaultLookup() throws {
        let codexHome = try Self.makeTemporaryDirectory()

        #expect(CodexServiceTierTraceStore.defaultDatabaseURL(codexHome: codexHome) == nil)

        let missing = CodexTurnBillingLookup.unavailable.classify(turnID: "x")
        #expect(missing.tier == .unknown)
        #expect(missing.source == .traceUnavailable)
    }

    @Test("import scan persists billing tier from Codex trace lookup")
    func importScanPersistsBillingTierFromCodexTraceLookup() async throws {
        let database = try Self.makeQuotaMonitorDatabase()
        let codexHome = try Self.makeTemporaryDirectory()
        let sessionsDirectory = codexHome.appending(path: "sessions/2026/06/20", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appending(path: "rollout-2026-06-20T10-00-00-test-session.jsonl")
        try Self.writeCodexRollout(
            to: rolloutURL,
            fastTurnID: "turn-fast",
            missingTurnID: "turn-miss")
        try Self.setModificationDate(
            Date(timeIntervalSince1970: 1_820_000_100),
            for: rolloutURL)
        _ = try Self.makeLogsDatabase(
            directory: codexHome,
            rows: [
                TraceRow(
                    ts: 1_820_000_100,
                    tsNanos: 10,
                    body: Self.requestTraceBody(turnID: "turn-fast", serviceTier: "priority", model: "gpt-5.5"))
            ])

        let report = try await ImportEngine(database: database, codexHome: codexHome).performScan()
        #expect(report.changedFiles == 1)
        #expect(report.importedEvents == 2)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT turn_id, billing_tier, billing_tier_source, total_tokens
                FROM usage_events
                ORDER BY timestamp ASC, id ASC
                """)
        }

        #expect(rows.map { $0["turn_id"] as String? } == ["turn-fast", "turn-miss"])
        #expect(rows.map { $0["billing_tier"] as String } == ["fast", "standard"])
        #expect(rows.map { $0["billing_tier_source"] as String } == ["trace", "trace"])
        #expect(rows.map { $0["total_tokens"] as Int64 } == [1_100, 550])
    }

    @Test("import scan rechecks rows that were imported while trace database was unavailable")
    func importScanRechecksRowsImportedWhileTraceDatabaseWasUnavailable() async throws {
        let database = try Self.makeQuotaMonitorDatabase()
        let codexHome = try Self.makeTemporaryDirectory()
        let sessionsDirectory = codexHome.appending(path: "sessions/2026/06/20", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appending(path: "rollout-2026-06-20T10-00-00-test-session.jsonl")
        try Self.writeCodexRollout(
            to: rolloutURL,
            fastTurnID: "turn-fast",
            missingTurnID: "turn-miss")
        try Self.setModificationDate(
            Date(timeIntervalSince1970: 1_820_000_100),
            for: rolloutURL)

        let firstReport = try await ImportEngine(database: database, codexHome: codexHome).performScan()
        #expect(firstReport.changedFiles == 1)

        _ = try Self.makeLogsDatabase(
            directory: codexHome,
            rows: [
                TraceRow(
                    ts: 1_820_000_100,
                    tsNanos: 10,
                    body: Self.requestTraceBody(turnID: "turn-fast", serviceTier: "priority", model: "gpt-5.5"))
            ])

        let secondReport = try await ImportEngine(database: database, codexHome: codexHome).performScan()
        #expect(secondReport.changedFiles == 1)
        #expect(secondReport.importedEvents == 2)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT turn_id, billing_tier, billing_tier_source
                FROM usage_events
                ORDER BY timestamp ASC, id ASC
                """)
        }

        #expect(rows.map { $0["turn_id"] as String? } == ["turn-fast", "turn-miss"])
        #expect(rows.map { $0["billing_tier"] as String } == ["fast", "standard"])
        #expect(rows.map { $0["billing_tier_source"] as String } == ["trace", "trace"])
    }

    @Test("import scan succeeds with unavailable trace lookup when trace database is missing")
    func importScanSucceedsWithUnavailableTraceLookupWhenTraceDatabaseIsMissing() async throws {
        let database = try Self.makeQuotaMonitorDatabase()
        let codexHome = try Self.makeTemporaryDirectory()
        let sessionsDirectory = codexHome.appending(path: "sessions/2026/06/20", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appending(path: "rollout-2026-06-20T10-00-00-test-session.jsonl")
        try Self.writeCodexRollout(
            to: rolloutURL,
            fastTurnID: "turn-fast",
            missingTurnID: "turn-miss")

        let report = try await ImportEngine(database: database, codexHome: codexHome).performScan()
        #expect(report.changedFiles == 1)
        #expect(report.importedEvents == 2)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT turn_id, billing_tier, billing_tier_source, total_tokens
                FROM usage_events
                ORDER BY timestamp ASC, id ASC
                """)
        }

        #expect(rows.map { $0["turn_id"] as String? } == ["turn-fast", "turn-miss"])
        #expect(rows.map { $0["billing_tier"] as String } == ["unknown", "unknown"])
        #expect(rows.map { $0["billing_tier_source"] as String } == ["trace_unavailable", "trace_unavailable"])
        #expect(rows.map { $0["total_tokens"] as Int64 } == [1_100, 550])
    }

    private struct TraceRow {
        let ts: Int64
        let tsNanos: Int64
        let body: String
    }

    private static func responseTraceBody(
        type: String = "response.completed",
        turnID: String,
        serviceTier: String,
        model: String
    ) -> String {
        """
        session_loop:turn{turn.id=\(turnID) model=\(model)}:run_sampling_request websocket event:{"type":"\(type)","response":{"service_tier":"\(serviceTier)","model":"\(model)","turn_id":"\(turnID)"}}
        """
    }

    private static func requestTraceBody(turnID: String, serviceTier: String, model: String) -> String {
        """
        session_loop:turn{turn.id=\(turnID) model=\(model)}:run_sampling_request websocket request:{"type":"response.create","service_tier":"\(serviceTier)","model":"\(model)","turn_id":"\(turnID)"}
        """
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "QuotaMonitorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeLogsDatabase(
        directory: URL? = nil,
        rows: [TraceRow]
    ) throws -> URL {
        #if canImport(SQLite3)
        let directory = try directory ?? makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "logs_2.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            throw TestDatabaseError.openFailed
        }
        defer { sqlite3_close(db) }

        try executeSQL(Self.schemaSQL, db: db)

        for row in rows {
            let sql = """
            INSERT INTO logs (ts, ts_nanos, level, target, feedback_log_body)
            VALUES (?, ?, 'INFO', 'codex', ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw TestDatabaseError.prepareFailed
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, row.ts)
            sqlite3_bind_int64(statement, 2, row.tsNanos)
            sqlite3_bind_text(statement, 3, row.body, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TestDatabaseError.insertFailed
            }
        }

        return databaseURL
        #else
        return URL(filePath: "/tmp/unavailable-\(UUID().uuidString).sqlite")
        #endif
    }

    private static func makeQuotaMonitorDatabase() throws -> DatabaseManager {
        let directory = try makeTemporaryDirectory()
        return try DatabaseManager(url: directory.appending(path: "quotamonitor.sqlite"))
    }

    private static func writeCodexRollout(
        to url: URL,
        fastTurnID: String,
        missingTurnID: String
    ) throws {
        try """
        {"timestamp":"2026-06-20T10:00:00.000Z","type":"session_meta","payload":{"id":"test-session","cwd":"/tmp/quota-monitor"}}
        {"timestamp":"2026-06-20T10:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"\(fastTurnID)"}}
        {"timestamp":"2026-06-20T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100}}}}
        {"timestamp":"2026-06-20T10:03:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"\(missingTurnID)"}}
        {"timestamp":"2026-06-20T10:04:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":450,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":550}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static let schemaSQL = """
    CREATE TABLE logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        ts_nanos INTEGER NOT NULL,
        level TEXT NOT NULL,
        target TEXT NOT NULL,
        feedback_log_body TEXT,
        module_path TEXT,
        file TEXT,
        line INTEGER,
        thread_id TEXT,
        process_uuid TEXT,
        estimated_bytes INTEGER NOT NULL DEFAULT 0
    );
    """

    #if canImport(SQLite3)
    private static func executeSQL(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            sqlite3_free(error)
            throw TestDatabaseError.execFailed
        }
    }
    #endif

    private enum TestDatabaseError: Error {
        case openFailed
        case prepareFailed
        case insertFailed
        case execFailed
    }
}

#if canImport(SQLite3)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif
