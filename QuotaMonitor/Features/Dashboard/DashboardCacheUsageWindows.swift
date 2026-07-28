import Foundation

struct DashboardCacheUsageWindows: Equatable {
    let today: CacheUsageSummary
    let last7Days: CacheUsageSummary
    let last30Days: CacheUsageSummary

    init(
        daily: [DailyPoint],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let todayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(
            byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let thirtyDayStart = calendar.date(
            byAdding: .day, value: -29, to: todayStart) ?? todayStart

        func combined(since start: Date) -> CacheUsageSummary {
            CacheUsageSummary.combined(daily.compactMap { point in
                let pointDay = calendar.startOfDay(for: point.date)
                guard pointDay >= start, pointDay <= todayStart else {
                    return nil
                }
                return point.cacheUsage
            })
        }

        self.today = CacheUsageSummary.combined(daily.compactMap { point in
            calendar.isDate(point.date, inSameDayAs: todayStart)
                ? point.cacheUsage
                : nil
        })
        self.last7Days = combined(since: sevenDayStart)
        self.last30Days = combined(since: thirtyDayStart)
    }
}
