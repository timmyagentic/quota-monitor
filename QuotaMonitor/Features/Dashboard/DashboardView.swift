import SwiftUI

/// Dashboard window — a Token Monitor-inspired HUD with the original
/// top-to-bottom section order preserved.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if env.menuBarUnreachable && !settings.firstRunHintDismissed {
                    hiddenIconHint
                }
                if let snapshot = env.dashboardSnapshot {
                    overview(snapshot)
                } else {
                    emptyState
                }
            }
            .padding(20)
            .frame(maxWidth: 1240, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DashboardBackground())
        .textSelection(.enabled)
        .task {
            env.refreshDashboard()
            env.refreshCodexAccountUsage(minInterval: 60, trigger: "dashboard")
        }
    }

    // MARK: - pages

    private func overview(_ snapshot: DashboardSnapshot) -> some View {
        @Bindable var env = env
        return VStack(alignment: .leading, spacing: 14) {
            statline
            ForecastSection(
                snapshot: snapshot,
                blocks: env.billingBlocks,
                claudeUsage: env.latestClaudeUsage,
                liveCodexRateLimits: env.latestRateLimits,
                providerFilter: env.providerFilter,
                enabledProviders: settings.enabledProviders)
            TrendsSection(
                dailyExtended: snapshot.dailyExtended,
                providerBreakdown: snapshot.dailyProviderExtended
                    .filter { providerIsVisible($0.provider) },
                modelBreakdown: snapshot.dailyModelExtended
                    .filter { providerIsVisible($0.provider) })
            ActivitySection(
                scope: $env.activityDataScope,
                indexed: indexedActivityContent(for: snapshot),
                account: accountActivityContent(for: snapshot),
                accountState: env.codexAccountUsageState,
                allowsAccountScope: env.providerFilter == .codex)
            CompositionSection(
                modelShares30d: snapshot.modelShares30d,
                modelSharesPrior30d: snapshot.modelSharesPrior30d,
                providerShares30d: snapshot.providerShares30d
                    .filter { providerIsVisible($0.provider) },
                showProviderBreakdown: visibleProviderCount > 1)
        }
    }

    // MARK: - rolling-window statline

    private var statline: some View {
        let codex = env.menuBarSnapshot?.codex
        let claude = env.menuBarSnapshot?.claude
        let window = settings.menuBarHeadlineWindow

        func usd(_ stats: ProviderStats?) -> Double {
            guard let stats else { return 0 }
            return window == .last7d ? stats.last7dValueUSD : stats.last30dValueUSD
        }
        func tokens(_ stats: ProviderStats?) -> Int64 {
            guard let stats else { return 0 }
            return window == .last7d ? stats.last7dTokens : stats.last30dTokens
        }
        func sessions(_ stats: ProviderStats?) -> Int {
            guard let stats else { return 0 }
            return window == .last7d ? stats.last7dSessionCount : stats.last30dSessionCount
        }

        let usdSum: Double
        let tokensSum: Int64
        let sessionsSum: Int
        let enabled = settings.enabledProviders

        switch env.providerFilter {
        case .all:
            let codexEnabled = enabled.contains("codex")
            let claudeEnabled = enabled.contains("claude")
            usdSum = (codexEnabled ? usd(codex) : 0) + (claudeEnabled ? usd(claude) : 0)
            tokensSum = (codexEnabled ? tokens(codex) : 0) + (claudeEnabled ? tokens(claude) : 0)
            sessionsSum = (codexEnabled ? sessions(codex) : 0) + (claudeEnabled ? sessions(claude) : 0)
        case .codex:
            usdSum = usd(codex)
            tokensSum = tokens(codex)
            sessionsSum = sessions(codex)
        case .claude:
            usdSum = usd(claude)
            tokensSum = tokens(claude)
            sessionsSum = sessions(claude)
        }

        let hasData = usdSum > 0 || tokensSum > 0 || sessionsSum > 0
        return HStack {
            if hasData {
                Text(L10n.dashboardHeadlineStatline(
                    window: window,
                    usd: usdSum.formatted(.currency(code: "USD")),
                    tokens: tokensSum.formatted(
                        .number.notation(.compactName).locale(settings.tokenFormatLocale)),
                    sessions: sessionsSum))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(L10n.headlineApiEquivalentHelp)
            } else {
                Text(L10n.dashboardHeadlineStatlineEmpty(window: window))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var visibleProviderCount: Int {
        ["codex", "claude"].filter(providerIsVisible).count
    }

    private func providerIsVisible(_ provider: String) -> Bool {
        guard settings.enabledProviders.contains(provider) else { return false }
        switch env.providerFilter {
        case .all:
            return true
        case .codex:
            return provider == "codex"
        case .claude:
            return provider == "claude"
        }
    }

    // MARK: - activity metrics

    private func indexedActivityContent(
        for snapshot: DashboardSnapshot
    ) -> ActivitySection.Content {
        let activity = snapshot.activity
        let dailyTokens = summedTokens(activity.daily)
        let asOf = snapshot.overview.lastEventAt
            .flatMap(Aggregator.parseTimestamp)
            .map { L10n.activityUpdated(shortDate($0)) }
        return ActivitySection.Content(
            metrics: activityMetrics(for: snapshot),
            daily: activity.daily,
            hasDailySeries: true,
            hasData: activity.hasData,
            summary: L10n.activityIndexedSummary(
                tokens: compactTokens(activity.lifetimeTokens)),
            asOf: asOf,
            heatmapScopeLabel: L10n.activityHeatmapScope(
                scope: L10n.activityScopeIndexed),
            heatmapAccessibilityLabel: L10n.activityHeatmapAccessibility(
                scope: L10n.activityScopeIndexed,
                activeDays: activity.daily.count { $0.tokens > 0 },
                totalTokens: compactTokens(dailyTokens)))
    }

    private func accountActivityContent(
        for localSnapshot: DashboardSnapshot
    ) -> ActivitySection.Content? {
        guard env.providerFilter == .codex,
              let account = env.codexAccountUsageState.snapshot else { return nil }

        let accountTokens = account.lifetimeTokens
        let localTokens = localSnapshot.activity.lifetimeTokens
        let localLastEvent = localSnapshot.overview.lastEventAt
            .flatMap(Aggregator.parseTimestamp)
        let totalsShareACutoff: Bool
        if let accountCutoff = account.latestBucketDate,
           let localLastEvent {
            totalsShareACutoff = Calendar.current.startOfDay(for: localLastEvent)
                <= Calendar.current.startOfDay(for: accountCutoff)
        } else {
            totalsShareACutoff = true
        }
        let coverage = totalsShareACutoff && !env.codexAccountUsageState.isStale
            ? ActivityCoverage.percentage(indexed: localTokens, account: accountTokens)
            : nil
        let accountTotalLabel = accountTokens.map(compactTokens) ?? "—"
        let heatmapTokens = summedTokens(account.daily)
        let asOfDate = account.latestBucketDate ?? account.capturedAt

        return ActivitySection.Content(
            metrics: accountActivityMetrics(account),
            daily: account.daily,
            hasDailySeries: account.dailySeries.points != nil,
            hasData: accountTokens.map { $0 > 0 } ?? account.daily.contains { $0.tokens > 0 },
            summary: L10n.activityAccountSummary(
                accountTokens: accountTotalLabel,
                indexedTokens: compactTokens(localTokens),
                coveragePercent: coverage),
            asOf: L10n.activityAsOf(shortDate(asOfDate)),
            heatmapScopeLabel: L10n.activityHeatmapScope(
                scope: L10n.activityScopeAccount),
            heatmapAccessibilityLabel: L10n.activityHeatmapAccessibility(
                scope: L10n.activityScopeAccount,
                activeDays: account.daily.count { $0.tokens > 0 },
                totalTokens: compactTokens(heatmapTokens)))
    }

    private func activityMetrics(for snapshot: DashboardSnapshot) -> [ActivitySection.Metric] {
        let activity = snapshot.activity
        let topModel = snapshot.modelShares30d.first?.displayName
            ?? snapshot.modelShares.first?.displayName
            ?? "—"
        return [
            ActivitySection.Metric(
                value: compactTokens(activity.lifetimeTokens),
                label: L10n.activityLifetimeTokens,
                accessibilityValue: fullTokens(activity.lifetimeTokens)),
            ActivitySection.Metric(
                value: compactUSD(snapshot.overview.totalValueUSD),
                label: L10n.dashboardMetricTotalCost),
            ActivitySection.Metric(
                value: activity.activeDays.formatted(
                    .number.locale(settings.tokenFormatLocale)),
                label: L10n.dashboardMetricActiveDays),
            ActivitySection.Metric(
                value: L10n.activityStreakDays(activity.currentStreakDays),
                label: L10n.activityCurrentStreak),
            ActivitySection.Metric(
                value: L10n.activityStreakDays(activity.longestStreakDays),
                label: L10n.activityLongestStreak),
            ActivitySection.Metric(
                value: compactTokens(activity.peakDayTokens),
                label: L10n.activityPeakTokens,
                accessibilityValue: fullTokens(activity.peakDayTokens),
                help: activity.peakDay.map(shortDate)),
            ActivitySection.Metric(
                value: topModel,
                label: L10n.dashboardMetricTopModel),
            ActivitySection.Metric(
                value: snapshot.overview.totalEvents.formatted(
                    .number.notation(.compactName).locale(settings.tokenFormatLocale)),
                label: L10n.dashboardMetricEvents)
        ]
    }

    private func accountActivityMetrics(
        _ account: CodexAccountUsageSnapshot
    ) -> [ActivitySection.Metric] {
        [
            tokenMetric(
                account.lifetimeTokens,
                label: L10n.activityAccountLifetimeTokens),
            tokenMetric(
                account.peakDailyTokens,
                label: L10n.activityAccountPeakTokens),
            ActivitySection.Metric(
                value: account.longestRunningTurnSeconds
                    .map(L10n.activityDuration) ?? "—",
                label: L10n.activityAccountLongestChat),
            streakMetric(
                account.currentStreakDays,
                label: L10n.activityAccountCurrentStreak),
            streakMetric(
                account.longestStreakDays,
                label: L10n.activityAccountLongestStreak)
        ]
    }

    private func tokenMetric(_ value: Int64?, label: String) -> ActivitySection.Metric {
        ActivitySection.Metric(
            value: value.map(compactTokens) ?? "—",
            label: label,
            accessibilityValue: value.map(fullTokens))
    }

    private func streakMetric(_ value: Int64?, label: String) -> ActivitySection.Metric {
        ActivitySection.Metric(
            value: value.map { L10n.activityStreakDays(Int(clamping: $0)) } ?? "—",
            label: label)
    }

    private func compactTokens(_ tokens: Int64) -> String {
        tokens.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(settings.tokenFormatLocale))
    }

    private func fullTokens(_ tokens: Int64) -> String {
        L10n.tokensCount(tokens.formatted(
            .number.locale(settings.tokenFormatLocale)))
    }

    private func summedTokens(_ daily: [DailyPoint]) -> Int64 {
        daily.reduce(0) { total, point in
            let (sum, overflow) = total.addingReportingOverflow(point.tokens)
            return overflow ? Int64.max : sum
        }
    }

    private func shortDate(_ date: Date) -> String {
        let locale = LocalizationStore.activeLanguage == .simplifiedChinese
            ? Locale(identifier: "zh_Hans")
            : Locale(identifier: "en_US")
        return date.formatted(
            .dateTime.year().month(.abbreviated).day().locale(locale))
    }

    private func compactUSD(_ value: Double) -> String {
        "$" + value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(settings.tokenFormatLocale))
    }

    // MARK: - hidden-icon hint

    @ViewBuilder
    private var hiddenIconHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "menubar.rectangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.menuBarHiddenHintTitle)
                    .font(.headline)
                Text(L10n.menuBarHiddenHintBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(L10n.menuBarHelpShowMeHow) {
                    WindowManager.shared.show("menubar-help")
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.menuBarHiddenHintDismiss) {
                    settings.firstRunHintDismissed = true
                }
            }
        }
        .dashboardPanel(cornerRadius: 10, padding: 12)
    }

    // MARK: - empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(env.isLoadingDashboard ? L10n.loadingDashboard : L10n.noData)
                .foregroundStyle(.secondary)
            Text(L10n.clickScanHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .dashboardPanel(cornerRadius: 12, padding: 18)
    }
}

private struct DashboardBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [DashboardTheme.codex.opacity(0.18), .clear],
                startPoint: .topLeading,
                endPoint: .center)
            LinearGradient(
                colors: [DashboardTheme.claude.opacity(0.10), .clear],
                startPoint: .bottomTrailing,
                endPoint: .center)
        }
        .ignoresSafeArea()
    }
}
