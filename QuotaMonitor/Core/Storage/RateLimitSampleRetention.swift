import Foundation
import GRDB

/// Bounds the otherwise-unbounded growth of `rate_limit_samples`.
///
/// The two live pollers append rows on every poll and nothing deleted them:
/// `RateLimitPoller` (Codex) writes a handful of rows every ~5 minutes and
/// `ClaudeUsagePoller` (Claude) every ~2 hours. Left alone the table grows by
/// hundreds of rows/day forever, inflating the DB file + WAL + index and
/// slowing the hot read paths that scan it to find the latest snapshot
/// (`Aggregator.fetchCodexQuota`, `RateLimitsHydrator`, `ClaudeUsageHydrator`
/// all take a MAX per `(bucket, limit_name)` with no time bound).
///
/// `jsonl`-sourced rows are intentionally left alone: the importer already
/// replaces them per-session (delete + reinsert in `ImportEngine`), so they're
/// bounded by what's on disk.
///
/// Retention rule, applied only to `live` + `claude_oauth`: delete a row when
/// it is BOTH
///   (a) older than `olderThanDays`, AND
///   (b) not the newest row for its `(source_kind, bucket, limit_name)` group.
///
/// Clause (b) is load-bearing. When a source goes cold (the user stops using
/// Codex/Claude for a while) the newest row for a group can itself be older
/// than the cutoff; without the "keep newest per group" guard we'd delete it
/// and the cold-start hydrators would have nothing to render. It also preserves
/// the most-recent `primary`/NULL sample that
/// `ClaudeUsageHydrator.latestExpiredFiveHour` reads to show an expired
/// 5-hour window.
enum RateLimitSampleRetention {
    /// Days of poller history to keep. Must comfortably exceed the widest UI
    /// read window — `Aggregator.fetchRateLimitHistory` reads 24h and
    /// `fetchBurnRates` reads 60min — so charts never lose in-window points.
    static let defaultRetentionDays = 7

    /// Deletes stale poller-sourced samples. Call inside an existing write
    /// transaction (both pollers already hold one when persisting). Returns the
    /// number of rows removed. Cheap once the table is bounded: the first run
    /// after upgrade does the bulk delete, later runs only trim the trailing
    /// edge.
    @discardableResult
    static func prune(
        db: Database,
        olderThanDays days: Int = defaultRetentionDays
    ) throws -> Int {
        // `sample_timestamp` is stored as ISO8601 (e.g. 2026-06-14T10:00:00.000Z),
        // so the cutoff MUST be built with the same strftime format. A plain
        // `datetime('now', ?)` yields "YYYY-MM-DD HH:MM:SS" and the lexical
        // comparison 'T' > ' ' would mis-bound the window — the same footgun
        // fixed in the analytics queries.
        try db.execute(sql: """
            DELETE FROM rate_limit_samples
            WHERE source_kind IN ('live', 'claude_oauth')
              AND sample_timestamp < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)
              AND id NOT IN (
                  SELECT id FROM (
                      SELECT id,
                             ROW_NUMBER() OVER (
                                 PARTITION BY source_kind, bucket,
                                              COALESCE(limit_name, '')
                                 ORDER BY sample_timestamp DESC, id DESC
                             ) AS rn
                      FROM rate_limit_samples
                      WHERE source_kind IN ('live', 'claude_oauth')
                  )
                  WHERE rn = 1
              )
            """, arguments: ["-\(days) days"])
        return db.changesCount
    }
}
