import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex reset credits snapshot")
struct CodexResetCreditsSnapshotTests {
    @Test("available credits are sorted by expiration")
    func availableCreditsSortedByExpiration() throws {
        let later = try #require(ISO8601.parse("2026-07-18T00:28:14.459108Z"))
        let earlier = try #require(ISO8601.parse("2026-07-12T00:16:55.107346Z"))
        let snapshot = CodexResetCreditsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_781_000_000),
            availableCount: 2,
            credits: [
                CodexResetCredit(grantedAt: nil, expiresAt: later),
                CodexResetCredit(grantedAt: nil, expiresAt: earlier)
            ],
            detailStatus: .complete)

        #expect(snapshot.credits.map(\.expiresAt) == [earlier, later])
        #expect(snapshot.nextExpiration == earlier)
        #expect(snapshot.hasDetailedExpirations)
    }

    @Test("count-only fallback has no detailed expirations")
    func countOnlyFallback() {
        let snapshot = CodexResetCreditsSnapshot.countOnly(
            availableCount: 2,
            capturedAt: Date(timeIntervalSince1970: 1_781_000_000))

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.isEmpty)
        #expect(snapshot.nextExpiration == nil)
        #expect(!snapshot.hasDetailedExpirations)
    }
}
