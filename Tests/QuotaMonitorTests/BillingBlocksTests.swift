import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Coverage for the 5-hour billing-block algorithm
/// (`Core/Analytics/BillingBlocks.swift`), ported from ccusage.
///
/// Pre-2026-04-30 this had zero tests despite being the engine behind every
/// "Active 5h block" / "Pace ~$X.XX/hr" string in the menu bar. The math is
/// not complicated but it's full of edge cases (gaps > 5h, hour-flooring of
/// block start, active-vs-closed determination at "now") and any silent
/// regression would directly mislead the user.
///
/// We exercise the public entry point `loadSnapshot(db:provider:now:)` —
/// the lower-level helpers (`identifyBlocks`, `makeBlock`, …) are private,
/// and DB-level tests are closer to what production actually hits anyway.
@Suite("BillingBlocks")
struct BillingBlocksTests {

    // MARK: - DB harness (mirrors AggregatorTests.makeDatabase shape)

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "blocks-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert one usage_event at an absolute timestamp. We need absolute
    /// timestamps (not "daysAgo") because the algorithm pivots on the
    /// `now` parameter — keeping `seedAt` and `now` aligned is what makes
    /// the active/closed assertions deterministic.
    private func seedEvent(
        in db: DatabaseManager,
        provider: String = "claude",
        sessionId: String,
        at when: Date,
        modelId: String = "claude-3-5-sonnet",
        valueUSD: Double = 1.00,
        inputTokens: Int64 = 100,
        outputTokens: Int64 = 50
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = iso.string(from: when)

        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL,
                        ?, NULL, 0, ?, ?, ?)
                """, arguments: [
                    sessionId, sessionId, stamp, stamp,
                    modelId, stamp, stamp, provider
                ])
            try conn.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred)
                VALUES (?, ?, ?, ?, 0, ?, 0, ?, ?, ?, 0, 0)
                """, arguments: [
                    sessionId, stamp, modelId,
                    inputTokens, outputTokens,
                    inputTokens + outputTokens,
                    valueUSD, provider
                ])
        }
    }

    // MARK: - empty input

    @Test("empty DB returns an empty snapshot, not a crash or nil-deref")
    func emptyDatabase() throws {
        let db = try makeDatabase()
        let snap = try db.pool.read { conn in
            try BillingBlocks.loadSnapshot(db: conn, provider: .claude)
        }
        #expect(snap.currentBlock == nil)
        #expect(snap.burnRate == nil)
        #expect(snap.projection == nil)
        #expect(snap.recentBlocks.isEmpty)
    }

    // MARK: - single event → one active block

    @Test("single recent event yields one active block with that event's tokens/cost")
    func singleEventActiveBlock() throws {
        let db = try makeDatabase()
        // Put the event 30 minutes ago — well within the 5h window from `now`.
        let now = Date()
        let when = now.addingTimeInterval(-30 * 60)
        try seedEvent(in: db, sessionId: "s-1", at: when,
                      valueUSD: 2.50, inputTokens: 1000, outputTokens: 500)

        let snap = try db.pool.read { conn in
            try BillingBlocks.loadSnapshot(db: conn, provider: .claude, now: now)
        }
        let block = try #require(snap.currentBlock)
        #expect(block.isActive == true,
                "event 30 min ago must produce an active 5h block")
        #expect(block.isGap == false)
        #expect(block.entryCount == 1)
        #expect(block.tokenCounts.input == 1000)
        #expect(block.tokenCounts.output == 500)
        #expect(abs(block.costUSD - 2.50) < 1e-9)
        #expect(block.models == ["claude-3-5-sonnet"])
        // Block start must be hour-floored, not equal to the event timestamp.
        #expect(block.startTime <= when,
                "startTime is hour-floor of the first event, so <= the event timestamp")
        #expect(block.endTime == block.startTime.addingTimeInterval(5 * 3600))
        #expect(snap.recentBlocks.count == 1)
        #expect(snap.recentBlocks.first?.id == block.id)
    }

    // MARK: - active vs closed determination

    @Test("event >5h ago yields a closed (non-active) block")
    func oldEventBlockIsClosed() throws {
        let db = try makeDatabase()
        let now = Date()
        // 6 hours ago = strictly outside the 5h window from now → closed.
        let when = now.addingTimeInterval(-6 * 3600)
        try seedEvent(in: db, sessionId: "s-1", at: when)

        let snap = try db.pool.read { conn in
            try BillingBlocks.loadSnapshot(db: conn, provider: .claude, now: now)
        }
        let block = try #require(snap.currentBlock)
        #expect(block.isActive == false,
                "event 6h ago is older than the 5h sessionDuration; block must be closed")
        // Closed block still falls inside `recentDays=3` window so it's
        // included in recentBlocks.
        #expect(snap.recentBlocks.count == 1)
        // No active projection on a closed block.
        #expect(snap.projection == nil)
    }

    // MARK: - gap detection

    @Test("gap > 5h between events splits into two blocks plus a gap marker")
    func gapSplitsBlocks() throws {
        let db = try makeDatabase()
        let now = Date()
        // Event 1: 10 hours ago.
        try seedEvent(in: db, sessionId: "s-1",
                      at: now.addingTimeInterval(-10 * 3600))
        // Event 2: 30 minutes ago (gap of ~9.5 hours, way over the 5h
        // threshold).
        try seedEvent(in: db, sessionId: "s-2",
                      at: now.addingTimeInterval(-30 * 60))

        let snap = try db.pool.read { conn in
            try BillingBlocks.loadSnapshot(db: conn, provider: .claude, now: now)
        }
        // Algorithm emits: [closed-block-1, gap, active-block-2]. recentBlocks
        // filters out gaps, so we should see two non-gap blocks here.
        #expect(snap.recentBlocks.count == 2,
                "gap > 5h must split the events into two non-gap blocks (\(snap.recentBlocks.count) seen)")
        #expect(snap.recentBlocks.allSatisfy { !$0.isGap })
        // The currentBlock should be the ACTIVE one (block 2), not block 1.
        let current = try #require(snap.currentBlock)
        #expect(current.isActive == true,
                "second event is recent → its block is the active one")
    }

    // MARK: - back-to-back events stay in the same block

    @Test("two events 5 minutes apart fold into a single block")
    func sameBlockAggregation() throws {
        let db = try makeDatabase()
        let now = Date()
        try seedEvent(in: db, sessionId: "s-1",
                      at: now.addingTimeInterval(-30 * 60),
                      valueUSD: 1.00, inputTokens: 100, outputTokens: 50)
        try seedEvent(in: db, sessionId: "s-1",
                      at: now.addingTimeInterval(-25 * 60),
                      valueUSD: 2.00, inputTokens: 200, outputTokens: 100)

        let snap = try db.pool.read { conn in
            try BillingBlocks.loadSnapshot(db: conn, provider: .claude, now: now)
        }
        let block = try #require(snap.currentBlock)
        #expect(block.entryCount == 2)
        #expect(block.tokenCounts.input == 300)
        #expect(block.tokenCounts.output == 150)
        #expect(abs(block.costUSD - 3.00) < 1e-9)
        // Burn rate is well-defined when we have two events spanning a
        // non-zero duration.
        let rate = try #require(snap.burnRate)
        #expect(rate.tokensPerMinute > 0)
        #expect(rate.costPerHour > 0)
    }

    // MARK: - hour-flooring of block start (UTC)

    @Test("block.startTime is floored to the UTC hour boundary of the first event")
    func blockStartIsHourFloored() throws {
        let db = try makeDatabase()
        let now = Date()
        // Pick an event timestamp that is NOT on an hour boundary so the
        // floor is observable. 1h 23min 45s ago, then check the block's
        // startTime falls on a UTC hour.
        let offset: TimeInterval = (1 * 3600) + (23 * 60) + 45
        let when = now.addingTimeInterval(-offset)
        try seedEvent(in: db, sessionId: "s-1", at: when)

        let snap = try db.pool.read { conn in
            try BillingBlocks.loadSnapshot(db: conn, provider: .claude, now: now)
        }
        let block = try #require(snap.currentBlock)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let comps = cal.dateComponents([.minute, .second, .nanosecond],
                                       from: block.startTime)
        #expect(comps.minute == 0)
        #expect(comps.second == 0)
        // floorToHour zeroes minute/second; nanosecond may be 0 or unset.
        #expect((comps.nanosecond ?? 0) == 0)
        #expect(block.startTime <= when)
    }

    @Test("History covering indexes preserve billing entry order")
    func billingEntryQueryPlanAvoidsTimestampIDSort() throws {
        let manager = try makeDatabase()
        let now = Date()
        try seedEvent(
            in: manager,
            sessionId: "plan",
            at: now.addingTimeInterval(-60))

        for provider in [ProviderFilter.all, .claude] {
            try manager.pool.read { db in
                var statements: [String] = []
                db.trace { event in
                    guard case .statement(let statement) = event else { return }
                    statements.append(statement.expandedSQL)
                }
                _ = try BillingBlocks.loadSnapshot(
                    db: db,
                    provider: provider,
                    now: now)
                db.trace(options: [])

                let entrySQL = try #require(statements.first {
                    $0.contains("ORDER BY timestamp ASC, id ASC")
                })
                let plan = try Row.fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN \(entrySQL)"
                ).map { $0["detail"] as String }

                #expect(plan.contains {
                    $0.contains("SEARCH usage_events USING INDEX")
                })
                #expect(plan.allSatisfy { !$0.contains("TEMP B-TREE") })
                let expectedIndex = provider == .all
                    ? "idx_usage_events_history_cover"
                    : "idx_usage_events_provider_history_cover"
                #expect(plan.contains { $0.contains(expectedIndex) })
            }
        }
    }
}
