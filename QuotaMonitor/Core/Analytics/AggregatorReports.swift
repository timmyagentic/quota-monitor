import Foundation
import GRDB

private struct RollingTrendBreakdownBucket: Hashable {
    let date: Date
    let provider: String
    let key: String
}

private struct RollingTrendBreakdownTotal {
    let label: String
    var valueUSD: Double
    var tokens: Int64
}

private struct RollingTrendAccumulator {
    var dayValue: [Date: Double] = [:]
    var dayTokens: [Date: Int64] = [:]
    var dayCacheUsage: [Date: CacheUsageSummary] = [:]
    var providerTotals: [RollingTrendBreakdownBucket: RollingTrendBreakdownTotal] = [:]
    var modelTotals: [RollingTrendBreakdownBucket: RollingTrendBreakdownTotal] = [:]

    mutating func add(
        day: Date,
        provider: String,
        modelKey: String,
        modelLabel: String,
        valueUSD: Double,
        tokens: Int64,
        cacheReadTokens: Int64,
        cacheEligibleInputTokens: Int64
    ) {
        dayValue[day, default: 0] += valueUSD
        dayTokens[day, default: 0] += tokens
        let currentCache = dayCacheUsage[day] ?? .zero
        dayCacheUsage[day] = CacheUsageSummary(
            readTokens: currentCache.readTokens + cacheReadTokens,
            eligibleInputTokens: currentCache.eligibleInputTokens
                + cacheEligibleInputTokens)

        addBreakdown(
            to: &providerTotals,
            bucket: RollingTrendBreakdownBucket(
                date: day, provider: provider, key: provider),
            label: provider,
            valueUSD: valueUSD,
            tokens: tokens)
        addBreakdown(
            to: &modelTotals,
            bucket: RollingTrendBreakdownBucket(
                date: day, provider: provider, key: modelKey),
            label: modelLabel,
            valueUSD: valueUSD,
            tokens: tokens)
    }

    private func addBreakdown(
        to totals: inout [RollingTrendBreakdownBucket: RollingTrendBreakdownTotal],
        bucket: RollingTrendBreakdownBucket,
        label: String,
        valueUSD: Double,
        tokens: Int64
    ) {
        var current = totals[bucket] ?? RollingTrendBreakdownTotal(
            label: label, valueUSD: 0, tokens: 0)
        current.valueUSD += valueUSD
        current.tokens += tokens
        totals[bucket] = current
    }
}

private struct RecentModelShareTotal {
    let displayName: String
    var valueUSD: Double = 0
    var tokens: Int64 = 0
    var eventCount: Int = 0
}

private struct RecentMonthlyTotal {
    var valueUSD: Double = 0
    var tokens: Int64 = 0
    var sessionIDs: Set<String> = []
}

private struct RecentProviderShareTotal {
    var valueUSD: Double = 0
    var tokens: Int64 = 0
}

private struct RecentUsageRollup {
    let trends: DashboardTrendData
    let monthly: [MonthlyPoint]
    let modelShares30d: [ModelShare]
    let modelSharesPrior30d: [ModelShare]
    let providerShares30d: [ProviderShare]
}

// Top-level dashboard / overview / per-model / per-provider queries.
// All methods compose inside one read transaction via `loadDashboard`.

extension Aggregator {

    static func loadDashboard(
        from pool: DatabasePool,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> DashboardSnapshot {
        try await pool.read { db in
            try loadDashboard(
                db: db,
                provider: provider,
                enabledProviders: enabledProviders,
                now: now,
                calendar: calendar)
        }
    }

    /// Synchronous-in-transaction variant used when a caller needs Dashboard
    /// and adjacent summary surfaces from the same GRDB read snapshot.
    static func loadDashboard(
        db: Database,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DashboardSnapshot {
        let overview = try fetchOverview(
            db: db, provider: provider, enabledProviders: enabledProviders)
        // One recent raw-row scan derives every elapsed-time Trends range,
        // monthly buckets, and current/prior Composition slices.
        let recent = try fetchRecentUsageRollup(
            db: db, provider: provider,
            enabledProviders: enabledProviders,
            now: now, calendar: calendar)
        let dailyExtended = recent.trends.last365Days.daily
        let daily = Array(dailyExtended.suffix(14))
        let shares = try fetchModelShares(
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
            db: db, provider: provider, enabledProviders: enabledProviders,
            now: now, calendar: calendar)
        return DashboardSnapshot(
            overview: overview,
            daily: daily,
            dailyExtended: dailyExtended,
            trends: recent.trends,
            monthly: recent.monthly,
            modelShares: shares,
            modelShares30d: recent.modelShares30d,
            modelSharesPrior30d: recent.modelSharesPrior30d,
            providerShares30d: recent.providerShares30d,
            recentRateLimits: history,
            codexQuota: quota,
            activity: activity)
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
        let cacheRead = cacheReadTokensExpression(table: "usage_events")
        let cacheEligibleInput = cacheEligibleInputExpression(table: "usage_events")
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
            SELECT timestamp, value_usd, total_tokens,
                   \(cacheRead) AS cache_read_tokens,
                   \(cacheEligibleInput) AS cache_eligible_input_tokens
            FROM usage_events
            WHERE timestamp >= ?
            \(scope.clause(table: "usage_events"))
            """, arguments: [lowerBound])

        var dayValue: [Date: Double] = [:]
        var dayTokens: [Date: Int64] = [:]
        var dayCacheUsage: [Date: CacheUsageSummary] = [:]
        for row in rows {
            let ts: String = row["timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            dayValue[dayStart, default: 0] += row["value_usd"] ?? 0
            dayTokens[dayStart, default: 0] += row["total_tokens"] ?? 0
            let current = dayCacheUsage[dayStart] ?? .zero
            dayCacheUsage[dayStart] = CacheUsageSummary(
                readTokens: current.readTokens + (row["cache_read_tokens"] ?? 0),
                eligibleInputTokens: current.eligibleInputTokens
                    + (row["cache_eligible_input_tokens"] ?? 0))
        }
        return dailySeries(dayTokens: dayTokens, dayValue: dayValue,
                           days: days, now: now, calendar: calendar,
                           dayCacheUsage: dayCacheUsage)
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

    /// Exact elapsed-time windows for Dashboard Trends. Events are filtered
    /// against `[now - N × 24h, now)` before being assigned to local-calendar
    /// days, so only the in-window portion of the first day is counted.
    static func fetchRollingTrends(
        db: Database,
        provider: ProviderFilter = .all,
        enabledProviders: Set<String>? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DashboardTrendData {
        try fetchRecentUsageRollup(
            db: db,
            provider: provider,
            enabledProviders: enabledProviders,
            now: now,
            calendar: calendar).trends
    }

    /// Reads the recent event window once, then derives every Dashboard slice
    /// whose time horizon is bounded to the latest year.
    private static func fetchRecentUsageRollup(
        db: Database,
        provider: ProviderFilter,
        enabledProviders: Set<String>?,
        now: Date,
        calendar: Calendar
    ) throws -> RecentUsageRollup {
        let scope = ProviderScope(
            filter: provider, enabledProviders: enabledProviders)
        let cutoffs = Dictionary(uniqueKeysWithValues:
            RollingTrendWindow.allCases.map { ($0, $0.lowerBound(from: now)) })
        let oldestCutoff = cutoffs[.last365Days] ?? .distantPast

        var monthlyCalendar = Calendar(identifier: .gregorian)
        monthlyCalendar.timeZone = calendar.timeZone
        let monthComponents = monthlyCalendar.dateComponents([.year, .month], from: now)
        let thisMonth = monthlyCalendar.date(from: monthComponents) ?? now
        let monthlyStart = monthlyCalendar.date(
            byAdding: .month, value: -11, to: thisMonth) ?? oldestCutoff
        let current30Lower = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let prior30Lower = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let prior30Upper = current30Lower
        let earliestCutoff = min(oldestCutoff, min(monthlyStart, prior30Lower))

        // Query conservatively from the UTC date before the partial boundary
        // day, then apply exact parsed-Date bounds below. Every timestamp shape
        // accepted by `parseTimestamp` begins with yyyy-MM-dd, but their later
        // separators and offsets are not lexically comparable. A date-only
        // bound keeps the timestamp index useful without dropping SQLite-form
        // or offset timestamps before they can be parsed.
        let queryStart = calendar.startOfDay(for: earliestCutoff)
        let conservativeQueryStart = queryStart.addingTimeInterval(-24 * 60 * 60)
        let lowerBound = String(
            ISO8601.fractional.string(from: conservativeQueryStart).prefix(10))
        let cacheRead = cacheReadTokensExpression(table: "ue")
        let cacheEligibleInput = cacheEligibleInputExpression(table: "ue")
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                ue.timestamp,
                ue.provider,
                ue.session_id,
                ue.model_id,
                COALESCE(pc.display_name, ue.model_id) AS model_label,
                ue.value_usd,
                ue.total_tokens,
                \(cacheRead) AS cache_read_tokens,
                \(cacheEligibleInput) AS cache_eligible_input_tokens
            FROM usage_events ue
            LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id
            WHERE ue.timestamp >= ?
            \(scope.clause(table: "ue"))
            """, arguments: [lowerBound])

        var accumulators: [RollingTrendWindow: RollingTrendAccumulator] = [:]
        var prior30DayValueUSD = 0.0
        var monthlyTotals: [Date: RecentMonthlyTotal] = [:]
        var modelShares30d: [String: RecentModelShareTotal] = [:]
        var modelSharesPrior30d: [String: RecentModelShareTotal] = [:]
        var providerShares30d: [String: RecentProviderShareTotal] = [:]

        for row in rows {
            let timestamp: String = row["timestamp"] ?? ""
            guard let date = parseTimestamp(timestamp),
                  date >= earliestCutoff
            else { continue }

            let valueUSD: Double = row["value_usd"] ?? 0
            let rawProvider: String = row["provider"] ?? "unknown"
            let normalizedProvider = normalizedTrendValue(
                rawProvider, fallback: "unknown")
            let rawModelKey: String = row["model_id"] ?? "unknown"
            let modelKey = normalizedTrendValue(
                rawModelKey, fallback: "unknown")
            let rawModelLabel: String = row["model_label"] ?? modelKey
            let modelLabel = normalizedTrendValue(
                rawModelLabel, fallback: modelKey)
            let day = calendar.startOfDay(for: date)
            let tokens: Int64 = row["total_tokens"] ?? 0
            let cacheReadTokens: Int64 = row["cache_read_tokens"] ?? 0
            let cacheEligibleInputTokens: Int64 =
                row["cache_eligible_input_tokens"] ?? 0

            if date < now {
                for window in RollingTrendWindow.allCases {
                    guard let cutoff = cutoffs[window], date >= cutoff else { continue }
                    accumulators[window, default: RollingTrendAccumulator()].add(
                        day: day,
                        provider: normalizedProvider,
                        modelKey: modelKey,
                        modelLabel: modelLabel,
                        valueUSD: valueUSD,
                        tokens: tokens,
                        cacheReadTokens: cacheReadTokens,
                        cacheEligibleInputTokens: cacheEligibleInputTokens)
                }

                if date >= current30Lower {
                    addModelShare(
                        to: &modelShares30d,
                        modelKey: modelKey,
                        displayName: modelLabel,
                        valueUSD: valueUSD,
                        tokens: tokens)
                } else if date >= prior30Lower, date < prior30Upper {
                    addModelShare(
                        to: &modelSharesPrior30d,
                        modelKey: modelKey,
                        displayName: modelLabel,
                        valueUSD: valueUSD,
                        tokens: tokens)
                    prior30DayValueUSD += valueUSD
                }
            }

            if date >= current30Lower, date < now {
                var providerTotal = providerShares30d[normalizedProvider]
                    ?? RecentProviderShareTotal()
                providerTotal.valueUSD += valueUSD
                providerTotal.tokens += tokens
                providerShares30d[normalizedProvider] = providerTotal
            }

            if date >= monthlyStart, date < now {
                let components = monthlyCalendar.dateComponents(
                    [.year, .month], from: date)
                if let month = monthlyCalendar.date(from: components) {
                    var total = monthlyTotals[month] ?? RecentMonthlyTotal()
                    total.valueUSD += valueUSD
                    total.tokens += tokens
                    if let sessionID: String = row["session_id"] {
                        total.sessionIDs.insert(sessionID)
                    }
                    monthlyTotals[month] = total
                }
            }
        }

        func snapshot(for window: RollingTrendWindow) -> TrendWindowSnapshot {
            let accumulator = accumulators[window] ?? RollingTrendAccumulator()
            let cutoff = cutoffs[window] ?? now
            return TrendWindowSnapshot(
                daily: rollingDailySeries(
                    dayTokens: accumulator.dayTokens,
                    dayValue: accumulator.dayValue,
                    dayCacheUsage: accumulator.dayCacheUsage,
                    lowerBound: cutoff,
                    now: now,
                    calendar: calendar),
                providerBreakdown: rollingBreakdownSeries(
                    accumulator.providerTotals),
                modelBreakdown: rollingBreakdownSeries(
                    accumulator.modelTotals))
        }

        let trends = DashboardTrendData(
            last7Days: snapshot(for: .last7Days),
            last30Days: snapshot(for: .last30Days),
            last90Days: snapshot(for: .last90Days),
            last365Days: snapshot(for: .last365Days),
            prior30DayValueUSD: prior30DayValueUSD)

        let monthly = (0..<12).reversed().compactMap { offset -> MonthlyPoint? in
            guard let month = monthlyCalendar.date(
                byAdding: .month, value: -offset, to: thisMonth)
            else { return nil }
            let total = monthlyTotals[month] ?? RecentMonthlyTotal()
            return MonthlyPoint(
                month: month,
                valueUSD: total.valueUSD,
                tokens: total.tokens,
                sessionCount: total.sessionIDs.count)
        }

        let providerShares = scope.zeroFillProviders().map { providerID in
            let total = providerShares30d[providerID]
                ?? RecentProviderShareTotal()
            return ProviderShare(
                provider: providerID,
                valueUSD: total.valueUSD,
                tokens: total.tokens)
        }

        return RecentUsageRollup(
            trends: trends,
            monthly: monthly,
            modelShares30d: makeModelShares(modelShares30d),
            modelSharesPrior30d: makeModelShares(modelSharesPrior30d),
            providerShares30d: providerShares)
    }

    private static func addModelShare(
        to totals: inout [String: RecentModelShareTotal],
        modelKey: String,
        displayName: String,
        valueUSD: Double,
        tokens: Int64
    ) {
        var total = totals[modelKey] ?? RecentModelShareTotal(
            displayName: displayName)
        total.valueUSD += valueUSD
        total.tokens += tokens
        total.eventCount += 1
        totals[modelKey] = total
    }

    private static func makeModelShares(
        _ totals: [String: RecentModelShareTotal]
    ) -> [ModelShare] {
        totals.map { modelID, total in
            ModelShare(
                modelId: modelID,
                displayName: total.displayName,
                valueUSD: total.valueUSD,
                tokens: total.tokens,
                eventCount: total.eventCount)
        }
        .sorted {
            if $0.valueUSD != $1.valueUSD { return $0.valueUSD > $1.valueUSD }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private static func normalizedTrendValue(
        _ rawValue: String,
        fallback: String
    ) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }

    private static func rollingDailySeries(
        dayTokens: [Date: Int64],
        dayValue: [Date: Double],
        dayCacheUsage: [Date: CacheUsageSummary],
        lowerBound: Date,
        now: Date,
        calendar: Calendar
    ) -> [DailyPoint] {
        let firstDay = calendar.startOfDay(for: lowerBound)
        let today = calendar.startOfDay(for: now)
        guard firstDay <= today else { return [] }

        var points: [DailyPoint] = []
        points.reserveCapacity(367)
        var day = firstDay
        while day <= today {
            points.append(DailyPoint(
                date: day,
                valueUSD: dayValue[day] ?? 0,
                tokens: dayTokens[day] ?? 0,
                cacheUsage: dayCacheUsage[day] ?? .zero))
            guard let next = calendar.date(
                byAdding: .day, value: 1, to: day),
                next > day
            else { break }
            day = next
        }
        return points
    }

    private static func rollingBreakdownSeries(
        _ totals: [RollingTrendBreakdownBucket: RollingTrendBreakdownTotal]
    ) -> [DailyBreakdownPoint] {
        totals.map { bucket, total in
            DailyBreakdownPoint(
                date: bucket.date,
                provider: bucket.provider,
                key: bucket.key,
                label: total.label,
                valueUSD: total.valueUSD,
                tokens: total.tokens)
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.label.localizedCaseInsensitiveCompare($1.label)
                == .orderedAscending
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
        // Anthropic has no weekly quota counter, so the 7-day spend is surfaced
        // instead. The rolling 30-day window drives the headline KPI. Keep
        // strftime's ISO8601 T/Z shape so lexical comparisons include boundary
        // events written by the importer; datetime() emits a space instead.
        let rows = try Row.fetchAll(db, sql: """
            SELECT
              provider,
              COALESCE(SUM(value_usd), 0)            AS total_value,
              COALESCE(SUM(total_tokens), 0)         AS total_tokens,
              COUNT(*)                               AS total_events,
              MAX(timestamp)                         AS last_at,
              COALESCE(SUM(CASE
                WHEN timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
                THEN value_usd ELSE 0 END), 0)        AS w_value,
              COALESCE(SUM(CASE
                WHEN timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
                THEN total_tokens ELSE 0 END), 0)     AS w_tokens,
              COUNT(DISTINCT CASE
                WHEN timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-7 days')
                THEN session_id END)                  AS w_sessions,
              COALESCE(SUM(CASE
                WHEN timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
                THEN value_usd ELSE 0 END), 0)        AS m_value,
              COALESCE(SUM(CASE
                WHEN timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
                THEN total_tokens ELSE 0 END), 0)     AS m_tokens,
              COUNT(DISTINCT CASE
                WHEN timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
                THEN session_id END)                  AS m_sessions
            FROM usage_events
            GROUP BY provider
            """)
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
            out[p] = ProviderStats(
                provider: p,
                totalValueUSD: r["total_value"] ?? 0,
                totalTokens: r["total_tokens"] ?? 0,
                eventCount: r["total_events"] ?? 0,
                sessionCount: sessionsBy[p] ?? 0,
                lastActivityAt: r["last_at"],
                last7dValueUSD: r["w_value"] ?? 0,
                last7dTokens: r["w_tokens"] ?? 0,
                last7dSessionCount: r["w_sessions"] ?? 0,
                last30dValueUSD: r["m_value"] ?? 0,
                last30dTokens: r["m_tokens"] ?? 0,
                last30dSessionCount: r["m_sessions"] ?? 0)
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
