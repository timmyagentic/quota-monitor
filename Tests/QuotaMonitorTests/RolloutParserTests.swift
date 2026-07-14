import Foundation
import Testing
@testable import QuotaMonitor

/// Snapshot tests for `RolloutParser` against canned `rollout-*.jsonl`
/// shapes. Locks down:
///
///   1. Session/project metadata separation: `session_meta.cwd` feeds cwd and
///      projectName, while Codex thread title metadata is loaded elsewhere.
///   2. Subagent reconciliation — `parent_session_id` populated when present,
///      nil when absent.
///   3. Cumulative→delta conversion: the first event is the baseline (no
///      delta emitted), every subsequent event is the running difference.
///   4. Legacy fallback: when no `turn_context` ever sets a model AND the
///      payload itself doesn't carry one, attribute to `gpt-5` and flag the
///      event so the UI can asterisk the cost.
///
/// Fixtures live under `Tests/QuotaMonitorTests/Fixtures/Rollout/` and are
/// bundled via `Package.swift` `resources: [.copy("Fixtures")]`.
@Suite("RolloutParser")
struct RolloutParserTests {

    private func loadFixture(_ stem: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: stem, withExtension: "jsonl",
            subdirectory: "Fixtures/Rollout")
        else {
            Issue.record("missing fixture \(stem).jsonl — check Package.swift `resources`")
            throw CocoaError(.fileReadNoSuchFile)
        }
        return url
    }

    private func writeRollout(_ jsonl: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-rollout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-05-20T00-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - project metadata

    @Test("CLI 0.40 with cwd → project name is cwd's leaf directory")
    func projectNameDerivedFromCwdLeaf() throws {
        let url = try loadFixture("cli_0_40_with_cwd")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.title == nil)
        #expect(parsed.projectName == "codexmonitor",
                "projectName must equal the last component of /Users/jane/Code/codexmonitor")
        #expect(parsed.cwd == "/Users/jane/Code/codexmonitor")
        #expect(parsed.sessionId == "019aa0fd-1111-7000-8000-aaaaaaaaaaaa")
        #expect(parsed.parentSessionId == nil)
    }

    @Test("CLI 0.39 without cwd → title and project metadata are nil")
    func titleAndProjectMetadataNilWhenCwdMissing() throws {
        let url = try loadFixture("cli_0_39_no_cwd")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.title == nil,
                "no cwd in session_meta → title must be nil, never 'Untitled session'")
        #expect(parsed.projectName == nil)
        #expect(parsed.cwd == nil)
        #expect(parsed.sessionId == "019aa0fd-2222-7000-8000-bbbbbbbbbbbb")
    }

    // MARK: - subagent metadata

    @Test("subagent: parent_session_id + nickname + role flow through")
    func subagentMetadataRoundTrips() throws {
        let url = try loadFixture("subagent_no_turn_context")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.parentSessionId == "019aa0fd-9999-7000-8000-dddddddddddd")
        #expect(parsed.agentNickname == "researcher")
        #expect(parsed.agentRole == "subagent")
        #expect(parsed.title == nil)
        #expect(parsed.projectName == "parent-project")
    }

    // MARK: - cumulative → delta

    @Test("first token_count emits cumulative-as-delta, second yields the diff")
    func deltaComputationFromCumulativeCounters() throws {
        let url = try loadFixture("cli_0_40_with_cwd")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        // Two token_count events. `total_token_usage` is cumulative from
        // session start, so the first sample IS the delta from t=0:
        //   first event:  totals = (input=100, output=0,  total=100)
        //                 delta  = (input=100, output=0,  total=100)
        //   second event: totals = (input=250, output=40, total=290)
        //                 delta  = (input=150, output=40, total=190)
        // Mirrors codex-pacer's importer.rs:719-723 which clones `current`
        // when `previous` is None.
        #expect(parsed.usageDeltas.count == 2)

        let first = parsed.usageDeltas[0]
        #expect(first.inputTokens == 100)
        #expect(first.outputTokens == 0)
        #expect(first.totalTokens == 100)
        #expect(first.modelId == "gpt-5.5",
                "model from turn_context must be normalized to lowercase")
        #expect(first.modelInferred == false)

        let second = parsed.usageDeltas[1]
        #expect(second.inputTokens == 150)
        #expect(second.outputTokens == 40)
        #expect(second.totalTokens == 190)
        #expect(second.modelInferred == false)
    }

    // MARK: - rate-limit sample extraction

    @Test("embedded rate_limits become primary + secondary sample drafts")
    func embeddedRateLimitsExtracted() throws {
        let url = try loadFixture("cli_0_40_with_cwd")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.rateLimitSamples.count == 2)
        let primary = try #require(parsed.rateLimitSamples.first { $0.bucket == "primary" })
        #expect(abs(primary.usedPercent - 12.5) < 0.0001)
        #expect(primary.planType == "plus")
        #expect(parsed.latestPlanType == "plus")
    }

    @Test("rate_limits are retained when token_count info is null")
    func rateLimitsWithoutUsageInfoAreRetained() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":7.0,"window_minutes":300,"resets_at":1779272370},"secondary":{"used_percent":22.0,"window_minutes":10080,"resets_at":1779820985},"plan_type":"prolite"}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.usageDeltas.isEmpty)
        #expect(parsed.rateLimitSamples.count == 2)
        #expect(parsed.latestPlanType == "prolite")
    }

    @Test("weekly window in embedded primary slot is stored as semantic secondary")
    func weeklyOnlyEmbeddedRateLimitIsClassifiedByDuration() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-07-14T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-07-14T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-07-14T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":64.0,"window_minutes":10080,"resets_at":1784506860},"secondary":null,"plan_type":"pro"}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.rateLimitSamples.count == 1)
        #expect(parsed.rateLimitSamples.first?.bucket == "secondary")
        #expect(parsed.rateLimitSamples.first?.windowDuration == 604_800)
        #expect(parsed.rateLimitSamples.first?.usedPercent == 64)
    }

    @Test("embedded windows without duration are not mislabeled from wire slots")
    func embeddedRateLimitWithoutDurationIsOmitted() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-07-14T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-07-14T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-07-14T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":12.0,"resets_at":1784506860},"secondary":null,"plan_type":"pro"}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.rateLimitSamples.isEmpty)
    }

    @Test("embedded windows with unknown nonzero duration are omitted")
    func embeddedRateLimitWithUnknownDurationIsOmitted() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-07-14T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-07-14T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-07-14T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":12.0,"window_minutes":60,"resets_at":1784506860},"secondary":null,"plan_type":"pro"}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.rateLimitSamples.isEmpty)
    }

    @Test("last_token_usage wins when total_token_usage is non-monotonic")
    func lastTokenUsageWinsForCurrentCodexRows() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-05-20T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        {"timestamp":"2026-05-20T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":990,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":1120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        {"timestamp":"2026-05-20T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":800,"output_tokens":25,"reasoning_output_tokens":0,"total_tokens":925},"last_token_usage":{"input_tokens":50,"cached_input_tokens":40,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":55}}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 110, 55])
    }

    @Test("total-only token_count samples with zero component buckets are skipped")
    func malformedTotalOnlySamplesAreSkipped() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-05-20T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":12460012}}}}
        {"timestamp":"2026-05-20T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":990,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":1120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.usageDeltas.map(\.totalTokens) == [110])
    }

    @Test("repeated token snapshots are skipped even when last_token_usage is present")
    func repeatedTokenSnapshotsAreSkipped() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-05-20T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        {"timestamp":"2026-05-20T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":990,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":1120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        {"timestamp":"2026-05-20T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        {"timestamp":"2026-05-20T00:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":1080,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":1230},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 110, 110])
    }

    @Test("same cumulative total with different last_token_usage is kept")
    func sameTotalWithDifferentLastUsageIsKept() throws {
        let url = try writeRollout(#"""
        {"timestamp":"2026-05-20T00:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-05-20T00:00:00.000Z","cwd":"/tmp/project"}}
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-05-20T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        {"timestamp":"2026-05-20T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":25,"cached_input_tokens":20,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":30}}}}
        """# + "\n")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.usageDeltas.map(\.totalTokens) == [110, 30])
    }

    // MARK: - legacy fallback

    @Test("subagent without turn_context: legacy gpt-5 fallback, modelInferred=true")
    func legacyFallback_whenTurnContextMissing() throws {
        let url = try loadFixture("subagent_no_turn_context")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        // Two token_count events → two deltas (first is cumulative-as-delta).
        #expect(parsed.usageDeltas.count == 2)
        for delta in parsed.usageDeltas {
            #expect(delta.modelId == LegacyFallbackModel)
            #expect(delta.modelInferred == true,
                    "no turn_context anywhere in the file → cost is approximate, must be flagged")
        }
    }
}
