import Foundation
import GRDB

/// Reads the most recent persisted Codex rate-limit snapshot from
/// `rate_limit_samples` so the menu bar / popover have something to
/// render on cold start — even before `RateLimitPoller` has finished
/// its first live poll. Mirror of `ClaudeUsageHydrator` for the Codex
/// side.
///
/// Strategy differs from Claude's "one-timestamp-group" approach: Codex
/// rows can come from two sources (`live` polls and `jsonl` rollout
/// imports) at arbitrary timestamps, so we take the max-per-(bucket,
/// limit_name) instead. That matches `Aggregator.fetchCodexQuota`'s
/// behaviour for the Dashboard — live rows naturally win when present
/// (their timestamps are newer), jsonl rows remain visible after the
/// live source goes cold.
///
/// `source_kind = 'claude_oauth'` is excluded so Claude's own samples
/// (which share the table) can't leak into a Codex hydrate.
enum RateLimitsHydrator {
    static func loadLatest(database: DatabaseManager) async throws -> RateLimitSnapshot? {
        try await database.pool.read { db in
            // Per-(bucket, limit_name) max sample_timestamp, joined back
            // to fetch the row payload. `COALESCE(limit_name, '')` lets us
            // group plain primary/secondary alongside the per-model
            // additional rows in the same query.
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.bucket, s.limit_name, s.plan_type,
                       s.used_percent, s.resets_at, s.sample_timestamp
                FROM rate_limit_samples s
                JOIN (
                    SELECT bucket,
                           COALESCE(limit_name, '') AS lname,
                           MAX(sample_timestamp) AS max_ts
                    FROM rate_limit_samples
                    WHERE source_kind IN ('live', 'jsonl')
                    GROUP BY bucket, COALESCE(limit_name, '')
                ) m
                  ON m.bucket = s.bucket
                 AND m.lname = COALESCE(s.limit_name, '')
                 AND m.max_ts = s.sample_timestamp
                WHERE s.source_kind IN ('live', 'jsonl')
                """)

            guard !rows.isEmpty else { return nil }

            func parseDate(_ s: String?) -> Date? {
                guard let s else { return nil }
                return ISO8601.parse(s)
            }

            var primary: RateLimitSnapshot.Window?
            var secondary: RateLimitSnapshot.Window?
            var additional: [String: (primary: RateLimitSnapshot.Window?,
                                      secondary: RateLimitSnapshot.Window?)] = [:]
            var plan: String?
            var newestCaptured: Date?

            for row in rows {
                if plan == nil { plan = row["plan_type"] as String? }
                let bucket: String? = row["bucket"]
                let limitName: String? = row["limit_name"]
                let usedPercent: Double = row["used_percent"] ?? 0
                guard let resetAt = parseDate(row["resets_at"] as String?) else { continue }

                if let captured = parseDate(row["sample_timestamp"] as String?) {
                    if newestCaptured == nil || captured > newestCaptured! {
                        newestCaptured = captured
                    }
                }

                // Codex's stored rows don't carry an explicit window
                // duration. Infer from bucket: primary = 5h, secondary
                // = 7d. Matches the wire-format defaults the live poll
                // produces and the inference `ClaudeUsageHydrator` uses.
                let duration: TimeInterval = (bucket == "primary") ? 18_000 : 604_800
                let window = RateLimitSnapshot.Window(
                    usedPercent: usedPercent,
                    windowDuration: duration,
                    resetAt: resetAt)

                if let limitName, !limitName.isEmpty {
                    var entry = additional[limitName] ?? (nil, nil)
                    if bucket == "primary" { entry.primary = window }
                    else if bucket == "secondary" { entry.secondary = window }
                    additional[limitName] = entry
                } else {
                    if bucket == "primary" { primary = window }
                    else if bucket == "secondary" { secondary = window }
                }
            }

            // No usable rows (e.g. every row failed to parse `resets_at`)
            // → signal "nothing to hydrate" so the caller leaves the
            // menu-bar fallback alone.
            if primary == nil && secondary == nil && additional.isEmpty {
                return nil
            }

            return RateLimitSnapshot(
                capturedAt: newestCaptured ?? Date(),
                planType: plan,
                primary: primary,
                secondary: secondary,
                additional: additional.map { (name, pair) in
                    RateLimitSnapshot.Additional(
                        limitName: name,
                        meteredFeature: nil,
                        primary: pair.primary,
                        secondary: pair.secondary)
                },
                resetCreditsAvailable: nil)
        }
    }
}
