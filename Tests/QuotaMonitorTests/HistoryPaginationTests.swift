import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("History pagination")
struct HistoryPaginationTests {
    private struct SQLTrace {
        let statements: [String]
        let aggregatePlan: [String]
        let olderPlan: [String]
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func makeDatabase() throws -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-monitor-history-page-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return try DatabaseManager(url: directory.appendingPathComponent(
            "history-\(UUID().uuidString).sqlite"))
    }

    private func seed(
        in database: DatabaseManager,
        sessionId: String,
        timestamp: String,
        provider: String = "codex",
        tokens: Int64 = 10,
        valueUSD: Double = 1
    ) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL,
                        'gpt-5', NULL, 0, ?, ?, ?)
                """, arguments: [
                    sessionId, sessionId, timestamp, timestamp,
                    timestamp, timestamp, provider
                ])
            try db.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred)
                VALUES (?, ?, 'gpt-5', ?, 0, 0, 0, ?, ?, ?, 0, 0)
                """, arguments: [
                    sessionId, timestamp, tokens, tokens, valueUSD, provider
                ])
        }
    }

    private func traceHistorySQL(
        in database: DatabaseManager,
        provider: ProviderFilter,
        now: Date,
        calendar: Calendar
    ) throws -> SQLTrace {
        try database.pool.read { db in
            var statements: [String] = []
            db.trace { event in
                guard case .statement(let statement) = event else { return }
                statements.append(statement.expandedSQL)
            }
            _ = try Aggregator.fetchHistoryPage(
                db: db, provider: provider, now: now, calendar: calendar)
            db.trace(options: [])

            let aggregateSQL = try #require(statements.first {
                $0.contains("UNION ALL")
            })
            let olderSQL = try #require(statements.first {
                $0.contains("ORDER BY timestamp DESC") && $0.contains("LIMIT 1")
            })
            let aggregatePlan = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN \(aggregateSQL)"
            ).map { $0["detail"] as String }
            let olderPlan = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN \(olderSQL)"
            ).map { $0["detail"] as String }
            return SQLTrace(
                statements: statements,
                aggregatePlan: aggregatePlan,
                olderPlan: olderPlan)
        }
    }

    @Test("page load triggers have stable diagnostics values")
    func pageLoadTriggerRawValues() {
        let triggers: [HistoryPageLoadTrigger] = [.initial, .scroll, .retry]
        #expect(triggers.map(\.rawValue) == ["initial", "scroll", "retry"])
    }

    @Test("initial page is today plus the previous six natural dates")
    func initialPageBounds() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "today", timestamp: "2026-07-15T10:00:00Z")
        try seed(in: db, sessionId: "lower", timestamp: "2026-07-09T00:00:00Z")
        try seed(in: db, sessionId: "older", timestamp: "2026-07-08T23:59:59Z")

        let page = try db.pool.read {
            try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
        }
        let expectedCursor = try #require(ISO8601.parse("2026-07-09T00:00:00Z"))

        #expect(page.days.map(\.day) == ["2026-07-15", "2026-07-09"])
        #expect(page.nextCursor == expectedCursor)
        #expect(page.hasMore)
    }

    @Test("next page uses the preceding cursor as an exclusive upper bound")
    func cursorHasNoOverlapOrGap() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "boundary", timestamp: "2026-07-09T00:00:00Z")
        try seed(in: db, sessionId: "older", timestamp: "2026-07-08T23:59:59Z")
        let first = try db.pool.read {
            try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
        }
        let second = try db.pool.read {
            try Aggregator.fetchHistoryPage(
                db: $0, before: first.nextCursor, now: now, calendar: calendar)
        }
        let expectedCursor = try #require(ISO8601.parse("2026-07-02T00:00:00Z"))

        #expect(first.days.map(\.day) == ["2026-07-09"])
        #expect(second.days.map(\.day) == ["2026-07-08"])
        #expect(Set(first.days.map(\.id)).isDisjoint(with: second.days.map(\.id)))
        #expect(second.nextCursor == expectedCursor)
        #expect(!second.hasMore)
    }

    @Test("page aggregates match day detail exactly")
    func aggregatesMatchDayDetail() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(
            in: db, sessionId: "same", timestamp: "2026-07-15T08:00:00Z",
            tokens: 10, valueUSD: 1.25)
        try seed(
            in: db, sessionId: "same", timestamp: "2026-07-15T09:00:00Z",
            tokens: 20, valueUSD: 2.50)
        try seed(
            in: db, sessionId: "other", timestamp: "2026-07-15T10:00:00Z",
            tokens: 30, valueUSD: 4.00)

        let (page, optionalDetail) = try db.pool.read { connection in
            let page = try Aggregator.fetchHistoryPage(
                db: connection, now: now, calendar: calendar)
            let detail = try Aggregator.fetchDayDetail(
                db: connection, day: "2026-07-15", calendar: calendar)
            return (page, detail)
        }
        let summary = try #require(page.days.first)
        let detail = try #require(optionalDetail)

        #expect(summary.valueUSD == 7.75)
        #expect(summary.tokens == 60)
        #expect(summary.eventCount == 3)
        #expect(summary.sessionCount == 2)
        #expect(detail.summary == summary)
    }

    @Test("provider filter applies to pages and older lookup")
    func providerFilter() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(
            in: db, sessionId: "codex", timestamp: "2026-07-15T08:00:00Z",
            provider: "codex", tokens: 10, valueUSD: 1.25)
        try seed(
            in: db, sessionId: "claude", timestamp: "2026-07-15T09:00:00Z",
            provider: "claude", tokens: 20, valueUSD: 2.50)
        try seed(
            in: db, sessionId: "older-claude", timestamp: "2026-07-08T23:00:00Z",
            provider: "claude", tokens: 100, valueUSD: 10)

        let (all, codex, claude) = try db.pool.read { connection in
            let all = try Aggregator.fetchHistoryPage(
                db: connection, provider: .all, now: now, calendar: calendar)
            let codex = try Aggregator.fetchHistoryPage(
                db: connection, provider: .codex, now: now, calendar: calendar)
            let claude = try Aggregator.fetchHistoryPage(
                db: connection, provider: .claude, now: now, calendar: calendar)
            return (all, codex, claude)
        }

        #expect(all.days.first?.valueUSD == 3.75)
        #expect(all.days.first?.tokens == 30)
        #expect(all.days.first?.eventCount == 2)
        #expect(all.days.first?.sessionCount == 2)
        #expect(codex.days.first?.valueUSD == 1.25)
        #expect(codex.days.first?.tokens == 10)
        #expect(codex.days.first?.eventCount == 1)
        #expect(!codex.hasMore)
        #expect(claude.days.first?.valueUSD == 2.50)
        #expect(claude.days.first?.tokens == 20)
        #expect(claude.days.first?.eventCount == 1)
        #expect(claude.hasMore)
    }

    @Test("spring-forward page ends at the next local midnight")
    func springForwardRange() throws {
        let calendar = newYorkCalendar()
        let now = try #require(ISO8601.parse("2025-03-09T16:00:00Z"))
        let db = try makeDatabase()
        try seed(
            in: db, sessionId: "inside", timestamp: "2025-03-10T03:59:59Z",
            tokens: 11)
        try seed(
            in: db, sessionId: "outside", timestamp: "2025-03-10T04:00:00Z",
            tokens: 99)

        let page = try db.pool.read {
            try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
        }
        let expectedCursor = try #require(ISO8601.parse("2025-03-03T05:00:00Z"))

        #expect(page.days.map(\.day) == ["2025-03-09"])
        #expect(page.days.first?.tokens == 11)
        #expect(page.days.first?.eventCount == 1)
        #expect(page.nextCursor == expectedCursor)
    }

    @Test("fall-back page ends at the next local midnight")
    func fallBackRange() throws {
        let calendar = newYorkCalendar()
        let now = try #require(ISO8601.parse("2025-11-02T17:00:00Z"))
        let db = try makeDatabase()
        try seed(
            in: db, sessionId: "inside", timestamp: "2025-11-03T04:59:59Z",
            tokens: 11)
        try seed(
            in: db, sessionId: "outside", timestamp: "2025-11-03T05:00:00Z",
            tokens: 99)

        let page = try db.pool.read {
            try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
        }
        let expectedCursor = try #require(ISO8601.parse("2025-10-27T04:00:00Z"))

        #expect(page.days.map(\.day) == ["2025-11-02"])
        #expect(page.days.first?.tokens == 11)
        #expect(page.days.first?.eventCount == 1)
        #expect(page.nextCursor == expectedCursor)
    }

    @Test("all-provider aggregate uses seven indexed range searches")
    func allProviderAggregateQueryPlan() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "today", timestamp: "2026-07-15T10:00:00Z")

        let trace = try traceHistorySQL(
            in: db, provider: .all, now: now, calendar: calendar)

        #expect(trace.aggregatePlan.filter {
            $0.contains("SEARCH usage_events")
        }.count == 7)
        #expect(trace.aggregatePlan.allSatisfy {
            !$0.contains("SCAN usage_events")
        })
        #expect(trace.aggregatePlan.allSatisfy {
            !$0.contains("TEMP B-TREE FOR ORDER BY")
        })
        #expect(trace.aggregatePlan.contains {
            $0.contains("idx_usage_events_timestamp")
        })
    }

    @Test("provider aggregate uses the provider-timestamp index")
    func providerAggregateQueryPlan() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "today", timestamp: "2026-07-15T10:00:00Z")

        let trace = try traceHistorySQL(
            in: db, provider: .codex, now: now, calendar: calendar)

        #expect(trace.aggregatePlan.filter {
            $0.contains("SEARCH usage_events")
        }.count == 7)
        #expect(trace.aggregatePlan.allSatisfy {
            !$0.contains("SCAN usage_events")
        })
        #expect(trace.aggregatePlan.contains {
            $0.contains("index_usage_events_on_provider_timestamp")
        })
    }

    @Test("older lookup is covering and page query never projects raw events")
    func olderLookupQueryPlan() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "today", timestamp: "2026-07-15T10:00:00Z")

        let trace = try traceHistorySQL(
            in: db, provider: .all, now: now, calendar: calendar)
        let normalizedStatements = trace.statements.map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        #expect(trace.olderPlan.contains {
            $0.contains("SEARCH usage_events USING COVERING INDEX idx_usage_events_timestamp")
        })
        #expect(normalizedStatements.allSatisfy {
            !$0.contains("SELECT timestamp, value_usd, total_tokens, session_id")
        })
    }
}
