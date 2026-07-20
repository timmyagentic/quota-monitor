import Foundation
import Testing
@testable import QuotaMonitor

/// Snapshot tests pinning the wire format of Anthropic's
/// `/api/oauth/usage` to the fixtures under `Fixtures/ClaudeUsage/`.
///
/// The history of this file is the history of "Claude quota numbers
/// went insane and we shipped it." We don't have integration tests
/// for the live endpoint (token-bound, rate-limited, intermittent),
/// so these fixtures are the only thing standing between the user and
/// another 6000% rendering. Treat the fixtures as a contract:
///
/// - Add a fixture every time you observe a new wire shape in the wild.
/// - Never silently widen the decoder's tolerance — write a fixture
///   that proves the new shape, then change `decode`.
/// - The `_comment` key inside each fixture is human documentation;
///   our decoder ignores unknown keys so leave it in.
///
/// We use `swift-testing` rather than XCTest because the only Swift
/// toolchain on the dev machine is Command Line Tools, which ships
/// `Testing.framework` but not `XCTest.framework`. The `@Test` macro
/// runs identically under `swift test` or Xcode.
///
/// Decoder under test: `ClaudeUsageClient.decode(data:capturedAt:)`
/// Domain model: `ClaudeUsageSnapshot`
@Suite("Claude /api/oauth/usage decoder")
struct ClaudeUsageDecoderTests {

    // MARK: - helpers

    /// Load a fixture by stem. We `.copy("Fixtures")` the whole folder
    /// in `Package.swift`, so SPM exposes it via `Bundle.module` under
    /// the original subpath.
    private func loadFixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures/ClaudeUsage")
        else {
            Issue.record("missing fixture \(name).json — check Package.swift `resources`")
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// All decode calls share a fixed `capturedAt` so equality checks
    /// don't drift; the value itself is meaningless to the decoder.
    private let capturedAt = Date(timeIntervalSince1970: 1_777_000_000)

    // MARK: - real captures

    /// **The test that would have caught the 6000% bug.**
    /// Anthropic returns `utilization` already in percent (60.0 = 60%).
    /// If anyone re-introduces a `*100` step in `mkWindow`, this snaps
    /// to 6000.0 and the test fails loudly.
    @Test("live Pro 2026-04-29: utilization is already in percent")
    func livePro_decodesUtilizationAsPercent() throws {
        let data = try loadFixture("live_pro_2026-04-29")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        #expect(abs((snap.fiveHour?.usedPercent ?? 0) - 60.0) < 0.0001,
                "5h utilization arrived as 60.0; if this reads 6000 the decoder is double-scaling")
        #expect(abs((snap.sevenDay?.usedPercent ?? 0) - 12.0) < 0.0001)
        #expect(snap.sevenDayOpus == nil)
        #expect(snap.sevenDaySonnet == nil)
        #expect(snap.tier == nil)
    }

    /// Reset timestamp must round-trip through ISO-8601 with fractional
    /// seconds. Apple's default ISO formatter rejects fractionals — we
    /// keep two formatters in `decode` for exactly this reason.
    @Test("live Pro: reset timestamp parses despite fractional seconds")
    func livePro_resetTimestampRoundTrips() throws {
        let data = try loadFixture("live_pro_2026-04-29")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        let expectedFiveHour = ISO8601DateFormatter().date(from: "2026-04-29T11:40:00Z")!
        let actual = snap.fiveHour?.resetAt.timeIntervalSince1970 ?? 0
        #expect(abs(actual - expectedFiveHour.timeIntervalSince1970) < 1.0)
    }

    // MARK: - synthetic shapes

    @Test("Max5x: per-model windows + tier badge")
    func max5x_populatesPerModelWindowsAndTier() throws {
        let data = try loadFixture("synthetic_max5x")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        #expect(snap.tier == "max5x")
        #expect(abs((snap.fiveHour?.usedPercent ?? 0) - 42.5) < 0.0001)
        #expect(abs((snap.sevenDay?.usedPercent ?? 0) - 18.3) < 0.0001)
        #expect(abs((snap.sevenDayOpus?.usedPercent ?? 0) - 73.1) < 0.0001)
        #expect(abs((snap.sevenDaySonnet?.usedPercent ?? 0) - 9.8) < 0.0001)
    }

    @Test("Fable 5: structured weekly limit decodes at its literal percent")
    func fable5_structuredWeeklyLimitDecodes() throws {
        let data = try loadFixture("live_fable5_weekly_scoped")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        let scoped = try #require(snap.weeklyScoped.first)
        #expect(scoped.key == "fable")
        #expect(scoped.displayName == "Fable 5")
        #expect(abs(scoped.window.usedPercent - 1.0) < 0.0001,
                "limits[].percent is already 0...100; 1 must stay 1%, not become 100%")
        #expect(abs((snap.sevenDay?.usedPercent ?? -1) - 1.0) < 0.0001,
                "modern top-level utilization is also literal percent when limits[] is present")
        #expect(snap.sevenDayFable == scoped.window)
        #expect(snap.tier == "max20x")
    }

    @Test("structured Fable wins over a top-level compatibility fallback")
    func fable5_structuredLimitWinsOverFallback() throws {
        let json = """
        {
          "seven_day_fable": {
            "utilization": 40.0,
            "resets_at": "2026-07-05T10:00:00Z"
          },
          "limits": [{
            "kind": "weekly_scoped",
            "percent": 12.0,
            "resets_at": "2026-07-06T10:00:00Z",
            "scope": {"model": {"display_name": "Fable"}}
          }]
        }
        """.data(using: .utf8)!

        let snap = try ClaudeUsageClient.decode(data: json, capturedAt: capturedAt)
        #expect(snap.weeklyScoped.count == 1)
        #expect(abs((snap.sevenDayFable?.usedPercent ?? -1) - 12.0) < 0.0001)
    }

    @Test("top-level Fable fallback decodes modern percent literally")
    func fable5_topLevelFallbackStaysAtLiteralOnePercent() throws {
        let json = """
        {
          "seven_day_fable": {
            "utilization": 1.0,
            "resets_at": "2026-07-05T10:00:00Z"
          }
        }
        """.data(using: .utf8)!

        let snap = try ClaudeUsageClient.decode(data: json, capturedAt: capturedAt)
        #expect(abs((snap.sevenDayFable?.usedPercent ?? -1) - 1.0) < 0.0001,
                "seven_day_fable is a modern 0...100 field, even without limits[]")
    }

    @Test("limits-only response restores aggregate and model weekly windows")
    func limitsOnlyResponseRestoresAllWindowKinds() throws {
        let json = """
        {
          "limits": [
            {
              "kind": "session",
              "percent": 14.0,
              "resets_at": "2026-07-20T14:00:00Z",
              "scope": null
            },
            {
              "kind": "weekly_all",
              "percent": 22.0,
              "resets_at": "2026-07-25T10:00:00Z",
              "scope": null
            },
            {
              "kind": "weekly_scoped",
              "percent": 33.0,
              "resets_at": "2026-07-24T10:00:00Z",
              "scope": {"model": {"display_name": "Fable"}}
            }
          ]
        }
        """.data(using: .utf8)!

        let snap = try ClaudeUsageClient.decode(data: json, capturedAt: capturedAt)
        #expect(abs((snap.fiveHour?.usedPercent ?? -1) - 14.0) < 0.0001)
        #expect(abs((snap.fiveHour?.windowDuration ?? -1) - 5 * 3600) < 0.0001)
        #expect(abs((snap.sevenDay?.usedPercent ?? -1) - 22.0) < 0.0001)
        #expect(abs((snap.sevenDay?.windowDuration ?? -1) - 7 * 86400) < 0.0001)
        #expect(abs((snap.sevenDayFable?.usedPercent ?? -1) - 33.0) < 0.0001)
    }

    @Test("structured aggregate wins and 1 percent stays 1 when both shapes exist")
    func structuredAggregateWinsAtOnePercent() throws {
        let json = """
        {
          "seven_day": {
            "utilization": 1.0,
            "resets_at": "2026-07-24T10:00:00Z"
          },
          "limits": [{
            "kind": "weekly_all",
            "percent": 1.0,
            "resets_at": "2026-07-25T10:00:00Z",
            "scope": null
          }]
        }
        """.data(using: .utf8)!

        let snap = try ClaudeUsageClient.decode(data: json, capturedAt: capturedAt)
        #expect(abs((snap.sevenDay?.usedPercent ?? -1) - 1.0) < 0.0001)
        #expect(snap.sevenDay?.resetAt == ISO8601.parse("2026-07-25T10:00:00Z"),
                "structured weekly_all must win over the ambiguous top-level value")
    }

    @Test("legacy `used_percent` + `reset_at` keys still decode")
    func legacyUsedPercent_andResetAt_stillDecode() throws {
        let data = try loadFixture("legacy_used_percent")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        // Old key `used_percent` (already in 0..100) wins when
        // `utilization` is missing.
        #expect(abs((snap.fiveHour?.usedPercent ?? 0) - 25.0) < 0.0001)
        #expect(abs((snap.sevenDay?.usedPercent ?? 0) - 4.5) < 0.0001)
    }

    /// If Anthropic ever ships utilization=0.42-style ratios again, the
    /// `<=1.5 → percent` heuristic must still scale them up. Boundary
    /// at exactly 1.5 is deliberately treated as a ratio (1.5 → 150%);
    /// see fixture comment.
    @Test("legacy 0..1 ratio: heuristic scales to percent")
    func legacyRatio_scalesToPercent() throws {
        let data = try loadFixture("legacy_ratio")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        #expect(abs((snap.fiveHour?.usedPercent ?? 0) - 42.0) < 0.0001,
                "0.42 ratio must scale to 42%, not stay at 0.42 or balloon to 4200")
        #expect(abs((snap.sevenDay?.usedPercent ?? 0) - 8.0) < 0.0001)
    }

    @Test("Free tier: only 5h, no per-model windows, no crash")
    func freeTier_omitsEverythingButFiveHour() throws {
        let data = try loadFixture("free_tier_minimal")
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)

        #expect(snap.tier == "free")
        #expect(snap.fiveHour != nil)
        #expect(snap.sevenDay == nil)
        #expect(snap.sevenDayOpus == nil)
        #expect(snap.sevenDaySonnet == nil)
    }

    // MARK: - unknown / future fields are ignored

    /// New top-level keys (Anthropic seems to A/B-test them constantly:
    /// `iguana_necktie`, `omelette_promotional`, `seven_day_omelette`,
    /// `seven_day_oauth_apps`) must NOT cause decode failures. The live
    /// fixture contains all of these.
    @Test("unknown top-level fields are ignored, not rejected")
    func unknownTopLevelFields_doNotBreakDecode() throws {
        let data = try loadFixture("live_pro_2026-04-29")
        // Will throw if the decoder ever switches to strict mode.
        _ = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)
    }

    // MARK: - extra_usage is intentionally NOT decoded

    /// We deliberately dropped `extra_usage` from the wire model on
    /// 2026-04-29 (product decision: don't surface dollar overflow in
    /// CodexMonitor). Adding an `extra_usage` key to a fixture must
    /// therefore have ZERO observable effect on `ClaudeUsageSnapshot`.
    /// If a future PR re-introduces the field, the model no longer has
    /// the property to compare and the file simply fails to compile.
    @Test("extra_usage payload is silently ignored")
    func extraUsageField_isIgnored() throws {
        let json = """
        {
          "five_hour": {"utilization": 5.0, "resets_at": "2026-04-29T11:00:00Z"},
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 50.0,
            "used_credits": 12.34,
            "currency": "USD"
          }
        }
        """.data(using: .utf8)!

        let snap = try ClaudeUsageClient.decode(data: json, capturedAt: capturedAt)
        #expect(abs((snap.fiveHour?.usedPercent ?? 0) - 5.0) < 0.0001)
        // No `extraUsage` member exists on the snapshot anymore — the
        // mere fact that this file compiles is half the test.
    }

    // MARK: - error paths

    @Test("garbage JSON → .malformed")
    func garbageJSON_throwsMalformed() {
        let data = "not json".data(using: .utf8)!
        #expect(throws: ClaudeUsageClient.FetchError.self) {
            try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)
        }
    }

    @Test("empty object → empty snapshot")
    func emptyObject_decodesToEmptySnapshot() throws {
        let data = "{}".data(using: .utf8)!
        let snap = try ClaudeUsageClient.decode(data: data, capturedAt: capturedAt)
        #expect(snap.tier == nil)
        #expect(snap.fiveHour == nil)
        #expect(snap.sevenDay == nil)
        #expect(snap.sevenDayOpus == nil)
        #expect(snap.sevenDaySonnet == nil)
    }

    @Test("window without resetAt is dropped, not crashed")
    func window_withoutResetTimestamp_isDropped() throws {
        // Live response includes `seven_day_omelette: {utilization: 0,
        // resets_at: null}`. A known window with null timestamp must
        // also drop cleanly.
        let json = """
        { "five_hour": {"utilization": 33.0, "resets_at": null} }
        """.data(using: .utf8)!
        let snap = try ClaudeUsageClient.decode(data: json, capturedAt: capturedAt)
        #expect(snap.fiveHour == nil, "no resetAt → window should be dropped")
    }
}
