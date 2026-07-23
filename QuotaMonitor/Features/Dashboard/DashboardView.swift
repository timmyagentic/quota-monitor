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
        .task { env.refreshDashboard() }
    }

    // MARK: - pages

    private func overview(_ snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            statline(snapshot)
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
                activity: snapshot.activity,
                metrics: activityMetrics(for: snapshot))
            CompositionSection(
                modelShares30d: snapshot.modelShares30d,
                modelSharesPrior30d: snapshot.modelSharesPrior30d,
                providerShares30d: snapshot.providerShares30d
                    .filter { providerIsVisible($0.provider) },
                showProviderBreakdown: visibleProviderCount > 1)
        }
    }

    // MARK: - rolling-window statline

    private func statline(_ snapshot: DashboardSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                usageHeadline
                Spacer(minLength: 16)
                cacheHitRateSummary(snapshot)
            }
            VStack(alignment: .leading, spacing: 8) {
                usageHeadline
                cacheHitRateSummary(snapshot)
            }
        }
    }

    private var usageHeadline: some View {
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
        return Group {
            if hasData {
                Text(L10n.dashboardHeadlineStatline(
                    window: window,
                    usd: usdSum.formatted(.currency(code: "USD")),
                    tokens: tokensSum.formatted(
                        .number.notation(.compactName).locale(settings.tokenFormatLocale)),
                    sessions: sessionsSum))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(L10n.headlineApiEquivalentHelp)
            } else {
                Text(L10n.dashboardHeadlineStatlineEmpty(window: window))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func cacheHitRateSummary(_ snapshot: DashboardSnapshot) -> some View {
        let last7Days = CacheUsageSummary.combined(
            snapshot.dailyExtended.suffix(7).map(\.cacheUsage))
        let last30Days = CacheUsageSummary.combined(
            snapshot.dailyExtended.suffix(30).map(\.cacheUsage))

        return HStack(spacing: 8) {
            Circle()
                .fill(DashboardTheme.cache)
                .frame(width: 6, height: 6)
            Text(L10n.cacheHitRateTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Divider()
                .frame(height: 14)

            cacheHitRateValue(L10n.last7Days, summary: last7Days)

            Divider()
                .frame(height: 14)

            cacheHitRateValue(L10n.last30Days, summary: last30Days)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(DashboardTheme.cache.opacity(0.09))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DashboardTheme.cache.opacity(0.18), lineWidth: 0.6)
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private func cacheHitRateValue(
        _ period: String,
        summary: CacheUsageSummary
    ) -> some View {
        HStack(spacing: 5) {
            Text(period)
                .foregroundStyle(.secondary)
            Text(formatCacheHitRate(summary.hitRate))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.caption.monospacedDigit())
        .help(cacheHitRateHelp(summary))
    }

    private func formatCacheHitRate(_ rate: Double?) -> String {
        rate?.formatted(.percent.precision(.fractionLength(1))) ?? "—"
    }

    private func cacheHitRateHelp(_ summary: CacheUsageSummary) -> String {
        guard summary.eligibleInputTokens > 0 else {
            return L10n.cacheHitRateUnavailable
                + "\n" + L10n.cacheHitRateCalendarWindowHelp
        }
        return L10n.cacheHitRateTokenDetail(
            read: compactTokens(summary.readTokens),
            eligible: compactTokens(summary.eligibleInputTokens))
            + "\n" + L10n.cacheHitRateWeightedHelp
            + "\n" + L10n.cacheHitRateCalendarWindowHelp
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

    private func activityMetrics(for snapshot: DashboardSnapshot) -> [ActivitySection.Metric] {
        let activity = snapshot.activity
        let topModel = snapshot.modelShares30d.first?.displayName
            ?? snapshot.modelShares.first?.displayName
            ?? "—"
        return [
            ActivitySection.Metric(
                value: compactTokens(activity.lifetimeTokens),
                label: L10n.activityLifetimeTokens),
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
                label: L10n.activityPeakTokens),
            ActivitySection.Metric(
                value: topModel,
                label: L10n.dashboardMetricTopModel),
            ActivitySection.Metric(
                value: snapshot.overview.totalEvents.formatted(
                    .number.notation(.compactName).locale(settings.tokenFormatLocale)),
                label: L10n.dashboardMetricEvents)
        ]
    }

    private func compactTokens(_ tokens: Int64) -> String {
        tokens.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(settings.tokenFormatLocale))
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
