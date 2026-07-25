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

    @Test("50-row pages are stable prefixes for every global sort")
    func pagesMatchStableGlobalPrefixes() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 55)

        try database.pool.read { db in
            for sort in SessionSort.allCases {
                let first = try Aggregator.fetchSessionsPage(
                    db: db,
                    sort: sort,
                    limit: 50)
                let expanded = try Aggregator.fetchSessionsPage(
                    db: db,
                    sort: sort,
                    limit: 100)
                let all = try Aggregator.fetchSessions(
                    db: db,
                    sort: sort,
                    limit: 100)

                #expect(first.rows == Array(all.prefix(50)))
                #expect(first.hasMore)
                #expect(expanded.rows == all)
                #expect(!expanded.hasMore)
                #expect(first.rows.map(\.sessionId) == (0..<50).map {
                    String(format: "session-%03d", $0)
                })
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
                db: db, sort: .recent, limit: 50)
            let value = try Aggregator.fetchSessionsPage(
                db: db, sort: .value, limit: 50)
            let tokens = try Aggregator.fetchSessionsPage(
                db: db, sort: .tokens, limit: 50)

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
                try Aggregator.fetchSessionsPage(db: $0, limit: 50)
            }

            #expect(page.rows.count == 50)
            #expect(page.hasMore == expectedHasMore)
        }
    }

    @Test("search and provider filter apply before page limiting")
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
                limit: 1)
            let allMatches = try Aggregator.fetchSessionsPage(
                db: db,
                search: "target",
                provider: .claude,
                limit: 50)
            let eventless = try Aggregator.fetchSessionsPage(
                db: db,
                search: "other session 64",
                provider: .claude,
                limit: 50)

            #expect(firstMatch.rows.map(\.sessionId) == ["session-052"])
            #expect(firstMatch.hasMore)
            #expect(allMatches.rows.map(\.sessionId) == [
                "session-052", "session-059",
            ])
            #expect(!allMatches.hasMore)
            #expect(eventless.rows.map(\.sessionId) == ["session-064"])
            #expect(eventless.rows.first?.eventCount == 0)
        }
    }

    @Test("progressive prefix continues beyond the former 500-row ceiling")
    func paginationContinuesPastFormerCeiling() throws {
        let database = try makeDatabase()
        try seedSessions(in: database, count: 505)

        try database.pool.read { db in
            let formerCeiling = try Aggregator.fetchSessionsPage(
                db: db,
                limit: 500)
            let expanded = try Aggregator.fetchSessionsPage(
                db: db,
                limit: 550)

            #expect(formerCeiling.rows.count == 500)
            #expect(formerCeiling.hasMore)
            #expect(expanded.rows.count == 505)
            #expect(!expanded.hasMore)
            #expect(expanded.rows.prefix(500).elementsEqual(formerCeiling.rows))
        }
    }
}
