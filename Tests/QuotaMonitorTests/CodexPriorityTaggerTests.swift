import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Coverage for `CodexPriorityTagger` — the three-state tier stamp:
///   - turn in the trace's priority set        → 'priority' (forced)
///   - in the trace window, turn not priority   → 'standard' (reverse-evidence)
///   - outside the window / no turn id          → NULL (global switch decides)
///
/// Plus the two invariants that keep re-runs safe:
///   - priority is monotonic (a shrinking trace never downgrades a row)
///   - re-tagging an unchanged trace reports zero changes
@Suite("CodexPriorityTagger")
struct CodexPriorityTaggerTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-tagger-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tagger-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    private func insertCodexEvent(
        in db: DatabaseManager, turnId: String?, timestamp: String,
        tier: String? = nil
    ) throws {
        let sid = "s-\(UUID().uuidString)"
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, contains_subagents,
                 created_at, imported_at, provider)
                VALUES (?, ?, 0, ?, ?, 'codex')
                """, arguments: [sid, sid, timestamp, timestamp])
            try conn.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id, input_tokens, cached_input_tokens,
                 output_tokens, reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred,
                 codex_turn_id, codex_billing_tier)
                VALUES (?, ?, 'gpt-5.5', 0, 0, 0, 0, 0, 0, 'codex', 0, 0, ?, ?)
                """, arguments: [sid, timestamp, turnId, tier])
        }
    }

    private func tier(in db: DatabaseManager, turnId: String) throws -> String? {
        try db.pool.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT codex_billing_tier FROM usage_events
                WHERE codex_turn_id = ? LIMIT 1
                """, arguments: [turnId])
        }
    }

    private func tierForNilTurn(in db: DatabaseManager) throws -> String? {
        try db.pool.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT codex_billing_tier FROM usage_events
                WHERE codex_turn_id IS NULL LIMIT 1
                """)
        }
    }

    @Test("tags priority hits, window standards, and leaves out-of-window / no-turn rows null")
    func tagsPriorityStandardAndNull() throws {
        let db = try makeDatabase()
        try insertCodexEvent(in: db, turnId: "turn-prio", timestamp: "2026-07-05T00:00:00.000Z")
        try insertCodexEvent(in: db, turnId: "turn-std", timestamp: "2026-07-05T00:00:00.000Z")
        try insertCodexEvent(in: db, turnId: "turn-old", timestamp: "2026-06-01T00:00:00.000Z")
        try insertCodexEvent(in: db, turnId: nil, timestamp: "2026-07-05T00:00:00.000Z")

        let trace = CodexPriorityTraceReader.Result(
            priorityTurnIds: ["turn-prio"],
            windowStart: "2026-07-01T00:00:00.000Z",
            windowEnd: "2026-07-10T00:00:00.000Z")

        try db.pool.write { conn in
            _ = try CodexPriorityTagger.tag(in: conn, trace: trace)
        }

        let prio = try tier(in: db, turnId: "turn-prio")
        let std = try tier(in: db, turnId: "turn-std")
        let old = try tier(in: db, turnId: "turn-old")
        let noTurn = try tierForNilTurn(in: db)
        #expect(prio == "priority")
        #expect(std == "standard")
        #expect(old == nil, "before the trace window → no evidence → null")
        #expect(noTurn == nil, "no turn id → cannot attribute → null")
    }

    @Test("priority is monotonic: an empty trace does not downgrade an existing priority row")
    func priorityIsMonotonic() throws {
        let db = try makeDatabase()
        try insertCodexEvent(in: db, turnId: "turn-x",
                             timestamp: "2026-07-05T00:00:00.000Z", tier: "priority")

        try db.pool.write { conn in
            _ = try CodexPriorityTagger.tag(in: conn, trace: .empty)
        }
        let t = try tier(in: db, turnId: "turn-x")
        #expect(t == "priority", "an empty/expired trace must not roll a proven priority row back")
    }

    @Test("second tag with the same trace reports zero changes (idempotent)")
    func idempotentSecondRun() throws {
        let db = try makeDatabase()
        try insertCodexEvent(in: db, turnId: "turn-p", timestamp: "2026-07-05T00:00:00.000Z")
        try insertCodexEvent(in: db, turnId: "turn-s", timestamp: "2026-07-05T00:00:00.000Z")
        let trace = CodexPriorityTraceReader.Result(
            priorityTurnIds: ["turn-p"],
            windowStart: "2026-07-01T00:00:00.000Z",
            windowEnd: "2026-07-10T00:00:00.000Z")

        let first = try db.pool.write { conn in
            try CodexPriorityTagger.tag(in: conn, trace: trace)
        }
        let second = try db.pool.write { conn in
            try CodexPriorityTagger.tag(in: conn, trace: trace)
        }
        #expect(first > 0)
        #expect(second == 0, "re-tagging an identical trace must be a no-op")
    }
}
