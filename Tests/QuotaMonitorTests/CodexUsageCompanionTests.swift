import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex usage companions")
struct CodexUsageCompanionTests {
    @Test("different cumulative streams still represent one response")
    func differentCumulativeCounters() throws {
        let parsed = try parse([
            record("response-a", total: 900),
            tokenCount(total: 600),
        ])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110])
        #expect(parsed.usageDeltas.first?.cachedInputTokens == 80)
        #expect(parsed.usageDeltas.first?.cacheWriteInputTokens == 5)
        #expect(parsed.usageDeltas.first?.reasoningOutputTokens == 3)
    }

    @Test("a companion without cumulative usage is consumed once")
    func companionWithoutCumulativeCounter() throws {
        let parsed = try parse([
            record("response-a", total: nil),
            tokenCount(total: nil),
            tokenCount(total: nil),
        ])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 110])
    }

    @Test("different response IDs retain equal usage and equal cumulative totals")
    func distinctResponsesWithEqualUsage() throws {
        let parsed = try parse([
            record("response-a", total: 900),
            tokenCount(total: 600),
            record("response-b", total: 900),
            tokenCount(total: 600),
        ])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 110])
    }

    @Test("a response ID replay remains one response")
    func repeatedResponseID() throws {
        let parsed = try parse([
            record("response-a", total: 900),
            tokenCount(total: 600),
            record("response-a", total: 1200),
            tokenCount(total: 1000),
        ])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110])
    }

    @Test("legacy-first same-cumulative companions retain compatibility")
    func legacyFirstCompanion() throws {
        let parsed = try parse([
            tokenCount(total: 900),
            record("response-a", total: 900),
        ])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110])
    }

    @Test("a new record is retained after an independent legacy response")
    func independentLegacyAndRecordResponses() throws {
        let parsed = try parse([
            tokenCount(total: 600),
            record("response-a", total: 900),
            tokenCount(total: 700),
        ])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 110])
    }

    @Test("legacy-only responses with equal usage remain independent")
    func legacyOnlyEqualResponses() throws {
        let parsed = try parse([tokenCount(total: 600), tokenCount(total: 700)])
        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 110])
    }

    @Test("record companion and response identity survive an incremental checkpoint")
    func incrementalCompanion() throws {
        let url = try write([metadata(), context(), record("response-a", total: 900)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try RolloutParser.parseIncrementally(fileURL: url)
        let checkpoint = try CodexRolloutCheckpoint.decoded(
            from: #require(first.checkpoint).encoded())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(([
            tokenCount(total: 600),
            record("response-a", total: 900),
            tokenCount(total: 600),
            record("response-b", total: 1200),
            tokenCount(total: 700),
        ].joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let resumed = try RolloutParser.parseIncrementally(fileURL: url, checkpoint: checkpoint)
        let full = try #require(try RolloutParser.parse(fileURL: url))
        let firstSession = try #require(first.session)
        let resumedSession = try #require(resumed.session)
        #expect(firstSession.usageDeltas + resumedSession.usageDeltas == full.usageDeltas)
        #expect(full.usageDeltas.map(\.totalTokens) == [110, 110])
    }

    @Test("older reducer checkpoints decode without companion fields")
    func olderCheckpointState() throws {
        let state = CodexRolloutReducerState(sessionId: "session-a")
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CodexRolloutReducerState.self, from: encoded)
        #expect(decoded.pendingUsageCompanion == nil)
        #expect(decoded.seenResponseIds == nil)
        #expect(decoded.sessionId == "session-a")
    }

    private func parse(_ records: [String]) throws -> ParsedSession {
        let url = try write([metadata(), context()] + records)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try #require(try RolloutParser.parse(fileURL: url))
    }

    private func write(_ lines: [String]) throws -> URL {
        let directory = TestResources.temporaryDirectory
            .appendingPathComponent("qm-usage-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-test.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func metadata() -> String {
        #"{"timestamp":"2026-11-16T00:00:00Z","type":"session_meta","payload":{"id":"session-a","cwd":"/tmp/project"}}"#
    }

    private func context() -> String {
        #"{"timestamp":"2026-11-16T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","turn_id":"turn-a"}}"#
    }

    private func usage(total: Int = 110) -> [String: Int] {
        ["input_tokens": total - 10, "cached_input_tokens": 80,
         "cache_write_input_tokens": 5, "output_tokens": 10,
         "reasoning_output_tokens": 3, "total_tokens": total]
    }

    private func record(_ response: String, total: Int?) -> String {
        var payload: [String: Any] = [
            "turn_id": "turn-a", "response_id": response, "usage": usage(),
        ]
        if let total { payload["thread_token_usage"] = usage(total: total) }
        return line(type: "token_usage_record", payload: payload)
    }

    private func tokenCount(total: Int?) -> String {
        var info: [String: Any] = ["last_token_usage": usage()]
        if let total { info["total_token_usage"] = usage(total: total) }
        return line(type: "event_msg", payload: ["type": "token_count", "info": info])
    }

    private func line(type: String, payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-11-16T00:00:01Z", "type": type, "payload": payload,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
