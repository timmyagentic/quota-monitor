import SwiftUI

/// Activity card: the lifetime / engagement profile a CodeX-style usage
/// screen shows. A four-up stat strip (lifetime tokens, peak day, current
/// + longest streak) over a contribution-style daily heatmap.
///
/// Reads `DashboardSnapshot.activity`, which `loadDashboard` already scopes
/// to the active provider filter — so every number here follows the
/// All / Codex / Claude picker in the toolbar.
struct ActivitySection: View {
    @Environment(SettingsStore.self) private var settings
    let activity: ActivitySnapshot
    var showsStatStrip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.activitySectionTitle)
                    .font(.headline)
                Spacer()
            }

            if showsStatStrip {
                statStrip
            }

            if activity.hasData {
                chartCard
            } else {
                Text(L10n.activityNoData)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 14)
    }

    // MARK: - stat strip

    private var statStrip: some View {
        let locale = settings.tokenFormatLocale
        return HStack(spacing: 0) {
            statCell(
                value: compactTokens(activity.lifetimeTokens, locale: locale),
                label: L10n.activityLifetimeTokens)
            cellDivider
            statCell(
                value: compactTokens(activity.peakDayTokens, locale: locale),
                label: L10n.activityPeakTokens,
                help: activity.peakDay.map {
                    $0.formatted(.dateTime.year().month().day())
                })
            cellDivider
            statCell(
                value: L10n.activityStreakDays(activity.currentStreakDays),
                label: L10n.activityCurrentStreak)
            cellDivider
            statCell(
                value: L10n.activityStreakDays(activity.longestStreakDays),
                label: L10n.activityLongestStreak)
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

    private func statCell(value: String, label: String, help: String? = nil) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .modifier(StatCellHelp(help))
    }

    // MARK: - chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.activityTokenActivity)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            ActivityHeatmap(
                daily: activity.daily,
                tokenLocale: settings.tokenFormatLocale)
        }
    }

    // MARK: - formatting

    private func compactTokens(_ tokens: Int64, locale: Locale) -> String {
        guard tokens > 0 else { return "0" }
        return tokens.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(locale))
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
