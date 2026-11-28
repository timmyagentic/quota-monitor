import Foundation
import GRDB

/// Additive dashboard facts, grouped by UTC hour, session, model and tier.
/// Historical noncanonical timestamps stay exact; the report calendar and
/// elapsed-window cutoffs are applied by the reader, not by database triggers.
enum DashboardUsageBuckets {
    private static func isCanonical(_ stamp: String) -> String {
        "strftime('%Y-%m-%dT%H:%M:%fZ', \(stamp), '+0 seconds') = \(stamp)"
    }

    private static func bucket(_ table: String) -> String {
        let stamp = "\(table).timestamp"
        return "CASE WHEN \(isCanonical(stamp)) THEN substr(\(stamp), 1, 13) ELSE '!' || \(stamp) END"
    }

    // The triggers are installed on existing databases by v29. A future change
    // to the grouping key or cache normalization must migrate the stored facts.
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE dashboard_usage_buckets (
                provider TEXT NOT NULL, bucket TEXT NOT NULL, session_id TEXT NOT NULL,
                model_id TEXT NOT NULL, tier TEXT NOT NULL,
                event_count INTEGER NOT NULL, total_tokens INTEGER NOT NULL, value_usd REAL NOT NULL,
                cache_read_tokens INTEGER NOT NULL, cache_eligible_input_tokens INTEGER NOT NULL,
                PRIMARY KEY (provider, bucket, session_id, model_id, tier)
            ) WITHOUT ROWID
            """)
        try db.execute(sql: """
            INSERT INTO dashboard_usage_buckets
            SELECT ue.provider, \(bucket("ue")), ue.session_id, ue.model_id,
                   COALESCE(ue.codex_service_tier_preference, ''),
                   COUNT(*), SUM(ue.total_tokens), SUM(ue.value_usd),
                   SUM(\(Aggregator.cacheReadTokensExpression(table: "ue"))),
                   SUM(\(Aggregator.cacheEligibleInputExpression(table: "ue")))
            FROM usage_events ue GROUP BY 1, 2, 3, 4, 5
            """)

        let insert = """
            INSERT INTO dashboard_usage_buckets
            VALUES (NEW.provider, \(bucket("NEW")), NEW.session_id, NEW.model_id,
                    COALESCE(NEW.codex_service_tier_preference, ''), 1, NEW.total_tokens, NEW.value_usd,
                    \(Aggregator.cacheReadTokensExpression(table: "NEW")),
                    \(Aggregator.cacheEligibleInputExpression(table: "NEW")))
            ON CONFLICT (provider, bucket, session_id, model_id, tier) DO UPDATE SET
                event_count = event_count + 1,
                total_tokens = total_tokens + excluded.total_tokens,
                value_usd = value_usd + excluded.value_usd,
                cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
                cache_eligible_input_tokens = cache_eligible_input_tokens + excluded.cache_eligible_input_tokens;
            """
        let oldKey = """
            provider = OLD.provider AND bucket = \(bucket("OLD"))
            AND session_id = OLD.session_id AND model_id = OLD.model_id
            AND tier = COALESCE(OLD.codex_service_tier_preference, '')
            """
        let remove = """
            UPDATE dashboard_usage_buckets SET
                event_count = event_count - 1,
                total_tokens = total_tokens - OLD.total_tokens,
                value_usd = value_usd - OLD.value_usd,
                cache_read_tokens = cache_read_tokens - (\(Aggregator.cacheReadTokensExpression(table: "OLD"))),
                cache_eligible_input_tokens = cache_eligible_input_tokens - (\(Aggregator.cacheEligibleInputExpression(table: "OLD")))
            WHERE \(oldKey);
            DELETE FROM dashboard_usage_buckets WHERE \(oldKey) AND event_count = 0;
            """
        let columns = ["provider", "timestamp", "session_id", "model_id", "codex_service_tier_preference",
                       "total_tokens", "value_usd", "input_tokens", "cached_input_tokens", "cache_creation_tokens",
                       "cache_creation_5m_tokens", "cache_creation_1h_tokens"]
        try db.execute(sql: """
            CREATE TRIGGER dashboard_usage_insert AFTER INSERT ON usage_events BEGIN
                \(insert)
            END;
            CREATE TRIGGER dashboard_usage_delete AFTER DELETE ON usage_events BEGIN
                \(remove)
            END;
            CREATE TRIGGER dashboard_usage_update AFTER UPDATE OF \(columns.joined(separator: ", ")) ON usage_events
            WHEN \(columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR "))
            BEGIN
                \(remove)
                \(insert)
            END;
            """)
    }

    /// UTC hours cut by local midnight, the moving upper bound or a rolling
    /// cutoff must use their original event times. This also handles zones
    /// whose offset isn't a whole hour and days that change length at DST.
    static func splitHours(cutoffs: [Date], from start: Date, to now: Date, calendar: Calendar) -> [Date] {
        var hours: Set<Date> = []
        func split(at instant: Date) {
            let seconds = instant.timeIntervalSince1970
            let hour = floor(seconds / 3600) * 3600
            if seconds != hour { hours.insert(Date(timeIntervalSince1970: hour)) }
        }
        for cutoff in cutoffs { split(at: cutoff) }
        split(at: now)
        var day = calendar.startOfDay(for: start)
        while day < now {
            split(at: day)
            guard let next = calendar.dateInterval(of: .day, for: day)?.end, next > day else { break }
            day = next
        }
        return hours.sorted()
    }

    static func recentRows(
        db: Database, scope: ProviderScope, lowerBound: String, splitHours: [Date]
    ) throws -> RowCursor {
        let edges = splitHours.isEmpty ? "SELECT NULL, NULL WHERE 0"
            : "VALUES " + Array(repeating: "(?, ?)", count: splitHours.count).joined(separator: ", ")
        var bounds = splitHours.flatMap {
            [ISO8601.fractional.string(from: $0), ISO8601.fractional.string(from: $0.addingTimeInterval(3600))]
        }
        bounds += [lowerBound, "!" + lowerBound]
        return try Row.fetchCursor(db, sql: """
            WITH edges(lo, hi) AS (\(edges)),
            usage AS (
                SELECT CASE WHEN substr(b.bucket, 1, 1) = '!' THEN substr(b.bucket, 2)
                            ELSE b.bucket || ':00:00.000Z' END AS timestamp,
                       b.provider, b.session_id, b.model_id, b.tier AS codex_service_tier_preference,
                       b.value_usd, b.total_tokens, b.cache_read_tokens, b.cache_eligible_input_tokens, b.event_count
                FROM dashboard_usage_buckets b
                WHERE (b.bucket >= ? OR (b.bucket >= ? AND b.bucket < '0'))
                  AND b.bucket NOT IN (SELECT substr(lo, 1, 13) FROM edges)
                  \(scope.clause(table: "b"))
                UNION ALL
                SELECT ue.timestamp, ue.provider, ue.session_id, ue.model_id, ue.codex_service_tier_preference,
                       ue.value_usd, ue.total_tokens,
                       \(Aggregator.cacheReadTokensExpression(table: "ue")) AS cache_read_tokens,
                       \(Aggregator.cacheEligibleInputExpression(table: "ue")) AS cache_eligible_input_tokens, 1
                FROM edges CROSS JOIN usage_events ue
                WHERE ue.timestamp >= edges.lo AND ue.timestamp < edges.hi
                  AND \(isCanonical("ue.timestamp")) \(scope.clause(table: "ue"))
            )
            SELECT usage.*, COALESCE(pc.display_name, usage.model_id) AS model_label
            FROM usage LEFT JOIN pricing_catalog pc ON pc.model_id = usage.model_id
            """, arguments: StatementArguments(bounds))
    }
}
