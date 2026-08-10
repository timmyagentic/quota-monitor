import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Sessions pagination")
struct SessionsPaginationTests {
    private func makeDatabase() throws -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-monitor-session-page-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return try DatabaseManager(url: directory.appendingPathComponent(
            "sessions-\(UUID().uuidString).sqlite"))
    }

    private func seedSessions(
        in database: DatabaseManager,
        count: Int,
        matching: Set<Int> = [],
        claude: Set<Int> = [],
        withoutEvents: Set<Int> = []
    ) throws {
        try database.pool.write { db in
            for index in 0..<count {
                let sessionID = String(format: "session-%03d", index)
                let provider = claude.contains(index) ? "claude" : "codex"
                let title = matching.contains(index)
                    ? "Target session \(index)"
                    : "Other session \(index)"
                let timestamp = "2026-07-20T12:00:00Z"
                try db.execute(sql: """
                    INSERT INTO sessions
                    (session_id, root_session_id, parent_session_id, title,
                     project_name, cwd, source_path, started_at, updated_at,
                     agent_nickname, agent_role, last_model_id, latest_plan_type,
                     contains_subagents, created_at, imported_at, provider)
                    VALUES (?, ?, NULL, ?, 'quota-monitor', NULL, NULL, ?, ?,
                            NULL, NULL, 'gpt-5.6-sol', NULL, 0, ?, ?, ?)
                    """, arguments: [
                        sessionID, sessionID, title, timestamp, timestamp,
                        timestamp, timestamp, provider,
                    ])
                if !withoutEvents.contains(index) {
                    try db.execute(sql: """
                        INSERT INTO usage_events
                        (session_id, timestamp, model_id,
                         input_tokens, cached_input_tokens, output_tokens,
                         reasoning_output_tokens, total_tokens, value_usd,
                         provider, cache_creation_tokens, model_inferred)
                        VALUES (?, ?, 'gpt-5.6-sol', 10, 0, 0, 0, 10, 1, ?, 0, 0)
                        """, arguments: [sessionID, timestamp, provider])
                }
            }
        }
    }

    @Test("keyset pages form the complete stable order for every sort")
    func keysetPagesMatchStableGlobalOrder() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 55)

        try database.pool.read { db in
            for sort in SessionSort.allCases {
                let all = try Aggregator.fetchSessions(
                    db: db,
                    sort: sort,
                    limit: 100)
                let first = try Aggregator.fetchSessionsPage(
                    db: db,
                    sort: sort,
                    pageSize: 50)
                let cursor = try #require(first.nextCursor)
                let second = try Aggregator.fetchSessionsPage(
                    db: db,
                    sort: sort,
                    after: cursor,
                    pageSize: 50)

                #expect(first.rows.count == 50)
                #expect(first.hasMore)
                #expect(second.rows.count == 5)
                #expect(!second.hasMore)
                #expect(first.rows + second.rows == all)
                #expect(all.map(\.sessionId) == (0..<55).map {
                    String(format: "session-%03d", $0)
                })
            }
        }
    }

    @Test("keyset boundaries merge tied and lower metrics in order")
    func keysetBoundariesMergeBothRanges() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 8)
        try database.pool.write { db in
            for index in 0..<8 {
                let rank = 4 - index / 2
                let sessionID = String(format: "session-%03d", index)
                let updatedAt = String(
                    format: "2026-07-%02dT12:00:00Z",
                    rank)
                try db.execute(
                    sql: "UPDATE sessions SET updated_at = ? WHERE session_id = ?",
                    arguments: [updatedAt, sessionID])
                try db.execute(sql: """
                    UPDATE usage_events
                    SET value_usd = ?, total_tokens = ?
                    WHERE session_id = ?
                    """, arguments: [Double(rank), Int64(rank * 10), sessionID])
            }
        }

        try database.pool.read { db in
            for sort in SessionSort.allCases {
                let expected = try Aggregator.fetchSessions(
                    db: db,
                    sort: sort,
                    limit: 20)
                var cursor: SessionPageCursor?
                var loaded: [SessionRow] = []
                var secondPageFirstID: String?
                repeat {
                    let page = try Aggregator.fetchSessionsPage(
                        db: db,
                        sort: sort,
                        after: cursor,
                        pageSize: 3)
                    if !loaded.isEmpty, secondPageFirstID == nil {
                        secondPageFirstID = page.rows.first?.sessionId
                    }
                    loaded.append(contentsOf: page.rows)
                    cursor = page.nextCursor
                } while cursor != nil

                #expect(loaded == expected)
                #expect(secondPageFirstID == "session-003")
            }
        }
    }

    @Test("each sort uses its global metric before the stable session ID tie-breaker")
    func sortsUseMetricsBeforeTieBreaker() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 4)
        let updates: [(id: String, updatedAt: String, value: Double, tokens: Int64)] = [
            ("session-000", "2026-07-01T12:00:00Z", 10, 100),
            ("session-001", "2026-07-03T12:00:00Z", 5, 300),
            ("session-002", "2026-07-02T12:00:00Z", 20, 200),
            ("session-003", "2026-07-03T12:00:00Z", 5, 300),
        ]
        try database.pool.write { db in
            for update in updates {
                try db.execute(
                    sql: "UPDATE sessions SET updated_at = ? WHERE session_id = ?",
                    arguments: [update.updatedAt, update.id])
                try db.execute(sql: """
                    UPDATE usage_events
                    SET value_usd = ?, total_tokens = ?
                    WHERE session_id = ?
                    """, arguments: [update.value, update.tokens, update.id])
            }
        }

        try database.pool.read { db in
            let recent = try Aggregator.fetchSessionsPage(
                db: db, sort: .recent, pageSize: 50)
            let value = try Aggregator.fetchSessionsPage(
                db: db, sort: .value, pageSize: 50)
            let tokens = try Aggregator.fetchSessionsPage(
                db: db, sort: .tokens, pageSize: 50)

            #expect(recent.rows.map(\.sessionId) == [
                "session-001", "session-003", "session-002", "session-000",
            ])
            #expect(value.rows.map(\.sessionId) == [
                "session-002", "session-000", "session-001", "session-003",
            ])
            #expect(tokens.rows.map(\.sessionId) == [
                "session-001", "session-003", "session-002", "session-000",
            ])
        }
    }

    @Test("page boundary distinguishes exactly 50 rows from 51")
    func exactPageBoundaryControlsHasMore() throws {
        for (count, expectedHasMore) in [(50, false), (51, true)] {
            let database = try makeDatabase()
            try seedSessions(in: database, count: count)
            let page = try database.pool.read {
                try Aggregator.fetchSessionsPage(db: $0, pageSize: 50)
            }

            #expect(page.rows.count == 50)
            #expect(page.hasMore == expectedHasMore)
        }
    }

    @Test("search and provider filter apply before each keyset page limit")
    func searchAndProviderAreGlobal() throws {
        let database = try makeDatabase()
        try seedSessions(
            in: database,
            count: 65,
            matching: [1, 52, 59],
            claude: [52, 59, 60, 61, 62, 63, 64],
            withoutEvents: [64])

        try database.pool.read { db in
            let firstMatch = try Aggregator.fetchSessionsPage(
                db: db,
                search: "target",
                provider: .claude,
                pageSize: 1)
            let secondMatch = try Aggregator.fetchSessionsPage(
                db: db,
                search: "target",
                provider: .claude,
                after: firstMatch.nextCursor,
                pageSize: 1)
            let eventless = try Aggregator.fetchSessionsPage(
                db: db,
                search: "other session 64",
                provider: .claude,
                pageSize: 50)

            #expect(firstMatch.rows.map(\.sessionId) == ["session-052"])
            #expect(firstMatch.hasMore)
            #expect(secondMatch.rows.map(\.sessionId) == ["session-059"])
            #expect(!secondMatch.hasMore)
            #expect(eventless.rows.map(\.sessionId) == ["session-064"])
            #expect(eventless.rows.first?.eventCount == 0)
        }
    }

    @Test("session summaries track usage insert, update, move, and delete")
    func sessionSummariesStayExact() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 2, withoutEvents: [1])

        try database.pool.write { db in
            try Self.expectSummary(
                db: db,
                sessionId: "session-000",
                value: 1,
                tokens: 10,
                events: 1,
                inferred: false)
            try Self.expectSummary(
                db: db,
                sessionId: "session-001",
                value: 0,
                tokens: 0,
                events: 0,
                inferred: false)

            try db.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred)
                VALUES ('session-000', '2026-07-20T12:01:00Z', 'gpt-5.6-sol',
                        20, 0, 0, 0, 20, 2.5, 'codex', 0, 1)
                """)
            let eventID = db.lastInsertedRowID
            try Self.expectSummary(
                db: db,
                sessionId: "session-000",
                value: 3.5,
                tokens: 30,
                events: 2,
                inferred: true)

            try db.execute(sql: """
                UPDATE usage_events
                SET value_usd = 4, total_tokens = 40, model_inferred = 0
                WHERE id = ?
                """, arguments: [eventID])
            try Self.expectSummary(
                db: db,
                sessionId: "session-000",
                value: 5,
                tokens: 50,
                events: 2,
                inferred: false)

            try db.execute(
                sql: "UPDATE usage_events SET session_id = 'session-001' WHERE id = ?",
                arguments: [eventID])
            try Self.expectSummary(
                db: db,
                sessionId: "session-000",
                value: 1,
                tokens: 10,
                events: 1,
                inferred: false)
            try Self.expectSummary(
                db: db,
                sessionId: "session-001",
                value: 4,
                tokens: 40,
                events: 1,
                inferred: false)

            try db.execute(
                sql: "DELETE FROM usage_events WHERE id = ?",
                arguments: [eventID])
            try Self.expectSummary(
                db: db,
                sessionId: "session-001",
                value: 0,
                tokens: 0,
                events: 0,
                inferred: false)
        }
    }

    @Test("keyset query plans use page indexes without usage aggregation or sorting")
    func pageQueriesUseSummaryIndexes() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 80)

        try database.pool.read { db in
            let expectedIndexes: [SessionSort: String] = [
                .recent: "idx_session_summaries_recent_page",
                .value: "idx_session_summaries_value_page",
                .tokens: "idx_session_summaries_tokens_page",
            ]
            for sort in SessionSort.allCases {
                let initialQuery = try Aggregator.makeSessionsPageQuery(
                    sort: sort,
                    search: "",
                    provider: .all,
                    after: nil,
                    limit: 51)
                let initialPlan = try Row.fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN \(initialQuery.sql)",
                    arguments: initialQuery.arguments
                ).map { $0["detail"] as String }
                let first = try Aggregator.fetchSessionsPage(
                    db: db,
                    sort: sort,
                    pageSize: 10)
                let cursor = try #require(first.nextCursor)
                let query = try Aggregator.makeSessionsPageQuery(
                    sort: sort,
                    search: "",
                    provider: .all,
                    after: cursor,
                    limit: 51)
                let plan = try Row.fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN \(query.sql)",
                    arguments: query.arguments
                ).map { $0["detail"] as String }
                let expectedIndex = try #require(expectedIndexes[sort])

                #expect(initialPlan.contains { $0.contains(expectedIndex) })
                #expect(plan.contains { $0.contains("SEARCH") && $0.contains(expectedIndex) })
                for (sql, queryPlan) in [
                    (initialQuery.sql, initialPlan),
                    (query.sql, plan),
                ] {
                    #expect(!sql.contains("usage_events"))
                    #expect(queryPlan.allSatisfy { !$0.contains("USE TEMP B-TREE") })
                    #expect(queryPlan.allSatisfy { !$0.contains("usage_events") })
                }
            }
        }
    }

    @Test("fixed-size keyset pages continue beyond the former 500-row ceiling")
    func paginationContinuesPastFormerCeiling() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 505)

        try database.pool.read { db in
            var cursor: SessionPageCursor?
            var rows: [SessionRow] = []
            var pageCount = 0
            repeat {
                let page = try Aggregator.fetchSessionsPage(
                    db: db,
                    after: cursor,
                    pageSize: 50)
                #expect(page.rows.count <= 50)
                rows.append(contentsOf: page.rows)
                cursor = page.nextCursor
                pageCount += 1
            } while cursor != nil

            #expect(pageCount == 11)
            #expect(rows.count == 505)
            #expect(Set(rows.map(\.sessionId)).count == 505)
            #expect(rows.last?.sessionId == "session-504")
        }
    }

    private static func expectSummary(
        db: Database,
        sessionId: String,
        value: Double,
        tokens: Int64,
        events: Int,
        inferred: Bool
    ) throws {
        let fetched = try Row.fetchOne(db, sql: """
            SELECT total_value_usd, total_tokens, event_count, has_inferred_model
            FROM session_summaries
            WHERE session_id = ?
            """, arguments: [sessionId])
        let row = try #require(fetched)
        #expect(abs((row["total_value_usd"] as Double) - value) < 1e-9)
        #expect((row["total_tokens"] as Int64) == tokens)
        #expect((row["event_count"] as Int) == events)
        #expect((row["has_inferred_model"] as Bool) == inferred)
    }
}
