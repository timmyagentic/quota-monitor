import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Automatic history scan policy")
struct AutomaticHistoryScanPolicyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    @Test("No previous full scan requests a recovery scan")
    func missingScanRequestsRecovery() {
        let now = date(2026, 8, 29, 9, 0)
        #expect(AutomaticHistoryScanPolicy.shouldScan(
            lastFullScanAt: nil,
            now: now,
            calendar: calendar))
    }

    @Test("Repeated foreground events on the same local day stay quiet")
    func sameDayStaysQuiet() {
        let last = date(2026, 8, 29, 0, 1)
        let now = date(2026, 8, 29, 23, 59)
        #expect(!AutomaticHistoryScanPolicy.shouldScan(
            lastFullScanAt: last,
            now: now,
            calendar: calendar))
    }

    @Test("Crossing local midnight requests exactly one new-day scan")
    func nextDayRequestsScan() {
        let last = date(2026, 8, 29, 23, 58)
        let now = date(2026, 8, 30, 0, 2)
        #expect(AutomaticHistoryScanPolicy.shouldScan(
            lastFullScanAt: last,
            now: now,
            calendar: calendar))
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute))!
    }
}
