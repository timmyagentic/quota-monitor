import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Quota cycle storage and local usage")
struct QuotaCycleStorageTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() throws -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-cycle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DatabaseManager(url: directory.appendingPathComponent("usage.sqlite"))
    }

    private func observation(provider: String = "codex", at: Double = 100,
                             reset: Double = 18_000, used: Double = 20) -> QuotaCycle.Observation {
        .init(provider: provider, bucket: "primary", scope: "fixture-account", plan: "pro",
              capturedAt: origin.addingTimeInterval(at), resetAt: origin.addingTimeInterval(reset),
              duration: 18_000, usedPercent: used)
    }

    @Test func persistenceRetainsEvidenceAndMissingWindowsCannotBeResurrected() throws {
        let manager = try database()
        try manager.pool.write { db in
            let first = observation(at: 17_900, used: 90)
            try QuotaCycleStore.record(db: db, provider: "codex", capturedAt: first.capturedAt,
                                       observations: [first])
            let next = observation(at: 18_100, reset: 36_000, used: 1)
            try QuotaCycleStore.record(db: db, provider: "codex", capturedAt: next.capturedAt,
                                       observations: [next])
        }
        let cycles = try manager.pool.read { try QuotaCycleStore.cycles(db: $0) }
        #expect(cycles.first?.basis == .observedRollover)
        #expect(cycles.first?.start == origin.addingTimeInterval(18_000))
        try manager.pool.write { db in
            try QuotaCycleStore.record(db: db, provider: "codex",
                                       capturedAt: origin.addingTimeInterval(18_200), observations: [])
            let late = observation(at: 18_150, reset: 36_000)
            try QuotaCycleStore.record(db: db, provider: "codex", capturedAt: late.capturedAt,
                                       observations: [late])
            #expect(try QuotaCycleStore.cycles(db: db).isEmpty)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quota_cycle_state") == 1)
        }
    }

    @Test func localTotalsUseExactBoundariesAndProviderSpecificCacheDenominators() throws {
        let manager = try database()
        try manager.pool.write { db in
            for provider in ["codex", "claude"] {
                try seed(db: db, provider: provider, offset: -0.001)
                try seed(db: db, provider: provider, offset: 0)
                try seed(db: db, provider: provider, offset: 300)
                try seed(db: db, provider: provider, offset: 999.999)
                try seed(db: db, provider: provider, offset: 1_000)
            }
        }
        let cycles = ["codex", "claude"].map {
            QuotaCycle.resolve(observation(provider: $0), previous: nil)
        }
        let results = try manager.pool.read { db in
            try Aggregator.quotaCycleUsage(db: db, cycles: cycles,
                                           now: origin.addingTimeInterval(1_000))
        }
        let codex = try #require(results.first { $0.cycle.observation.provider == "codex" })
        let claude = try #require(results.first { $0.cycle.observation.provider == "claude" })
        for result in results {
            #expect(result.eventCount == 3)
            #expect(result.tokens == 360)
            #expect(abs(result.valueUSD - 0.3) < 0.000_001)
            #expect(result.points.first?.tokens == 0)
            #expect(result.points.last?.tokens == result.tokens)
            #expect(result.points.last?.date == result.through)
            #expect(result.points.map(\.date) == result.points.map(\.date).sorted())
        }
        #expect(codex.cacheUsage == .init(readTokens: 150, eligibleInputTokens: 300))
        #expect(claude.cacheUsage == .init(readTokens: 150, eligibleInputTokens: 510))
    }

    @Test func weeklyTotalsIncludeEarlierFiveHourWindowsAndExcludeThePreviousWeek() throws {
        let manager = try database()
        let now = origin.addingTimeInterval(3 * 86_400)
        let cycles = ["codex", "claude"].flatMap { provider in
            ["primary", "secondary"].map { bucket in
                let duration: TimeInterval = bucket == "primary" ? 18_000 : 604_800
                let start = bucket == "primary" ? now.addingTimeInterval(-3_600) : origin
                return QuotaCycle.resolve(.init(provider: provider, bucket: bucket,
                    scope: "fixture-account", plan: "pro", capturedAt: now,
                    resetAt: start.addingTimeInterval(duration), duration: duration,
                    usedPercent: 20), previous: nil)
            }
        }
        try manager.pool.write { db in
            let offsets: [Double] = [-0.001, 0, 86_400, 3 * 86_400 - 1, 3 * 86_400]
            for provider in ["codex", "claude"] {
                for offset in offsets {
                    try seed(db: db, provider: provider, offset: offset)
                }
            }
        }
        let results = try manager.pool.read { db in
            try Aggregator.quotaCycleUsage(db: db, cycles: cycles, now: now)
        }
        #expect(results.count == 4)
        for usage in results {
            let weekly = usage.cycle.observation.bucket == "secondary"
            #expect(usage.eventCount == (weekly ? 3 : 1))
            #expect(usage.tokens == (weekly ? 360 : 120))
            #expect(abs(usage.valueUSD - (weekly ? 0.3 : 0.1)) < 0.000_001)
            #expect(usage.points.last?.tokens == usage.tokens)
        }
    }

    @Test func unpricedRecordsKeepTokensButMarkTheCostIncomplete() throws {
        let manager = try database()
        try manager.pool.write { db in
            try seed(db: db, provider: "codex", offset: 0)
            try seed(db: db, provider: "codex", offset: 300)
            try db.execute(sql: "UPDATE usage_events SET value_usd = 0 WHERE id = (SELECT MAX(id) FROM usage_events)")
        }
        let result = try #require(try manager.pool.read { db in
            try Aggregator.quotaCycleUsage(db: db,
                cycles: [QuotaCycle.resolve(observation(), previous: nil)],
                now: origin.addingTimeInterval(1_000)).first
        })
        #expect(result.tokens == 240)
        #expect(result.eventCount == 2)
        #expect(result.unpricedEventCount == 1)
        #expect(result.valueUSD == 0.1)
    }

    @Test func unconfirmedStartKeepsPaceUnavailableButShowsEstimatedLocalRecordsAfterRelaunch() throws {
        let manager = try database()
        let original = QuotaCycle.resolve(observation(), previous: nil)
        let unresolved = QuotaCycle.resolve(observation(at: 200, used: 1), previous: original)
        let restored = try JSONDecoder().decode(QuotaCycle.self, from: JSONEncoder().encode(unresolved))
        let snapshot = RateLimitSnapshot(capturedAt: restored.observation.capturedAt,
            planType: restored.observation.plan,
            primary: .init(usedPercent: 1, windowDuration: 18_000, resetAt: restored.observation.resetAt),
            secondary: nil, additional: [], resetCreditsAvailable: nil)
        let selected = QuotaCycleSelection.make(codex: snapshot, claude: nil, stored: [restored])
        try manager.pool.write { db in
            for offset in [-1.0, 0, 300, 1_000] {
                try seed(db: db, provider: "codex", offset: offset)
            }
            try seed(db: db, provider: "claude", offset: 300)
        }
        try manager.pool.read { db in
            let result = try Aggregator.quotaCycleUsage(db: db, cycles: selected,
                                                        now: origin.addingTimeInterval(1_000))
            #expect(result.first?.cycle.start == nil)
            #expect(result.first?.cycle.allowsPaceEstimate == false)
            #expect(result.first?.cycle.localUsageIsEstimated == true)
            #expect(result.first?.eventCount == 2)
            #expect(result.first?.tokens == 240)
            #expect(result.first?.cacheUsage.hitRate == 0.5)
            #expect(result.first?.valueUSD == 0.2)
            #expect(result.first?.points.first?.date == origin)
            #expect(result.first?.points.last?.tokens == 240)
            #expect(try Aggregator.quotaCycleUsage(db: db, cycles: [original],
                                                   now: original.observation.resetAt).isEmpty)
            let invalid = QuotaCycle.resolve(observation(reset: 40_000), previous: nil)
            #expect(try Aggregator.quotaCycleUsage(db: db, cycles: [invalid],
                now: origin.addingTimeInterval(1_000)).first?.points.isEmpty == true)
        }
    }

    @Test func localTotalsParseMixedTimestampFormatsBeforeApplyingExactBounds() throws {
        let manager = try database()
        let utc = ISO8601.fractional.string(from: origin)
        let sqlite = String(utc.prefix(19)).replacingOccurrences(of: "T", with: " ")
        let offsetFormatter = ISO8601DateFormatter()
        offsetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        offsetFormatter.timeZone = TimeZone(secondsFromGMT: -12 * 3600)
        let previousDatePrefix = offsetFormatter.string(from: origin.addingTimeInterval(300))
        offsetFormatter.timeZone = TimeZone(secondsFromGMT: 14 * 3600)
        let positiveOffset = offsetFormatter.string(from: origin.addingTimeInterval(600))
        let beforeStart = offsetFormatter.string(from: origin.addingTimeInterval(-1))
        offsetFormatter.timeZone = TimeZone(secondsFromGMT: -12 * 3600)
        let atEnd = offsetFormatter.string(from: origin.addingTimeInterval(1_000))
        try manager.pool.write { db in
            for timestamp in [sqlite, previousDatePrefix, positiveOffset, beforeStart, atEnd] {
                try seed(db: db, provider: "codex", offset: 0, timestamp: timestamp)
            }
        }
        let cycle = QuotaCycle.resolve(observation(), previous: nil)
        let result = try #require(try manager.pool.read { db in
            try Aggregator.quotaCycleUsage(db: db, cycles: [cycle],
                now: origin.addingTimeInterval(1_000)).first
        })
        #expect(result.eventCount == 3)
        #expect(result.tokens == 360)
        #expect(result.cacheUsage == .init(readTokens: 150, eligibleInputTokens: 300))
        #expect(abs(result.valueUSD - 0.3) < 0.000_001)
        #expect(result.points.map(\.tokens) == [0, 120, 240, 360, 360])
    }

    @MainActor @Test func duplicateSnapshotsDoNotScheduleAnotherCycleQuery() throws {
        let env = AppEnvironment(startBackgroundTasks: false, database: try database())
        let snapshot = RateLimitSnapshot(observationScope: "one", capturedAt: origin,
            planType: "pro", primary: nil, secondary: nil, additional: [], resetCreditsAvailable: nil)
        env.latestRateLimits = snapshot
        let firstGeneration = env.quotaCycleRefreshGeneration
        env.latestRateLimits = snapshot
        #expect(env.quotaCycleRefreshGeneration == firstGeneration)
        var differentAccount = snapshot
        differentAccount.observationScope = "two"
        env.latestRateLimits = differentAccount
        #expect(env.quotaCycleRefreshGeneration == firstGeneration + 1)
        let claude = ClaudeUsageSnapshot(capturedAt: origin, tier: nil, fiveHour: nil,
            sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil)
        env.latestClaudeUsage = claude
        let claudeGeneration = env.quotaCycleRefreshGeneration
        env.latestClaudeUsage = claude
        #expect(env.quotaCycleRefreshGeneration == claudeGeneration)
    }

    @Test func earlyChangeTotalsExcludeUncertainPollInterval() throws {
        let manager = try database()
        try manager.pool.write { db in
            try seed(db: db, provider: "codex", offset: 150)
            try seed(db: db, provider: "codex", offset: 201)
        }
        let prior = QuotaCycle.resolve(observation(used: 80), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 200, reset: 18_150, used: 1), previous: prior)
        let result = try manager.pool.read { db in
            try Aggregator.quotaCycleUsage(db: db, cycles: [cycle], now: origin.addingTimeInterval(500))
        }
        #expect(result.first?.eventCount == 1)
        #expect(result.first?.tokens == 120)
    }

    @Test func hydratedSnapshotRecoversOnlyItsOwnPersistedBoundary() {
        let previous = QuotaCycle.resolve(observation(at: 17_900, used: 90), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 18_100, reset: 36_000, used: 1), previous: previous)
        let snapshot = RateLimitSnapshot(capturedAt: cycle.observation.capturedAt,
            planType: "pro", primary: .init(usedPercent: 1, windowDuration: 18_000,
                                            resetAt: cycle.observation.resetAt),
            secondary: nil, additional: [], resetCreditsAvailable: nil)
        #expect(QuotaCycleSelection.make(codex: snapshot, claude: nil, stored: [cycle]).first == cycle)
        #expect(QuotaCycleSelection.make(codex: nil, claude: nil, stored: [cycle]).isEmpty)
        let changed = RateLimitSnapshot(capturedAt: cycle.observation.capturedAt.addingTimeInterval(300),
            planType: "pro", primary: .init(usedPercent: 0, windowDuration: 18_000,
                                            resetAt: cycle.observation.resetAt),
            secondary: nil, additional: [], resetCreditsAvailable: nil)
        #expect(QuotaCycleSelection.make(codex: changed, claude: nil, stored: [cycle]).first?.basis == .estimated)
    }

    private func seed(db: Database, provider: String, offset: Double, timestamp: String? = nil) throws {
        let session = UUID().uuidString
        let timestamp = timestamp ?? ISO8601.fractional.string(from: origin.addingTimeInterval(offset))
        try db.execute(sql: """
            INSERT INTO sessions (session_id, root_session_id, provider, created_at, imported_at)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [session, session, provider, timestamp, timestamp])
        try db.execute(sql: """
            INSERT INTO usage_events (session_id, timestamp, model_id, provider,
                total_tokens, input_tokens, cached_input_tokens, output_tokens, value_usd,
                cache_creation_tokens, cache_creation_5m_tokens, cache_creation_1h_tokens)
            VALUES (?, ?, 'fixture', ?, 120, 100, 50, 20, 0.1, 999, 5, 15)
            """, arguments: [session, timestamp, provider])
    }
}
