import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Activity data scope")
struct ActivityScopeTests {
    @Test("coverage is shown only for comparable totals")
    func safeCoverage() {
        #expect(ActivityCoverage.percentage(indexed: 25, account: 100) == 25)
        #expect(ActivityCoverage.percentage(indexed: 0, account: 100) == 0)
        #expect(ActivityCoverage.percentage(indexed: 100, account: 100) == 100)
        #expect(ActivityCoverage.percentage(indexed: 101, account: 100) == nil)
        #expect(ActivityCoverage.percentage(indexed: 1, account: 0) == nil)
        #expect(ActivityCoverage.percentage(indexed: -1, account: 100) == nil)
        #expect(ActivityCoverage.percentage(indexed: 1, account: nil) == nil)
    }

    @Test("refresh and stale states retain the last good snapshot")
    func cachedStateAccess() {
        let snapshot = CodexAccountUsageSnapshot(
            lifetimeTokens: 1_000,
            peakDailyTokens: 200,
            longestRunningTurnSeconds: 300,
            currentStreakDays: 4,
            longestStreakDays: 5,
            daily: [],
            latestBucketDate: nil,
            capturedAt: Date(timeIntervalSince1970: 1_000))

        #expect(CodexAccountUsageState.loaded(snapshot).snapshot == snapshot)
        #expect(CodexAccountUsageState.refreshing(snapshot).snapshot == snapshot)
        #expect(CodexAccountUsageState.stale(snapshot).snapshot == snapshot)
        #expect(CodexAccountUsageState.loading.snapshot == nil)
        #expect(CodexAccountUsageState.unavailable.snapshot == nil)
        #expect(CodexAccountUsageState.refreshing(snapshot).isRefreshing)
        #expect(CodexAccountUsageState.stale(snapshot).isStale)
    }
}
