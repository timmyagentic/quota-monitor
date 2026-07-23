import Foundation
import GRDB

// "Usage activity" stats for the Dashboard's ActivitySection — the
// lifetime / engagement numbers a CodeX-style profile shows: lifetime
// tokens, the busiest single day, active-day streaks, plus a ~1-year
// daily token series for the contribution-style heatmap.
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
    /// Consecutive active days ending today (or yesterday, so a day you
    /// simply haven't started yet doesn't read as a broken streak).
    let currentStreakDays: Int
    /// Longest run of consecutive active days, all-time.
    let longestStreakDays: Int
    /// Number of all-time local-calendar days with any token usage.
    let activeDays: Int
    /// Trailing ~1-year daily token series, oldest first, zero-filled.
    /// Powers the heatmap.
    let daily: [DailyPoint]

    static let empty = ActivitySnapshot(
        lifetimeTokens: 0, peakDayTokens: 0, peakDay: nil,
        currentStreakDays: 0, longestStreakDays: 0, activeDays: 0, daily: [])

    var hasData: Bool { lifetimeTokens > 0 }
}

extension Aggregator {

    /// Build the full activity profile for one provider filter from a single
    /// all-time query. Every derived number — lifetime tokens, peak day,
    /// streaks, AND the trailing daily series (heatmap) — buckets events by
    /// local calendar day client-side, so they stay mutually consistent and
    /// DST-correct.
    static func fetchActivity(
        db: Database,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        heatmapDays: Int = 365,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ActivitySnapshot {
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        // Fetch raw events; day bucketing happens client-side via Calendar
        // so each timestamp uses the correct DST offset for its own instant,
        // rather than today's offset applied uniformly to all history.
        let rows = try Row.fetchAll(db, sql: """
            SELECT timestamp, value_usd, total_tokens
            FROM usage_events
            \(scope.whereClause(table: "usage_events"))
            """)

        // Group by local calendar day — Calendar.startOfDay(for:) accounts
        // for the DST offset that was in effect at each specific timestamp.
        var dayTokens: [Date: Int64] = [:]
        var dayValue: [Date: Double] = [:]
        var lifetime: Int64 = 0
        for row in rows {
            let ts: String = row["timestamp"] ?? ""
            let tokens: Int64 = row["total_tokens"] ?? 0
            let value: Double = row["value_usd"] ?? 0
            guard let date = parseTimestamp(ts) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            dayTokens[dayStart, default: 0] += tokens
            dayValue[dayStart, default: 0] += value
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
        let daily = dailySeries(
            dayTokens: dayTokens, dayValue: dayValue,
            days: heatmapDays, now: now, calendar: calendar)

        return ActivitySnapshot(
            lifetimeTokens: lifetime,
            peakDayTokens: peakTokens,
            peakDay: peakDay,
            currentStreakDays: current,
            longestStreakDays: longest,
            activeDays: activeDays.count,
            daily: daily)
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

    /// Zero-filled trailing `days`-day series ending today (oldest first),
    /// built from the same per-event local-day maps as the stats above. Keys
    /// in `dayTokens` / `dayValue` are `Calendar.startOfDay(for:)` of each
    /// event's own instant, so the heatmap is DST-correct — unlike the
    /// single-`secondsFromGMT()` SQL bucketing in `fetchDaily`, which would
    /// mis-assign near-midnight events from the opposite DST half of the year.
    /// `nonisolated` with injectable `now` / `calendar` so it's unit-testable.
    nonisolated static func dailySeries(
        dayTokens: [Date: Int64],
        dayValue: [Date: Double],
        days: Int,
        now: Date,
        calendar: Calendar,
        dayCacheUsage: [Date: CacheUsageSummary] = [:]
    ) -> [DailyPoint] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var points: [DailyPoint] = []
        points.reserveCapacity(days)
        for offset in (0..<days).reversed() {
            guard let date = calendar.date(
                byAdding: .day, value: -offset, to: today) else { continue }
            points.append(DailyPoint(
                date: date,
                valueUSD: dayValue[date] ?? 0,
                tokens: dayTokens[date] ?? 0,
                cacheUsage: dayCacheUsage[date] ?? .zero))
        }
        return points
    }
}
