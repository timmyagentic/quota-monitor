import Foundation
import GRDB

// "Usage activity" stats for the Dashboard's ActivitySection — the
// lifetime / engagement numbers a CodeX-style profile shows: lifetime
// tokens, the busiest single day, the longest single task, and active-day
// streaks, plus a ~1-year daily token series for the contribution-style
// heatmap.
//
// Everything is derived from the existing `usage_events` table — no schema
// change, no new ingestion. Day bucketing is done client-side via
// `Calendar.startOfDay(for:)` so each historical event is grouped into the
// correct local day even across DST transitions (a single current-offset
// would mis-group events from the other DST half of the year).

struct ActivitySnapshot: Sendable, Equatable {
    /// All-time `SUM(total_tokens)`. Includes cached-read tokens, matching
    /// how the menu bar / overview count tokens — so the headline lines up
    /// with the rest of the app and reaches CodeX-scale figures.
    let lifetimeTokens: Int64
    /// Busiest single local-calendar day, by total tokens.
    let peakDayTokens: Int64
    let peakDay: Date?
    /// Longest single session's wall-clock span (last event − first event),
    /// in seconds.
    let longestTaskSeconds: Double
    /// Consecutive active days ending today (or yesterday, so a day you
    /// simply haven't started yet doesn't read as a broken streak).
    let currentStreakDays: Int
    /// Longest run of consecutive active days, all-time.
    let longestStreakDays: Int
    /// Trailing ~1-year daily token series, oldest first, zero-filled.
    /// Powers the heatmap — Daily / Weekly / Cumulative are all derived
    /// from this in the view.
    let daily: [DailyPoint]

    static let empty = ActivitySnapshot(
        lifetimeTokens: 0, peakDayTokens: 0, peakDay: nil,
        longestTaskSeconds: 0, currentStreakDays: 0,
        longestStreakDays: 0, daily: [])

    var hasData: Bool { lifetimeTokens > 0 }
}

extension Aggregator {

    /// Build the full activity profile for one provider filter. Three cheap
    /// queries: an all-time per-day token rollup (peak + streaks + lifetime),
    /// a per-session span scan (longest task), and the trailing daily series
    /// (heatmap). All bucket by local calendar day.
    static func fetchActivity(
        db: Database,
        provider: ProviderFilter = .all,
        heatmapDays: Int = 365,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ActivitySnapshot {
        // Fetch raw events; day bucketing happens client-side via Calendar
        // so each timestamp uses the correct DST offset for its own instant,
        // rather than today's offset applied uniformly to all history.
        let rows = try Row.fetchAll(db, sql: """
            SELECT timestamp, total_tokens
            FROM usage_events
            \(provider.whereClause(table: "usage_events"))
            """)

        // Group by local calendar day — Calendar.startOfDay(for:) accounts
        // for the DST offset that was in effect at each specific timestamp.
        var dayTokens: [Date: Int64] = [:]
        var lifetime: Int64 = 0
        for row in rows {
            let ts: String = row["timestamp"] ?? ""
            let tokens: Int64 = row["total_tokens"] ?? 0
            guard let date = parseTimestamp(ts) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            dayTokens[dayStart, default: 0] += tokens
            lifetime += tokens
        }

        var peakTokens: Int64 = 0
        var peakDay: Date?
        var activeDays: [Date] = []
        for (day, tokens) in dayTokens where tokens > 0 {
            if tokens > peakTokens {
                peakTokens = tokens
                peakDay = day
            }
            activeDays.append(day)
        }
        activeDays.sort()

        let (current, longest) = streaks(
            activeDays: activeDays, now: now, calendar: calendar)
        let longestTask = try fetchLongestTaskSeconds(db: db, provider: provider)
        let daily = try fetchDaily(db: db, days: heatmapDays, provider: provider)

        return ActivitySnapshot(
            lifetimeTokens: lifetime,
            peakDayTokens: peakTokens,
            peakDay: peakDay,
            longestTaskSeconds: longestTask,
            currentStreakDays: current,
            longestStreakDays: longest,
            daily: daily)
    }

    /// Longest single session wall-clock = `MAX(timestamp) − MIN(timestamp)`
    /// across that session's events. Parsed client-side via `parseTimestamp`
    /// so we don't depend on SQLite's `julianday()` coping with the
    /// trailing-`Z` ISO8601 shape our importer writes.
    static func fetchLongestTaskSeconds(
        db: Database, provider: ProviderFilter = .all
    ) throws -> Double {
        let rows = try Row.fetchAll(db, sql: """
            SELECT MIN(timestamp) AS first_at, MAX(timestamp) AS last_at
            FROM usage_events
            \(provider.whereClause(table: "usage_events"))
            GROUP BY session_id
            """)
        var maxSpan: Double = 0
        for row in rows {
            guard let first: String = row["first_at"],
                  let last: String = row["last_at"],
                  let firstDate = parseTimestamp(first),
                  let lastDate = parseTimestamp(last) else { continue }
            let span = lastDate.timeIntervalSince(firstDate)
            if span > maxSpan { maxSpan = span }
        }
        return maxSpan
    }

    /// Pure streak math over a set of active local-calendar days. Returns
    /// the consecutive-day run ending at today (or yesterday — so a day you
    /// simply haven't started yet doesn't reset the streak to 0) plus the
    /// longest run anywhere in history. `nonisolated` with injectable `now`
    /// / `calendar` so it's unit-testable without the system clock.
    nonisolated static func streaks(
        activeDays: [Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let days = Set(activeDays.map { calendar.startOfDay(for: $0) })
        let sorted = days.sorted()

        var longest = 1
        var run = 1
        for i in 1..<sorted.count {
            let previous = sorted[i - 1]
            let current = sorted[i]
            if let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: current) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if let yesterday, days.contains(yesterday) {
            cursor = yesterday
        } else {
            return (0, longest)
        }
        var currentStreak = 0
        while days.contains(cursor) {
            currentStreak += 1
            guard let previous = calendar.date(
                byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (currentStreak, longest)
    }
}
