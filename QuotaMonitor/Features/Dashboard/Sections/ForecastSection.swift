import SwiftUI

struct CodexForecastQuotaSelection: Equatable {
    struct Window: Equatable {
        let usedPercent: Double
        let resetsAt: Date
    }

    let primary: Window?
    let secondary: Window?

    static func make(
        live: RateLimitSnapshot?,
        stored: CodexQuotaSnapshot?
    ) -> Self {
        if let live {
            return Self(
                primary: live.primary.map {
                    Window(usedPercent: $0.usedPercent, resetsAt: $0.resetAt)
                },
                secondary: live.secondary.map {
                    Window(usedPercent: $0.usedPercent, resetsAt: $0.resetAt)
                })
        }
        return Self(
            primary: stored?.primary.map {
                Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
            },
            secondary: stored?.secondary.map {
                Window(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
            })
    }
}

/// Forecast card: per-provider quota block (Codex 5h+7d, Claude 5h) with a
/// pace line. Answers "am I about to blow a quota?". Replaces the old
/// `codexQuotaSection` + `billingBlockSection` pair on the Dashboard.
/// Sample-source caption, "Active 5-hour block" header, four KPI tiles,
/// "started at HH:MM" line, recent-blocks history, and the verbose model
/// list are all gone — model list collapses into a tooltip on the Claude
/// card header.
struct ForecastSection: View {
    let snapshot: DashboardSnapshot
    let blocks: BillingBlocks.Snapshot?
    let claudeUsage: ClaudeUsageSnapshot?
    /// Live Codex rate-limits pushed by the poller. Single source of
    /// truth for primary/secondary `usedPercent` so the Dashboard
    /// matches the menu-bar card in real time — the DB-derived
    /// `snapshot.codexQuota` lags one `refreshDashboard()` behind the
    /// poller, which is what used to cause "card says 14%, dashboard
    /// says 11%". We still read `burn` off the DB snapshot because
    /// it's a regression over sample history that the live payload
    /// doesn't carry.
    let liveCodexRateLimits: RateLimitSnapshot?
    let providerFilter: ProviderFilter
    /// Providers the user has enabled in Settings. We render a card
    /// only when both the toolbar filter allows it AND the user
    /// hasn't disabled it. Disabled = no card, no placeholder, no
    /// "data unavailable" — the user opted out, so silence is the
    /// honest answer.
    let enabledProviders: Set<String>

    private var showCodex: Bool {
        providerFilter != .claude && enabledProviders.contains("codex")
    }
    private var showClaude: Bool {
        providerFilter != .codex && enabledProviders.contains("claude")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.forecastSectionTitle)
                    .font(.headline)
                Spacer()
            }

            // Two cards side-by-side on wide windows; stack when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    if showCodex { codexCard }
                    if showClaude { claudeCard }
                }
                VStack(alignment: .leading, spacing: 14) {
                    if showCodex { codexCard }
                    if showClaude { claudeCard }
                }
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 14)
    }

    // MARK: - Codex card

    @ViewBuilder
    private var codexCard: some View {
        // Live poll = source of truth for the % bar (matches the menu
        // bar verbatim). DB snapshot is the fallback when the poller
        // hasn't landed a sample yet (cold launch before warm-start
        // hydrator, signed-out, etc.) and the source for burn.
        let dbQuota = snapshot.codexQuota
        let quota = CodexForecastQuotaSelection.make(
            live: liveCodexRateLimits,
            stored: dbQuota)
        let hasPrimary = quota.primary != nil
        let hasSecondary = quota.secondary != nil
        ProviderForecastCard(
            label: L10n.codex,
            accent: DashboardTheme.providerColor("codex"),
            tier: nil,
            tooltip: nil,
            isEmpty: !hasPrimary && !hasSecondary,
            emptyText: L10n.forecastNoCodexQuota
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let primary = quota.primary {
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle5h,
                        usedPercent: primary.usedPercent,
                        resetsAt: primary.resetsAt,
                        burn: dbQuota?.burn["primary"])
                }
                if let secondary = quota.secondary {
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle7d,
                        usedPercent: secondary.usedPercent,
                        resetsAt: secondary.resetsAt,
                        burn: dbQuota?.burn["secondary"])
                }
                // Pace line: prefer the 5h burn rate (more responsive); fall
                // back to the 7d slope when only that bucket has samples.
                if let burn = dbQuota?.burn["primary"] ?? dbQuota?.burn["secondary"],
                   abs(burn.percentPerMinute) > 0.0005 {
                    Text(L10n.forecastPaceCodex(percentPerHr: burn.percentPerMinute * 60))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Claude card

    @ViewBuilder
    private var claudeCard: some View {
        let block = blocks?.currentBlock
        let modelTooltip = block?.models.joined(separator: " · ")
        let burn = blocks?.burnRate
        // Plan badges are intentionally hidden across providers — the raw
        // upstream values ("prolite", "max5x") confuse users more than they
        // help, and the plan rarely changes for a single account.
        let tier: String? = nil
        // Prefer the live `/usage` 5h window (matches what Anthropic itself
        // shows). Fall back to the locally-derived billing block when the
        // OAuth poll hasn't landed yet — that's the only signal we have.
        let liveFiveHour = claudeUsage?.fiveHour
        let liveSevenDay = claudeUsage?.sevenDay
        let isFresh = liveFiveHour != nil || liveSevenDay != nil || block != nil

        ProviderForecastCard(
            label: L10n.claude,
            accent: DashboardTheme.providerColor("claude"),
            tier: tier,
            tooltip: modelTooltip,
            isEmpty: !isFresh,
            emptyText: L10n.forecastNoClaudeQuota
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let live = liveFiveHour {
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle5h,
                        usedPercent: live.usedPercent,
                        resetsAt: live.resetAt,
                        burn: nil)
                } else if let block {
                    let pct = blockProgress(block)
                    let resetsAt = block.endTime
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle5h,
                        usedPercent: pct * 100,
                        resetsAt: resetsAt,
                        burn: nil,
                        displayModeOverride: .used)
                }
                if let week = liveSevenDay {
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle7d,
                        usedPercent: week.usedPercent,
                        resetsAt: week.resetAt,
                        burn: nil)
                }
                if let burn {
                    Text(L10n.forecastPaceClaude(
                        costPerHr: burn.costPerHour,
                        tokensPerMin: burn.tokensPerMinute))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Mirror of MenuBarContentView's `Claude5hRow.pct` — fraction of the
    /// 5h window already elapsed for the active block (1 if inactive).
    private func blockProgress(_ block: BillingBlocks.Block) -> Double {
        let elapsed = max(0, Date().timeIntervalSince(block.startTime))
        let total = BillingBlocks.sessionDuration
        return block.isActive ? min(1, elapsed / total) : 1
    }
}

// MARK: - Card chrome

/// Card background + header used by both the Codex and Claude forecast
/// blocks. Owns the empty-state branch so the caller's `body` can stay
/// focused on the rows.
private struct ProviderForecastCard<Content: View>: View {
    let label: String
    let accent: Color
    let tier: String?
    let tooltip: String?
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: 10, height: 10)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                if let tier, !tier.isEmpty {
                    Text(tier)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .help(tooltip ?? "")

            if isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
    }
}

/// Quota progress row used by both providers in the Forecast card. Only
/// uses green / red for semantic meaning (healthy / warning); neutral text
/// stays `.secondary`. The countdown ticks once per minute via a
/// TimelineView so the displayed reset time stays fresh without forcing
/// the whole Dashboard to re-render.
struct QuotaProgressRow: View {
    @Environment(SettingsStore.self) private var settings

    let title: String
    let usedPercent: Double
    let resetsAt: Date
    /// Optional burn slope — when present and projected to bust the
    /// natural reset, the trailing label flips to red and reads
    /// "hits 100% in ~Xh".
    let burn: CodexBurnRate?
    /// Some fallback rows render elapsed-window progress rather than
    /// true quota usage. Keep those in the traditional increasing
    /// direction even when quota rows are set to "remaining".
    var displayModeOverride: SettingsStore.QuotaDisplayMode?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            let mode = displayModeOverride ?? settings.quotaDisplayMode
            let displayPercent = mode.displayPercent(forUsedPercent: usedPercent)
            let progressValue = mode.progressValue(forUsedPercent: usedPercent)
            let remaining = max(0, resetsAt.timeIntervalSince(now))
            let warn = usedPercent >= 80
            let bar: Color = warn ? .red : .green
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(String(format: "%.0f%%", displayPercent))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(warn ? .red : .primary)
                }
                ProgressView(value: progressValue)
                    .tint(bar)
                trailingLabel(now: now, remaining: remaining)
                    .font(.caption2.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func trailingLabel(now: Date, remaining: TimeInterval) -> some View {
        if let burn,
           let etaMinutes = burn.minutesUntilExhaustion(currentPercent: usedPercent),
           etaMinutes < remaining / 60 {
            Text(exhaustionLabel(formatRemaining(seconds: etaMinutes * 60)))
                .foregroundStyle(.red)
        } else {
            Text(L10n.forecastResetsIn(formatRemaining(seconds: remaining)))
                .foregroundStyle(.secondary)
        }
    }

    /// "1d 4h", "3h 12m", "47m" — same rule as the menu bar's countdown.
    private func formatRemaining(seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func exhaustionLabel(_ relative: String) -> String {
        let mode = displayModeOverride ?? settings.quotaDisplayMode
        switch mode {
        case .used:
            return L10n.forecastHits100In(relative)
        case .remaining:
            return L10n.forecastRunsOutIn(relative)
        }
    }
}
