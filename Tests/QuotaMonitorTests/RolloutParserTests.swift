import Foundation
import Testing
@testable import QuotaMonitor

/// Snapshot tests for `RolloutParser` against canned `rollout-*.jsonl`
/// shapes. Locks down:
///
///   1. The Day-30 fix that derives the session title from `session_meta.cwd`'s
///      leaf path. Pre-fix, every Codex session was titled "Untitled session".
///   2. Subagent reconciliation — `parent_session_id` populated when present,
///      nil when absent.
///   3. Cumulative→delta conversion: the first event is the baseline (no
///      delta emitted), every subsequent event is the running difference.
///   4. Legacy fallback: when no `turn_context` ever sets a model AND the
///      payload itself doesn't carry one, attribute to `gpt-5` and flag the
///      event so the UI can asterisk the cost.
///
/// Fixtures live under `Tests/CodexMonitorTests/Fixtures/Rollout/` and are
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

    // MARK: - title fallback (Day-30 fix)

    @Test("CLI 0.40 with cwd → title is cwd's leaf directory")
    func titleDerivedFromCwdLeaf() throws {
        let url = try loadFixture("cli_0_40_with_cwd")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.title == "codexmonitor",
                "title must equal the last component of /Users/jane/Code/codexmonitor")
        #expect(parsed.sessionId == "019aa0fd-1111-7000-8000-aaaaaaaaaaaa")
        #expect(parsed.parentSessionId == nil)
    }

    @Test("CLI 0.39 without cwd → title is nil (UI falls back to session-id chip)")
    func titleNilWhenCwdMissing() throws {
        let url = try loadFixture("cli_0_39_no_cwd")
        let parsed = try #require(try RolloutParser.parse(fileURL: url))

        #expect(parsed.title == nil,
                "no cwd in session_meta → title must be nil, never 'Untitled session'")
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
        #expect(parsed.title == "parent-project")
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
