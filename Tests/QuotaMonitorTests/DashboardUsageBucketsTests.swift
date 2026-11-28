import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Dashboard usage buckets")
struct DashboardUsageBucketsTests {
    private func seedSessions(_ db: Database) throws {
        for id in ["one", "two"] {
            try db.execute(sql: """
                INSERT INTO sessions(session_id, root_session_id, created_at, imported_at, provider)
                VALUES (?, ?, '2026-05-01', '2026-05-01', 'codex')
                """, arguments: [id, id])
        }
    }

    private func event(_ db: Database, at timestamp: String, tokens: Int, session: String = "one") throws {
        try db.execute(sql: """
            INSERT INTO usage_events(session_id, timestamp, model_id, input_tokens, cached_input_tokens,
                                     total_tokens, value_usd, provider)
            VALUES (?, ?, 'gpt-5', ?, 1, ?, 0.125, 'codex')
            """, arguments: [session, timestamp, tokens, tokens])
    }

    @Test("Migration, repricing, moving and deleting events keep dashboard facts transactional")
    func transactionalFacts() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue, upTo: "v28-codex-response-deduplication-reread")
        try queue.write { db in
            try seedSessions(db)
            try event(db, at: "2026-06-01T09:05:00.000Z", tokens: 10)
            try event(db, at: "2026-06-01T09:45:00.000Z", tokens: 20)
        }
        try migrator.migrate(queue)
        try queue.write { db in
            #expect(try Int.fetchOne(db, sql: "SELECT event_count FROM dashboard_usage_buckets") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dashboard_usage_buckets") == 1)
            try db.execute(sql: "UPDATE usage_events SET value_usd = 0.5 WHERE session_id = 'one'")
            #expect(try Double.fetchOne(db, sql: "SELECT value_usd FROM dashboard_usage_buckets") == 1.0)
            try db.execute(sql: """
                UPDATE usage_events SET session_id = 'two', provider = 'claude', model_id = 'other',
                    codex_service_tier_preference = 'priority', timestamp = '2026-06-02T10:00:00.000Z',
                    cached_input_tokens = 7, cache_creation_5m_tokens = 3, total_tokens = 26
                WHERE total_tokens = 20
                """)
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT * FROM dashboard_usage_buckets WHERE provider='claude' AND session_id='two'
                AND model_id='other' AND tier='priority' AND bucket='2026-06-02T10'
                """))
            #expect(row["total_tokens"] as Int == 26)
            #expect(row["cache_read_tokens"] as Int == 7)
            #expect(row["cache_eligible_input_tokens"] as Int == 30)
            try db.execute(sql: "SAVEPOINT undo_price")
            try db.execute(sql: "UPDATE usage_events SET value_usd = 100")
            try db.execute(sql: "ROLLBACK TO undo_price")
            try db.execute(sql: "RELEASE undo_price")
            #expect(try Double.fetchOne(db, sql: "SELECT SUM(value_usd) FROM dashboard_usage_buckets") == 1.0)
            try db.execute(sql: "DELETE FROM sessions WHERE session_id = 'two'")
            let remaining = try Aggregator.fetchOverview(db: db)
            #expect(remaining.totalEvents == 1)
            #expect(remaining.totalTokens == 10)
            #expect(remaining.totalValueUSD == 0.5)
            try db.execute(sql: "DELETE FROM usage_events")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dashboard_usage_buckets") == 0)
        }
    }

    @Test("Partial hours preserve local midnight, rolling cutoffs, legacy offsets and distinct sessions")
    func calendarAndMovingEdges() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        let calendar = local
        let now = try #require(ISO8601.parse("2026-06-07T18:40:00.123Z"))
        try queue.write { db in
            try seedSessions(db)
            for (stamp, tokens) in [
                ("2026-05-31T18:14:59.999Z", 1), ("2026-05-31T18:15:00.000Z", 2),
                ("2026-05-31T18:40:00.122Z", 4), ("2026-05-31T18:40:00.123Z", 8),
                ("2026-06-07T18:40:00.122Z", 16), ("2026-06-07T18:40:00.123Z", 32),
                ("2026-06-01T00:20:00+05:45", 64), ("2026-06-03T10:05:00.000Z", 128),
                ("2026-06-03T10:45:00.000Z", 256)
            ] { try event(db, at: stamp, tokens: tokens) }

            let snap = try Aggregator.loadDashboardPrimary(db: db, provider: .codex, now: now, calendar: calendar)
            #expect(snap.trends.last7Days.daily.map(\.tokens).reduce(0, +) == 408)
            #expect(snap.trends.last30Days.daily.map(\.tokens).reduce(0, +) == 479)
            #expect(snap.monthly.suffix(2).map(\.tokens) == [1, 478])
            #expect(snap.monthly.suffix(2).map(\.sessionCount) == [1, 1])
            #expect(snap.modelShares30d.first?.eventCount == 8)
            #expect(snap.overview.totalTokens == 511)
        }
    }
}
