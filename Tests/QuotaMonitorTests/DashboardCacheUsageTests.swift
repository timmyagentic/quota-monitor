import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Dashboard cache usage")
struct DashboardCacheUsageTests {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDatabase() throws -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-monitor-dashboard-cache-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return try DatabaseManager(url: directory.appendingPathComponent(
            "cache-\(UUID().uuidString).sqlite"))
    }

    private func seed(
        in database: DatabaseManager,
        sessionID: String,
        date: Date,
        provider: String,
        input: Int64,
        cacheRead: Int64,
        legacyCacheWrite: Int64 = 0,
        cacheWrite5m: Int64 = 0,
        cacheWrite1h: Int64 = 0
    ) throws {
        let timestamp = ISO8601.fractional.string(from: date)
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL,
                        'gpt-5', NULL, 0, ?, ?, ?)
                """, arguments: [
                    sessionID, sessionID, timestamp, timestamp,
                    timestamp, timestamp, provider
                ])
            try db.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens,
                 cache_creation_5m_tokens, cache_creation_1h_tokens,
                 model_inferred)
                VALUES (?, ?, 'gpt-5', ?, ?, 0, 0, ?, 0, ?, ?, ?, ?, 0)
                """, arguments: [
                    sessionID, timestamp, input, cacheRead,
                    max(input, 0), provider, legacyCacheWrite,
                    cacheWrite5m, cacheWrite1h
                ])
        }
    }

    @Test("daily cache rates use provider-normalized inputs and weighted windows")
    func dailyRatesAreProviderNormalizedAndWeighted() throws {
        let calendar = utcCalendar()
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 24, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(
            byAdding: .day, value: -1, to: today))
        let database = try makeDatabase()

        // Codex cached input is already a subset of the full input denominator.
        try seed(
            in: database,
            sessionID: "codex-today",
            date: today.addingTimeInterval(10 * 3600),
            provider: "codex",
            input: 100,
            cacheRead: 80)
        // Claude stores uncached input separately. Split writes (20) win over
        // the intentionally huge legacy fallback value.
        try seed(
            in: database,
            sessionID: "claude-yesterday",
            date: yesterday.addingTimeInterval(10 * 3600),
            provider: "claude",
            input: 10,
            cacheRead: 40,
            legacyCacheWrite: 999,
            cacheWrite5m: 5,
            cacheWrite1h: 15)

        let all = try database.pool.read { db in
            try Aggregator.fetchDaily(
                db: db, days: 7, provider: .all,
                now: now, calendar: calendar)
        }
        let codex = try database.pool.read { db in
            try Aggregator.fetchDaily(
                db: db, days: 7, provider: .codex,
                now: now, calendar: calendar)
        }
        let claude = try database.pool.read { db in
            try Aggregator.fetchDaily(
                db: db, days: 7, provider: .claude,
                now: now, calendar: calendar)
        }
        let enabledCodex = try database.pool.read { db in
            try Aggregator.fetchDaily(
                db: db, days: 7, provider: .all,
                enabledProviders: ["codex"],
                now: now, calendar: calendar)
        }
        let historyToday = try database.pool.read { db in
            try Aggregator.fetchDayDetail(
                db: db, day: "2026-07-24", calendar: calendar)
        }

        let todayUsage = try #require(all.first {
            calendar.isDate($0.date, inSameDayAs: today)
        }).cacheUsage
        let yesterdayUsage = try #require(all.first {
            calendar.isDate($0.date, inSameDayAs: yesterday)
        }).cacheUsage
        #expect(todayUsage == CacheUsageSummary(
            readTokens: 80, eligibleInputTokens: 100))
        #expect(yesterdayUsage == CacheUsageSummary(
            readTokens: 40, eligibleInputTokens: 70))
        #expect(historyToday?.cacheUsage == todayUsage,
                "Dashboard and History must keep the same cache accounting")

        let weighted = CacheUsageSummary.combined(all.map(\.cacheUsage))
        #expect(weighted == CacheUsageSummary(
            readTokens: 120, eligibleInputTokens: 170))
        #expect(abs((weighted.hitRate ?? 0) - (120.0 / 170.0)) < 0.000_001)
        let dailyPercentageAverage = (0.8 + (40.0 / 70.0)) / 2
        #expect(abs((weighted.hitRate ?? 0) - dailyPercentageAverage) > 0.01,
                "window rate must not average daily percentages")

        #expect(CacheUsageSummary.combined(codex.map(\.cacheUsage))
            == CacheUsageSummary(readTokens: 80, eligibleInputTokens: 100))
        #expect(CacheUsageSummary.combined(claude.map(\.cacheUsage))
            == CacheUsageSummary(readTokens: 40, eligibleInputTokens: 70))
        #expect(CacheUsageSummary.combined(enabledCodex.map(\.cacheUsage))
            == CacheUsageSummary(readTokens: 80, eligibleInputTokens: 100))
    }

    @Test("legacy Claude writes fall back and missing denominators stay unavailable")
    func legacyWritesAndUnavailableDays() throws {
        let calendar = utcCalendar()
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 24, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let database = try makeDatabase()

        try seed(
            in: database,
            sessionID: "legacy-claude",
            date: today.addingTimeInterval(10 * 3600),
            provider: "claude",
            input: 10,
            cacheRead: 20,
            legacyCacheWrite: 30)
        let daily = try database.pool.read { db in
            try Aggregator.fetchDaily(
                db: db, days: 3, now: now, calendar: calendar)
        }

        #expect(daily.count == 3)
        #expect(daily[0].cacheUsage == .zero)
        #expect(daily[0].cacheUsage.hitRate == nil)
        #expect(daily[1].cacheUsage == .zero)
        #expect(daily[2].cacheUsage == CacheUsageSummary(
            readTokens: 20, eligibleInputTokens: 60))
        #expect(abs((daily[2].cacheUsage.hitRate ?? 0) - (1.0 / 3.0)) < 0.000_001)
    }
}
