import Foundation
import GRDB

/// Reads the most recent persisted Claude `/usage` snapshot from
/// `rate_limit_samples` so the UI has something to show on cold start
/// — even if the next live poll 429s or hasn't fired yet.
///
/// Mirror of `ClaudeUsagePoller.persist` in reverse: we group rows by
/// `sample_timestamp`, take the newest group, and rebuild aggregate plus
/// model-scoped windows from `bucket` + `limit_name`.
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
            var staleFiveHour: ClaudeUsageSnapshot.Window?
            var sevenDay: ClaudeUsageSnapshot.Window?
            var sevenDayOpus: ClaudeUsageSnapshot.Window?
            var sevenDaySonnet: ClaudeUsageSnapshot.Window?
            var weeklyScoped: [ClaudeUsageSnapshot.WeeklyScopedLimit] = []
            var tier: String?

            for row in rows {
                if tier == nil { tier = row["plan_type"] as String? }
                let bucket: String? = row["bucket"]
                let limitName: String? = row["limit_name"]
                let structuredDisplayName = limitName.flatMap { name -> String? in
                    guard name.hasPrefix(ClaudeScopedQuotaRows.structuredStoragePrefix) else {
                        return nil
                    }
                    let displayName = String(
                        name.dropFirst(ClaudeScopedQuotaRows.structuredStoragePrefix.count))
                    return displayName.isEmpty ? nil : displayName
                }
                let normalizedLimitName = limitName.flatMap {
                    ClaudeUsageSnapshot.WeeklyScopedLimit.canonicalKey(for: $0)
                }
                let usedPercent: Double = row["used_percent"] ?? 0
                guard let resetAt = parseDate(row["resets_at"] as String?) else { continue }

                let duration: TimeInterval = (bucket == "primary") ? 18_000 : 604_800
                let window = ClaudeUsageSnapshot.Window(
                    usedPercent: usedPercent,
                    resetAt: resetAt,
                    windowDuration: duration)

                if bucket == "secondary",
                   let displayName = structuredDisplayName,
                   let key = ClaudeUsageSnapshot.WeeklyScopedLimit.canonicalKey(
                    for: displayName) {
                    weeklyScoped.append(.init(
                        key: key,
                        displayName: displayName,
                        window: window))
                    continue
                }

                switch (bucket, normalizedLimitName) {
                case ("primary", _):       fiveHour = window
                case ("secondary", nil):   sevenDay = window
                case ("secondary", "opus"):   sevenDayOpus = window
                case ("secondary", "sonnet"): sevenDaySonnet = window
                case ("secondary", let key?):
                    weeklyScoped.append(.init(key: key, window: window))
                default: continue
                }
            }

            if fiveHour == nil {
                staleFiveHour = try latestExpiredFiveHour(
                    db: db,
                    beforeSampleTimestamp: captured,
                    capturedAt: capturedAt,
                    parseDate: parseDate)
            }

            // Avoid "useless" rehydration if every window is empty.
            if fiveHour == nil && staleFiveHour == nil
                && sevenDay == nil && sevenDayOpus == nil && sevenDaySonnet == nil
                && weeklyScoped.isEmpty {
                return nil
            }

            return ClaudeUsageSnapshot(
                capturedAt: capturedAt,
                tier: tier,
                fiveHour: fiveHour,
                staleFiveHour: staleFiveHour,
                sevenDay: sevenDay,
                sevenDayOpus: sevenDayOpus,
                sevenDaySonnet: sevenDaySonnet,
                weeklyScoped: weeklyScoped)
        }
    }

    private static func latestExpiredFiveHour(
        db: Database,
        beforeSampleTimestamp captured: String,
        capturedAt: Date,
        parseDate: (String?) -> Date?
    ) throws -> ClaudeUsageSnapshot.Window? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT used_percent, resets_at
            FROM rate_limit_samples
            WHERE source_kind = 'claude_oauth'
              AND bucket = 'primary'
              AND limit_name IS NULL
              AND sample_timestamp < ?
            ORDER BY sample_timestamp DESC
            LIMIT 1
            """, arguments: [captured]) else {
            return nil
        }
        guard let resetAt = parseDate(row["resets_at"] as String?),
              resetAt <= capturedAt else {
            return nil
        }
        let usedPercent: Double = row["used_percent"] ?? 0
        return ClaudeUsageSnapshot.Window(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDuration: 18_000)
    }
}
