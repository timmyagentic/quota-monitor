import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Coverage for `CodexPriorityTraceReader` against a hand-built `logs` table
/// mirroring `~/.codex/logs_2.sqlite`. Real bodies embed the turn id in Rust
/// debug form (`turn_id=<uuid>`) and the tier as JSON (`"service_tier":"priority"`).
@Suite("CodexPriorityTraceReader")
struct CodexPriorityTraceReaderTests {

    private func makeLogsDB(_ rows: [(ts: Int64, body: String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("logs_2.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE logs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts INTEGER NOT NULL,
                    feedback_log_body TEXT
                )
                """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO logs (ts, feedback_log_body) VALUES (?, ?)",
                    arguments: [row.ts, row.body])
            }
        }
        return url
    }

    @Test("extracts turn ids from priority requests, ignores non-priority tiers")
    func extractsPriorityTurnIds() throws {
        let url = try makeLogsDB([
            (1783430000, #"session: request{turn_id=019f0000-0000-7000-8000-000000000001 model=gpt-5.5}: {"input":[],"service_tier":"priority","prompt_cache_key":"019f0000-0000-7000-8000-000000000001"}"#),
            (1783431000, #"session: request{turn_id=019f0000-0000-7000-8000-000000000002 model=gpt-5.5}: {"service_tier":"auto"}"#),
            (1783432000, #"session: request{turn_id=019f0000-0000-7000-8000-000000000003}: {"service_tier":"priority"}"#),
        ])

        let result = CodexPriorityTraceReader.read(logsDatabaseURL: url)

        #expect(result.priorityTurnIds == [
            "019f0000-0000-7000-8000-000000000001",
            "019f0000-0000-7000-8000-000000000003",
        ])
    }

    @Test("window spans MIN/MAX ts across all log rows")
    func windowSpansAllRows() throws {
        let url = try makeLogsDB([
            (1783430000, #"{"service_tier":"priority"} turn_id=019f0000-0000-7000-8000-000000000001"#),
            (1783432000, #"unrelated noise line"#),
        ])

        let result = CodexPriorityTraceReader.read(logsDatabaseURL: url)

        let start = try #require(result.windowStart.flatMap(ISO8601.parse))
        let end = try #require(result.windowEnd.flatMap(ISO8601.parse))
        #expect(abs(start.timeIntervalSince1970 - 1783430000) < 1.5)
        #expect(abs(end.timeIntervalSince1970 - 1783432000) < 1.5)
    }

    @Test("missing database file returns empty result without throwing")
    func missingFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        let result = CodexPriorityTraceReader.read(logsDatabaseURL: url)
        #expect(result.priorityTurnIds.isEmpty)
        #expect(result.windowStart == nil)
    }
}
