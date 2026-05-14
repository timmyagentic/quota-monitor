import Foundation
import GRDB

/// Reads the most recent persisted Claude `/usage` snapshot from
/// `rate_limit_samples` so the UI has something to show on cold start
/// — even if the next live poll 429s or hasn't fired yet.
///
/// Mirror of `ClaudeUsagePoller.persist` in reverse: we group rows by
/// `sample_timestamp`, take the newest group, and rebuild the four
/// `Window` slots from `bucket` + `limit_name`.
enum ClaudeUsageHydrator {
    static func loadLatest(database: DatabaseManager) async throws -> ClaudeUsageSnapshot? {
        try await database.pool.read { db in
            // Find the latest captured timestamp from the Claude OAuth source.
            guard let captured: String = try String.fetchOne(db, sql: """
                SELECT sample_timestamp
                FROM rate_limit_samples
                WHERE source_kind = 'claude_oauth'
                ORDER BY sample_timestamp DESC
                LIMIT 1
                """) else { return nil }

            let rows = try Row.fetchAll(db, sql: """
                SELECT bucket, limit_name, plan_type, used_percent, resets_at
                FROM rate_limit_samples
                WHERE source_kind = 'claude_oauth'
                  AND sample_timestamp = ?
                """, arguments: [captured])

            guard !rows.isEmpty else { return nil }

            func parseDate(_ s: String?) -> Date? {
                guard let s else { return nil }
                return ISO8601.parse(s)
            }

            let capturedAt = parseDate(captured) ?? Date()

            var fiveHour: ClaudeUsageSnapshot.Window?
            var sevenDay: ClaudeUsageSnapshot.Window?
            var sevenDayOpus: ClaudeUsageSnapshot.Window?
            var sevenDaySonnet: ClaudeUsageSnapshot.Window?
            var tier: String?

            for row in rows {
                if tier == nil { tier = row["plan_type"] as String? }
                let bucket: String? = row["bucket"]
                let limitName: String? = row["limit_name"]
                let usedPercent: Double = row["used_percent"] ?? 0
                guard let resetAt = parseDate(row["resets_at"] as String?) else { continue }

                let duration: TimeInterval = (bucket == "primary") ? 18_000 : 604_800
                let window = ClaudeUsageSnapshot.Window(
                    usedPercent: usedPercent,
                    resetAt: resetAt,
                    windowDuration: duration)

                switch (bucket, limitName) {
                case ("primary", _):       fiveHour = window
                case ("secondary", nil):   sevenDay = window
                case ("secondary", "opus"):   sevenDayOpus = window
                case ("secondary", "sonnet"): sevenDaySonnet = window
                default: continue
                }
            }

            // Avoid "useless" rehydration if every window is empty.
            if fiveHour == nil && sevenDay == nil && sevenDayOpus == nil && sevenDaySonnet == nil {
                return nil
            }

            return ClaudeUsageSnapshot(
                capturedAt: capturedAt,
                tier: tier,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDayOpus: sevenDayOpus,
                sevenDaySonnet: sevenDaySonnet)
        }
    }
}
