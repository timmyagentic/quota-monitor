import Foundation
import GRDB

private struct HistoryDayRange {
    let dayKey: String
    let ordinal: Int
    let start: Date
    let end: Date

    var lowerISO: String { ISO8601.fractional.string(from: start) }
    var upperISO: String { ISO8601.fractional.string(from: end) }
}

// Day-bucketed history queries powering the History tab.
//
// All day grouping is local-calendar correct across DST: paged list windows and
// per-day drilldowns use half-open local-day ranges `[startOfDay, nextDay)`
// computed with the same captured calendar. Each window therefore honours the
// offset for that historical day rather than applying today's offset to all
// history.

extension Aggregator {

    static func fetchHistoryPage(
        db: Database,
        before cursor: Date? = nil,
        pageSize: Int = 7,
        provider: ProviderFilter = .all,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> HistoryPage {
        precondition(pageSize > 0)
        let today = calendar.startOfDay(for: now)
        let requestedUpper = cursor.map { calendar.startOfDay(for: $0) }
            ?? calendar.date(byAdding: .day, value: 1, to: today)!
        let allowGapJump = cursor != nil
        var upper = requestedUpper
        while true {
            let page = try fetchHistoryWindow(
                db: db,
                upperBound: upper,
                pageSize: pageSize,
                provider: provider,
                calendar: calendar)
            if !page.days.isEmpty || !allowGapJump || !page.hasMore {
                return page
            }
            guard let timestamp = try newestOlderTimestamp(
                      db: db, before: page.nextCursor, provider: provider),
                  let olderDate = parseTimestamp(timestamp),
                  let jumpedUpper = calendar.date(
                      byAdding: .day,
                      value: 1,
                      to: calendar.startOfDay(for: olderDate)),
                  jumpedUpper < upper
            else {
                return HistoryPage(
                    days: [], nextCursor: page.nextCursor, hasMore: false)
            }
            upper = jumpedUpper
        }
    }

    private static func fetchHistoryWindow(
        db: Database,
        upperBound: Date,
        pageSize: Int,
        provider: ProviderFilter,
        calendar: Calendar
    ) throws -> HistoryPage {
        let ranges = historyDayRanges(
            endingAt: upperBound, pageSize: pageSize, calendar: calendar)
        let bucketCases = Array(
            repeating: "WHEN timestamp >= ? AND timestamp < ? THEN ?",
            count: ranges.count
        ).joined(separator: "\n")
        let sql = """
            SELECT CASE
                   \(bucketCases)
                   END AS ordinal,
                   SUM(value_usd) AS value_usd,
                   SUM(total_tokens) AS tokens,
                   COUNT(*) AS events,
                   COUNT(DISTINCT session_id) AS sessions
            FROM usage_events
            WHERE timestamp >= ? AND timestamp < ?
            \(provider.clause(table: "usage_events"))
            GROUP BY ordinal
            """
        var arguments: [(any DatabaseValueConvertible)?] = []
        for range in ranges {
            arguments.append(range.lowerISO)
            arguments.append(range.upperISO)
            arguments.append(range.ordinal)
        }
        let lower = ranges.last!.start
        arguments.append(ISO8601.fractional.string(from: lower))
        arguments.append(ranges.first!.upperISO)
        let rows = try Row.fetchAll(
            db, sql: sql, arguments: StatementArguments(arguments))
        let byOrdinal = Dictionary(uniqueKeysWithValues: ranges.map { ($0.ordinal, $0) })
        let days = rows.compactMap { row -> DaySummary? in
            let events: Int = row["events"] ?? 0
            let ordinal: Int = row["ordinal"] ?? -1
            guard events > 0, let range = byOrdinal[ordinal] else { return nil }
            return DaySummary(
                day: range.dayKey,
                date: range.start,
                valueUSD: row["value_usd"] ?? 0,
                tokens: row["tokens"] ?? 0,
                eventCount: events,
                sessionCount: row["sessions"] ?? 0)
        }.sorted { $0.date > $1.date }
        let older = try newestOlderTimestamp(
            db: db, before: lower, provider: provider)
        return HistoryPage(days: days, nextCursor: lower, hasMore: older != nil)
    }

    private static func newestOlderTimestamp(
        db: Database,
        before boundary: Date,
        provider: ProviderFilter
    ) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT timestamp
            FROM usage_events
            WHERE timestamp < ?
            \(provider.clause(table: "usage_events"))
            ORDER BY timestamp DESC
            LIMIT 1
            """, arguments: [ISO8601.fractional.string(from: boundary)])
    }

    private static func historyDayRanges(
        endingAt upperBound: Date,
        pageSize: Int,
        calendar: Calendar
    ) -> [HistoryDayRange] {
        let formatter = dayKeyFormatter(calendar)
        return (0..<pageSize).map { ordinal in
            let end = calendar.date(byAdding: .day, value: -ordinal, to: upperBound)!
            let start = calendar.date(byAdding: .day, value: -1, to: end)!
            return HistoryDayRange(
                dayKey: formatter.string(from: start),
                ordinal: ordinal,
                start: start,
                end: end)
        }
    }

    /// Drilldown for one local-calendar day: per-model breakdown + sessions
    /// active that day, with values restricted to events on that day only.
    static func fetchDayDetail(
        db: Database, day: String, provider: ProviderFilter = .all,
        calendar: Calendar = .current
    ) throws -> DayDetail? {
        guard let range = Self.localDayRange(day, calendar: calendar) else { return nil }
        let lo = range.lo
        let hi = range.hi
        let cacheRead = cacheReadTokensExpression(table: "usage_events")
        let cacheEligibleInput = cacheEligibleInputExpression(table: "usage_events")

        let summaryRow = try Row.fetchOne(db, sql: """
            SELECT
              SUM(value_usd) AS value_usd,
              SUM(total_tokens) AS tokens,
              COALESCE(SUM(\(cacheRead)), 0) AS cache_read_tokens,
              COALESCE(SUM(\(cacheEligibleInput)), 0) AS cache_eligible_input_tokens,
              COUNT(*) AS events,
              COUNT(DISTINCT session_id) AS sessions
            FROM usage_events
            WHERE timestamp >= ? AND timestamp < ?
            \(provider.clause(table: "usage_events"))
            """, arguments: [lo, hi])
        guard let summaryRow, (summaryRow["events"] as Int? ?? 0) > 0 else { return nil }

        let summary = DaySummary(
            day: day,
            date: range.start,
            valueUSD: summaryRow["value_usd"] ?? 0,
            tokens: summaryRow["tokens"] ?? 0,
            eventCount: summaryRow["events"] ?? 0,
            sessionCount: summaryRow["sessions"] ?? 0)
        let cacheUsage = CacheUsageSummary(
            readTokens: summaryRow["cache_read_tokens"] ?? 0,
            eligibleInputTokens: summaryRow["cache_eligible_input_tokens"] ?? 0)

        let breakdown = try Row.fetchAll(db, sql: """
            SELECT
              ue.model_id,
              COALESCE(pc.display_name, ue.model_id) AS display_name,
              SUM(ue.value_usd)     AS value_usd,
              SUM(ue.total_tokens)  AS tokens,
              COUNT(*)              AS event_count
            FROM usage_events ue
            LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id
            WHERE ue.timestamp >= ? AND ue.timestamp < ?
            \(provider.clause(table: "ue"))
            GROUP BY ue.model_id
            ORDER BY value_usd DESC
            """, arguments: [lo, hi]).map { row in
            ModelShare(
                modelId: row["model_id"] ?? "unknown",
                displayName: row["display_name"] ?? "Unknown",
                valueUSD: row["value_usd"] ?? 0,
                tokens: row["tokens"] ?? 0,
                eventCount: row["event_count"] ?? 0)
        }

        let sessions = try Row.fetchAll(db, sql: """
            SELECT
              s.session_id,
              s.title,
              s.project_name,
              s.cwd,
              s.agent_nickname,
              s.last_model_id,
              s.started_at,
              s.updated_at,
              s.contains_subagents,
              MIN(ue.timestamp) AS day_started_at,
              MAX(ue.timestamp) AS day_updated_at,
              SUM(ue.value_usd)     AS total_value,
              SUM(ue.total_tokens)  AS total_tokens,
              COUNT(ue.id)          AS event_count,
              COALESCE(MAX(ue.model_inferred), 0) AS has_inferred_model
            FROM usage_events ue
            JOIN sessions s ON s.session_id = ue.session_id
            WHERE ue.timestamp >= ? AND ue.timestamp < ?
            \(provider.clause(table: "ue"))
            GROUP BY s.session_id
            ORDER BY total_value DESC
            """, arguments: [lo, hi]).map { row in
            SessionRow(
                sessionId: row["session_id"] ?? "",
                title: row["title"],
                projectName: row["project_name"],
                cwd: row["cwd"],
                agentNickname: row["agent_nickname"],
                lastModelId: row["last_model_id"],
                startedAt: row["day_started_at"] ?? row["started_at"],
                updatedAt: row["day_updated_at"] ?? row["updated_at"],
                totalValueUSD: row["total_value"] ?? 0,
                totalTokens: row["total_tokens"] ?? 0,
                eventCount: row["event_count"] ?? 0,
                containsSubagents: row["contains_subagents"] ?? false,
                subagentCount: nil,
                hasInferredModel: row["has_inferred_model"] ?? false)
        }

        return DayDetail(
            summary: summary,
            modelBreakdown: breakdown,
            cacheUsage: cacheUsage,
            sessions: sessions)
    }

    /// Events for a given session restricted to a single local-calendar day.
    /// Powers the inline timeline shown when a user expands a session row in History.
    static func fetchEventsForSessionOnDay(
        db: Database, sessionId: String, day: String,
        calendar: Calendar = .current
    ) throws -> [SessionDetail.Event] {
        guard let range = Self.localDayRange(day, calendar: calendar) else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT id, timestamp, provider, model_id,
                   input_tokens, cached_input_tokens,
                   cache_creation_5m_tokens, cache_creation_1h_tokens,
                   output_tokens, reasoning_output_tokens,
                   total_tokens, value_usd, model_inferred
            FROM usage_events
            WHERE session_id = ? AND timestamp >= ? AND timestamp < ?
            ORDER BY timestamp ASC, id ASC
            """, arguments: [sessionId, range.lo, range.hi]).map { row in
            SessionDetail.Event(
                id: row["id"] ?? 0,
                timestamp: row["timestamp"] ?? "",
                provider: row["provider"] ?? "codex",
                modelId: row["model_id"] ?? "unknown",
                inputTokens: row["input_tokens"] ?? 0,
                cachedInputTokens: row["cached_input_tokens"] ?? 0,
                cacheCreation5mTokens: row["cache_creation_5m_tokens"] ?? 0,
                cacheCreation1hTokens: row["cache_creation_1h_tokens"] ?? 0,
                outputTokens: row["output_tokens"] ?? 0,
                reasoningOutputTokens: row["reasoning_output_tokens"] ?? 0,
                totalTokens: row["total_tokens"] ?? 0,
                valueUSD: row["value_usd"] ?? 0,
                modelInferred: row["model_inferred"] ?? false)
        }
    }

    // MARK: - local-day helpers

    /// `yyyy-MM-dd` formatter bound to `calendar` (POSIX locale) — the canonical
    /// History "day" key, shared by the list + drilldowns so they always agree.
    private static func dayKeyFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Parse a `yyyy-MM-dd` day key into a half-open local-day range, returned as
    /// ISO8601 UTC bounds for lexical SQL comparison against stored timestamps.
    /// The boundary is computed with `calendar`, so it honours the DST offset for
    /// THAT day rather than today's.
    private static func localDayRange(
        _ day: String, calendar: Calendar
    ) -> (start: Date, lo: String, hi: String)? {
        guard let parsed = dayKeyFormatter(calendar).date(from: day) else { return nil }
        let start = calendar.startOfDay(for: parsed)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start,
                ISO8601.fractional.string(from: start),
                ISO8601.fractional.string(from: end))
    }
}
