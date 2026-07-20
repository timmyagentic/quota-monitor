import SwiftUI

// Provider-block rendering helpers (Codex + Claude). Extracted from
// MenuBarContentView so the file's header is just top-level layout.

extension MenuBarContentView {

    /// Codex block: KPI header + plan badge + 5h / 7d / additional quota
    /// rows from the live rate-limit API. The block always renders even
    /// when there's no quota data (keeps the menu bar layout stable).
    @ViewBuilder
    func codexProviderBlock(stats: ProviderStats) -> some View {
        providerBlock(
            label: L10n.codex,
            accent: .blue,
            stats: stats,
            tail: AnyView(codexQuotaInner(stats: stats))
        )
    }

    @ViewBuilder
    func codexQuotaInner(stats: ProviderStats) -> some View {
        if let snapshot = env.latestRateLimits {
            // Compact quota rows nested inside the Codex block. Pre-Day-23
            // these lived in their own card with a separate "Codex CLI
            // quotas" header — folded into the provider block now.
            let activeAdditional = CodexAdditionalQuotaRows.visibleRows(
                for: snapshot.additional)

            VStack(alignment: .leading, spacing: 6) {
                if let primary = snapshot.primary {
                    QuotaRow(title: L10n.quotaCardTitle5h, window: primary, accent: .blue)
                }
                if let secondary = snapshot.secondary {
                    QuotaRow(title: L10n.quotaCardTitle7d, window: secondary, accent: .blue)
                }
                ForEach(activeAdditional, id: \.id) { row in
                    QuotaRow(title: row.title, window: row.window, accent: .blue)
                }
                if let resetCredits = env.latestCodexResetCredits {
                    CodexResetCreditsRow(snapshot: resetCredits)
                }
            }
        } else if let quota = env.dashboardSnapshot?.codexQuota,
                  quota.primary != nil || quota.secondary != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let primary = quota.primary {
                    QuotaRow(title: L10n.quotaCardTitle5h, window: primary, accent: .blue)
                }
                if let secondary = quota.secondary {
                    QuotaRow(title: L10n.quotaCardTitle7d, window: secondary, accent: .blue)
                }
                if let resetCredits = env.latestCodexResetCredits {
                    CodexResetCreditsRow(snapshot: resetCredits)
                }
            }
        } else if let resetCredits = env.latestCodexResetCredits {
            CodexResetCreditsRow(snapshot: resetCredits)
        } else if env.isRefreshingRateLimits {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if LocalQAEnvironment.isActive() {
            Text(L10n.codexLiveQuotaDisabledInQA)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            // No live data + not loading = either signed-out or first run.
            // Show a one-liner so the empty space isn't mysterious.
            Text(L10n.codexSignInPrompt)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Claude block: KPI header + (preferred) live OAuth `/usage` quota
    /// rows that mirror Codex, falling back to the measured 5h billing
    /// block + last-7d spend when no Claude Code credentials are
    /// available. The fallback path was the *only* path before Day-24,
    /// when we discovered Anthropic does expose a quota endpoint after
    /// all (`POST /api/oauth/usage`, used by the official `claude` CLI).
    @ViewBuilder
    func claudeProviderBlock(
        stats: ProviderStats, blocks: BillingBlocks.Snapshot
    ) -> some View {
        providerBlock(
            label: L10n.claude,
            accent: .orange,
            stats: stats,
            tail: AnyView(claudeQuotaInner(stats: stats, blocks: blocks))
        )
    }

    @ViewBuilder
    func claudeQuotaInner(
        stats: ProviderStats, blocks: BillingBlocks.Snapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            claudeRateLimitNotice()
            if let usage = env.latestClaudeUsage,
               usage.hasRenderableQuotaWindow {
                claudeOAuthInner(usage: usage)
                // A token revoked / de-scoped *after* a successful poll leaves
                // a stale snapshot up, so this branch (not the fallback) is what
                // renders. Surface the persistent auth hint next to the now-
                // stale numbers so the user knows to re-login. Transient 429 /
                // network blips are NOT shown here — they don't contradict the
                // displayed rows and would just be noise.
                if let err = env.lastClaudeUsageError,
                   env.lastClaudeUsageErrorIsAuthClass {
                    claudeErrorHintText(err)
                }
            } else {
                claudeFallbackInner(stats: stats, blocks: blocks)
            }
        }
    }

    /// Tiny inline banner shown above the quota rows while the Claude
    /// poller is sitting in a 429 cooldown. Tells the user *why* the
    /// Refresh button looks unresponsive (it silently no-ops during
    /// cooldown) and counts the remaining time down to the second
    /// so they can see it tick. Self-hides once the cooldown elapses.
    @ViewBuilder
    func claudeRateLimitNotice() -> some View {
        if let until = env.latestClaudeUsageCooldownUntil, until > Date() {
            // TimelineView ticks the body once per second so the
            // countdown ages in place. Once `until - context.date <= 0`
            // we render nothing, which makes the banner disappear
            // without needing the actor to broadcast a "cleared" event.
            // The poller does fire that event eventually, but this
            // keeps the UI honest in the interim (e.g. if the app was
            // sleeping during the cooldown's natural expiry).
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let remaining = until.timeIntervalSince(context.date)
                if remaining > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                        Text(L10n.claudeRateLimitedRetryIn(
                            cooldownDurationLabel(seconds: remaining),
                            lastUpdated: env.latestClaudeUsage.map {
                                claudeRateLimitLastUpdatedLabel($0.capturedAt)
                            }))
                            .font(.caption2)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Round-up duration label for cooldown countdowns. Cooldowns max
    /// out at 30 min so we only need second + minute granularity. We
    /// round seconds *up* so "0 s" never flashes before the banner
    /// hides — the user sees "1s", then the banner disappears.
    func cooldownDurationLabel(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s < 60 { return L10n.cooldownSeconds(s) }
        // Round up to whole minutes too so a 61-second remainder
        // doesn't render as "1 min" then suddenly "1 min" → "59s".
        let m = (s + 59) / 60
        return L10n.cooldownMinutes(m)
    }

    func claudeRateLimitLastUpdatedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Preferred path: render OAuth `/usage` like the Codex block — plan
    /// tier badge + 5h / 7d / per-model quota rows. Mirroring the Codex
    /// layout is the whole point of Day-23/24: one column, two providers,
    /// same shape.
    @ViewBuilder
    func claudeOAuthInner(usage: ClaudeUsageSnapshot) -> some View {
        let scopedRows = ClaudeScopedQuotaRows.visibleRows(for: usage)
        VStack(alignment: .leading, spacing: 6) {
            if let w = usage.fiveHour {
                QuotaRow(title: L10n.quotaCardTitle5h, window: w, accent: .orange)
            } else if let w = usage.staleFiveHour {
                QuotaRow(title: L10n.quotaCardTitle5h, window: w, accent: .orange)
            } else if usage.sevenDay != nil {
                // Anthropic's /api/oauth/usage drops `five_hour` entirely
                // after the window resets if the user hasn't prompted
                // Claude yet — not a zero value, the key is absent. If we
                // also lack a previous 5h sample, show a quiet placeholder
                // so the missing row doesn't read as a bug next to a healthy
                // 7d row.
                claude5hIdleRow()
            }
            if let w = usage.sevenDay {
                QuotaRow(title: L10n.quotaCardTitle7d, window: w, accent: .orange)
            }
            // Structured model-specific limits are useful even at 0%; their
            // presence tells the user the allowance exists. Legacy top-level
            // Opus/Sonnet rows retain their previous noise filter in the
            // shared selector.
            ForEach(scopedRows) { row in
                QuotaRow(
                    title: L10n.quotaCardTitle7dModel(row.displayName),
                    window: row.window,
                    accent: .orange)
            }
        }
    }

    /// Inactive-5h placeholder row. Title styled like a real QuotaRow title
    /// (so vertical rhythm stays consistent with the 7d row below) but
    /// rendered tertiary to signal "slot exists, no data". No progress bar,
    /// no percent, no pace label — there's nothing to show until the API
    /// starts including `five_hour` again.
    @ViewBuilder
    func claude5hIdleRow() -> some View {
        HStack(spacing: 6) {
            Text(L10n.quotaCardTitle5h)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(L10n.claude5hWindowIdle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Fallback when OAuth credentials are unavailable. Same shape as the
    /// pre-Day-24 layout (5h billing block + measured 7d spend), plus a
    /// caption explaining how to upgrade to live quotas.
    @ViewBuilder
    func claudeFallbackInner(
        stats: ProviderStats, blocks: BillingBlocks.Snapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let block = blocks.currentBlock {
                Claude5hRow(block: block,
                            burn: blocks.burnRate,
                            projection: blocks.projection)
            } else if stats.hasData {
                Text(L10n.no5hBlockActive)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if stats.hasData {
                HStack(spacing: 4) {
                    Text(L10n.last7Days)
                        .font(.caption2.weight(.medium))
                    Spacer()
                    Text(stats.last7dValueUSD.formatted(.currency(code: "USD")))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                    Text("· \(stats.last7dTokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.claudeStartTracking)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // This view only renders when there is no usable snapshot, so
            // any error here explains the empty block — show it unconditionally.
            if let err = env.lastClaudeUsageError {
                claudeErrorHintText(err)
            }
        }
    }

    /// One-liner re-login / error hint under the Claude block.
    @ViewBuilder
    func claudeErrorHintText(_ raw: String) -> some View {
        Text(claudeErrorHint(raw))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .help(raw)
    }

    /// Map the verbose `String(describing:)` form of `ClaudeUsageClient.FetchError`
    /// to a one-liner the user can act on.
    func claudeErrorHint(_ raw: String) -> String {
        if raw.contains("noCredentials") || raw.contains("No Claude Code credentials") {
            return L10n.errClaudeNoCreds
        }
        if raw.contains("insufficientScope") || raw.contains("user:profile") {
            return L10n.errClaudeMissingScope
        }
        if raw.contains("unauthorized") {
            return L10n.errClaudeUnauthorized
        }
        if raw.contains("rateLimited") || raw.contains("HTTP 429") || raw.contains("rate-limited") {
            return L10n.errClaudeRateLimited
        }
        return L10n.errClaudeUnavailable
    }

    /// Shared chrome for both provider blocks. `tail` is the provider-
    /// specific quota content rendered below the KPI header.
    func providerBlock(
        label: String, accent: Color, stats: ProviderStats, tail: AnyView
    ) -> some View {
        // Window picker is shared across both provider blocks so the user
        // sees a coherent "everything is the same period" header. Pulled
        // off SettingsStore here (not threaded through every call site)
        // because the only readers are these blocks + the Dashboard
        // statline — both already touch SettingsStore.
        let window = settings.menuBarHeadlineWindow
        let headlineUSD: Double
        let headlineTokens: Int64
        let headlineSessions: Int
        switch window {
        case .last7d:
            headlineUSD      = stats.last7dValueUSD
            headlineTokens   = stats.last7dTokens
            headlineSessions = stats.last7dSessionCount
        case .last30d:
            headlineUSD      = stats.last30dValueUSD
            headlineTokens   = stats.last30dTokens
            headlineSessions = stats.last30dSessionCount
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if stats.hasData {
                    Text(L10n.providerSessionCount(headlineSessions))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L10n.headlineApiEquivalentHelp)
                } else {
                    Text(L10n.noDataLower)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.headlineApiEquivalent(window))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(L10n.headlineApiEquivalentHelp)
                    // Headline: dollar figure + token count on the same
                    // line. Token count was relegated to a tiny right-
                    // corner chip pre-2026-05-06; merging here gives it
                    // the same visual weight as the dollar value, which
                    // matters because the API-equivalent USD is a
                    // *hypothetical* — actual subscription cost is fixed
                    // — while the token count is what you actually used.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(headlineUSD.formatted(.currency(code: "USD")))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(stats.hasData ? Color.primary : Color.secondary)
                            .help(L10n.headlineApiEquivalentHelp)
                        if stats.hasData {
                            Text(L10n.headlineTokensSuffix(
                                headlineTokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale))))
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(Color.primary)
                                .help(L10n.headlineApiEquivalentHelp)
                        }
                    }
                }
                Spacer()
            }
            tail
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.08))
        )
    }
}

struct CodexAdditionalQuotaRow: Equatable, Sendable {
    let id: String
    let title: String
    let window: RateLimitSnapshot.Window
}

enum CodexAdditionalQuotaRows {
    private static let activeUsageThreshold = 0.5

    static func visibleRows(
        for additional: [RateLimitSnapshot.Additional]
    ) -> [CodexAdditionalQuotaRow] {
        additional.flatMap { extra -> [CodexAdditionalQuotaRow] in
            guard hasActiveWindow(extra) else { return [] }

            var rows: [CodexAdditionalQuotaRow] = []
            if let primary = extra.primary {
                rows.append(row(
                    for: extra.limitName,
                    bucket: "primary",
                    label: L10n.quotaCardTitle5h,
                    window: primary))
            }
            if let secondary = extra.secondary {
                rows.append(row(
                    for: extra.limitName,
                    bucket: "secondary",
                    label: L10n.quotaCardTitle7d,
                    window: secondary))
            }
            return rows
        }
    }

    private static func hasActiveWindow(
        _ extra: RateLimitSnapshot.Additional
    ) -> Bool {
        isActive(extra.primary) || isActive(extra.secondary)
    }

    private static func isActive(_ window: RateLimitSnapshot.Window?) -> Bool {
        (window?.usedPercent ?? 0) > activeUsageThreshold
    }

    private static func row(
        for limitName: String,
        bucket: String,
        label: String,
        window: RateLimitSnapshot.Window
    ) -> CodexAdditionalQuotaRow {
        CodexAdditionalQuotaRow(
            id: "\(limitName)|\(bucket)",
            title: "\(limitName) \(label)",
            window: window)
    }
}
