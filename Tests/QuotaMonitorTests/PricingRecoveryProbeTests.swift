import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Pricing recovery on an explicit database copy", .serialized)
struct PricingRecoveryProbeTests {
    @Test func recoverCopyWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["QM_PRICING_RECOVERY_COPY"],
              let output = environment["QM_PRICING_RECOVERY_REPORT"] else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        #expect(url.path != DatabaseManager.defaultURL().standardizedFileURL.path)
        guard url.path != DatabaseManager.defaultURL().standardizedFileURL.path else { return }
        let started = Date()
        let database = try DatabaseManager(url: url)
        let startupSeconds = Date().timeIntervalSince(started)
        let valuesMatch = try database.pool.write { db in
            let before = try Double.fetchAll(db, sql: "SELECT value_usd FROM usage_events ORDER BY id")
            try PricingService.backfillAllValues(in: db)
            let after = try Double.fetchAll(db, sql: "SELECT value_usd FROM usage_events ORDER BY id")
            return before.map(\.bitPattern) == after.map(\.bitPattern)
        }
        #expect(valuesMatch, "scoped startup recovery must agree with the full pricing reference")
        let usages = try database.pool.read { db in
            try Aggregator.quotaCycleUsage(db: db, cycles: QuotaCycleStore.cycles(db: db))
        }
        let report: [String: Any] = [
            "startupSeconds": startupSeconds,
            "matchesFullPricingReference": valuesMatch,
            "cycles": usages.map { usage in
                ["provider": usage.cycle.observation.provider,
                 "bucket": usage.cycle.observation.bucket,
                 "tokens": usage.tokens, "valueUSD": usage.valueUSD,
                 "events": usage.eventCount] as [String: Any]
            }
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
        print("pricing-copy-recovery: startup=\(startupSeconds)s reference-match=\(valuesMatch)")
    }
}
