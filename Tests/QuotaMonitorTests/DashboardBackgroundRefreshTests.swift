import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Dashboard background freshness")
struct DashboardBackgroundRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let interval = DashboardBackgroundRefreshPolicy.refreshInterval

    @Test("A closed Dashboard is prepared every five hours across several days")
    func closedForSeveralDays() {
        var policy = DashboardBackgroundRefreshPolicy()
        var lastPrepared = now
        for hour in 1...72 {
            let time = now.addingTimeInterval(Double(hour) * 3600)
            let began = policy.begin(historyAt: lastPrepared, snapshotAt: lastPrepared,
                                     now: time, isBusy: false)
            #expect(began == (hour % 5 == 0))
            if began { lastPrepared = time }
            #expect(time.timeIntervalSince(lastPrepared) < 6 * 3600)
        }
    }

    @Test("A new chart cannot conceal stale unscanned Codex history")
    func freshSnapshotDoesNotPostponeHistory() {
        let policy = DashboardBackgroundRefreshPolicy()
        #expect(policy.isDue(historyAt: now.addingTimeInterval(-interval),
                             snapshotAt: now, now: now))
        #expect(policy.nextDelay(historyAt: now.addingTimeInterval(-interval + 600),
                                 snapshotAt: now, now: now) == 600)
    }

    @Test("Frequent scans cannot postpone preparation of an old or missing chart")
    func freshHistoryDoesNotPostponeSnapshot() {
        let policy = DashboardBackgroundRefreshPolicy()
        #expect(policy.isDue(historyAt: now, snapshotAt: nil, now: now))
        #expect(policy.isDue(historyAt: now, snapshotAt: now.addingTimeInterval(-interval),
                             now: now))
        #expect(!policy.isDue(historyAt: now, snapshotAt: now.addingTimeInterval(-interval + 1),
                              now: now))
    }

    @Test("Wake after days away starts once and keeps failure retries bounded")
    func wakeAndRetry() {
        var policy = DashboardBackgroundRefreshPolicy()
        let stale = now.addingTimeInterval(-3 * 24 * 3600)
        let first = policy.begin(historyAt: stale, snapshotAt: stale, now: now, isBusy: false)
        let repeated = policy.begin(historyAt: stale, snapshotAt: stale, now: now, isBusy: false)
        #expect(first)
        #expect(!repeated)
        #expect(policy.nextDelay(historyAt: stale, snapshotAt: stale, now: now) == 300)
        let earlyRetry = policy.begin(historyAt: stale, snapshotAt: stale,
                                      now: now.addingTimeInterval(299), isBusy: false)
        let retry = policy.begin(historyAt: stale, snapshotAt: stale,
                                 now: now.addingTimeInterval(300), isBusy: false)
        #expect(!earlyRetry)
        #expect(retry)
    }

    @Test("An in-flight import or primary refresh absorbs the background request")
    func busyWorkIsNotDuplicated() {
        var policy = DashboardBackgroundRefreshPolicy()
        let busy = policy.begin(historyAt: nil, snapshotAt: nil, now: now, isBusy: true)
        #expect(!busy)
        #expect(policy.lastAttemptAt == nil)
        let initial = policy.begin(historyAt: nil, snapshotAt: nil, now: now, isBusy: false)
        let refreshed = policy.begin(historyAt: now, snapshotAt: now,
                                     now: now.addingTimeInterval(300), isBusy: false)
        #expect(initial)
        #expect(!refreshed)
        #expect(policy.nextDelay(historyAt: now, snapshotAt: now, now: now) == interval)
    }

    @Test("Continuous chart updates cannot defer a due history scan")
    func continuousPublicationKeepsEarliestDeadline() {
        let policy = DashboardBackgroundRefreshPolicy()
        let history = now.addingTimeInterval(-interval)
        var scheduled: Date?
        for second in stride(from: 0, through: 295, by: 5) {
            let time = now.addingTimeInterval(Double(second))
            scheduled = policy.nextDeadline(scheduled: scheduled, historyAt: history,
                                            snapshotAt: time, now: time)
            #expect(scheduled == now.addingTimeInterval(300))
        }
    }

    @Test("Clock rollback does not freeze the cache until a future timestamp")
    func clockRollbackRecovers() {
        var policy = DashboardBackgroundRefreshPolicy()
        let initial = policy.begin(historyAt: nil, snapshotAt: nil,
                                   now: now.addingTimeInterval(3600), isBusy: false)
        let rollback = policy.begin(historyAt: now.addingTimeInterval(1), snapshotAt: now,
                                    now: now, isBusy: false)
        #expect(initial)
        #expect(rollback)
    }
}
