import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex rollout incremental parser")
struct CodexRolloutIncrementalParserTests {
    private let sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test("serialized checkpoint resume is identical to one full reduction")
    func checkpointResumeMatchesFullParse() throws {
        let url = try makeRolloutURL()
        let prefixLines = [
            metaLine(),
            settingsLine("priority", timestamp: "2026-07-18T00:00:01.000Z"),
            taskLine("task_started", turn: "turn-a", timestamp: "2026-07-18T00:00:02.000Z"),
            contextLine(turn: "turn-a", model: "GPT-5.5", timestamp: "2026-07-18T00:00:03.000Z"),
            tokenLine(total: 100, last: 100, timestamp: "2026-07-18T00:00:04.000Z"),
        ]
        let suffixLines = [
            // Real Codex files can repeat the same root metadata in the middle
            // of an active turn. It must not reset model/turn/tier/counters.
            metaLine(timestamp: "2026-07-18T00:00:05.000Z", includeCwd: false),
            tokenLine(total: 150, last: 50, timestamp: "2026-07-18T00:00:06.000Z"),
            // Non-consecutive replay of the exact first snapshot: exact seen
            // state must survive checkpoint encoding, so this emits nothing.
            tokenLine(total: 100, last: 100, timestamp: "2026-07-18T00:00:07.000Z"),
            // Because the replay did not move previousUsage backwards, this is
            // 200 - 150, not 200 - 100.
            tokenLine(total: 200, last: nil, timestamp: "2026-07-18T00:00:08.000Z"),
            taskLine("task_complete", turn: "turn-a", timestamp: "2026-07-18T00:00:09.000Z"),
        ]

        let prefixData = Data((prefixLines.joined(separator: "\n") + "\n").utf8)
        let suffixData = Data((suffixLines.joined(separator: "\n") + "\n").utf8)
        try prefixData.write(to: url)

        let prefix = try RolloutParser.parseIncrementally(fileURL: url)
        let prefixCheckpoint = try #require(prefix.checkpoint)
        #expect(prefixCheckpoint.state.isIncrementalRootEligible)
        #expect(prefix.endOffset == Int64(prefixData.count))

        let encoded = try prefixCheckpoint.encoded()
        let decoded = try CodexRolloutCheckpoint.decoded(from: encoded)
        #expect(decoded == prefixCheckpoint)
        #expect(try decoded.encoded() == encoded, "checkpoint encoding must be canonical")

        try append(suffixData, to: url)
        let resumed = try RolloutParser.parseIncrementally(
            fileURL: url,
            checkpoint: decoded)
        let full = try RolloutParser.parseIncrementally(fileURL: url)
        let prefixSession = try #require(prefix.session)
        let resumedSession = try #require(resumed.session)
        let fullSession = try #require(full.session)

        #expect(prefixSession.usageDeltas + resumedSession.usageDeltas
            == fullSession.usageDeltas)
        #expect(prefixSession.rateLimitSamples + resumedSession.rateLimitSamples
            == fullSession.rateLimitSamples)
        #expect(fullSession.usageDeltas.map(\.totalTokens) == [100, 50, 50])
        #expect(fullSession.usageDeltas.map(\.modelId) == ["gpt-5.5", "gpt-5.5", "gpt-5.5"])
        #expect(fullSession.usageDeltas.map(\.turnId) == ["turn-a", "turn-a", "turn-a"])
        #expect(fullSession.usageDeltas.map(\.serviceTierPreference)
            == [.priority, .priority, .priority])

        #expect(resumedSession.sessionId == fullSession.sessionId)
        #expect(resumedSession.cwd == fullSession.cwd)
        #expect(resumedSession.startedAt == fullSession.startedAt)
        #expect(resumedSession.updatedAt == fullSession.updatedAt)
        #expect(resumedSession.lastModelId == fullSession.lastModelId)
        #expect(resumed.checkpoint?.state.seenUsageSnapshots.count == 3)
        #expect(resumed.sequentialBytesRead == Int64(suffixData.count))
        #expect(prefixCheckpoint.sourceIdentity == resumed.snapshot.sourceIdentity)
        #expect(prefixCheckpoint.prefixHash == resumed.startPrefixHash)
        #expect(prefixCheckpoint.boundaryHash == resumed.startBoundaryHash)
    }

    @Test("incomplete EOF JSON has no effects and is retried from its start")
    func incompleteEOFTailIsRetried() throws {
        let url = try makeRolloutURL()
        let meta = metaLine() + "\n"
        let token = tokenLine(
            total: 110,
            last: 110,
            timestamp: "2026-07-18T00:00:01.000Z")
        let split = token.index(token.startIndex, offsetBy: token.count / 2)
        let firstHalf = String(token[..<split])
        let secondHalf = String(token[split...]) + "\n"
        let initial = Data((meta + firstHalf).utf8)
        try initial.write(to: url)

        let first = try RolloutParser.parseIncrementally(fileURL: url)
        let checkpoint = try #require(first.checkpoint)
        #expect(first.session?.usageDeltas.isEmpty == true)
        #expect(first.hasIncompleteTail)
        #expect(first.endOffset == Int64(meta.utf8.count))
        #expect(checkpoint.offset == first.endOffset)

        try append(Data(secondHalf.utf8), to: url)
        let resumed = try RolloutParser.parseIncrementally(
            fileURL: url,
            checkpoint: checkpoint)
        let full = try RolloutParser.parseIncrementally(fileURL: url)

        #expect(resumed.hasIncompleteTail == false)
        #expect(resumed.session?.usageDeltas == full.session?.usageDeltas)
        #expect(resumed.session?.usageDeltas.map(\.totalTokens) == [110])
        #expect(resumed.endOffset == resumed.snapshot.size)
        #expect(checkpoint.boundaryHash == resumed.startBoundaryHash)
    }

    @Test("complete EOF JSON without newline commits once")
    func completeEOFWithoutNewlineCommitsOnce() throws {
        let url = try makeRolloutURL()
        let contents = metaLine() + "\n" + tokenLine(
            total: 75,
            last: 75,
            timestamp: "2026-07-18T00:00:01.000Z")
        try Data(contents.utf8).write(to: url)

        let first = try RolloutParser.parseIncrementally(fileURL: url)
        let checkpoint = try #require(first.checkpoint)
        #expect(first.hasIncompleteTail == false)
        #expect(first.endOffset == first.snapshot.size)
        #expect(first.session?.usageDeltas.map(\.totalTokens) == [75])

        try append(Data("\n".utf8), to: url)
        let resumed = try RolloutParser.parseIncrementally(
            fileURL: url,
            checkpoint: checkpoint)
        #expect(resumed.session?.usageDeltas.isEmpty == true)
        #expect(resumed.endOffset == resumed.snapshot.size)
        #expect(resumed.sequentialBytesRead == 1)
    }

    @Test("tail metadata that introduces lineage requires a full rebuild")
    func tailLineageChangeFailsClosed() throws {
        let url = try makeRolloutURL()
        try Data((metaLine() + "\n").utf8).write(to: url)
        let first = try RolloutParser.parseIncrementally(fileURL: url)
        let checkpoint = try #require(first.checkpoint)

        let childMeta = #"{"timestamp":"2026-07-18T00:00:01.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","forked_from_id":"parent-session"}}"#
        try append(Data((childMeta + "\n").utf8), to: url)

        do {
            _ = try RolloutParser.parseIncrementally(
                fileURL: url,
                checkpoint: checkpoint)
            Issue.record("expected lineage change to require a full rebuild")
        } catch let error as RolloutParserError {
            guard case .requiresFullRebuild = error else {
                Issue.record("unexpected parser error: \(error)")
                return
            }
        }
    }

    @Test("child and filename-fallback parses never emit incremental checkpoints")
    func onlyVerifiedRootsEmitCheckpoints() throws {
        let childURL = try makeRolloutURL()
        let childMeta = #"{"timestamp":"2026-07-18T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","parent_session_id":"parent-session"}}"#
        try Data((childMeta + "\n").utf8).write(to: childURL)
        let child = try RolloutParser.parseIncrementally(fileURL: childURL)
        #expect(child.session?.parentSessionId == "parent-session")
        #expect(child.checkpoint == nil)

        let fallbackURL = try makeRolloutURL()
        let context = contextLine(
            turn: "turn-a",
            model: "gpt-5.5",
            timestamp: "2026-07-18T00:00:00.000Z")
        try Data((context + "\n").utf8).write(to: fallbackURL)
        let fallback = try RolloutParser.parseIncrementally(fileURL: fallbackURL)
        #expect(fallback.session?.sessionId == sessionId)
        #expect(fallback.checkpoint == nil)
    }

    @Test("record reader scans multi-chunk lines linearly")
    func multiChunkRecordSearchIsLinear() throws {
        let url = try makeRolloutURL()
        let prefix = Data(#"{"blob":""#.utf8)
        let payload = Data(repeating: 0x78, count: 2 * 1024 * 1024 + 37)
        let firstLine = prefix + payload + Data(#""}"#.utf8)
        let secondLine = Data(#"{"tail":true}"#.utf8)
        let contents = firstLine + Data("\n".utf8)
            + secondLine + Data("\n".utf8)
        try contents.write(to: url)

        let reader = try RolloutRecordReader(
            fileURL: url,
            chunkSize: 1_003)
        defer { try? reader.close() }

        let first = try #require(try reader.next())
        #expect(first.data == firstLine)
        #expect(first.startOffset == 0)
        #expect(first.endOffset == Int64(firstLine.count + 1))
        #expect(first.hadNewline)
        #expect(reader.newlineBytesScanned == Int64(firstLine.count + 1))

        let second = try #require(try reader.next())
        #expect(second.data == secondLine)
        #expect(second.startOffset == first.endOffset)
        #expect(second.endOffset == Int64(contents.count))
        #expect(second.hadNewline)
        let eof = try reader.next()
        #expect(eof == nil)
        #expect(reader.newlineBytesScanned == Int64(contents.count))
    }

    private func makeRolloutURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-incremental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            "rollout-2026-07-18T00-00-00-\(sessionId).jsonl")
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func metaLine(
        timestamp: String = "2026-07-18T00:00:00.000Z",
        includeCwd: Bool = true
    ) -> String {
        let cwd = includeCwd ? #","cwd":"/tmp/checkpoint-project""# : ""
        return #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(sessionId)"\#(cwd)}}"#
    }

    private func settingsLine(_ tier: String, timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"\#(tier)"}}}"#
    }

    private func taskLine(_ type: String, turn: String, timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
    }

    private func contextLine(turn: String, model: String, timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"\#(turn)","model":"\#(model)"}}"#
    }

    private func tokenLine(total: Int, last: Int?, timestamp: String) -> String {
        func usage(_ value: Int) -> String {
            #"{"input_tokens":\#(value),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(value)}"#
        }
        let lastField = last.map { #","last_token_usage":\#(usage($0))"# } ?? ""
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage(total))\#(lastField)}}}"#
    }
}
