import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Dashboard visible snapshot cache")
struct DashboardSnapshotCacheTests {
    @Test("fresh compatible snapshot makes a warm open query-free")
    func freshSnapshotSkipsRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = cacheKey()
        let snapshot = sampleSnapshot(tokens: 100)
        var cache = DashboardSnapshotMemoryCache()

        cache.store(
            snapshot,
            for: key,
            generation: 7,
            generatedAt: now)
        let decision = cache.decision(
            for: key,
            currentGeneration: 7,
            now: now.addingTimeInterval(30),
            maxAge: 300)

        #expect(decision.snapshot == snapshot)
        #expect(!decision.needsRefresh)
        #expect(decision.reason == .fresh)
    }

    @Test("dirty snapshot remains visible while one background refresh is needed")
    func dirtySnapshotStaysVisible() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = cacheKey()
        let snapshot = sampleSnapshot(tokens: 100)
        var cache = DashboardSnapshotMemoryCache()

        cache.store(snapshot, for: key, generation: 7, generatedAt: now)
        let decision = cache.decision(
            for: key,
            currentGeneration: 8,
            now: now.addingTimeInterval(30),
            maxAge: 300)

        #expect(decision.snapshot == snapshot)
        #expect(decision.needsRefresh)
        #expect(decision.reason == .generationChanged)
    }

    @Test("expired and restored snapshots display before revalidation")
    func expiredAndRestoredSnapshotsStayVisible() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = cacheKey()
        let snapshot = sampleSnapshot(tokens: 100)
        var expired = DashboardSnapshotMemoryCache()
        expired.store(
            snapshot,
            for: key,
            generation: 2,
            generatedAt: now.addingTimeInterval(-301))

        let expiredDecision = expired.decision(
            for: key, currentGeneration: 2, now: now, maxAge: 300)
        #expect(expiredDecision.snapshot == snapshot)
        #expect(expiredDecision.needsRefresh)
        #expect(expiredDecision.reason == .expired)

        var restored = DashboardSnapshotMemoryCache()
        restored.restore(DashboardSnapshotCacheEnvelope(
            key: key,
            generatedAt: now,
            snapshot: snapshot))
        let restoredDecision = restored.decision(
            for: key, currentGeneration: 0, now: now, maxAge: 300)
        #expect(restoredDecision.snapshot == snapshot)
        #expect(restoredDecision.needsRefresh)
        #expect(restoredDecision.reason == .restored)
    }

    @Test("a snapshot never crosses provider or timezone cache keys")
    func cacheKeysAreSemantic() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = DashboardSnapshotMemoryCache()
        cache.store(
            sampleSnapshot(tokens: 100),
            for: cacheKey(),
            generation: 1,
            generatedAt: now)

        let codexOnly = DashboardSnapshotCacheKey(
            providerFilter: .codex,
            enabledProviders: ["codex", "claude"],
            timeZoneIdentifier: "Asia/Shanghai")
        let otherTimeZone = DashboardSnapshotCacheKey(
            providerFilter: .all,
            enabledProviders: ["codex", "claude"],
            timeZoneIdentifier: "America/New_York")

        #expect(cache.decision(
            for: codexOnly, currentGeneration: 1, now: now, maxAge: 300
        ).snapshot == nil)
        #expect(cache.decision(
            for: otherTimeZone, currentGeneration: 1, now: now, maxAge: 300
        ).snapshot == nil)
    }

    @Test("persistent last-good snapshot round-trips atomically with private permissions")
    func persistentSnapshotRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-cache-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("snapshot.json")
        let store = DashboardSnapshotStore(fileURL: url)
        let envelope = DashboardSnapshotCacheEnvelope(
            key: cacheKey(),
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshot: sampleSnapshot(tokens: 321))

        try store.save(envelope)
        let loaded = try #require(store.load())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

        #expect(loaded == envelope)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("persistent cache ignores corruption and unsupported schemas")
    func persistentSnapshotFailsOpen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-cache-invalid-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("snapshot.json")
        let store = DashboardSnapshotStore(fileURL: url)

        try Data("not-json".utf8).write(to: url)
        #expect(store.load() == nil)

        let unsupported = DashboardSnapshotCacheEnvelope(
            schemaVersion: DashboardSnapshotCacheEnvelope.currentSchemaVersion + 1,
            key: cacheKey(),
            generatedAt: Date(),
            snapshot: sampleSnapshot(tokens: 1))
        let data = try JSONEncoder().encode(unsupported)
        try data.write(to: url, options: .atomic)
        #expect(store.load() == nil)
    }

    @Test("primary publication can preserve and later replace Activity")
    func primarySnapshotDoesNotWaitForActivity() throws {
        let original = sampleSnapshot(tokens: 100)
        let primary = original.primary
        let oldActivity = original.activity
        let newActivity = ActivitySnapshot(
            lifetimeTokens: 999,
            peakDayTokens: 999,
            peakDay: Date(timeIntervalSince1970: 1_800_000_000),
            currentStreakDays: 2,
            longestStreakDays: 3,
            activeDays: 4,
            daily: [])

        let immediate = DashboardSnapshot(primary: primary, activity: oldActivity)
        let completed = immediate.replacingActivity(newActivity)

        #expect(immediate.trends == original.trends)
        #expect(immediate.activity == oldActivity)
        #expect(completed.primary == primary)
        #expect(completed.activity == newActivity)
    }

    private func cacheKey() -> DashboardSnapshotCacheKey {
        DashboardSnapshotCacheKey(
            providerFilter: .all,
            enabledProviders: ["claude", "codex"],
            timeZoneIdentifier: "Asia/Shanghai")
    }

    private func sampleSnapshot(tokens: Int64) -> DashboardSnapshot {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let daily = DailyPoint(
            date: date,
            valueUSD: 1,
            tokens: tokens,
            cacheUsage: CacheUsageSummary(
                readTokens: tokens / 2,
                eligibleInputTokens: tokens))
        let breakdown = DailyBreakdownPoint(
            date: date,
            provider: "codex",
            key: "gpt-5",
            label: "GPT-5",
            valueUSD: 1,
            tokens: tokens)
        let window = TrendWindowSnapshot(
            daily: [daily],
            providerBreakdown: [breakdown],
            modelBreakdown: [breakdown])
        let trends = DashboardTrendData(
            last7Days: window,
            last30Days: window,
            last90Days: window,
            last365Days: window,
            prior30DayValueUSD: 0)
        return DashboardSnapshot(
            overview: OverviewStats(
                totalValueUSD: 1,
                totalTokens: tokens,
                totalSessions: 1,
                totalEvents: 1,
                firstEventAt: "2027-01-15T08:00:00Z",
                lastEventAt: "2027-01-15T08:00:00Z"),
            daily: [daily],
            dailyExtended: [daily],
            trends: trends,
            monthly: [MonthlyPoint(
                month: date, valueUSD: 1, tokens: tokens, sessionCount: 1)],
            modelShares: [ModelShare(
                modelId: "gpt-5", displayName: "GPT-5",
                valueUSD: 1, tokens: tokens, eventCount: 1)],
            modelShares30d: [],
            modelSharesPrior30d: [],
            providerShares30d: [ProviderShare(
                provider: "codex", valueUSD: 1, tokens: tokens)],
            recentRateLimits: [],
            codexQuota: nil,
            activity: ActivitySnapshot(
                lifetimeTokens: tokens,
                peakDayTokens: tokens,
                peakDay: date,
                currentStreakDays: 1,
                longestStreakDays: 1,
                activeDays: 1,
                daily: [daily]))
    }
}
