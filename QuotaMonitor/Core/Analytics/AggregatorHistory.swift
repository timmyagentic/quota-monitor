import Foundation
import GRDB

// Day-bucketed history queries powering the History tab.
//
// All day grouping is local-calendar correct across DST: `fetchDays` buckets
// client-side via `Calendar.startOfDay(for:)`, and the per-day drilldowns filter
// on a half-open local-day range `[startOfDay, nextDay)` computed with the
// calendar — so the window honours the DST offset for THAT day, not today's. The
// previous SQL `date(timestamp, ±offset)` applied today's single offset to all
// history, mis-bucketing near-midnight events from the opposite DST half.

extension Aggregator {

    /// Returns days that had at least one usage_event, newest first.
    /// Buckets by local-calendar day client-side (mirrors `fetchActivity`) so
    /// each event uses the UTC offset in effect at its own instant.
    static func fetchDays(
        db: Database, limit: Int = 365, provider: ProviderFilter = .all,
        calendar: Calendar = .current
    ) throws -> [DaySummary] {
        guard limit > 0 else { return [] }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT timestamp, value_usd, total_tokens, session_id
            FROM usage_events
            \(provider.whereClause(table: "usage_events"))
            ORDER BY timestamp DESC, id DESC
            """)

        var byDay: [Date: (value: Double, tokens: Int64, events: Int, sessions: Set<String>)] = [:]
        var orderedDays: [Date] = []
        while let row = try rows.next() {
            let ts: String = row["timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            var bucket = byDay[dayStart] ?? (0, 0, 0, [])
            if bucket.events == 0 {
                guard orderedDays.count < limit else { break }
                orderedDays.append(dayStart)
            }
            bucket.value += row["value_usd"] ?? 0
            bucket.tokens += row["total_tokens"] ?? 0
            bucket.events += 1
            if let sid: String = row["session_id"] { bucket.sessions.insert(sid) }
            byDay[dayStart] = bucket
        }

        let dayFormatter = Self.dayKeyFormatter(calendar)
        return orderedDays.map { dayStart in
            let bucket = byDay[dayStart] ?? (0, 0, 0, [])
            return DaySummary(
                day: dayFormatter.string(from: dayStart),
                date: dayStart,
                valueUSD: bucket.value,
                tokens: bucket.tokens,
                eventCount: bucket.events,
                sessionCount: bucket.sessions.count)
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

        let summaryRow = try Row.fetchOne(db, sql: """
            SELECT
              SUM(value_usd) AS value_usd,
              SUM(total_tokens) AS tokens,
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

        let breakdown = try Row.fetchAll(db, sql: """
            SELECT
              ue.model_id,
              COALESCE(pc.display_name, ue.model_id) AS display_name,
              SUM(ue.value_usd)     AS value_usd,
              SUM(CASE WHEN ue.provider = 'codex' AND ue.billing_tier = 'standard' THEN ue.value_usd ELSE 0 END) AS standard_value_usd,
              SUM(CASE WHEN ue.provider = 'codex' AND ue.billing_tier = 'fast' THEN ue.value_usd ELSE 0 END) AS fast_value_usd,
              SUM(CASE WHEN ue.provider = 'codex' AND ue.billing_tier = 'unknown' THEN ue.value_usd ELSE 0 END) AS unknown_value_usd,
              SUM(ue.total_tokens)  AS tokens,
              SUM(CASE WHEN ue.provider = 'codex' AND ue.billing_tier = 'standard' THEN ue.total_tokens ELSE 0 END) AS standard_tokens,
              SUM(CASE WHEN ue.provider = 'codex' AND ue.billing_tier = 'fast' THEN ue.total_tokens ELSE 0 END) AS fast_tokens,
              SUM(CASE WHEN ue.provider = 'codex' AND ue.billing_tier = 'unknown' THEN ue.total_tokens ELSE 0 END) AS unknown_tokens,
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
                standardValueUSD: row["standard_value_usd"] ?? 0,
                fastValueUSD: row["fast_value_usd"] ?? 0,
                unknownValueUSD: row["unknown_value_usd"] ?? 0,
                tokens: row["tokens"] ?? 0,
                standardTokens: row["standard_tokens"] ?? 0,
                fastTokens: row["fast_tokens"] ?? 0,
                unknownTokens: row["unknown_tokens"] ?? 0,
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

        return DayDetail(summary: summary, modelBreakdown: breakdown, sessions: sessions)
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
                   total_tokens, value_usd, turn_id,
                   billing_tier, billing_tier_source, model_inferred
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
                turnId: row["turn_id"],
                billingTier: CodexBillingTier(rawValue: row["billing_tier"] ?? "") ?? .unknown,
                billingTierSource: CodexBillingTierSource(rawValue: row["billing_tier_source"] ?? "") ?? .legacy,
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
