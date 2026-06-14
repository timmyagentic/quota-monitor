import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Regression tests for `RateLimitSampleRetention.prune`.
///
/// The table grows without bound because the live pollers append on every
/// poll and nothing deleted the rows. These pin the retention contract:
///
///   - stale rows that are NOT the newest of their group are removed,
///   - rows inside the retention window are always kept,
///   - the newest row of each group survives even when it is itself older
///     than the window (cold-source cold-start guard),
///   - grouping is per `(source_kind, bucket, limit_name)`,
///   - `jsonl` rows are never touched (the importer owns them).
@Suite("Rate-limit sample retention")
struct RateLimitSampleRetentionTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "retention-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert one `rate_limit_samples` row `daysAgo` in the past and return
    /// its rowid. `sample_timestamp` is ISO8601 to match what the pollers write.
    @discardableResult
    private func seed(
        in db: DatabaseManager,
        sourceKind: String,
        bucket: String = "primary",
        limitName: String? = nil,
        daysAgo: Double,
        usedPercent: Double = 50
    ) throws -> Int64 {
        let when = Date().addingTimeInterval(-daysAgo * 86_400)
        let stamp = ISO8601.fractional.string(from: when)
        return try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO rate_limit_samples
                  (source_kind, source_session_id, bucket, sample_timestamp,
                   plan_type, limit_name, window_start, resets_at,
                   used_percent, remaining_percent)
                VALUES (?, NULL, ?, ?, NULL, ?, NULL, ?, ?, ?)
                """, arguments: [
                    sourceKind, bucket, stamp, limitName,
                    stamp, usedPercent, max(0, 100 - usedPercent)
                ])
            return conn.lastInsertedRowID
        }
    }

    private func remainingIDs(_ db: DatabaseManager) throws -> Set<Int64> {
        try db.pool.read { conn in
            Set(try Int64.fetchAll(conn, sql: "SELECT id FROM rate_limit_samples"))
        }
    }

    @discardableResult
    private func prune(
        _ db: DatabaseManager,
        days: Int = RateLimitSampleRetention.defaultRetentionDays
    ) throws -> Int {
        try db.pool.write { conn in
            try RateLimitSampleRetention.prune(db: conn, olderThanDays: days)
        }
    }

    @Test("prunes stale non-newest rows, keeps in-window and newest")
    func prunesStaleNonNewest() throws {
        let db = try makeDatabase()
        let stale = try seed(in: db, sourceKind: "live", daysAgo: 10)
        let inWindow = try seed(in: db, sourceKind: "live", daysAgo: 3)
        let newest = try seed(in: db, sourceKind: "live", daysAgo: 0.01)

        let deleted = try prune(db)

        #expect(deleted == 1)
        #expect(try remainingIDs(db) == [inWindow, newest])
        #expect(!(try remainingIDs(db)).contains(stale))
    }

    @Test("cold source keeps the newest row even when it is older than the window")
    func coldSourceKeepsNewest() throws {
        let db = try makeDatabase()
        let oldest = try seed(in: db, sourceKind: "live", daysAgo: 40)
        let newestButStale = try seed(in: db, sourceKind: "live", daysAgo: 20)

        let deleted = try prune(db)

        #expect(deleted == 1)
        #expect(try remainingIDs(db) == [newestButStale],
                "the latest snapshot must survive so cold-start hydrate has data")
        #expect(!(try remainingIDs(db)).contains(oldest))
    }

    @Test("keeps newest per (source_kind, bucket, limit_name) group")
    func keepsNewestPerGroup() throws {
        let db = try makeDatabase()
        let groups: [(String, String, String?)] = [
            ("live", "primary", nil),
            ("live", "secondary", nil),
            ("live", "secondary", "opus"),
            ("claude_oauth", "primary", nil),
        ]
        var newestByGroup: Set<Int64> = []
        for (kind, bucket, limit) in groups {
            _ = try seed(in: db, sourceKind: kind, bucket: bucket,
                         limitName: limit, daysAgo: 40)
            let newest = try seed(in: db, sourceKind: kind, bucket: bucket,
                                  limitName: limit, daysAgo: 30)
            newestByGroup.insert(newest)
        }

        let deleted = try prune(db)

        #expect(deleted == groups.count)
        #expect(try remainingIDs(db) == newestByGroup)
    }

    @Test("jsonl rows are never pruned")
    func jsonlExempt() throws {
        let db = try makeDatabase()
        let a = try seed(in: db, sourceKind: "jsonl", daysAgo: 40)
        let b = try seed(in: db, sourceKind: "jsonl", daysAgo: 30)

        let deleted = try prune(db)

        #expect(deleted == 0)
        #expect(try remainingIDs(db) == [a, b])
    }

    @Test("no-op when every row is within the window")
    func allRecentNoop() throws {
        let db = try makeDatabase()
        _ = try seed(in: db, sourceKind: "live", daysAgo: 1)
        _ = try seed(in: db, sourceKind: "claude_oauth", daysAgo: 2)

        let deleted = try prune(db)

        #expect(deleted == 0)
        #expect((try remainingIDs(db)).count == 2)
    }
}
