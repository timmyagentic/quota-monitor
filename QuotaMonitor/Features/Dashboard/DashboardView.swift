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
            DashboardMetricStrip(metrics: metrics(for: snapshot))
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
            ActivitySection(activity: snapshot.activity, showsStatStrip: false)
            CompositionSection(
                modelShares30d: snapshot.modelShares30d,
                modelSharesPrior30d: snapshot.modelSharesPrior30d,
                providerShares30d: snapshot.providerShares30d
                    .filter { providerIsVisible($0.provider) },
                showProviderBreakdown: visibleProviderCount > 1)
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

    // MARK: - metric strip

    private func metrics(for snapshot: DashboardSnapshot) -> [DashboardMetric] {
        let activity = snapshot.activity
        let activeDays = activity.daily.filter { $0.tokens > 0 }.count
        let topModel = snapshot.modelShares30d.first?.displayName
            ?? snapshot.modelShares.first?.displayName
            ?? "—"
        return [
            DashboardMetric(
                value: compactTokens(activity.lifetimeTokens),
                label: L10n.activityLifetimeTokens),
            DashboardMetric(
                value: compactUSD(snapshot.overview.totalValueUSD),
                label: L10n.dashboardMetricTotalCost),
            DashboardMetric(
                value: activeDays.formatted(.number.locale(settings.tokenFormatLocale)),
                label: L10n.dashboardMetricActiveDays),
            DashboardMetric(
                value: L10n.activityStreakDays(activity.currentStreakDays),
                label: L10n.activityCurrentStreak),
            DashboardMetric(
                value: L10n.activityStreakDays(activity.longestStreakDays),
                label: L10n.activityLongestStreak),
            DashboardMetric(
                value: compactTokens(activity.peakDayTokens),
                label: L10n.activityPeakTokens),
            DashboardMetric(
                value: topModel,
                label: L10n.dashboardMetricTopModel),
            DashboardMetric(
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

private struct DashboardMetric: Identifiable {
    let value: String
    let label: String

    var id: String { label }
}

private struct DashboardMetricStrip: View {
    let metrics: [DashboardMetric]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.value)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(metric.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)

                if index < metrics.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 54)
                }
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 0)
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
