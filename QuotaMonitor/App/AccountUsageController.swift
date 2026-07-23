import Foundation

extension AppEnvironment {
    /// Refresh the optional account-wide Activity source. This is intentionally
    /// lazy: Indexed mode never starts an account request, and non-Codex
    /// Dashboard filters keep their existing behavior unchanged.
    func refreshCodexAccountUsage(
        minInterval: TimeInterval? = nil,
        trigger: String = "manual",
        parentOperation: DeveloperLogOperation? = nil
    ) {
        guard providerFilter == .codex, activityDataScope == .account else {
            return
        }

        if LocalQAEnvironment.isActive() {
            installLocalQAMockCodexAccountUsage()
            return
        }
        guard LocalQAEnvironment.allowsExternalDataSources() else {
            codexAccountUsageState = .unavailable
            return
        }

        let settings = SettingsStore.snapshot()
        guard settings.hasCompletedProviderOnboarding,
              settings.enabledProviders.contains("codex") else {
            codexAccountUsageState = .unavailable
            return
        }
        if let interval = minInterval,
           let lastAttempt = lastCodexAccountUsageRefreshAttemptAt,
           Date().timeIntervalSince(lastAttempt) < interval {
            return
        }
        guard !isRefreshingCodexAccountUsage else { return }

        let previous = codexAccountUsageState.snapshot
        codexAccountUsageState = previous.map(CodexAccountUsageState.refreshing) ?? .loading
        isRefreshingCodexAccountUsage = true
        lastCodexAccountUsageRefreshAttemptAt = Date()
        codexAccountUsageRefreshGeneration &+= 1
        let generation = codexAccountUsageRefreshGeneration
        let operation = DeveloperLog.startOperation(
            "codex_account_usage.refresh",
            category: "poller",
            trigger: trigger,
            provider: "codex",
            parent: parentOperation)

        Task { @MainActor [weak self, client = codexAccountUsageClient] in
            guard let self else { return }
            defer {
                // A provider disable/re-enable can invalidate this request and
                // start a newer generation before the old task unwinds. Only
                // the generation that still owns the in-flight flag may clear
                // it; otherwise the superseded task would make a newer fetch
                // look idle and allow overlapping refreshes.
                if self.codexAccountUsageRefreshGeneration == generation {
                    self.isRefreshingCodexAccountUsage = false
                }
            }
            do {
                let snapshot = try await Self.withTimeout(
                    seconds: 15,
                    context: "refreshCodexAccountUsage"
                ) {
                    try await client.fetchAccountUsage()
                }
                guard self.codexAccountUsageRefreshGeneration == generation else {
                    DeveloperLog.finishOperation(operation, result: "superseded")
                    return
                }
                self.codexAccountUsageState = .loaded(snapshot)
                DeveloperLog.finishOperation(
                    operation,
                    fields: [
                        "daily_bucket_count": .int(snapshot.daily.count),
                        "has_lifetime_tokens": .bool(snapshot.lifetimeTokens != nil),
                        "has_latest_bucket": .bool(snapshot.latestBucketDate != nil)
                    ])
            } catch {
                guard self.codexAccountUsageRefreshGeneration == generation else {
                    DeveloperLog.finishOperation(operation, result: "superseded")
                    return
                }
                self.codexAccountUsageState = previous.map(CodexAccountUsageState.stale)
                    ?? .unavailable
                // Keep potentially sensitive RPC bodies out of diagnostics.
                DeveloperLog.finishOperation(
                    operation,
                    result: "failure",
                    fields: [
                        "error_type": .string(String(describing: type(of: error))),
                        "has_cached_snapshot": .bool(previous != nil)
                    ])
            }
        }
    }

    /// Deterministic, synthetic account data for screenshot/local QA. This is
    /// only reachable when the QA harness is active, where all external data
    /// sources (including app-server) are already blocked.
    func installLocalQAMockCodexAccountUsage(now: Date = Date()) {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        let daily = (0..<365).reversed().compactMap { offset -> DailyPoint? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let ordinal = 364 - offset
            let activeThreshold = ordinal > 294 ? 11 : 6
            let isActive = ordinal >= 105
                && ((ordinal * 19 + (ordinal % 7) * 11) % 17) < activeThreshold
            let tokens: Int64 = isActive
                ? Int64(18_000_000 + (ordinal % 11) * 7_500_000)
                : 0
            return DailyPoint(date: date, valueUSD: 0, tokens: tokens)
        }
        codexAccountUsageState = .loaded(CodexAccountUsageSnapshot(
            lifetimeTokens: 18_400_000_000,
            peakDailyTokens: 1_600_000_000,
            longestRunningTurnSeconds: 9 * 60 * 60 + 26 * 60,
            currentStreakDays: 37,
            longestStreakDays: 64,
            daily: daily,
            latestBucketDate: today,
            capturedAt: now))
        lastCodexAccountUsageRefreshAttemptAt = now
        DeveloperLog.eventRecord(
            "codex_account_usage.qa_mock.install",
            category: "poller",
            trigger: "qa",
            provider: "codex",
            fields: ["daily_bucket_count": .int(daily.count)])
    }
}
