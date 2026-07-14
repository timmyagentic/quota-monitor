import Foundation
import GRDB

// Codex `rate_limit_samples` queries: latest coherent snapshot, derived
// burn rates, and the 24h history used by the Dashboard's rate-limit chart.
//
// Time-window predicates use `strftime('%Y-%m-%dT%H:%M:%fZ', 'now', …)`
// rather than `datetime('now', …)`. `sample_timestamp` is stored in ISO8601
// (with `T`/`Z`) and SQLite compares these as plain strings; datetime()
// returns a space-separated form ("YYYY-MM-DD HH:MM:SS") that lexically
// mis-compares against the stored values — silently widening the window to
// "everything since 00:00 today". See AggregatorReports.fetchPerProviderStats.

extension Aggregator {

    /// Most-recent coherent Codex rate-limit snapshot. We read only Codex
    /// sources (`live` app-server polls + `jsonl` rollout imports) so Claude
    /// OAuth samples that share the table cannot override Codex quota rows.
    /// Live API updates win when present, while old jsonl samples remain
    /// visible after the live source goes cold (e.g. between Codex sessions).
    static func fetchCodexQuota(db: Database) throws -> CodexQuotaSnapshot? {
        let rows = try Row.fetchAll(db, sql: """
            WITH latest_snapshot AS (
                SELECT source_kind,
                       COALESCE(source_session_id, '') AS session_key,
                       sample_timestamp
                FROM rate_limit_samples
                WHERE limit_name IS NULL
                  AND source_kind IN ('live', 'jsonl')
                ORDER BY sample_timestamp DESC,
                         CASE WHEN source_kind = 'live' THEN 0 ELSE 1 END,
                         id DESC
                LIMIT 1
            )
            SELECT sample.*
            FROM rate_limit_samples sample
            JOIN latest_snapshot latest
              ON latest.source_kind = sample.source_kind
             AND latest.session_key = COALESCE(sample.source_session_id, '')
             AND latest.sample_timestamp = sample.sample_timestamp
            WHERE sample.limit_name IS NULL
              AND sample.source_kind IN ('live', 'jsonl')
              AND sample.id = (
                  SELECT MAX(duplicate.id)
                  FROM rate_limit_samples duplicate
                  WHERE duplicate.source_kind = sample.source_kind
                    AND COALESCE(duplicate.source_session_id, '')
                        = COALESCE(sample.source_session_id, '')
                    AND duplicate.limit_name IS NULL
                    AND duplicate.sample_timestamp = sample.sample_timestamp
                    AND duplicate.bucket = sample.bucket
              )
            """)
        guard !rows.isEmpty else { return nil }

        let pairedSecondarySnapshots = Set(rows.compactMap { row -> String? in
            let bucket: String = row["bucket"] ?? ""
            return bucket == CodexQuotaWindowBucket.secondary.rawValue
                ? rateLimitSnapshotKey(from: row)
                : nil
        })
        var primary: CodexQuotaWindow?
        var secondary: CodexQuotaWindow?
        for row in rows {
            guard let window = quotaWindow(
                from: row,
                hasPairedSecondary: pairedSecondarySnapshots.contains(
                    rateLimitSnapshotKey(from: row)))
            else { continue }
            switch window.bucket {
            case "primary":   primary = window
            case "secondary": secondary = window
            default:          break
            }
        }
        guard primary != nil || secondary != nil else { return nil }

        // Burn rate from the last 60 min of samples per bucket. Long enough
        // to smooth out single-event spikes, short enough that an idle
        // session doesn't drag the slope to 0.
        let burn = try fetchBurnRates(db: db, bucketsOfInterest: ["primary", "secondary"])
        return CodexQuotaSnapshot(primary: primary, secondary: secondary, burn: burn)
    }

    /// Per-bucket linear regression on `used_percent` vs. minutes-since-
    /// first-sample for the last `windowMinutes` of samples. Returns the
    /// least-squares slope so a single growing series wins over a single
    /// noisy point. Empty bucket → no entry in the result.
    static func fetchBurnRates(
        db: Database,
        bucketsOfInterest: [String],
        windowMinutes: Int = 60
    ) throws -> [String: CodexBurnRate] {
        let rows = try Row.fetchAll(db, sql: """
            WITH ranked_anchors AS (
                SELECT id, source_kind,
                       COALESCE(source_session_id, '') AS session_key,
                       sample_timestamp,
                       ROW_NUMBER() OVER (
                           PARTITION BY sample_timestamp
                           ORDER BY CASE WHEN source_kind = 'live' THEN 0 ELSE 1 END,
                                    id DESC
                       ) AS snapshot_rank
                FROM rate_limit_samples
                WHERE limit_name IS NULL
                  AND source_kind IN ('live', 'jsonl')
                  AND sample_timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)
            ),
            selected_snapshots AS (
                SELECT source_kind, session_key, sample_timestamp
                FROM ranked_anchors
                WHERE snapshot_rank = 1
            )
            SELECT sample.bucket, sample.source_kind, sample.source_session_id,
                   sample.limit_name, sample.sample_timestamp,
                   sample.window_start, sample.resets_at, sample.used_percent
            FROM rate_limit_samples sample
            JOIN selected_snapshots selected
              ON selected.source_kind = sample.source_kind
             AND selected.session_key = COALESCE(sample.source_session_id, '')
             AND selected.sample_timestamp = sample.sample_timestamp
            WHERE sample.limit_name IS NULL
              AND sample.source_kind IN ('live', 'jsonl')
              AND sample.id = (
                  SELECT MAX(duplicate.id)
                  FROM rate_limit_samples duplicate
                  WHERE duplicate.source_kind = sample.source_kind
                    AND COALESCE(duplicate.source_session_id, '')
                        = COALESCE(sample.source_session_id, '')
                    AND duplicate.limit_name IS NULL
                    AND duplicate.sample_timestamp = sample.sample_timestamp
                    AND duplicate.bucket = sample.bucket
              )
            ORDER BY sample.sample_timestamp ASC
            """, arguments: ["-\(windowMinutes) minutes"])
        let pairedSecondarySnapshots = Set(rows.compactMap { row -> String? in
            let bucket: String = row["bucket"] ?? ""
            return bucket == CodexQuotaWindowBucket.secondary.rawValue
                ? rateLimitSnapshotKey(from: row)
                : nil
        })
        var pointsByBucket: [String: [(minutes: Double, percent: Double)]] = [:]
        for row in rows {
            guard let bucket = semanticBucket(
                from: row,
                hasPairedSecondary: pairedSecondarySnapshots.contains(
                    rateLimitSnapshotKey(from: row))),
                  bucketsOfInterest.contains(bucket.rawValue)
            else { continue }
            let ts: String = row["sample_timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { continue }
            let pct: Double = row["used_percent"] ?? 0
            pointsByBucket[bucket.rawValue, default: []].append(
                (date.timeIntervalSinceReferenceDate / 60, pct))
        }

        var out: [String: CodexBurnRate] = [:]
        for bucket in bucketsOfInterest {
            let points = pointsByBucket[bucket] ?? []
            guard points.count >= 2,
                  let first = points.first,
                  let last = points.last,
                  last.minutes - first.minutes > 0.5  // need at least 30s of spread
            else { continue }

            // Simple linear regression slope (mean-centered for stability).
            let xs = points.map { $0.minutes - first.minutes }
            let ys = points.map { $0.percent }
            let xMean = xs.reduce(0, +) / Double(xs.count)
            let yMean = ys.reduce(0, +) / Double(ys.count)
            var num = 0.0, den = 0.0
            for i in 0..<xs.count {
                let dx = xs[i] - xMean
                num += dx * (ys[i] - yMean)
                den += dx * dx
            }
            guard den > 0 else { continue }
            let slope = num / den            // %/minute
            out[bucket] = CodexBurnRate(percentPerMinute: slope, sampleCount: points.count)
        }
        return out
    }

    static func quotaWindow(
        from row: Row,
        hasPairedSecondary: Bool = false
    ) -> CodexQuotaWindow? {
        let resetsRaw: String = row["resets_at"] ?? ""
        guard let resets = parseTimestamp(resetsRaw) else { return nil }
        let sampleRaw: String = row["sample_timestamp"] ?? ""
        guard let sampleAt = parseTimestamp(sampleRaw) else { return nil }
        let windowStart: Date? = (row["window_start"] as String?).flatMap(parseTimestamp)
        guard let bucket = semanticBucket(
            from: row,
            hasPairedSecondary: hasPairedSecondary)
        else { return nil }
        return CodexQuotaWindow(
            bucket: bucket.rawValue,
            sourceKind: row["source_kind"] ?? "?",
            planType: row["plan_type"],
            sampleAt: sampleAt,
            windowStart: windowStart,
            resetsAt: resets,
            usedPercent: row["used_percent"] ?? 0,
            remainingPercent: row["remaining_percent"] ?? 0)
    }

    private static func semanticBucket(
        from row: Row,
        hasPairedSecondary: Bool
    ) -> CodexQuotaWindowBucket? {
        let rawBucket: String = row["bucket"] ?? ""
        guard let legacySlot = CodexQuotaWindowBucket(rawValue: rawBucket),
              let sampleAt = parseTimestamp(row["sample_timestamp"] ?? ""),
              let resetAt = parseTimestamp(row["resets_at"] ?? "")
        else { return nil }
        let windowStart: Date? = (row["window_start"] as String?).flatMap(parseTimestamp)
        return CodexQuotaWindowClassifier.classifyPersisted(
            legacySlot: legacySlot,
            windowStart: windowStart,
            sampleAt: sampleAt,
            resetAt: resetAt,
            hasPairedSecondary: hasPairedSecondary)
    }

    private static func rateLimitSnapshotKey(from row: Row) -> String {
        let sourceKind: String = row["source_kind"] ?? ""
        let sourceSessionId: String = row["source_session_id"] ?? ""
        let limitName: String = row["limit_name"] ?? ""
        let timestamp: String = row["sample_timestamp"] ?? ""
        return [sourceKind, sourceSessionId, limitName, timestamp]
            .joined(separator: "\u{1F}")
    }

    /// Top-level (non-additional) primary/secondary samples in the last `hours`,
    /// from both jsonl and live sources, ordered by sample_timestamp.
    static func fetchRateLimitHistory(db: Database, hours: Int) throws -> [RateLimitHistoryPoint] {
        let rows = try Row.fetchAll(db, sql: """
            WITH ranked_anchors AS (
                SELECT id, source_kind,
                       COALESCE(source_session_id, '') AS session_key,
                       sample_timestamp,
                       ROW_NUMBER() OVER (
                           PARTITION BY sample_timestamp
                           ORDER BY CASE WHEN source_kind = 'live' THEN 0 ELSE 1 END,
                                    id DESC
                       ) AS snapshot_rank
                FROM rate_limit_samples
                WHERE limit_name IS NULL
                  AND source_kind IN ('live', 'jsonl')
                  AND sample_timestamp >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)
            ),
            selected_snapshots AS (
                SELECT source_kind, session_key, sample_timestamp
                FROM ranked_anchors
                WHERE snapshot_rank = 1
            )
            SELECT sample.id, sample.source_session_id, sample.limit_name,
                   sample.sample_timestamp, sample.bucket, sample.source_kind,
                   sample.window_start, sample.resets_at, sample.used_percent
            FROM rate_limit_samples sample
            JOIN selected_snapshots selected
              ON selected.source_kind = sample.source_kind
             AND selected.session_key = COALESCE(sample.source_session_id, '')
             AND selected.sample_timestamp = sample.sample_timestamp
            WHERE sample.limit_name IS NULL
              AND sample.source_kind IN ('live', 'jsonl')
              AND sample.id = (
                  SELECT MAX(duplicate.id)
                  FROM rate_limit_samples duplicate
                  WHERE duplicate.source_kind = sample.source_kind
                    AND COALESCE(duplicate.source_session_id, '')
                        = COALESCE(sample.source_session_id, '')
                    AND duplicate.limit_name IS NULL
                    AND duplicate.sample_timestamp = sample.sample_timestamp
                    AND duplicate.bucket = sample.bucket
              )
            ORDER BY sample.sample_timestamp ASC
            """, arguments: ["-\(hours) hours"])

        let pairedSecondarySnapshots = Set(rows.compactMap { row -> String? in
            let bucket: String = row["bucket"] ?? ""
            return bucket == CodexQuotaWindowBucket.secondary.rawValue
                ? rateLimitSnapshotKey(from: row)
                : nil
        })

        return rows.compactMap { row -> RateLimitHistoryPoint? in
            let ts: String = row["sample_timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { return nil }
            guard let bucket = semanticBucket(
                from: row,
                hasPairedSecondary: pairedSecondarySnapshots.contains(
                    rateLimitSnapshotKey(from: row)))
            else { return nil }
            let kind: String   = row["source_kind"] ?? "?"
            return RateLimitHistoryPoint(
                id: row["id"] ?? 0,
                sampleAt: date,
                bucket: bucket.rawValue,
                series: "\(bucket.rawValue) (\(kind))",
                usedPercent: row["used_percent"] ?? 0)
        }
    }
}
