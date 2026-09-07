import SwiftUI

struct CodexForecastQuotaSelection: Equatable {
    struct Window: Equatable {
        let usedPercent: Double
        let resetsAt: Date
    }

    let primary: Window?
    let secondary: Window?

    func selecting(bucket: String?, now: Date = Date()) -> Self {
        Self(primary: bucket == "primary" && (primary?.resetsAt ?? .distantPast) > now ? primary : nil,
             secondary: bucket == "secondary" && (secondary?.resetsAt ?? .distantPast) > now ? secondary : nil)
    }

    func paceBurn(
        burn: [String: CodexBurnRate], cycles: [QuotaCycle], now: Date = Date()
    ) -> CodexBurnRate? {
        for (bucket, window) in [("primary", primary), ("secondary", secondary)] {
            guard let window, let rate = burn[bucket] else { continue }
            let cycle = cycles.first {
                $0.id == "codex/" + bucket
                    && abs($0.observation.resetAt.timeIntervalSince(window.resetsAt)) < 0.01
            }
            guard abs(rate.percentPerMinute) > 0.0005,
                  cycle?.allowsPaceEstimate != false,
                  window.resetsAt > now else { return nil }
            return rate
        }
        return nil
    }

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

enum ForecastCycleSelection {
    static func availableBuckets(
        codex: CodexForecastQuotaSelection, claude: ClaudeUsageSnapshot?,
        blockResetAt: Date?, visibleProviders: Set<String>, now: Date = Date()
    ) -> [String] {
        var buckets: Set<String> = []
        if visibleProviders.contains("codex") {
            if let window = codex.primary, window.resetsAt > now { buckets.insert("primary") }
            if let window = codex.secondary, window.resetsAt > now { buckets.insert("secondary") }
        }
        if visibleProviders.contains("claude") {
            let fiveHourReset = claude == nil ? blockResetAt : claude?.fiveHourForDisplay?.resetAt
            if (fiveHourReset ?? .distantPast) > now {
                buckets.insert("primary")
            }
            if (claude?.sevenDay?.resetAt ?? .distantPast) > now
                || (claude.map { ClaudeScopedQuotaRows.visibleRows(for: $0) }
                    ?? []).contains(where: { $0.window.resetAt > now }) {
                buckets.insert("secondary")
            }
        }
        return ["primary", "secondary"].filter { buckets.contains($0) }
    }

    static func resolve(_ requested: String, available: [String]) -> String? {
        available.contains(requested) ? requested : available.first
    }
}

/// Forecast card: per-provider quota for the selected period with a
/// pace line. Answers "am I about to blow a quota?". Replaces the old
/// `codexQuotaSection` + `billingBlockSection` pair on the Dashboard.
/// Sample-source caption, "Active 5-hour block" header, four KPI tiles,
/// "started at HH:MM" line, recent-blocks history, and the verbose model
/// list are all gone — model list collapses into a tooltip on the Claude
/// card header.
struct ForecastSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LocalizationStore.self) private var localization
    @State private var cycleBucket = "primary"
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

    private var codexQuota: CodexForecastQuotaSelection {
        CodexForecastQuotaSelection.make(live: liveCodexRateLimits, stored: snapshot.codexQuota)
    }

    private var availableBuckets: [String] {
        ForecastCycleSelection.availableBuckets(codex: codexQuota, claude: claudeUsage,
            blockResetAt: blocks?.currentBlock?.endTime,
            visibleProviders: Set([(showCodex ? "codex" : nil), (showClaude ? "claude" : nil)].compactMap { $0 }))
    }

    private var selectedBucket: String? {
        ForecastCycleSelection.resolve(cycleBucket, available: availableBuckets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.forecastSectionTitle)
                    .font(.headline)
                Spacer()
                if availableBuckets.count > 1 {
                    Picker(L10n.cycleRangeLabel, selection: Binding(
                        get: { selectedBucket ?? "primary" }, set: { cycleBucket = $0 })) {
                        ForEach(availableBuckets, id: \.self) { bucket in
                            Text(bucket == "primary" ? L10n.cycleCurrent5h : L10n.cycleCurrent7d).tag(bucket)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                } else if let selectedBucket {
                    Text(selectedBucket == "primary" ? L10n.cycleCurrent5h : L10n.cycleCurrent7d)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
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
        .onChange(of: availableBuckets, initial: true) {
            if let selectedBucket { cycleBucket = selectedBucket }
        }
    }

    // MARK: - Codex card

    @ViewBuilder
    private var codexCard: some View {
        // Live poll = source of truth for the % bar (matches the menu
        // bar verbatim). DB snapshot is the fallback when the poller
        // hasn't landed a sample yet (cold launch before warm-start
        // hydrator, signed-out, etc.) and the source for burn.
        let dbQuota = snapshot.codexQuota
        let quota = codexQuota.selecting(bucket: selectedBucket)
        let hasPrimary = quota.primary != nil
        let hasSecondary = quota.secondary != nil
        let paceBurn = quota.paceBurn(
            burn: dbQuota?.burn ?? [:], cycles: env.quotaCycleUsages.map(\.cycle))
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
                        burn: dbQuota?.burn["primary"],
                        cycle: env.quotaCycle(provider: "codex", bucket: "primary", resetAt: primary.resetsAt),
                        windowDuration: 18_000)
                }
                if let secondary = quota.secondary {
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle7d,
                        usedPercent: secondary.usedPercent,
                        resetsAt: secondary.resetsAt,
                        burn: dbQuota?.burn["secondary"],
                        cycle: env.quotaCycle(provider: "codex", bucket: "secondary", resetAt: secondary.resetsAt),
                        windowDuration: 604_800)
                }
                // The pace uses the same selected window as the quota row.
                if let burn = paceBurn {
                    Text(L10n.forecastPaceCodex(percentPerHr: burn.percentPerMinute * 60))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                QuotaCycleMetricsView(usage: selectedCycleUsage(provider: "codex"))
            }
        }
    }

    // MARK: - Claude card

    @ViewBuilder
    private var claudeCard: some View {
        let now = Date()
        let block = selectedBucket == "primary" && claudeUsage == nil
            ? blocks?.currentBlock.flatMap { $0.endTime > now ? $0 : nil } : nil
        let modelTooltip = block?.models.joined(separator: " · ")
        let burn = selectedBucket == "primary" ? blocks?.burnRate : nil
        // Plan badges are intentionally hidden across providers — the raw
        // upstream values ("prolite", "max5x") confuse users more than they
        // help, and the plan rarely changes for a single account.
        let tier: String? = nil
        // Prefer the current `/usage` 5h window, then its preserved stale
        // predecessor when a weekly-only response omits `five_hour`. Fall
        // back to a local billing block only before any OAuth snapshot exists.
        let displayedFiveHour = selectedBucket == "primary"
            ? claudeUsage?.fiveHourForDisplay.flatMap { $0.resetAt > now ? $0 : nil } : nil
        let liveSevenDay = selectedBucket == "secondary"
            ? claudeUsage?.sevenDay.flatMap { $0.resetAt > now ? $0 : nil } : nil
        let scopedRows = selectedBucket == "secondary" ? claudeUsage.map {
            ClaudeScopedQuotaRows.visibleRows(for: $0).filter { $0.window.resetAt > now }
        } ?? [] : []
        let isFresh = displayedFiveHour != nil || liveSevenDay != nil || !scopedRows.isEmpty || block != nil

        ProviderForecastCard(
            label: L10n.claude,
            accent: DashboardTheme.providerColor("claude"),
            tier: tier,
            tooltip: modelTooltip,
            isEmpty: !isFresh,
            emptyText: L10n.forecastNoClaudeQuota
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let displayed = displayedFiveHour {
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle5h,
                        usedPercent: displayed.usedPercent,
                        resetsAt: displayed.resetAt,
                        burn: nil,
                        cycle: env.quotaCycle(provider: "claude", bucket: "primary", resetAt: displayed.resetAt),
                        windowDuration: displayed.windowDuration)
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
                        title: L10n.quotaCardTitle7dFull,
                        usedPercent: week.usedPercent,
                        resetsAt: week.resetAt,
                        burn: nil,
                        cycle: env.quotaCycle(provider: "claude", bucket: "secondary", resetAt: week.resetAt),
                        windowDuration: week.windowDuration)
                }
                ForEach(scopedRows) { row in
                    QuotaProgressRow(
                        title: L10n.quotaCardTitle7dModel(row.displayName),
                        usedPercent: row.window.usedPercent,
                        resetsAt: row.window.resetAt,
                        burn: nil,
                        windowDuration: row.window.windowDuration)
                }
                if let burn {
                    Text(L10n.forecastPaceClaude(
                        costPerHr: burn.costPerHour,
                        tokensPerMin: burn.tokensPerMinute))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                QuotaCycleMetricsView(usage: selectedCycleUsage(provider: "claude"))
            }
        }
    }

    private func selectedCycleUsage(provider: String) -> QuotaCycleUsage? {
        env.quotaCycleUsages.first {
            $0.cycle.observation.provider == provider && $0.cycle.observation.bucket == selectedBucket
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
    var cycle: QuotaCycle? = nil
    var windowDuration: TimeInterval? = nil

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
                if windowDuration != nil || cycle != nil {
                    QuotaCycleTimingView(cycle: cycle, resetAt: resetsAt, duration: windowDuration)
                }
                trailingLabel(now: now, remaining: remaining)
                    .font(.caption2.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func trailingLabel(now: Date, remaining: TimeInterval) -> some View {
        if remaining <= 0 {
            Text(L10n.quotaRowStaleLabel).foregroundStyle(.secondary)
        } else if let burn, cycle?.allowsPaceEstimate != false,
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
