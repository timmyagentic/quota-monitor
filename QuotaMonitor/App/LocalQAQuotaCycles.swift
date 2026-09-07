import Foundation
import GRDB

extension AppEnvironment {
    /// Opt-in, synthetic current windows for visible QA. No quota API calls.
    func installLocalQAQuotaCycles() async throws {
        guard LocalQAEnvironment.isActive() else { return }
        let (database, _) = try ensureServices()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let codex = RateLimitSnapshot(observationScope: "fixture-codex", capturedAt: now,
            planType: "pro",
            primary: .init(usedPercent: 42, windowDuration: 18_000, resetAt: now.addingTimeInterval(7_200)),
            secondary: .init(usedPercent: 36, windowDuration: 604_800, resetAt: now.addingTimeInterval(432_000)),
            additional: [], resetCreditsAvailable: nil)
        let claude = ClaudeUsageSnapshot(capturedAt: now, tier: "max5x",
            fiveHour: .init(usedPercent: 24, resetAt: now.addingTimeInterval(9_000), windowDuration: 18_000),
            sevenDay: .init(usedPercent: 15, resetAt: now.addingTimeInterval(345_600), windowDuration: 604_800),
            sevenDayOpus: nil, sevenDaySonnet: nil, observationScope: "fixture-claude")
        try await database.pool.write { db in
            // This table belongs to the isolated fixture DB, never a live DB.
            try db.execute(sql: "DELETE FROM quota_cycle_state")
            let codexStart = now.addingTimeInterval(-10_800)
            try QuotaCycleStore.record(db: db, provider: "codex", capturedAt: codexStart.addingTimeInterval(-300),
                observations: [.init(provider: "codex", bucket: "primary", scope: "fixture-codex", plan: "pro",
                    capturedAt: codexStart.addingTimeInterval(-300), resetAt: codexStart,
                    duration: 18_000, usedPercent: 88)])
            try QuotaCycleStore.record(db: db, snapshot: codex)
            let claudeBefore = now.addingTimeInterval(-9_300)
            let claudeAfter = now.addingTimeInterval(-8_700)
            try QuotaCycleStore.record(db: db, provider: "claude", capturedAt: claudeBefore,
                observations: [
                    .init(provider: "claude", bucket: "primary", scope: "fixture-claude", plan: "max5x",
                        capturedAt: claudeBefore, resetAt: now.addingTimeInterval(-3_600),
                        duration: 18_000, usedPercent: 90),
                    .init(provider: "claude", bucket: "secondary", scope: "fixture-claude", plan: "max5x",
                        capturedAt: claudeBefore, resetAt: claude.sevenDay!.resetAt,
                        duration: 604_800, usedPercent: 65)])
            let after = ClaudeUsageSnapshot(capturedAt: claudeAfter, tier: "max5x",
                fiveHour: .init(usedPercent: 1, resetAt: claude.fiveHour!.resetAt, windowDuration: 18_000),
                sevenDay: claude.sevenDay, sevenDayOpus: nil, sevenDaySonnet: nil,
                observationScope: "fixture-claude")
            try QuotaCycleStore.record(db: db, snapshot: after)
            try QuotaCycleStore.record(db: db, snapshot: claude)
            // The popover can rehydrate samples even in QA. Persist the same
            // fixture windows so reopening it preserves the observed evidence.
            for cycle in QuotaCycleSelection.make(codex: codex, claude: claude, stored: []) {
                let observation = cycle.observation
                try db.execute(sql: """
                    INSERT INTO rate_limit_samples (source_kind, bucket, sample_timestamp,
                        plan_type, window_start, resets_at, used_percent, remaining_percent)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [observation.provider == "codex" ? "live" : "claude_oauth",
                        observation.bucket, ISO8601.fractional.string(from: now), observation.plan,
                        ISO8601.fractional.string(from: observation.resetAt.addingTimeInterval(-observation.duration)),
                        ISO8601.fractional.string(from: observation.resetAt), observation.usedPercent,
                        100 - observation.usedPercent])
            }
            for provider in ["codex", "claude"] {
                let session = "qa-quota-cycle-" + provider
                let iso = ISO8601.fractional.string(from: now)
                try db.execute(sql: """
                    INSERT OR IGNORE INTO sessions
                        (session_id, root_session_id, provider, title, created_at, imported_at)
                    VALUES (?, ?, ?, 'Quota cycle fixture', ?, ?)
                    """, arguments: [session, session, provider, iso, iso])
                try db.execute(sql: "DELETE FROM usage_events WHERE session_id = ?", arguments: [session])
                for index in 1...96 {
                    let date = now.addingTimeInterval(-Double(index) * 1_800)
                    let input = Int64((index % 7 + 1) * 21_000)
                    let output = Int64((index % 4 + 1) * 2_000)
                    try db.execute(sql: """
                        INSERT INTO usage_events (session_id, timestamp, model_id, provider,
                            input_tokens, cached_input_tokens, output_tokens, total_tokens, value_usd)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [session, ISO8601.fractional.string(from: date),
                            provider == "codex" ? "gpt-6-astra" : "claude-fable-5-1", provider,
                            input, input / 2, output, input + output, Double(input + output) / 1_000_000])
                }
            }
        }
        latestRateLimits = codex
        latestClaudeUsage = claude
        refreshDashboard(includeMenuBar: true, trigger: "qa-quota-cycles")
    }
}
