import Foundation
import GRDB

// Codex `rate_limit_samples` queries: latest per-bucket snapshot, derived
// burn rates, and the 24h history used by the Dashboard's rate-limit chart.

extension Aggregator {

    /// Most-recent Codex rate-limit sample per bucket. We read only Codex
    /// sources (`live` app-server polls + `jsonl` rollout imports) so Claude
    /// OAuth samples that share the table cannot override Codex quota rows.
    /// Live API updates win when present, while old jsonl samples remain
    /// visible after the live source goes cold (e.g. between Codex sessions).
    static func fetchCodexQuota(db: Database) throws -> CodexQuotaSnapshot? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.*
            FROM rate_limit_samples s
            JOIN (
                SELECT bucket, MAX(sample_timestamp) AS max_ts
                FROM rate_limit_samples
                WHERE limit_name IS NULL
                  AND source_kind IN ('live', 'jsonl')
                GROUP BY bucket
            ) m ON m.bucket = s.bucket AND m.max_ts = s.sample_timestamp
            WHERE s.limit_name IS NULL
              AND s.source_kind IN ('live', 'jsonl')
            """)
        guard !rows.isEmpty else { return nil }

        var primary: CodexQuotaWindow?
        var secondary: CodexQuotaWindow?
        for row in rows {
            guard let window = quotaWindow(from: row) else { continue }
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
        var out: [String: CodexBurnRate] = [:]
        for bucket in bucketsOfInterest {
            let rows = try Row.fetchAll(db, sql: """
                SELECT sample_timestamp, used_percent
                FROM rate_limit_samples
                WHERE bucket = ? AND limit_name IS NULL
                  AND source_kind IN ('live', 'jsonl')
                  AND sample_timestamp >= datetime('now', ?)
                ORDER BY sample_timestamp ASC
                """, arguments: [bucket, "-\(windowMinutes) minutes"])
            let points: [(minutes: Double, percent: Double)] = rows.compactMap { row in
                let ts: String = row["sample_timestamp"] ?? ""
                guard let date = parseTimestamp(ts) else { return nil }
                let pct: Double = row["used_percent"] ?? 0
                return (date.timeIntervalSinceReferenceDate / 60, pct)
            }
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

    static func quotaWindow(from row: Row) -> CodexQuotaWindow? {
        let resetsRaw: String = row["resets_at"] ?? ""
        guard let resets = parseTimestamp(resetsRaw) else { return nil }
        let sampleRaw: String = row["sample_timestamp"] ?? ""
        let sampleAt = parseTimestamp(sampleRaw) ?? Date()
        let windowStart: Date? = (row["window_start"] as String?).flatMap(parseTimestamp)
        return CodexQuotaWindow(
            bucket: row["bucket"] ?? "?",
            sourceKind: row["source_kind"] ?? "?",
            planType: row["plan_type"],
            sampleAt: sampleAt,
            windowStart: windowStart,
            resetsAt: resets,
            usedPercent: row["used_percent"] ?? 0,
            remainingPercent: row["remaining_percent"] ?? 0)
    }

    /// Top-level (non-additional) primary/secondary samples in the last `hours`,
    /// from both jsonl and live sources, ordered by sample_timestamp.
    static func fetchRateLimitHistory(db: Database, hours: Int) throws -> [RateLimitHistoryPoint] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, sample_timestamp, bucket, source_kind, used_percent
            FROM rate_limit_samples
            WHERE limit_name IS NULL
              AND source_kind IN ('live', 'jsonl')
              AND sample_timestamp >= datetime('now', ?)
            ORDER BY sample_timestamp ASC
            """, arguments: ["-\(hours) hours"])

        return rows.compactMap { row -> RateLimitHistoryPoint? in
            let ts: String = row["sample_timestamp"] ?? ""
            guard let date = parseTimestamp(ts) else { return nil }
            let bucket: String = row["bucket"] ?? "?"
            let kind: String   = row["source_kind"] ?? "?"
            return RateLimitHistoryPoint(
                id: row["id"] ?? 0,
                sampleAt: date,
                bucket: bucket,
                series: "\(bucket) (\(kind))",
                usedPercent: row["used_percent"] ?? 0)
        }
    }
}
