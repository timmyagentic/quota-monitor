import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// DST / time-zone bucketing regressions for the report + history query layer.
///
/// Before this fix `fetchDaily`, `fetchMonthly`, `fetchDayDetail`, and
/// `fetchEventsForSessionOnDay` bucketed days/months in SQL using a SINGLE
/// fixed UTC offset (today's `TimeZone.current` offset). That offset is wrong
/// for any historical timestamp in the opposite DST half of the year, so events
/// near local midnight leaked into the adjacent day. These tests pin the
/// client-side `Calendar`-based bucketing — with a deterministic, injectable
/// `now` window — that fixes it.
@Suite("Aggregator DST bucketing")
struct AggregatorDSTTests {

    // MARK: - helpers

    /// America/New_York: EST (UTC-5) in winter, EDT (UTC-4) in summer.
    private func nyCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agg-dst-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert one session + one usage_event at an explicit ISO8601 (UTC) stamp.
    private func seed(
        in db: DatabaseManager,
        sessionId: String,
        timestamp: String,
        tokens: Int64,
        valueUSD: Double = 0
    ) throws {
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL,
                        'gpt-5', NULL, 0, ?, ?, 'codex')
                """, arguments: [
                    sessionId, sessionId, timestamp, timestamp, timestamp, timestamp
                ])
            try conn.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred)
                VALUES (?, ?, 'gpt-5', ?, 0, 0, 0, ?, ?, 'codex', 0, 0)
                """, arguments: [sessionId, timestamp, tokens, tokens, valueUSD])
        }
    }

    // MARK: - fetchDaily

    @Test("fetchDaily buckets near-midnight events on their own local day across DST")
    func fetchDaily_dstCorrect() throws {
        let cal = nyCalendar()
        let db = try makeDatabase()
        // Winter: Jan 15 04:30 UTC = Jan 14 23:30 EST → local Jan 14.
        try seed(in: db, sessionId: "winter",
                 timestamp: "2025-01-15T04:30:00Z", tokens: 2000)
        // Summer: Jun 15 03:30 UTC = Jun 14 23:30 EDT → local Jun 14.
        try seed(in: db, sessionId: "summer",
                 timestamp: "2025-06-15T03:30:00Z", tokens: 1000)

        // Pin `now` to mid-2025 so both events fall inside the trailing window.
        let now = cal.date(from: DateComponents(
            year: 2025, month: 6, day: 20, hour: 12))!
        let daily = try db.pool.read { conn in
            try Aggregator.fetchDaily(db: conn, days: 365, now: now, calendar: cal)
        }

        func tokens(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
            let target = cal.date(from: DateComponents(
                year: y, month: m, day: d, hour: 12))!
            return daily.first { cal.isDate($0.date, inSameDayAs: target) }?.tokens ?? -1
        }
        #expect(tokens(2025, 1, 14) == 2000)
        #expect(tokens(2025, 6, 14) == 1000)
        // A single summer offset (−4h) would have put the winter event on Jan 15.
        #expect(tokens(2025, 1, 15) == 0, "winter event must not leak onto Jan 15")
        #expect(tokens(2025, 6, 15) == 0, "summer event must not leak onto Jun 15")
    }

    // MARK: - fetchMonthly

    @Test("fetchMonthly buckets by local month within the injected-now window")
    func fetchMonthly_localMonthWindow() throws {
        let cal = nyCalendar()
        let db = try makeDatabase()
        // now = mid-June 2025; ask for 3 months → Apr, May, Jun 2025.
        let now = cal.date(from: DateComponents(
            year: 2025, month: 6, day: 20, hour: 12))!
        try seed(in: db, sessionId: "apr",
                 timestamp: "2025-04-10T12:00:00Z", tokens: 10, valueUSD: 1.00)
        try seed(in: db, sessionId: "may",
                 timestamp: "2025-05-10T12:00:00Z", tokens: 10, valueUSD: 2.00)
        try seed(in: db, sessionId: "jun",
                 timestamp: "2025-06-10T12:00:00Z", tokens: 10, valueUSD: 4.00)
        // March is one month before the window's lower bound → excluded.
        try seed(in: db, sessionId: "mar",
                 timestamp: "2025-03-10T12:00:00Z", tokens: 10, valueUSD: 99.00)

        let monthly = try db.pool.read { conn in
            try Aggregator.fetchMonthly(db: conn, months: 3, now: now, timeZone: cal.timeZone)
        }
        #expect(monthly.count == 3)
        #expect(abs(monthly[0].valueUSD - 1.00) < 0.0001, "April bucket")
        #expect(abs(monthly[1].valueUSD - 2.00) < 0.0001, "May bucket")
        #expect(abs(monthly[2].valueUSD - 4.00) < 0.0001, "June bucket")
        let total = monthly.reduce(0) { $0 + $1.valueUSD }
        #expect(abs(total - 7.00) < 0.0001, "March sits outside the 3-month window")
    }

    // MARK: - fetchDayDetail

    @Test("fetchDayDetail scopes to the queried day's own local-day range across DST")
    func fetchDayDetail_localDayRange() throws {
        let cal = nyCalendar()
        let db = try makeDatabase()
        // Jan 15 04:30 UTC = Jan 14 23:30 EST → belongs to local Jan 14.
        try seed(in: db, sessionId: "winter",
                 timestamp: "2025-01-15T04:30:00Z", tokens: 2000, valueUSD: 3.00)

        let onJan14 = try db.pool.read { conn in
            try Aggregator.fetchDayDetail(db: conn, day: "2025-01-14", calendar: cal)
        }
        let onJan15 = try db.pool.read { conn in
            try Aggregator.fetchDayDetail(db: conn, day: "2025-01-15", calendar: cal)
        }
        #expect(onJan14 != nil, "the 23:30 EST event is on local Jan 14")
        #expect(abs((onJan14?.summary.valueUSD ?? 0) - 3.00) < 0.0001)
        #expect(onJan14?.summary.eventCount == 1)
        #expect(onJan15 == nil, "nothing happened on local Jan 15")
    }

    // MARK: - fetchEventsForSessionOnDay

    @Test("fetchEventsForSessionOnDay scopes to the queried local day across DST")
    func fetchEventsForSessionOnDay_localDayRange() throws {
        let cal = nyCalendar()
        let db = try makeDatabase()
        try seed(in: db, sessionId: "s",
                 timestamp: "2025-01-15T04:30:00Z", tokens: 2000)

        let onJan14 = try db.pool.read { conn in
            try Aggregator.fetchEventsForSessionOnDay(
                db: conn, sessionId: "s", day: "2025-01-14", calendar: cal)
        }
        let onJan15 = try db.pool.read { conn in
            try Aggregator.fetchEventsForSessionOnDay(
                db: conn, sessionId: "s", day: "2025-01-15", calendar: cal)
        }
        #expect(onJan14.count == 1, "the 23:30 EST event is on local Jan 14")
        #expect(onJan15.isEmpty, "nothing on local Jan 15")
    }
}
