import SwiftUI

/// Activity card for either locally indexed history or the complete activity
/// reported by the current Codex account. Both sources deliberately reuse the
/// same metric strip and heatmap so switching scope does not redesign or move
/// the rest of the Dashboard.
struct ActivitySection: View {
    struct Metric: Identifiable, Equatable {
        let value: String
        let label: String
        var accessibilityValue: String?
        var help: String?

        var id: String { label }
    }

    struct Content: Equatable {
        let metrics: [Metric]
        let daily: [DailyPoint]
        let hasDailySeries: Bool
        let hasData: Bool
        let summary: String
        let asOf: String?
        let heatmapScopeLabel: String
        let heatmapAccessibilityLabel: String
    }

    @Environment(SettingsStore.self) private var settings
    @Binding var scope: ActivityDataScope
    let indexed: Content
    let account: Content?
    let accountState: CodexAccountUsageState
    let allowsAccountScope: Bool

    private var effectiveScope: ActivityDataScope {
        allowsAccountScope ? scope : .indexed
    }

    private var selectedContent: Content? {
        effectiveScope == .account ? account : indexed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.activitySectionTitle)
                    .font(.headline)
                Spacer()
                if allowsAccountScope {
                    Picker(L10n.activityDataSourceLabel, selection: $scope) {
                        Text(L10n.activityScopeIndexed)
                            .tag(ActivityDataScope.indexed)
                        Text(L10n.activityScopeAccount)
                            .tag(ActivityDataScope.account)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L10n.activityDataSourceLabel)
                    .accessibilityHint(L10n.activityDataSourceHint)
                }
            }

            if allowsAccountScope {
                sourceSummary
            }

            if let selectedContent {
                content(selectedContent)
                    .id(effectiveScope)
            } else if effectiveScope == .account {
                accountPlaceholder
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 14)
    }

    // MARK: - source summary

    private var sourceSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sourceIndicator
                Text(sourceSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                accountRefreshIndicator
                Spacer(minLength: 12)
                if let asOf = selectedContent?.asOf {
                    Text(asOf)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    sourceIndicator
                    Text(sourceSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    accountRefreshIndicator
                }
                if let asOf = selectedContent?.asOf {
                    Text(asOf)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sourceAccessibilityLabel)
    }

    private var sourceIndicator: some View {
        Circle()
            .fill(DashboardTheme.accentBlue)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var accountRefreshIndicator: some View {
        if effectiveScope == .account && accountState.isRefreshing {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(L10n.activityRefreshingAccount)
        }
    }

    private var sourceSummaryText: String {
        guard effectiveScope == .account else { return indexed.summary }
        if accountState.isStale {
            return "\(L10n.activityShowingCachedData) · \(account?.summary ?? "")"
        }
        return account?.summary ?? placeholderMessage
    }

    private var sourceAccessibilityLabel: String {
        var parts = [sourceSummaryText, selectedContent?.asOf]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if effectiveScope == .account && accountState.isRefreshing {
            parts.append(L10n.activityRefreshingAccount)
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - content

    private func content(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            metricStrip(content.metrics)

            if !content.hasDailySeries {
                Text(L10n.activityAccountDailyUnavailable)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if content.hasData {
                chartCard(content)
            } else {
                Text(L10n.activityNoData)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var accountPlaceholder: some View {
        VStack(spacing: 8) {
            if case .loading = accountState {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.activityLoadingAccount)
            }
            Text(placeholderMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 176)
        .accessibilityElement(children: .combine)
    }

    private var placeholderMessage: String {
        switch accountState {
        case .idle, .loading:
            return L10n.activityLoadingAccount
        case .unavailable:
            return L10n.activityAccountUnavailable
        case .loaded, .refreshing, .stale:
            return L10n.activityAccountUnavailable
        }
    }

    // MARK: - stat strip

    private func metricStrip(_ metrics: [Metric]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                statCell(metric)

                if index < metrics.count - 1 {
                    cellDivider
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: 34)
    }

    private func statCell(_ metric: Metric) -> some View {
        VStack(spacing: 3) {
            Text(metric.value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(metric.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.label)
        .accessibilityValue(metric.accessibilityValue ?? metric.value)
        .modifier(StatCellHelp(metric.help))
    }

    // MARK: - chart

    private func chartCard(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.activityTokenActivity)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if allowsAccountScope {
                    Text(content.heatmapScopeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ActivityHeatmap(
                daily: content.daily,
                tokenLocale: settings.tokenFormatLocale)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(content.heatmapAccessibilityLabel)
        }
    }
}

/// Conditional `.help()` modifier — avoids passing an empty string
/// (which shows an empty tooltip) or force-unwrapping an Optional.
private struct StatCellHelp: ViewModifier {
    let text: String?
    init(_ text: String?) { self.text = text }
    @ViewBuilder func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
