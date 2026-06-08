import SwiftUI

/// Renders one quota window — used by both Codex (live API) and Claude
/// (OAuth `/usage`) so the two provider blocks read identically.
/// Inputs are deliberately primitives so we don't need protocol gymnastics
/// to share between two slightly-different snapshot types.
struct QuotaRow: View {
    @Environment(SettingsStore.self) private var settings

    let title: String
    let usedPercent: Double
    let resetAt: Date
    let paceLabel: QuotaPaceLabel.Result?
    /// Tint applied to the title chip and progress bar so the row reads as
    /// part of its parent provider block (blue for Codex, orange for
    /// Claude). Defaults to provider-neutral.
    var accent: Color = .accentColor

    /// Convenience constructor for Codex windows.
    init(title: String, window: RateLimitSnapshot.Window, accent: Color = .accentColor) {
        self.title = title
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetAt
        self.paceLabel = window.paceLabel()
        self.accent = accent
    }

    /// Convenience constructor for Claude OAuth windows.
    init(title: String, window: ClaudeUsageSnapshot.Window, accent: Color = .accentColor) {
        self.title = title
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetAt
        self.paceLabel = window.paceLabel()
        self.accent = accent
    }

    /// Convenience constructor for DB-hydrated Codex quota windows.
    init(title: String, window: CodexQuotaWindow, accent: Color = .accentColor) {
        self.title = title
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetsAt
        self.paceLabel = nil
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(displayPercent))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tintColor)
            }
            ProgressView(value: progressValue)
                .tint(tintColor)
            HStack(spacing: 4) {
                Text(L10n.resetsRelative(relativeReset))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if isStale {
                    // Window's resets_at is already in the past but the
                    // background poller hasn't picked up the new window
                    // yet (Claude is on a 2h cadence). Replace the pace
                    // label with an explicit "stale, waiting for refresh"
                    // chip so users don't read the old 100% as current.
                    // We keep the percent + bar visible (just grayed via
                    // .opacity below) so the layout doesn't jump.
                    Text(L10n.quotaRowStaleLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let pace = paceLabel {
                    Text(pace.text)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(paceColor(pace.severity))
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isStale ? 0.45 : 1)
        .help(isStale ? L10n.quotaRowStaleLabel : "")
    }

    /// `resetAt` already passed → the snapshot describes a window that
    /// no longer exists. Common for Claude (2h cadence) right after a
    /// 5h window rolls over.
    private var isStale: Bool {
        resetAt < Date()
    }

    private var tintColor: Color {
        switch usedPercent {
        case ..<60: .green
        case ..<85: .orange
        default: .red
        }
    }

    private var displayPercent: Double {
        settings.quotaDisplayMode.displayPercent(forUsedPercent: usedPercent)
    }

    private var progressValue: Double {
        settings.quotaDisplayMode.progressValue(forUsedPercent: usedPercent)
    }

    /// Locale-aware relative-time string for `resetAt` ("in 23 minutes" /
    /// "23 分钟后"). Computed at body-evaluation time, so it refreshes
    /// when the popover re-renders. Uses the `RelativeDateTimeFormatter`
    /// configured with `LocalizationStore.locale`, which is the SwiftUI
    /// environment locale we inject from `QuotaMonitorApp` — meaning a
    /// language flip in Settings instantly re-formats this string the
    /// next time the popover re-renders.
    private var relativeReset: String {
        let f = RelativeDateTimeFormatter()
        f.locale = LocalizationStore.activeLanguage.locale
        f.unitsStyle = .short
        return f.localizedString(for: resetAt, relativeTo: Date())
    }

    private func paceColor(_ s: QuotaPaceLabel.Severity) -> Color {
        switch s {
        case .neutral: .secondary
        case .good:    .green
        case .warning: .orange
        case .danger:  .red
        }
    }
}
