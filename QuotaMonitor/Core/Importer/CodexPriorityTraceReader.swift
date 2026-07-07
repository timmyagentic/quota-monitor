import Foundation
import GRDB

/// Reads Codex's `~/.codex/logs_2.sqlite` websocket-request trace to find
/// which turns ran on the `priority` service tier (billed as Fast) and the
/// time window the trace covers.
///
/// Read-only and best-effort: the file is opened `readonly` and never
/// written, so it can't disturb a running Codex. Any failure (missing file,
/// locked, schema drift) yields `.empty`, degrading the whole feature to the
/// global Fast-Mode switch rather than erroring out a scan.
enum CodexPriorityTraceReader {

    struct Result: Sendable, Equatable {
        /// Turn ids that ran on the `priority` service tier.
        var priorityTurnIds: Set<String>
        /// ISO-8601 UTC bounds of the trace's coverage (`MIN`/`MAX(ts)`),
        /// comparable by string ordering against `usage_events.timestamp`.
        var windowStart: String?
        var windowEnd: String?

        static let empty = Result(
            priorityTurnIds: [], windowStart: nil, windowEnd: nil)
    }

    static func read(logsDatabaseURL url: URL) -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            var config = Configuration()
            config.readonly = true
            // Short cap: if Codex is mid-write and holds a lock, give up and
            // fall back to the global switch rather than stalling the scan.
            config.busyMode = .timeout(2)
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            return try queue.read { db in
                let minTs = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM logs")
                let maxTs = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM logs")

                // Narrow to rows that mention a priority tier. The LIKE is a
                // full-body scan (no index on a multi-hundred-MB text column,
                // so this is seconds on a large trace) — the caller only runs
                // it when Codex actually imported new rows. Stream with a
                // cursor so bodies (which can be MB-sized requests) aren't all
                // held in memory at once.
                var priority: Set<String> = []
                let cursor = try String.fetchCursor(db, sql: """
                    SELECT feedback_log_body FROM logs
                    WHERE feedback_log_body LIKE '%service_tier%priority%'
                    """)
                while let body = try cursor.next() {
                    if isPriorityBody(body) {
                        priority.formUnion(turnIds(in: body))
                    }
                }

                return Result(
                    priorityTurnIds: priority,
                    windowStart: minTs.map(Self.isoString(fromEpochSeconds:)),
                    windowEnd: maxTs.map(Self.isoString(fromEpochSeconds:)))
            }
        } catch {
            return .empty
        }
    }

    // MARK: - body parsing

    /// True when the body carries `service_tier: priority` (JSON `"service_tier":"priority"`
    /// or debug `service_tier=priority`), not merely the word "priority" elsewhere.
    private static func isPriorityBody(_ body: String) -> Bool {
        let range = NSRange(body.startIndex..., in: body)
        return priorityTierRegex.firstMatch(in: body, range: range) != nil
    }

    /// All UUID-shaped turn ids in the body. Codex writes them as
    /// `turn_id=<uuid>` (rust debug) or `"turn_id":"<uuid>"` (JSON).
    private static func turnIds(in body: String) -> Set<String> {
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        var ids: Set<String> = []
        for match in turnIdRegex.matches(in: body, range: range)
        where match.numberOfRanges > 1 {
            ids.insert(ns.substring(with: match.range(at: 1)))
        }
        return ids
    }

    private static let priorityTierRegex = try! NSRegularExpression(
        pattern: #"service_tier["\s:=]{1,4}"?priority"#)

    private static let turnIdRegex = try! NSRegularExpression(
        pattern: #"turn_id["\s:=]{1,4}"?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#)

    private static func isoString(fromEpochSeconds ts: Int64) -> String {
        ISO8601.fractional.string(
            from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
