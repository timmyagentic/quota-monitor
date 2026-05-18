import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Round-trip tests for `RateLimitsHydrator` — the warm-start path that
/// pulls the most recent persisted Codex rate-limit snapshot out of
/// `rate_limit_samples` so the menu bar has something to show before
/// the first live poll lands.
///
/// The schema we test against is the one `RateLimitPoller.persist` writes
/// for live polls and `ImportEngine` writes for JSONL rollout imports.
/// If either writer drifts, these round-trips fail loudly rather than
/// the warm-start silently returning nil.
@Suite("RateLimitsHydrator round-trip")
struct RateLimitsHydratorTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "rl-hyd-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Inserts a row in the shape `RateLimitPoller.persist` / `ImportEngine`
    /// would write. SQL is inlined (rather than calling persist) because
    /// persist is private and the whole point of this suite is to verify
    /// the on-disk schema, not the writer's API surface.
    private func insert(
        _ db: DatabaseManager,
        sourceKind: String = "live",
        sampleAt: String,
        bucket: String,
        limitName: String? = nil,
        plan: String? = nil,
        usedPercent: Double,
        resetAt: String
    ) async throws {
        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO rate_limit_samples
                  (source_kind, source_session_id, bucket, sample_timestamp,
                   plan_type, limit_name, window_start, resets_at,
                   used_percent, remaining_percent)
                VALUES (?, NULL, ?, ?, ?, ?, NULL, ?, ?, ?)
                """, arguments: [
                    sourceKind, bucket, sampleAt, plan, limitName, resetAt,
                    usedPercent, max(0, 100 - usedPercent)
                ])
        }
    }

    // MARK: - happy path

    @Test("live primary + secondary round-trip with plan_type")
    func roundTripLiveBuckets() async throws {
        let db = try makeDatabase()
        let captured = "2026-05-18T10:00:00Z"
        try await insert(db, sampleAt: captured, bucket: "primary",
                         plan: "plus",
                         usedPercent: 23, resetAt: "2026-05-18T15:00:00Z")
        try await insert(db, sampleAt: captured, bucket: "secondary",
                         plan: "plus",
                         usedPercent: 8, resetAt: "2026-05-25T10:00:00Z")

        let snap = try #require(try await RateLimitsHydrator.loadLatest(database: db))
        #expect(snap.planType == "plus")
        #expect(abs((snap.primary?.usedPercent ?? 0) - 23) < 0.0001)
        #expect(abs((snap.secondary?.usedPercent ?? 0) - 8) < 0.0001)
        #expect(snap.additional.isEmpty)
        // Window duration is inferred from bucket — verify the inference
        // didn't get flipped (5h primary, 7d secondary).
        #expect(snap.primary?.windowDuration == 18_000)
        #expect(snap.secondary?.windowDuration == 604_800)
    }

    // MARK: - per-bucket max wins

    @Test("per-bucket max wins — older row in same bucket is ignored")
    func perBucketMaxWins() async throws {
        let db = try makeDatabase()
        // Older primary — must be ignored.
        try await insert(db, sampleAt: "2026-05-18T09:00:00Z",
                         bucket: "primary",
                         usedPercent: 99, resetAt: "2026-05-18T14:00:00Z")
        // Newer primary — must win.
        try await insert(db, sampleAt: "2026-05-18T10:00:00Z",
                         bucket: "primary",
                         usedPercent: 12, resetAt: "2026-05-18T15:00:00Z")

        let snap = try #require(try await RateLimitsHydrator.loadLatest(database: db))
        #expect(abs((snap.primary?.usedPercent ?? -1) - 12) < 0.0001,
                "older 99% sample must NOT bleed into the hydrated snapshot")
    }

    // MARK: - jsonl fallback

    @Test("jsonl rows hydrate when no live rows exist")
    func jsonlFallsBackWhenLiveMissing() async throws {
        let db = try makeDatabase()
        try await insert(db, sourceKind: "jsonl",
                         sampleAt: "2026-05-18T09:00:00Z",
                         bucket: "primary",
                         usedPercent: 55, resetAt: "2026-05-18T14:00:00Z")

        let snap = try #require(try await RateLimitsHydrator.loadLatest(database: db))
        #expect(abs((snap.primary?.usedPercent ?? 0) - 55) < 0.0001,
                "jsonl-sourced rows must hydrate when live is unavailable")
    }

    @Test("live rows beat older jsonl rows for the same bucket")
    func liveBeatsOlderJsonl() async throws {
        let db = try makeDatabase()
        // Older jsonl — should lose to the newer live row.
        try await insert(db, sourceKind: "jsonl",
                         sampleAt: "2026-05-18T08:00:00Z",
                         bucket: "primary",
                         usedPercent: 80, resetAt: "2026-05-18T13:00:00Z")
        // Newer live row.
        try await insert(db, sourceKind: "live",
                         sampleAt: "2026-05-18T10:00:00Z",
                         bucket: "primary",
                         usedPercent: 5, resetAt: "2026-05-18T15:00:00Z")

        let snap = try #require(try await RateLimitsHydrator.loadLatest(database: db))
        #expect(abs((snap.primary?.usedPercent ?? -1) - 5) < 0.0001)
    }

    // MARK: - additional rows

    @Test("per-model additional rows hydrate by limit_name")
    func additionalRoundTrip() async throws {
        let db = try makeDatabase()
        let captured = "2026-05-18T10:00:00Z"
        // Plain primary.
        try await insert(db, sampleAt: captured, bucket: "primary",
                         usedPercent: 5, resetAt: "2026-05-18T15:00:00Z")
        // Per-model primary — distinct from the plain row above.
        try await insert(db, sampleAt: captured, bucket: "primary",
                         limitName: "gpt-5",
                         usedPercent: 30, resetAt: "2026-05-18T15:00:00Z")

        let snap = try #require(try await RateLimitsHydrator.loadLatest(database: db))
        #expect(snap.primary != nil)
        #expect(snap.additional.count == 1)
        #expect(snap.additional.first?.limitName == "gpt-5")
        #expect(abs((snap.additional.first?.primary?.usedPercent ?? 0) - 30) < 0.0001)
    }

    // MARK: - cross-provider isolation

    @Test("claude_oauth rows must not leak into Codex hydrate")
    func claudeSourceIgnored() async throws {
        let db = try makeDatabase()
        // Only Claude-source rows exist — Codex hydrate must return nil.
        try await insert(db, sourceKind: "claude_oauth",
                         sampleAt: "2026-05-18T10:00:00Z",
                         bucket: "primary",
                         usedPercent: 77, resetAt: "2026-05-18T15:00:00Z")
        let snap = try await RateLimitsHydrator.loadLatest(database: db)
        #expect(snap == nil,
                "Codex hydrate must ignore Claude-source rows that share the table")
    }

    // MARK: - empty DB

    @Test("empty DB returns nil")
    func emptyDatabase() async throws {
        let db = try makeDatabase()
        let snap = try await RateLimitsHydrator.loadLatest(database: db)
        #expect(snap == nil, "no rows → nil so warm-start path knows to skip")
    }
}
