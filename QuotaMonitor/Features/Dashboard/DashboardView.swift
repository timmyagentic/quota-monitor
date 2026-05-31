import SwiftUI

/// Dashboard window — a slim composition of four semantic sections that
/// each answer one question:
///
/// 1. `ForecastSection` — am I about to blow a quota?
/// 2. `TrendsSection`   — is my usage trending up or down?
/// 3. `ActivitySection` — what does my usage profile look like?
/// 4. `CompositionSection` — where is the spend going?
///
/// All three read from `AppEnvironment.dashboardSnapshot` /
/// `billingBlocks` / `menuBarSnapshot`. The provider filter picker lives
/// in `MainWindowView` (not here) so it sits above the dashboard /
/// history / sessions tab switch. No `Divider()` between top-level
/// sections — each section owns its card-style background.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if env.menuBarUnreachable && !settings.firstRunHintDismissed {
                    hiddenIconHint
                }
                if let snapshot = env.dashboardSnapshot {
                    statline
                    ForecastSection(
                        snapshot: snapshot,
                        blocks: env.billingBlocks,
                        claudeUsage: env.latestClaudeUsage,
                        liveCodexRateLimits: env.latestRateLimits,
                        providerFilter: env.providerFilter,
                        enabledProviders: settings.enabledProviders)
                    TrendsSection(
                        dailyExtended: snapshot.dailyExtended)
                    ActivitySection(activity: snapshot.activity)
                    CompositionSection(
                        modelShares30d: snapshot.modelShares30d,
                        modelSharesPrior30d: snapshot.modelSharesPrior30d,
                        providerShares30d: snapshot.providerShares30d
                            .filter { settings.enabledProviders.contains($0.provider) },
                        showProviderDonut: settings.enabledProviders.count > 1)
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        // Make every label / number / model-name in the Dashboard
        // selectable so the user can copy a USD figure or a session id
        // out without screenshotting. Buttons / charts are unaffected
        // (`.textSelection` only modifies standalone Text views).
        .textSelection(.enabled)
        .task { env.refreshDashboard() }
    }

    // MARK: - rolling-window statline

    /// Single-line summary at the top of the Dashboard. Pulls from
    /// `MenuBarSnapshot` so the numbers match the menu bar verbatim. The
    /// rolling window (7d vs 30d) is shared with the menu bar so the
    /// user sees one consistent period across the whole app. When the
    /// user has filtered to one provider, we restrict the line to that
    /// provider's slice; otherwise we sum both.
    private var statline: some View {
        let codex = env.menuBarSnapshot?.codex
        let claude = env.menuBarSnapshot?.claude
        let window = settings.menuBarHeadlineWindow
        // Per-provider field selectors keep the switch on `window`
        // out of every arithmetic line below.
        func usd(_ s: ProviderStats?) -> Double {
            guard let s else { return 0 }
            return window == .last7d ? s.last7dValueUSD : s.last30dValueUSD
        }
        func tokens(_ s: ProviderStats?) -> Int64 {
            guard let s else { return 0 }
            return window == .last7d ? s.last7dTokens : s.last30dTokens
        }
        func sessions(_ s: ProviderStats?) -> Int {
            guard let s else { return 0 }
            return window == .last7d ? s.last7dSessionCount : s.last30dSessionCount
        }
        let usdSum: Double
        let tokensSum: Int64
        let sessionsSum: Int
        // The provider filter narrows first; the enabled set then
        // gates the `.all` arm so a disabled provider can't still leak
        // into the rolling sum (it can't anyway since the poller is
        // off, but we belt-and-brace the math because the snapshot
        // can outlive a freshly-disabled provider for a few seconds).
        let enabled = settings.enabledProviders
        switch env.providerFilter {
        case .all:
            let codexEnabled = enabled.contains("codex")
            let claudeEnabled = enabled.contains("claude")
            usdSum      = (codexEnabled ? usd(codex) : 0) + (claudeEnabled ? usd(claude) : 0)
            tokensSum   = (codexEnabled ? tokens(codex) : 0) + (claudeEnabled ? tokens(claude) : 0)
            sessionsSum = (codexEnabled ? sessions(codex) : 0) + (claudeEnabled ? sessions(claude) : 0)
        case .codex:
            usdSum      = usd(codex)
            tokensSum   = tokens(codex)
            sessionsSum = sessions(codex)
        case .claude:
            usdSum      = usd(claude)
            tokensSum   = tokens(claude)
            sessionsSum = sessions(claude)
        }
        let hasData = usdSum > 0 || tokensSum > 0 || sessionsSum > 0
        return HStack {
            if hasData {
                Text(L10n.dashboardHeadlineStatline(
                    window: window,
                    usd: usdSum.formatted(.currency(code: "USD")),
                    tokens: tokensSum.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)),
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

    // MARK: - hidden-icon hint

    /// Shown when the menu-bar status item was detected as clipped/hidden
    /// and we promoted to a permanent Dock icon. Dismissible; the choice
    /// persists via `settings.firstRunHintDismissed`.
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
                    env.activateForWindow()
                    openWindow(id: "menubar-help")
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.menuBarHiddenHintDismiss) {
                    settings.firstRunHintDismissed = true
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
    }
}
