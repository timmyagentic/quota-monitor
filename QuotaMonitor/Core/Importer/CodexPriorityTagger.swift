import Foundation
import GRDB

/// Stamps `usage_events.codex_billing_tier` from a `CodexPriorityTraceReader`
/// result. Idempotent and monotonic — safe to re-run on every scan.
enum CodexPriorityTagger {

    /// Returns the number of rows whose tier actually changed (used by the
    /// caller to decide whether a pricing backfill is needed).
    @discardableResult
    static func tag(
        in db: Database, trace: CodexPriorityTraceReader.Result
    ) throws -> Int {
        var changed = 0

        // (a) Priority hits → 'priority'. Monotonic upgrade: the `<> 'priority'`
        // guard means an unchanged row isn't rewritten (keeps re-runs no-ops)
        // and a shrinking trace never touches — let alone downgrades — a row it
        // no longer lists. Chunked IN to stay under SQLite's variable cap.
        let ids = Array(trace.priorityTurnIds)
        var index = 0
        let chunkSize = 900
        while index < ids.count {
            let upper = min(index + chunkSize, ids.count)
            let chunk = Array(ids[index..<upper])
            index = upper
            let placeholders = databaseQuestionMarks(count: chunk.count)
            try db.execute(sql: """
                UPDATE usage_events
                SET codex_billing_tier = 'priority'
                WHERE provider = 'codex'
                  AND codex_turn_id IN (\(placeholders))
                  AND (codex_billing_tier IS NULL OR codex_billing_tier <> 'priority')
                """, arguments: StatementArguments(chunk))
            changed += db.changesCount
        }

        // (b) Rows the trace window covers, with a turn id, not already
        // resolved → 'standard'. The `NOT IN ('priority','standard')` guard
        // never downgrades a priority row (a ran first) or rewrites a settled
        // standard row, so priority stays monotonic and re-runs report zero.
        if let start = trace.windowStart, let end = trace.windowEnd {
            try db.execute(sql: """
                UPDATE usage_events
                SET codex_billing_tier = 'standard'
                WHERE provider = 'codex'
                  AND codex_turn_id IS NOT NULL
                  AND timestamp >= ? AND timestamp <= ?
                  AND (codex_billing_tier IS NULL
                       OR codex_billing_tier NOT IN ('priority', 'standard'))
                """, arguments: [start, end])
            changed += db.changesCount
        }

        return changed
    }
}
