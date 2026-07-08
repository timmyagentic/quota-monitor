import Foundation
import GRDB

// Top-level dashboard / overview / per-model / per-provider queries.
// All methods compose inside one read transaction via `loadDashboard`.

extension Aggregator {

    static func loadDashboard(
        from pool: DatabasePool,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil
    ) async throws -> DashboardSnapshot {
        try await pool.read { db in
            let overview = try fetchOverview(
                db: db, provider: provider, enabledProviders: enabledProviders)
            let daily = try fetchDaily(
                db: db, days: 14, provider: provider,
                enabledProviders: enabledProviders)
            // One-year window powers the Token Monitor-inspired Trends
            // page. The statline still reads only the trailing 60 days.
            let dailyExtended = try fetchDaily(
                db: db, days: 365, provider: provider,
                enabledProviders: enabledProviders)
            let dailyProviderExtended = try fetchDailyBreakdown(
                db: db, days: 365, grouping: .provider, provider: provider,
                enabledProviders: enabledProviders)
            let dailyModelExtended = try fetchDailyBreakdown(
                db: db, days: 365, grouping: .model, provider: provider,
                enabledProviders: enabledProviders)
            let monthly = try fetchMonthly(
                db: db, months: 12, provider: provider,
                enabledProviders: enabledProviders)
            let shares = try fetchModelShares(
                db: db, provider: provider, enabledProviders: enabledProviders)
            // 30d + prior-30d slices fuel the Composition section's bar
            // list, banner ("X drives Y% of cost"), and the auto-insight
            // delta sentence.
            let shares30d = try fetchModelShares(
                db: db, provider: provider, sinceDays: 30, untilDaysAgo: 0,
                enabledProviders: enabledProviders)
            let sharesPrior30d = try fetchModelShares(
                db: db, provider: provider, sinceDays: 60, untilDaysAgo: 30,
                enabledProviders: enabledProviders)
            let providerShares30d = try fetchProviderShares30d(
                db: db, provider: provider, enabledProviders: enabledProviders)
            // Codex quota/history queries filter the shared rate-limit table
            // to Codex sources (`live` + `jsonl`). Hide the Codex section for
            // the Claude-only dashboard view.
            let history = provider == .claude
                ? []
                : try fetchRateLimitHistory(db: db, hours: 24)
            let quota = provider == .claude
                ? nil
                : try fetchCodexQuota(db: db)
            let activity = try fetchActivity(
                db: db, provider: provider, enabledProviders: enabledProviders)
            return DashboardSnapshot(
                overview: overview,
                daily: daily,
                dailyExtended: dailyExtended,
                dailyProviderExtended: dailyProviderExtended,
                dailyModelExtended: dailyModelExtended,
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
        db: Database,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil
    ) throws -> OverviewStats {
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COALESCE(SUM(value_usd), 0)  AS total_value,
                COALESCE(SUM(total_tokens), 0) AS total_tokens,
                COUNT(*)                     AS total_events,
                MIN(timestamp)               AS first_at,
                MAX(timestamp)               AS last_at
            FROM usage_events
            \(scope.whereClause(table: "usage_events"))
            """)
        let sessionCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sessions
            \(scope.whereClause(table: "sessions"))
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
    ///
    /// Day bucketing happens client-side via `Calendar.startOfDay(for:)`, so each
    /// event is grouped using the UTC offset in effect at its OWN instant — i.e.
    /// DST-correct, mirroring `fetchActivity`. The previous SQL `date(timestamp,
    /// ±offset)` applied today's single offset to all history, mis-bucketing
    /// near-midnight events from the opposite DST half of the year.
    static func fetchDaily(
        db: Database, days: Int, provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> [DailyPoint] {
        guard days > 0 else { return [] }
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        // Lower bound = local start-of-day of the earliest bucket, serialized to
        // ISO8601 UTC for lexical comparison against stored T/Z timestamps.
        // Derived from the injected `now` (not SQL 'now') so the window is
        // deterministic + test-injectable. Each row is then bucketed client-side
        // by its OWN local day, so a DST offset shift never mis-assigns a
        // near-midnight event (the old SQL `date(timestamp, ±offset)` applied
        // today's single offset to all of history).
        let earliestDay = calendar.date(
            byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
        let lowerBound = ISO8601.fractional.string(from: earliestDay ?? .distantPast)
        let rows = try Row.fetchAll(db, sql: """
            SELECT timestamp, value_usd, total_tokens
            FROM usage_events
            WHERE timestamp >= ?
            \(scope.clause(table: "usage_events"))
            """, arguments: [lowerBound])

        var dayValue: [Date: Double] = [:]
        var dayTokens: [Date: Int64] = [:]
        for row in rows {
            let ts: String = row["timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            dayValue[dayStart, default: 0] += row["value_usd"] ?? 0
            dayTokens[dayStart, default: 0] += row["total_tokens"] ?? 0
        }
        return dailySeries(dayTokens: dayTokens, dayValue: dayValue,
                           days: days, now: now, calendar: calendar)
    }

    static func fetchDailyBreakdown(
        db: Database,
        days: Int,
        grouping: TrendBreakdownGrouping,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [DailyBreakdownPoint] {
        guard days > 0 else { return [] }
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        let earliestDay = calendar.date(
            byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
        let lowerBound = ISO8601.fractional.string(from: earliestDay ?? .distantPast)

        let keySQL: String
        let labelSQL: String
        let joinSQL: String
        switch grouping {
        case .provider:
            keySQL = "ue.provider"
            labelSQL = "ue.provider"
            joinSQL = ""
        case .model:
            keySQL = "ue.model_id"
            labelSQL = "COALESCE(pc.display_name, ue.model_id)"
            joinSQL = "LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id"
        }

        let rows = try Row.fetchAll(db, sql: """
            SELECT
                ue.timestamp,
                ue.provider,
                ue.value_usd,
                ue.total_tokens,
                \(keySQL) AS breakdown_key,
                \(labelSQL) AS breakdown_label
            FROM usage_events ue
            \(joinSQL)
            WHERE ue.timestamp >= ?
            \(scope.clause(table: "ue"))
            """, arguments: [lowerBound])

        struct Bucket: Hashable {
            let date: Date
            let provider: String
            let key: String
        }
        var totals: [Bucket: (label: String, valueUSD: Double, tokens: Int64)] = [:]
        for row in rows {
            let ts: String = row["timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let rawKey: String = row["breakdown_key"] ?? "unknown"
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "unknown"
                : rawKey
            let rawLabel: String = row["breakdown_label"] ?? key
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? key
                : rawLabel
            let rawProvider: String = row["provider"] ?? "unknown"
            let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "unknown"
                : rawProvider
            let bucket = Bucket(date: dayStart, provider: provider, key: key)
            var current = totals[bucket] ?? (label: label, valueUSD: 0, tokens: 0)
            current.valueUSD += row["value_usd"] ?? 0
            current.tokens += row["total_tokens"] ?? 0
            totals[bucket] = current
        }

        return totals.map { bucket, value in
            DailyBreakdownPoint(
                date: bucket.date,
                provider: bucket.provider,
                key: bucket.key,
                label: value.label,
                valueUSD: value.valueUSD,
                tokens: value.tokens)
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Buckets `usage_events` by local-calendar month, returning `months`
    /// consecutive months ending with the current month (zero-filled).
    /// `session_count` uses DISTINCT session_id so cross-month sessions
    /// count once per month they touched. Mirrors ccusage's `monthly.ts`.
    static func fetchMonthly(
        db: Database, months: Int, provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        now: Date = Date(), timeZone: TimeZone = .current
    ) throws -> [MonthlyPoint] {
        guard months > 0 else { return [] }
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        // Anchor on first-of-current-month in the local calendar; the lower
        // bound is the earliest bucket's local month start, serialized to
        // ISO8601 UTC. Derived from the injected `now` (not SQL 'now') so the
        // window is deterministic + test-injectable.
        let comps = cal.dateComponents([.year, .month], from: now)
        let thisMonth = cal.date(from: comps) ?? now
        let lowerMonth = cal.date(byAdding: .month, value: -(months - 1), to: thisMonth)
        let lowerBound = ISO8601.fractional.string(from: lowerMonth ?? .distantPast)
        // Bucket client-side by the local month of each event's OWN instant
        // (mirrors fetchDaily/fetchActivity), so a DST/UTC offset never shifts a
        // near-boundary event into the wrong month.
        let rows = try Row.fetchAll(db, sql: """
            SELECT timestamp, value_usd, total_tokens, session_id
            FROM usage_events
            WHERE timestamp >= ?
            \(scope.clause(table: "usage_events"))
            """, arguments: [lowerBound])

        var byMonth: [Date: (value: Double, tokens: Int64, sessions: Set<String>)] = [:]
        for row in rows {
            let ts: String = row["timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { continue }
            let mComps = cal.dateComponents([.year, .month], from: date)
            guard let monthStart = cal.date(from: mComps) else { continue }
            var bucket = byMonth[monthStart] ?? (0, 0, [])
            bucket.value += row["value_usd"] ?? 0
            bucket.tokens += row["total_tokens"] ?? 0
            if let sid: String = row["session_id"] { bucket.sessions.insert(sid) }
            byMonth[monthStart] = bucket
        }

        // Zero-fill `months` consecutive buckets ending at the current month.
        var points: [MonthlyPoint] = []
        for offset in (0..<months).reversed() {
            guard let date = cal.date(byAdding: .month, value: -offset, to: thisMonth) else { continue }
            let bucket = byMonth[date] ?? (0, 0, [])
            points.append(MonthlyPoint(month: date, valueUSD: bucket.value,
                                       tokens: bucket.tokens,
                                       sessionCount: bucket.sessions.count))
        }
        return points
    }

    static func fetchModelShares(
        db: Database,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil
    ) throws -> [ModelShare] {
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        return try Row.fetchAll(db, sql: """
            SELECT
              ue.model_id,
              COALESCE(pc.display_name, ue.model_id) AS display_name,
              SUM(ue.value_usd)     AS value_usd,
              SUM(ue.total_tokens)  AS tokens,
              COUNT(*)              AS event_count
            FROM usage_events ue
            LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id
            \(scope.whereClause(table: "ue"))
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
        untilDaysAgo: Int,
        enabledProviders: Set<String>? = nil
    ) throws -> [ModelShare] {
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
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
        sql += scope.clause(table: "ue")
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

    /// Per-provider usage over the trailing 30 days. Always returns rows
    /// for both `codex` and `claude` (zero-filled when the provider has no
    /// recent activity) so the Composition tool breakdown layout is stable.
    static func fetchProviderShares30d(
        db: Database,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil
    ) throws -> [ProviderShare] {
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        let rows = try Row.fetchAll(db, sql: """
            SELECT
              provider,
              COALESCE(SUM(value_usd), 0) AS v,
              COALESCE(SUM(total_tokens), 0) AS tokens
            FROM usage_events
            WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
            \(scope.clause(table: "usage_events"))
            GROUP BY provider
            """)
        var by: [String: (valueUSD: Double, tokens: Int64)] = [:]
        for r in rows {
            let p: String = r["provider"] ?? "codex"
            by[p] = (r["v"] ?? 0, r["tokens"] ?? 0)
        }
        return scope.zeroFillProviders().map {
            let bucket = by[$0] ?? (0, 0)
            return ProviderShare(
                provider: $0,
                valueUSD: bucket.valueUSD,
                tokens: bucket.tokens)
        }
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
