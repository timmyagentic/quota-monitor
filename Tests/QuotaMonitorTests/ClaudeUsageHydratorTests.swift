import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Round-trip tests for `ClaudeUsageHydrator` — the warm-start path that
/// pulls the most recent persisted Claude `/usage` snapshot out of
/// `rate_limit_samples` so the menu bar has something to show on cold
/// boot, even before the next live poll.
///
/// Verifies the hydrator's grouping logic against rows shaped EXACTLY the
/// way `ClaudeUsagePoller.persist` writes them. If the persist schema
/// drifts, this test will fail loudly rather than the warm-start silently
/// returning nil.
@Suite("ClaudeUsageHydrator round-trip")
struct ClaudeUsageHydratorTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "hyd-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert rows in the exact shape `ClaudeUsagePoller.persist` writes.
    /// We reproduce the SQL inline rather than calling persist directly
    /// because persist is private — but the schema check is the whole
    /// point, so duplicating the column list is intentional.
    private func insert(
        _ db: DatabaseManager,
        sampleAt: String,
        bucket: String,
        limitName: String?,
        plan: String?,
        usedPercent: Double,
        resetAt: String
    ) async throws {
        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO rate_limit_samples
                  (source_kind, source_session_id, bucket, sample_timestamp,
                   plan_type, limit_name, window_start, resets_at,
                   used_percent, remaining_percent)
                VALUES ('claude_oauth', NULL, ?, ?, ?, ?, NULL, ?, ?, ?)
                """, arguments: [
                    bucket, sampleAt, plan, limitName, resetAt,
                    usedPercent, max(0, 100 - usedPercent)
                ])
        }
    }

    // MARK: - happy path

    @Test("all 4 windows + tier round-trip cleanly")
    func roundTripAllWindows() async throws {
        let db = try makeDatabase()
        let captured = "2026-04-29T10:00:00Z"
        let resetIn1h = "2026-04-29T11:00:00Z"
        let resetIn7d = "2026-05-06T10:00:00Z"

        try await insert(db, sampleAt: captured, bucket: "primary",
                         limitName: nil, plan: "max5x",
                         usedPercent: 42.5, resetAt: resetIn1h)
        try await insert(db, sampleAt: captured, bucket: "secondary",
                         limitName: nil, plan: "max5x",
                         usedPercent: 18.3, resetAt: resetIn7d)
        try await insert(db, sampleAt: captured, bucket: "secondary",
                         limitName: "opus", plan: "max5x",
                         usedPercent: 73.1, resetAt: resetIn7d)
        try await insert(db, sampleAt: captured, bucket: "secondary",
                         limitName: "sonnet", plan: "max5x",
                         usedPercent: 9.8, resetAt: resetIn7d)

        let snap = try #require(try await ClaudeUsageHydrator.loadLatest(database: db))
        #expect(snap.tier == "max5x")
        #expect(abs((snap.fiveHour?.usedPercent ?? 0) - 42.5) < 0.0001)
        #expect(abs((snap.sevenDay?.usedPercent ?? 0) - 18.3) < 0.0001)
        #expect(abs((snap.sevenDayOpus?.usedPercent ?? 0) - 73.1) < 0.0001)
        #expect(abs((snap.sevenDaySonnet?.usedPercent ?? 0) - 9.8) < 0.0001)
    }

    // MARK: - newest-only group

    @Test("only the newest sample_timestamp group is reconstructed")
    func newestSampleGroupWins() async throws {
        let db = try makeDatabase()
        // Old snapshot — must be ignored.
        try await insert(db, sampleAt: "2026-04-28T10:00:00Z",
                         bucket: "primary", limitName: nil, plan: "free",
                         usedPercent: 99, resetAt: "2026-04-28T11:00:00Z")
        // Newer snapshot — must win.
        try await insert(db, sampleAt: "2026-04-29T10:00:00Z",
                         bucket: "primary", limitName: nil, plan: "max5x",
                         usedPercent: 1.0, resetAt: "2026-04-29T11:00:00Z")

        let snap = try #require(try await ClaudeUsageHydrator.loadLatest(database: db))
        #expect(abs((snap.fiveHour?.usedPercent ?? -1) - 1.0) < 0.0001,
                "older 99% sample must NOT bleed into the newest snapshot")
        #expect(snap.tier == "max5x")
    }

    @Test("newest 7d-only sample keeps the expired 5h sample as stale")
    func newestSevenDayOnlySampleKeepsExpiredFiveHourAsStale() async throws {
        let db = try makeDatabase()
        try await insert(db, sampleAt: "2026-04-29T10:00:00Z",
                         bucket: "primary", limitName: nil, plan: "pro",
                         usedPercent: 3.0, resetAt: "2026-04-29T11:00:00Z")
        try await insert(db, sampleAt: "2026-04-29T12:00:00Z",
                         bucket: "secondary", limitName: nil, plan: "pro",
                         usedPercent: 27.0, resetAt: "2026-05-06T12:00:00Z")

        let snap = try #require(try await ClaudeUsageHydrator.loadLatest(database: db))
        #expect(snap.fiveHour == nil,
                "expired fallback must not masquerade as the active 5h window")
        #expect(abs((snap.staleFiveHour?.usedPercent ?? -1) - 3.0) < 0.0001)
        #expect(abs((snap.sevenDay?.usedPercent ?? -1) - 27.0) < 0.0001)
    }

    // MARK: - partial windows (model-only quotas, no plain secondary)

    @Test("opus/sonnet without a plain secondary row still hydrate")
    func opusSonnetOnly_withoutPlainSecondary() async throws {
        let db = try makeDatabase()
        let captured = "2026-04-29T10:00:00Z"

        try await insert(db, sampleAt: captured, bucket: "primary",
                         limitName: nil, plan: "max5x",
                         usedPercent: 5, resetAt: "2026-04-29T11:00:00Z")
        // No plain (limit_name=nil) secondary row. Just per-model.
        try await insert(db, sampleAt: captured, bucket: "secondary",
                         limitName: "opus", plan: "max5x",
                         usedPercent: 60, resetAt: "2026-05-06T10:00:00Z")
        try await insert(db, sampleAt: captured, bucket: "secondary",
                         limitName: "sonnet", plan: "max5x",
                         usedPercent: 20, resetAt: "2026-05-06T10:00:00Z")

        let snap = try #require(try await ClaudeUsageHydrator.loadLatest(database: db))
        #expect(snap.fiveHour != nil)
        #expect(snap.sevenDay == nil,
                "no plain secondary row → plain 7d window must be nil")
        #expect(abs((snap.sevenDayOpus?.usedPercent ?? 0) - 60) < 0.0001)
        #expect(abs((snap.sevenDaySonnet?.usedPercent ?? 0) - 20) < 0.0001)
    }

    @Test("Fable-only named weekly row hydrates without aggregate windows")
    func fableOnly_withoutAggregateWindows() async throws {
        let db = try makeDatabase()
        let captured = "2026-07-20T10:00:00Z"

        try await insert(db, sampleAt: captured, bucket: "secondary",
                         limitName: "fable", plan: "max20x",
                         usedPercent: 62, resetAt: "2026-07-24T10:00:00Z")

        let snap = try #require(try await ClaudeUsageHydrator.loadLatest(database: db))
        #expect(snap.fiveHour == nil)
        #expect(snap.sevenDay == nil)
        #expect(snap.weeklyScoped.map(\.key) == ["fable"])
        #expect(snap.weeklyScoped.first?.displayName == "Fable 5")
        #expect(abs((snap.sevenDayFable?.usedPercent ?? -1) - 62) < 0.0001)
        #expect(snap.hasRenderableQuotaWindow)
    }

    // MARK: - empty DB

    @Test("empty DB returns nil, not an empty snapshot")
    func emptyDatabase_returnsNil() async throws {
        let db = try makeDatabase()
        let snap = try await ClaudeUsageHydrator.loadLatest(database: db)
        #expect(snap == nil, "no rows → nil so warm-start path knows to skip")
    }

    // MARK: - Codex samples don't pollute

    @Test("rows with source_kind != 'claude_oauth' are ignored")
    func codexSamplesIgnored() async throws {
        let db = try makeDatabase()
        // Codex row that happens to share the captured timestamp shape.
        try await db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO rate_limit_samples
                  (source_kind, source_session_id, bucket, sample_timestamp,
                   plan_type, limit_name, window_start, resets_at,
                   used_percent, remaining_percent)
                VALUES ('jsonl', 'sess-1', 'primary',
                        '2026-04-29T10:00:00Z', 'plus', NULL, NULL,
                        '2026-04-29T11:00:00Z', 88, 12)
                """)
        }
        let snap = try await ClaudeUsageHydrator.loadLatest(database: db)
        #expect(snap == nil,
                "Codex source_kind rows must NOT hydrate into the Claude snapshot")
    }
}
