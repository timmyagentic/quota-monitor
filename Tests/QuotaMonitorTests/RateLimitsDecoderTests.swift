import Foundation
import Testing
@testable import QuotaMonitor

/// Snapshot tests pinning the wire format of `codex app-server`'s
/// `account/rateLimits/read` response.
///
/// **Why this file exists.** Between codex CLI 0.126 and 0.128 the wire
/// format silently flipped from `snake_case` to `camelCase` and renamed
/// most fields (`rate_limit` → `rateLimits`, `primary_window` →
/// `primary`, `limit_window_seconds` → `windowDurationMins`,
/// `additional_rate_limits[]` → `rateLimitsByLimitId{}`). All fields in
/// `RateLimitsPayload` were Optional, so decoding "succeeded" but every
/// window came out nil — the menu bar then fell back to the
/// `else` branch and showed "Sign in via codex CLI to see live quotas"
/// even for fully signed-in users.
///
/// Both fixtures must keep decoding cleanly. Add a new fixture every
/// time you observe a new wire shape in the wild — never silently
/// widen the decoder.
@Suite("RateLimits payload decoder")
struct RateLimitsDecoderTests {

    private func loadFixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures/RateLimits")
        else {
            Issue.record("missing fixture \(name).json — check Package.swift `resources`")
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    @Test("camelCase live capture (codex CLI ≥ 0.128) decodes primary + secondary")
    func decodeCamelLive() throws {
        let data = try loadFixture("live_camel_2026-05-06")
        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: data)
        let snap = RateLimitSnapshot(from: payload,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000))

        #expect(snap.planType == "prolite")
        #expect(snap.primary?.usedPercent == 10)
        #expect(snap.primary?.windowDuration == TimeInterval(300 * 60))   // 5h in seconds
        #expect(snap.secondary?.usedPercent == 11)
        #expect(snap.secondary?.windowDuration == TimeInterval(10080 * 60)) // 7d in seconds

        // The `codex` entry inside `rateLimitsByLimitId` duplicates the
        // headline `rateLimits` group — decoder must drop it. Only the
        // model-specific spark entry should remain.
        #expect(snap.additional.count == 1)
        #expect(snap.additional.first?.limitName == "GPT-5.3-Codex-Spark")
    }

    @Test("legacy snake_case capture still decodes")
    func decodeLegacySnake() throws {
        let data = try loadFixture("legacy_snake")
        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: data)
        let snap = RateLimitSnapshot(from: payload,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000))

        #expect(snap.planType == "pro")
        #expect(snap.primary?.usedPercent == 42.5)
        #expect(snap.primary?.windowDuration == 18000)      // legacy seconds
        #expect(snap.secondary?.usedPercent == 12.0)
        #expect(snap.additional.count == 1)
        #expect(snap.additional.first?.limitName == "gpt-5-codex-spark")
    }

    @Test("camelCase rateLimitResetCredits decodes available count")
    func decodeCamelResetCreditsCount() throws {
        let json = """
        {
          "rateLimitResetCredits": { "availableCount": 2 },
          "rateLimits": {
            "planType": "pro",
            "primary": {
              "usedPercent": 1,
              "windowDurationMins": 300,
              "resetsAt": 1781169600
            },
            "secondary": {
              "usedPercent": 31,
              "windowDurationMins": 10080,
              "resetsAt": 1781510400
            }
          }
        }
        """
        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
        let snap = RateLimitSnapshot(from: payload, capturedAt: Date(timeIntervalSince1970: 1_781_100_000))

        #expect(payload.resetCreditsAvailable == 2)
        #expect(snap.resetCreditsAvailable == 2)
    }

    @Test("snake_case rate_limit_reset_credits decodes available count")
    func decodeSnakeResetCreditsCount() throws {
        let json = """
        {
          "rate_limit_reset_credits": { "available_count": 3 },
          "rate_limit": {
            "primary_window": {
              "used_percent": 5,
              "limit_window_seconds": 18000,
              "reset_at": 1781169600
            }
          }
        }
        """
        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
        let snap = RateLimitSnapshot(from: payload, capturedAt: Date(timeIntervalSince1970: 1_781_100_000))

        #expect(payload.resetCreditsAvailable == 3)
        #expect(snap.resetCreditsAvailable == 3)
    }
}
