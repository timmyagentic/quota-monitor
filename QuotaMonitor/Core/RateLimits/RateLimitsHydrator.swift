import Foundation
import GRDB

/// Reads the most recent persisted Codex rate-limit snapshot from
/// `rate_limit_samples` so the menu bar / popover have something to
/// render on cold start — even before `RateLimitPoller` has finished
/// its first live poll. Mirror of `ClaudeUsageHydrator` for the Codex
/// side.
///
/// Codex rows can come from two sources (`live` polls and `jsonl` rollout
/// imports) at arbitrary timestamps. We select one latest timestamp per
/// `limit_name`, then keep only the windows present in that coherent snapshot.
/// A missing window is meaningful (for example, the temporary weekly-only
/// policy), so it must never be backfilled from an older timestamp.
///
/// `source_kind = 'claude_oauth'` is excluded so Claude's own samples
/// (which share the table) can't leak into a Codex hydrate.
enum RateLimitsHydrator {
    static func loadLatest(database: DatabaseManager) async throws -> RateLimitSnapshot? {
        try await database.pool.read { db in
            // Latest snapshot per limit group, joined back to fetch every
            // window in that snapshot. `COALESCE(limit_name, '')` keeps the
            // headline group separate from per-model additional limits.
            let rows = try Row.fetchAll(db, sql: """
                WITH latest_times AS (
                    SELECT COALESCE(limit_name, '') AS lname,
                           MAX(sample_timestamp) AS sample_timestamp
                    FROM rate_limit_samples
                    WHERE source_kind IN ('live', 'jsonl')
                    GROUP BY COALESCE(limit_name, '')
                ),
                latest_snapshots AS (
                    SELECT latest.lname,
                           anchor.source_kind,
                           COALESCE(anchor.source_session_id, '') AS session_key,
                           anchor.sample_timestamp
                    FROM latest_times latest
                    JOIN rate_limit_samples anchor
                      ON COALESCE(anchor.limit_name, '') = latest.lname
                     AND anchor.sample_timestamp = latest.sample_timestamp
                    WHERE anchor.source_kind IN ('live', 'jsonl')
                      AND anchor.id = (
                          SELECT candidate.id
                          FROM rate_limit_samples candidate
                          WHERE candidate.source_kind IN ('live', 'jsonl')
                            AND COALESCE(candidate.limit_name, '') = latest.lname
                            AND candidate.sample_timestamp = latest.sample_timestamp
                          ORDER BY CASE WHEN candidate.source_kind = 'live' THEN 0 ELSE 1 END,
                                   candidate.id DESC
                          LIMIT 1
                      )
                )
                SELECT s.source_kind, s.source_session_id, s.bucket,
                       s.limit_name, s.plan_type,
                       s.used_percent, s.window_start, s.resets_at,
                       s.sample_timestamp
                FROM rate_limit_samples s
                JOIN latest_snapshots latest
                  ON latest.lname = COALESCE(s.limit_name, '')
                 AND latest.source_kind = s.source_kind
                 AND latest.session_key = COALESCE(s.source_session_id, '')
                 AND latest.sample_timestamp = s.sample_timestamp
                WHERE s.source_kind IN ('live', 'jsonl')
                  AND s.id = (
                      SELECT MAX(duplicate.id)
                      FROM rate_limit_samples duplicate
                      WHERE duplicate.source_kind = s.source_kind
                        AND COALESCE(duplicate.source_session_id, '')
                            = COALESCE(s.source_session_id, '')
                        AND COALESCE(duplicate.limit_name, '')
                            = COALESCE(s.limit_name, '')
                        AND duplicate.sample_timestamp = s.sample_timestamp
                        AND duplicate.bucket = s.bucket
                  )
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

            func snapshotKey(_ row: Row) -> String {
                let sourceKind: String = row["source_kind"] ?? ""
                let sourceSessionId: String = row["source_session_id"] ?? ""
                let limitName: String = row["limit_name"] ?? ""
                let timestamp: String = row["sample_timestamp"] ?? ""
                return [sourceKind, sourceSessionId, limitName, timestamp]
                    .joined(separator: "\u{1F}")
            }

            let pairedSecondarySnapshots = Set(rows.compactMap { row -> String? in
                let bucket: String = row["bucket"] ?? ""
                return bucket == CodexQuotaWindowBucket.secondary.rawValue
                    ? snapshotKey(row)
                    : nil
            })

            for row in rows {
                let rawBucket: String = row["bucket"] ?? ""
                guard let legacySlot = CodexQuotaWindowBucket(rawValue: rawBucket)
                else { continue }
                let limitName: String? = row["limit_name"]
                let usedPercent: Double = row["used_percent"] ?? 0
                guard let resetAt = parseDate(row["resets_at"] as String?),
                      let captured = parseDate(row["sample_timestamp"] as String?)
                else { continue }
                let windowStart = parseDate(row["window_start"] as String?)
                guard let bucket = CodexQuotaWindowClassifier.classifyPersisted(
                    legacySlot: legacySlot,
                    windowStart: windowStart,
                    sampleAt: captured,
                    resetAt: resetAt,
                    hasPairedSecondary: pairedSecondarySnapshots.contains(snapshotKey(row)))
                else { continue }

                if newestCaptured == nil || captured > newestCaptured! {
                    newestCaptured = captured
                    plan = row["plan_type"] as String?
                }

                let window = RateLimitSnapshot.Window(
                    usedPercent: usedPercent,
                    windowDuration: CodexQuotaWindowClassifier.duration(for: bucket),
                    resetAt: resetAt)

                if let limitName, !limitName.isEmpty {
                    var entry = additional[limitName] ?? (nil, nil)
                    if bucket == .primary { entry.primary = window }
                    else { entry.secondary = window }
                    additional[limitName] = entry
                } else {
                    if bucket == .primary { primary = window }
                    else { secondary = window }
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
