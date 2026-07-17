import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Anonymous daily-active payload")
struct DailyActivePayloadTests {
    private let canonicalToken = "AAECAwQFBgcICQoLDA0ODw"

    @Test("The wire payload has exactly the six versioned contract fields")
    func exactWireContract() throws {
        let payload = try #require(DailyActivePayload(
            day: "2026-07-16",
            token: canonicalToken,
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id"))

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
                as? [String: Any])

        #expect(Set(object.keys) == ["schema", "day", "token", "version", "brand", "channel"])
        #expect(payload.schema == 1)
        #expect(payload.day == "2026-07-16")
        #expect(payload.token == canonicalToken)
        #expect(payload.version == "0.2.41")
        #expect(payload.brand == "quota-monitor")
        #expect(payload.channel == "developer-id")
    }

    @Test("Validation matches the Worker allowlists and canonical formats", arguments: [
        PayloadCase(label: "impossible day", day: "2026-02-30"),
        PayloadCase(label: "non-padded day", day: "2026-7-16"),
        PayloadCase(label: "short token", token: "AECAwQFBgcICQoLDA0ODw"),
        PayloadCase(label: "invalid token alphabet", token: "AAECAwQFBgcICQoLDA0OD+"),
        PayloadCase(label: "non-canonical token", token: "AAAAAAAAAAAAAAAAAAAAAB"),
        PayloadCase(label: "empty version", version: ""),
        PayloadCase(label: "short version", version: "0.2"),
        PayloadCase(label: "leading zero", version: "0.02.41"),
        PayloadCase(label: "prerelease", version: "0.2.41-beta.1"),
        PayloadCase(label: "overlong version", version: "1.2.\(String(repeating: "3", count: 61))"),
        PayloadCase(label: "unknown brand", brand: "other-monitor"),
        PayloadCase(label: "unknown channel", channel: "nightly"),
    ])
    func rejectsInvalidPayload(testCase: PayloadCase) {
        #expect(DailyActivePayload(
            day: testCase.day,
            token: testCase.token,
            version: testCase.version,
            brand: testCase.brand,
            channel: testCase.channel) == nil, "Expected rejection for \(testCase.label)")
    }

    @Test("UTC Gregorian day generation crosses the UTC boundary exactly")
    func utcDayGeneration() throws {
        let beforeMidnight = try #require(ISO8601DateFormatter().date(
            from: "2026-07-16T23:59:59Z"))
        let midnight = try #require(ISO8601DateFormatter().date(
            from: "2026-07-17T00:00:00Z"))

        #expect(DailyActivePayload.utcDay(for: beforeMidnight) == "2026-07-16")
        #expect(DailyActivePayload.utcDay(for: midnight) == "2026-07-17")
    }

    @Test("Brand telemetry slugs fail closed for unknown code names")
    func brandTelemetrySlugs() {
        #expect(Branding.telemetrySlug(forCodeName: "QuotaMonitor") == "quota-monitor")
        #expect(Branding.telemetrySlug(forCodeName: "CodexMonitor") == "codex-monitor")
        #expect(Branding.telemetrySlug(forCodeName: "Quota Monitor") == nil)
        #expect(Branding.telemetrySlug(forCodeName: "quotamonitor") == nil)
        #expect(Branding.telemetrySlug(forCodeName: "") == nil)
    }

    @Test("Telemetry channel resolution is strict without changing current fallback behavior")
    func strictDistributionChannelResolution() {
        #expect(DistributionChannel.telemetryChannel(
            infoDictionary: [DistributionChannel.infoDictionaryKey: "developer-id"],
            environment: [:]) == .developerID)
        #expect(DistributionChannel.telemetryChannel(
            infoDictionary: nil,
            environment: ["QM_DISTRIBUTION": "app-store"]) == .appStore)
        #expect(DistributionChannel.telemetryChannel(
            infoDictionary: [DistributionChannel.infoDictionaryKey: "nightly"],
            environment: ["QM_DISTRIBUTION": "developer-id"]) == nil)
        #expect(DistributionChannel.telemetryChannel(
            infoDictionary: [DistributionChannel.infoDictionaryKey: 41],
            environment: ["QM_DISTRIBUTION": "developer-id"]) == nil)
        #expect(DistributionChannel.telemetryChannel(
            infoDictionary: nil,
            environment: [:]) == nil)
        #expect(DistributionChannel.from(infoDictionary: nil, environment: [:]) == .developerID)
    }

    @Test("Reporting context validates version and keeps App Store reporting gated")
    func reportingContextResolution() {
        let developerID = DailyActiveReportingContext.resolve(
            version: "0.2.41",
            appCodeName: "QuotaMonitor",
            infoDictionary: [DistributionChannel.infoDictionaryKey: "developer-id"],
            environment: [:],
            appStoreReportingAllowed: false)
        #expect(developerID == DailyActiveReportingContext(
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id"))

        #expect(DailyActiveReportingContext.resolve(
            version: "unknown",
            appCodeName: "QuotaMonitor",
            infoDictionary: [DistributionChannel.infoDictionaryKey: "developer-id"],
            environment: [:],
            appStoreReportingAllowed: true) == nil)
        #expect(DailyActiveReportingContext.resolve(
            version: "0.2.41",
            appCodeName: "FutureMonitor",
            infoDictionary: [DistributionChannel.infoDictionaryKey: "developer-id"],
            environment: [:],
            appStoreReportingAllowed: true) == nil)
        #expect(DailyActiveReportingContext.resolve(
            version: "0.2.41",
            appCodeName: "QuotaMonitor",
            infoDictionary: [DistributionChannel.infoDictionaryKey: "app-store"],
            environment: [:],
            appStoreReportingAllowed: false) == nil)
        #expect(DailyActiveReportingContext.resolve(
            version: "0.2.41",
            appCodeName: "QuotaMonitor",
            infoDictionary: [DistributionChannel.infoDictionaryKey: "app-store"],
            environment: [:],
            appStoreReportingAllowed: true)?.channel == "app-store")
    }
}

struct PayloadCase: Sendable, CustomTestStringConvertible {
    let label: String
    var day = "2026-07-16"
    var token = "AAECAwQFBgcICQoLDA0ODw"
    var version = "0.2.41"
    var brand = "quota-monitor"
    var channel = "developer-id"

    var testDescription: String { label }
}
