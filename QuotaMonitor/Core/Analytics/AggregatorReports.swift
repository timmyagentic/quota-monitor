import Foundation
import GRDB

// Top-level dashboard / overview / per-model / per-provider queries.
// All methods compose inside one read transaction via `loadDashboard`.

extension Aggregator {

    static func loadDashboard(
        from pool: DatabasePool,
        provider: ProviderFilter = .all
    ) async throws -> DashboardSnapshot {
        try await pool.read { db in
            let overview = try fetchOverview(db: db, provider: provider)
            let daily = try fetchDaily(db: db, days: 14, provider: provider)
            // 60-day window powers Trends "Today/7d/30d (Δ vs prior 30d)".
            let dailyExtended = try fetchDaily(db: db, days: 60, provider: provider)
            let monthly = try fetchMonthly(db: db, months: 12, provider: provider)
            let shares = try fetchModelShares(db: db, provider: provider)
            // 30d + prior-30d slices fuel the Composition section's bar
            // list, banner ("X drives Y% of cost"), and the auto-insight
            // delta sentence.
            let shares30d = try fetchModelShares(
                db: db, provider: provider, sinceDays: 30, untilDaysAgo: 0)
            let sharesPrior30d = try fetchModelShares(
                db: db, provider: provider, sinceDays: 60, untilDaysAgo: 30)
            let providerShares30d = try fetchProviderShares30d(db: db)
            // Codex quota/history queries filter the shared rate-limit table
            // to Codex sources (`live` + `jsonl`). Hide the Codex section for
            // the Claude-only dashboard view.
            let history = provider == .claude
                ? []
                : try fetchRateLimitHistory(db: db, hours: 24)
            let quota = provider == .claude
                ? nil
                : try fetchCodexQuota(db: db)
            let activity = try fetchActivity(db: db, provider: provider)
            return DashboardSnapshot(
                overview: overview,
                daily: daily,
                dailyExtended: dailyExtended,
                monthly: monthly,
                modelShares: shares,
                modelShares30d: shares30d,
                modelSharesPrior30d: sharesPrior30d,
                providerShares30d: providerShares30d,
                recentRateLimits: history,
                codexQuota: quota,
                activity: activity)
        }
    }

    static func fetchOverview(
        db: Database, provider: ProviderFilter = .all
    ) throws -> OverviewStats {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COALESCE(SUM(value_usd), 0)  AS total_value,
                COALESCE(SUM(total_tokens), 0) AS total_tokens,
                COUNT(*)                     AS total_events,
                MIN(timestamp)               AS first_at,
                MAX(timestamp)               AS last_at
            FROM usage_events
            \(provider.whereClause(table: "usage_events"))
            """)
        let sessionCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sessions
            \(provider.whereClause(table: "sessions"))
            """) ?? 0

        return OverviewStats(
            totalValueUSD: row?["total_value"] ?? 0,
            totalTokens: row?["total_tokens"] ?? 0,
            totalSessions: sessionCount,
            totalEvents: row?["total_events"] ?? 0,
            firstEventAt: row?["first_at"],
            lastEventAt: row?["last_at"])
    }

    /// Buckets usage_events by local-calendar day. Returns `days` consecutive days
    /// ending at today, even when no events exist on a given day (zero-fill).
    static func fetchDaily(
        db: Database, days: Int, provider: ProviderFilter = .all
    ) throws -> [DailyPoint] {
        // SQLite's `date()` parses ISO8601 timestamps and returns a YYYY-MM-DD string in UTC.
        // For local-day bucketing we offset by the local UTC offset.
        // NB: SQLite modifier syntax is `±N seconds`. Parentheses cause silent NULL
        // results (we hit this before — chart was showing zero-filled bars).
        let cal = Calendar(identifier: .gregorian)
        let offsetSeconds = TimeZone.current.secondsFromGMT()
        let plusOffset  = String(format: "%+d seconds", offsetSeconds)
        let minusOffset = String(format: "%+d seconds", -offsetSeconds)

        let rows = try Row.fetchAll(db, sql: """
            SELECT
              date(timestamp, ?) AS day,
              SUM(value_usd) AS value_usd,
              SUM(total_tokens) AS tokens
            FROM usage_events
            -- strftime (not datetime): the ISO8601 `now` threshold lexically
            -- matches stored T/Z timestamps. See fetchPerProviderStats.
            WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?, 'start of day', ?)
            \(provider.clause(table: "usage_events"))
            GROUP BY day
            ORDER BY day
            """, arguments: [
                plusOffset,
                "-\(days - 1) days",
                minusOffset
            ])

        var byDay: [String: (Double, Int64)] = [:]
        for row in rows {
            let day: String = row["day"] ?? ""
            byDay[day] = (row["value_usd"] ?? 0, row["tokens"] ?? 0)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = cal
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let today = cal.startOfDay(for: Date())
        var points: [DailyPoint] = []
        for offset in (0..<days).reversed() {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = dayFormatter.string(from: date)
            let (value, tokens) = byDay[key] ?? (0, 0)
            points.append(DailyPoint(date: date, valueUSD: value, tokens: tokens))
        }
        return points
    }

    /// Buckets `usage_events` by local-calendar month, returning `months`
    /// consecutive months ending with the current month (zero-filled).
    /// `session_count` uses DISTINCT session_id so cross-month sessions
    /// count once per month they touched. Mirrors ccusage's `monthly.ts`.
    static func fetchMonthly(
        db: Database, months: Int, provider: ProviderFilter = .all,
        timeZone: TimeZone = .current
    ) throws -> [MonthlyPoint] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let offsetSeconds = timeZone.secondsFromGMT()
        let plusOffset = String(format: "%+d seconds", offsetSeconds)
        // Lower bound: shift the UTC `start of month` back by the local offset
        // so it lands on the *local* month start (mirrors fetchDaily). Without
        // this, first-of-month rows whose UTC instant falls in the previous
        // month are dropped from the earliest bucket in non-UTC time zones.
        let minusOffset = String(format: "%+d seconds", -offsetSeconds)
        let rows = try Row.fetchAll(db, sql: """
            SELECT
              strftime('%Y-%m', timestamp, ?) AS month,
              SUM(value_usd) AS value_usd,
              SUM(total_tokens) AS tokens,
              COUNT(DISTINCT session_id) AS sessions
            FROM usage_events
            WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?, 'start of month', ?)
            \(provider.clause(table: "usage_events"))
            GROUP BY month
            ORDER BY month
            """, arguments: [plusOffset, "-\(months - 1) months", minusOffset])

        var byMonth: [String: (Double, Int64, Int)] = [:]
        for row in rows {
            let m: String = row["month"] ?? ""
            byMonth[m] = (
                row["value_usd"] ?? 0,
                row["tokens"] ?? 0,
                row["sessions"] ?? 0)
        }

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = cal
        monthFormatter.timeZone = timeZone
        monthFormatter.dateFormat = "yyyy-MM"

        // Anchor on first-of-current-month in the local calendar.
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let thisMonth = cal.date(from: comps) ?? now
        var points: [MonthlyPoint] = []
        for offset in (0..<months).reversed() {
            guard let date = cal.date(byAdding: .month, value: -offset, to: thisMonth) else { continue }
            let key = monthFormatter.string(from: date)
            let (value, tokens, sessions) = byMonth[key] ?? (0, 0, 0)
            points.append(MonthlyPoint(month: date, valueUSD: value,
                                       tokens: tokens, sessionCount: sessions))
        }
        return points
    }

    static func fetchModelShares(
        db: Database, provider: ProviderFilter = .all
    ) throws -> [ModelShare] {
        try Row.fetchAll(db, sql: """
            SELECT
              ue.model_id,
              COALESCE(pc.display_name, ue.model_id) AS display_name,
              SUM(ue.value_usd)     AS value_usd,
              SUM(ue.total_tokens)  AS tokens,
              COUNT(*)              AS event_count
            FROM usage_events ue
            LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id
            \(provider.whereClause(table: "ue"))
            GROUP BY ue.model_id
            ORDER BY value_usd DESC
            """).map { row in
            ModelShare(
                modelId: row["model_id"] ?? "unknown",
                displayName: row["display_name"] ?? "Unknown",
                valueUSD: row["value_usd"] ?? 0,
                tokens: row["tokens"] ?? 0,
                eventCount: row["event_count"] ?? 0)
        }
    }

    /// Per-model spend over a sliding window expressed as a half-open
    /// `[now - sinceDays, now - untilDaysAgo)` range. With
    /// `sinceDays = 30, untilDaysAgo = 0` this is "the last 30 days";
    /// with `sinceDays = 60, untilDaysAgo = 30` this is "the 30 days
    /// before the most recent 30". Used by the Composition section to
    /// compute pp-deltas vs the prior month.
    static func fetchModelShares(
        db: Database,
        provider: ProviderFilter,
        sinceDays: Int,
        untilDaysAgo: Int
    ) throws -> [ModelShare] {
        // Build WHERE clause manually so we can compose the time predicate
        // with the provider clause (which contributes "AND ue.provider =
        // ...").
        var sql = """
            SELECT
              ue.model_id,
              COALESCE(pc.display_name, ue.model_id) AS display_name,
              SUM(ue.value_usd)     AS value_usd,
              SUM(ue.total_tokens)  AS tokens,
              COUNT(*)              AS event_count
            FROM usage_events ue
            LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id
            -- strftime (not datetime): the ISO8601 `now` bounds lexically
            -- match stored T/Z timestamps; datetime() would drop today's events.
            WHERE ue.timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)
              AND ue.timestamp <  strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)
            """
        sql += provider.clause(table: "ue")
        sql += """

            GROUP BY ue.model_id
            ORDER BY value_usd DESC
            """
        let args: [(any DatabaseValueConvertible)?] = [
            "-\(sinceDays) days",
            "-\(untilDaysAgo) days"
        ]
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
            ModelShare(
                modelId: row["model_id"] ?? "unknown",
                displayName: row["display_name"] ?? "Unknown",
                valueUSD: row["value_usd"] ?? 0,
                tokens: row["tokens"] ?? 0,
                eventCount: row["event_count"] ?? 0)
        }
    }

    /// Per-provider $ over the trailing 30 days. Always returns rows for
    /// both `codex` and `claude` (zero-filled when the provider has no
    /// recent activity) so the Composition donut layout is stable.
    static func fetchProviderShares30d(db: Database) throws -> [ProviderShare] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT provider, COALESCE(SUM(value_usd), 0) AS v
            FROM usage_events
            WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
            GROUP BY provider
            """)
        var by: [String: Double] = [:]
        for r in rows {
            let p: String = r["provider"] ?? "codex"
            by[p] = r["v"] ?? 0
        }
        return ["codex", "claude"].map { ProviderShare(provider: $0, valueUSD: by[$0] ?? 0) }
    }

    /// Per-provider stats in a single query — used by the menu bar so the two
    /// KPI rows are always populated, regardless of the active dashboard filter.
    static func fetchPerProviderStats(db: Database) throws -> [String: ProviderStats] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT
              provider,
              COALESCE(SUM(value_usd), 0)    AS total_value,
              COALESCE(SUM(total_tokens), 0) AS total_tokens,
              COUNT(*)                       AS total_events,
              MAX(timestamp)                 AS last_at
            FROM usage_events
            GROUP BY provider
            """)
        // Last 7 calendar days per provider — Anthropic doesn't expose a
        // weekly quota counter, so we surface raw spend instead. Same query
        // shape on both providers keeps the menu bar code symmetric.
        // Includes distinct session count so the menu bar can swap to a
        // 7-day headline window without the session-count chip going stale.
        // strftime (not datetime) so the threshold uses ISO8601 format
        // with `T` and `Z` — matches the format we wrote in the importer
        // and lets SQLite's lex compare include boundary events correctly.
        // datetime() returns "YYYY-MM-DD HH:MM:SS" which lex-compares
        // wrongly against stored "YYYY-MM-DDTHH:MM:SS.SSSZ" timestamps.
        let weekRows = try Row.fetchAll(db, sql: """
            SELECT
              provider,
              COALESCE(SUM(value_usd), 0)            AS w_value,
              COALESCE(SUM(total_tokens), 0)         AS w_tokens,
              COUNT(DISTINCT session_id)             AS w_sessions
            FROM usage_events
            WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
            GROUP BY provider
            """)
        var weekBy: [String: (Double, Int64, Int)] = [:]
        for r in weekRows {
            let p: String = r["provider"] ?? "codex"
            weekBy[p] = (r["w_value"] ?? 0,
                         r["w_tokens"] ?? 0,
                         r["w_sessions"] ?? 0)
        }
        // Rolling 30-day spend per provider — drives the menu bar's
        // headline KPI (lifetime totals grow forever and stop being a
        // useful "how heavy is my usage right now" signal). Tokens +
        // distinct session count pulled in the same pass so the menu
        // bar's secondary KPI line shares the 30d window.
        let monthRows = try Row.fetchAll(db, sql: """
            SELECT
              provider,
              COALESCE(SUM(value_usd), 0)            AS m_value,
              COALESCE(SUM(total_tokens), 0)         AS m_tokens,
              COUNT(DISTINCT session_id)             AS m_sessions
            FROM usage_events
            WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
            GROUP BY provider
            """)
        var monthBy: [String: (Double, Int64, Int)] = [:]
        for r in monthRows {
            let p: String = r["provider"] ?? "codex"
            monthBy[p] = (r["m_value"] ?? 0,
                          r["m_tokens"] ?? 0,
                          r["m_sessions"] ?? 0)
        }
        let sessionRows = try Row.fetchAll(db, sql: """
            SELECT provider, COUNT(*) AS c
            FROM sessions
            GROUP BY provider
            """)
        var sessionsBy: [String: Int] = [:]
        for r in sessionRows {
            let p: String = r["provider"] ?? "codex"
            sessionsBy[p] = r["c"] ?? 0
        }
        var out: [String: ProviderStats] = [:]
        for r in rows {
            let p: String = r["provider"] ?? "codex"
            let week = weekBy[p] ?? (0, 0, 0)
            let month = monthBy[p] ?? (0, 0, 0)
            out[p] = ProviderStats(
                provider: p,
                totalValueUSD: r["total_value"] ?? 0,
                totalTokens: r["total_tokens"] ?? 0,
                eventCount: r["total_events"] ?? 0,
                sessionCount: sessionsBy[p] ?? 0,
                lastActivityAt: r["last_at"],
                last7dValueUSD: week.0,
                last7dTokens: week.1,
                last7dSessionCount: week.2,
                last30dValueUSD: month.0,
                last30dTokens: month.1,
                last30dSessionCount: month.2)
        }
        // Always emit zero-rows for known providers so the UI can render
        // "no data yet" rather than hiding the row entirely.
        for p in ["codex", "claude"] where out[p] == nil {
            out[p] = ProviderStats(
                provider: p, totalValueUSD: 0, totalTokens: 0,
                eventCount: 0, sessionCount: 0, lastActivityAt: nil)
        }
        return out
    }
}
