import Foundation

/// Prepare local history and its display cache before the six-hour freshness
/// budget expires. The extra hour leaves room for a large incremental scan.
struct DashboardBackgroundRefreshPolicy: Sendable {
    static let refreshInterval: TimeInterval = 5 * 60 * 60
    static let retryInterval: TimeInterval = 5 * 60
    private(set) var lastAttemptAt: Date?

    func isDue(historyAt: Date?, snapshotAt: Date?, now: Date) -> Bool {
        guard let historyAt, let snapshotAt else { return true }
        return [historyAt, snapshotAt].contains {
            let age = now.timeIntervalSince($0)
            return age < 0 || age >= Self.refreshInterval
        }
    }

    mutating func begin(
        historyAt: Date?, snapshotAt: Date?, now: Date, isBusy: Bool
    ) -> Bool {
        guard !isBusy, isDue(historyAt: historyAt, snapshotAt: snapshotAt, now: now)
        else { return false }
        if let lastAttemptAt {
            let elapsed = now.timeIntervalSince(lastAttemptAt)
            if elapsed >= 0 && elapsed < Self.retryInterval { return false }
        }
        lastAttemptAt = now
        return true
    }

    func nextDeadline(
        scheduled: Date?, historyAt: Date?, snapshotAt: Date?, now: Date
    ) -> Date {
        let candidate = now.addingTimeInterval(nextDelay(
            historyAt: historyAt, snapshotAt: snapshotAt, now: now))
        // Frequent publication must not keep pushing an overdue history scan
        // five minutes into the future.
        return scheduled.map { min($0, candidate) } ?? candidate
    }

    func nextDelay(historyAt: Date?, snapshotAt: Date?, now: Date) -> TimeInterval {
        guard !isDue(historyAt: historyAt, snapshotAt: snapshotAt, now: now),
              let historyAt, let snapshotAt else { return Self.retryInterval }
        return max(Self.retryInterval,
                   min(historyAt, snapshotAt).addingTimeInterval(Self.refreshInterval)
                    .timeIntervalSince(now))
    }
}

extension AppEnvironment {
    func startDashboardBackgroundRefresh() {
        guard !dashboardBackgroundRefreshEnabled,
              SettingsStore.snapshot().hasCompletedProviderOnboarding,
              LocalQAEnvironment.allowsExternalDataSources() else { return }
        dashboardBackgroundRefreshEnabled = true
        scheduleDashboardBackgroundRefresh()
    }

    func stopDashboardBackgroundRefresh() {
        dashboardBackgroundRefreshEnabled = false
        dashboardBackgroundRefreshTask?.cancel()
        dashboardBackgroundRefreshTask = nil
        dashboardBackgroundRefreshDeadline = nil
    }

    /// One cancellable deadline, recomputed after successful scans/publication.
    /// No network calls and no dependency on the quota pollers' auth/cooldowns.
    func scheduleDashboardBackgroundRefresh() {
        guard dashboardBackgroundRefreshEnabled else { return }
        let now = Date()
        let deadline = dashboardBackgroundRefreshPolicy.nextDeadline(
            scheduled: dashboardBackgroundRefreshDeadline,
            historyAt: dashboardHistoryRefreshedAt,
            snapshotAt: dashboardCachedSnapshotDate,
            now: now)
        guard dashboardBackgroundRefreshDeadline != deadline else { return }
        dashboardBackgroundRefreshTask?.cancel()
        dashboardBackgroundRefreshDeadline = deadline
        let delay = max(0, deadline.timeIntervalSince(now))
        dashboardBackgroundRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.dashboardBackgroundRefreshTask = nil
            self.dashboardBackgroundRefreshDeadline = nil
            self.refreshDashboardInBackgroundIfNeeded()
        }
    }

    /// Also called on wake/foreground, where a sleep deadline may have expired
    /// while the machine was suspended. Busy/failed work retries in five minutes.
    func refreshDashboardInBackgroundIfNeeded(now: Date = Date()) {
        guard dashboardBackgroundRefreshEnabled,
              SettingsStore.snapshot().hasCompletedProviderOnboarding else { return }
        let shouldStart = dashboardBackgroundRefreshPolicy.begin(
            historyAt: dashboardHistoryRefreshedAt,
            snapshotAt: dashboardCachedSnapshotDate,
            now: now,
            isBusy: isScanning || isLoadingDashboard)
        if shouldStart {
            runScan(trigger: "dashboard-cache")
        }
        scheduleDashboardBackgroundRefresh()
    }
}
