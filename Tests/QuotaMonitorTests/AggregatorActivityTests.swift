import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Tests for the activity profile that powers the Dashboard's
/// ActivitySection: the pure streak math (deterministic, clock-injected)
/// and the `fetchActivity` rollup over seeded `usage_events`.
@Suite("Aggregator activity")
struct AggregatorActivityTests {

    // MARK: - helpers

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("activity-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert one session + one usage_event at an explicit ISO8601 timestamp.
    private func seed(
        in db: DatabaseManager,
        provider: String = "codex",
        sessionId: String,
        timestamp: String,
        tokens: Int64
    ) throws {
        try db.pool.write { conn in
            try conn.execute(sql: """
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
            try conn.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred)
                VALUES (?, ?, 'gpt-5', ?, 0, 0, 0, ?, 0, ?, 0, 0)
                """, arguments: [sessionId, timestamp, tokens, tokens, provider])
        }
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - pure streak math

    @Test("streaks: empty set is zero/zero")
    func streaks_empty() {
        let (current, longest) = Aggregator.streaks(activeDays: [])
        #expect(current == 0)
        #expect(longest == 0)
    }

    @Test("streaks: three consecutive days ending today")
    func streaks_consecutiveEndingToday() {
        let cal = utcCalendar()
        let now = day(2026, 5, 30, cal: cal)
        let active = [day(2026, 5, 28, cal: cal),
                      day(2026, 5, 29, cal: cal),
                      day(2026, 5, 30, cal: cal)]
        let (current, longest) = Aggregator.streaks(
            activeDays: active, now: now, calendar: cal)
        #expect(current == 3)
        #expect(longest == 3)
    }

    @Test("streaks: a gap before the recent run doesn't extend the current count")
    func streaks_gapBeforeCurrentRun() {
        let cal = utcCalendar()
        let now = day(2026, 5, 30, cal: cal)
        let active = [day(2026, 5, 20, cal: cal),  // isolated, run of 1
                      day(2026, 5, 28, cal: cal),
                      day(2026, 5, 29, cal: cal),
                      day(2026, 5, 30, cal: cal)]
        let (current, longest) = Aggregator.streaks(
            activeDays: active, now: now, calendar: cal)
        #expect(current == 3)
        #expect(longest == 3)
    }

    @Test("streaks: today idle but yesterday active still counts the run")
    func streaks_todayIdleYesterdayActive() {
        let cal = utcCalendar()
        let now = day(2026, 5, 30, cal: cal)
        let active = [day(2026, 5, 28, cal: cal),
                      day(2026, 5, 29, cal: cal)]   // nothing today
        let (current, longest) = Aggregator.streaks(
            activeDays: active, now: now, calendar: cal)
        #expect(current == 2, "yesterday-anchored streak counts back through 5/28")
        #expect(longest == 2)
    }

    @Test("streaks: last activity two days ago resets current to zero")
    func streaks_staleResetsCurrent() {
        let cal = utcCalendar()
        let now = day(2026, 5, 30, cal: cal)
        let active = [day(2026, 5, 27, cal: cal),
                      day(2026, 5, 28, cal: cal)]
        let (current, longest) = Aggregator.streaks(
            activeDays: active, now: now, calendar: cal)
        #expect(current == 0, "neither today nor yesterday active → current is 0")
        #expect(longest == 2)
    }

    @Test("streaks: longest run can exceed the current run")
    func streaks_longestExceedsCurrent() {
        let cal = utcCalendar()
        let now = day(2026, 5, 30, cal: cal)
        var active = [day(2026, 5, 29, cal: cal),
                      day(2026, 5, 30, cal: cal)]   // current run of 2
        for d in 1...5 { active.append(day(2026, 1, d, cal: cal)) }  // 5-day run
        let (current, longest) = Aggregator.streaks(
            activeDays: active, now: now, calendar: cal)
        #expect(current == 2)
        #expect(longest == 5)
    }

    // MARK: - fetchActivity rollup

    @Test("fetchActivity: lifetime tokens, peak day total, and longest task span")
    func fetchActivity_rollup() throws {
        let db = try makeDatabase()
        // Busiest day: two events, same day, 5 minutes apart → 7000 tokens.
        try seed(in: db, sessionId: "peak-a",
                 timestamp: "2025-06-15T10:00:00Z", tokens: 3000)
        try seed(in: db, sessionId: "peak-b",
                 timestamp: "2025-06-15T10:05:00Z", tokens: 4000)
        // A quiet earlier day.
        try seed(in: db, sessionId: "small",
                 timestamp: "2025-01-10T10:00:00Z", tokens: 1000)
        // One long session spanning 3h30m (12600s), small tokens so it
        // doesn't disturb the peak-day total.
        try seed(in: db, sessionId: "long",
                 timestamp: "2025-03-01T08:00:00Z", tokens: 500)
        try seed(in: db, sessionId: "long",
                 timestamp: "2025-03-01T11:30:00Z", tokens: 500)

        let activity = try db.pool.read { conn in
            try Aggregator.fetchActivity(db: conn)
        }

        #expect(activity.lifetimeTokens == 9000)
        #expect(activity.peakDayTokens == 7000,
                "busiest local day sums both same-day events")
        #expect(abs(activity.longestTaskSeconds - 12600) < 1.0,
                "longest session wall-clock = 3h30m")
    }

    @Test("fetchActivity: current streak counts consecutive days up to today")
    func fetchActivity_currentStreak() throws {
        let db = try makeDatabase()
        // Anchor on local-noon of three consecutive calendar days ending
        // today. Noon keeps each instant unambiguously on its own local day
        // (no midnight straddle) regardless of the runner's timezone.
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        for k in 0...2 {
            guard let dayStart = cal.date(byAdding: .day, value: -k, to: todayStart),
                  let noon = cal.date(byAdding: .hour, value: 12, to: dayStart)
            else { continue }
            try seed(in: db, sessionId: "streak-\(k)",
                     timestamp: iso(noon), tokens: 1000)
        }

        let activity = try db.pool.read { conn in
            try Aggregator.fetchActivity(db: conn)
        }

        #expect(activity.currentStreakDays == 3)
        #expect(activity.longestStreakDays >= 3)
    }

    @Test("fetchActivity: day bucketing is correct across a DST boundary")
    func fetchActivity_dstCorrectBucketing() throws {
        // Use America/New_York: EST (UTC-5) in winter, EDT (UTC-4) in summer.
        // DST spring-forward in 2025: March 9 at 02:00 local → 03:00 local.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        // Event A: Jan 15 at 04:30 UTC = Jan 14 23:30 EST (local).
        // Should land on Jan 14 local day.
        // Event B: Jun 15 at 03:30 UTC = Jun 14 23:30 EDT (local).
        // Should land on Jun 14 local day.
        // A single-offset approach using the summer offset (-4h) would
        // incorrectly place event A on Jan 15 (04:30 − 4h = Jan 15 00:30).
        let db = try makeDatabase()
        try seed(in: db, sessionId: "winter",
                 timestamp: "2025-01-15T04:30:00Z", tokens: 2000)
        try seed(in: db, sessionId: "summer",
                 timestamp: "2025-06-15T03:30:00Z", tokens: 1000)

        let activity = try db.pool.read { conn in
            try Aggregator.fetchActivity(db: conn, calendar: cal)
        }

        // Both events are near midnight in their respective local days but
        // should each stay on the *previous* local day. Peak tokens should
        // be 2000 (the winter event alone on Jan 14), not 3000 (both on
        // the same mis-bucketed day).
        #expect(activity.peakDayTokens == 2000,
                "winter event should be on its own local day, not grouped with summer")
        #expect(activity.lifetimeTokens == 3000)
    }

    @Test("fetchActivity: empty database returns the zero snapshot")
    func fetchActivity_empty() throws {
        let db = try makeDatabase()
        let activity = try db.pool.read { conn in
            try Aggregator.fetchActivity(db: conn)
        }
        #expect(activity.lifetimeTokens == 0)
        #expect(activity.currentStreakDays == 0)
        #expect(activity.longestStreakDays == 0)
        #expect(activity.peakDayTokens == 0)
        #expect(activity.hasData == false)
    }
}
