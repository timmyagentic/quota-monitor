import SwiftUI
import AppKit

// Top-level menu-bar popover. Only chrome + provider-block delegation here;
// the heavy view code lives in:
//   - ProviderBlock.swift   (codex / claude blocks + shared chrome)
//   - ScanStatusView.swift  (last-scan row + errors popover)
//   - QuotaRow.swift / Claude5hRow.swift / CopyButton.swift (atoms)

struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(SettingsStore.self) var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State var showingErrors = false

    var body: some View {
        Group {
            // Onboarding is a hard gate: until the user has finished
            // the wizard we replace the entire popover body with a
            // lock screen. Refreshes, scans, and Settings are all
            // disabled so a first-launch user can't accidentally fire
            // a Keychain prompt or a JSONL scan before opting in.
            // AppEnvironment.refresh*() / runScan() are independently
            // guarded on the same flag (defense in depth), but
            // swapping the UI is what stops the user from being
            // confused about why nothing reacts.
            if settings.needsProviderOnboarding {
                onboardingLock
            } else {
                normalContent
            }
        }
        .padding(14)
        .frame(width: 360)
        // Allow click-and-drag to select any number / label in the popover.
        // Buttons stay clickable — `.textSelection` only affects standalone
        // Text views, not text inside Button labels. Lets the user copy
        // a USD figure or a token count without screenshotting.
        .textSelection(.enabled)
        // Refresh whenever the popover comes back into the foreground so
        // the user always sees current stats without clicking Refresh.
        // The button's three actions are mirrored here, but each carries
        // a `minInterval` so popping the popover open three times in a
        // row doesn't trigger three back-to-back JSONL scans + three
        // app-server `/rateLimits/read` calls. The Refresh button itself
        // still goes through with no gate (nil minInterval) because the
        // user clicking it is explicit intent.
        //
        // refreshClaudeUsage / refreshMenuBar manage their own throttling
        // internally (60s spam gap on the Claude poller, isLoadingMenuBar
        // guard on the menu-bar reader) so they don't need an external
        // gate here.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Onboarding gate — skip the auto-refresh fan-out entirely
            // while the wizard is up. AppEnvironment's per-method
            // guards would catch this too, but bailing at the source
            // also avoids touching `SettingsStore.snapshot()` four
            // times for a no-op.
            guard !settings.needsProviderOnboarding else { return }
            env.refreshRateLimits(minInterval: 30)
            env.refreshClaudeUsage()
            env.runScan(minInterval: 20)
            env.refreshMenuBar()
        }
    }

    @ViewBuilder
    private var normalContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // Two grouped provider blocks. Each block owns its own KPI line
            // + quota rows so the user can scan one column from top to
            // bottom without bouncing between Codex / Claude data spread
            // across 5 separate cards (the prior layout). Section colors
            // (blue / orange) match the Dashboard provider filter chips.
            //
            // Disabled providers are omitted entirely — no card, no
            // placeholder. The Settings → General "Tracked tools"
            // section is the user's escape hatch if they want them
            // back. We only show the loading spinner while we have
            // *some* provider enabled but no snapshot yet.
            if let snap = env.menuBarSnapshot {
                if settings.enabledProviders.contains("codex") {
                    codexProviderBlock(stats: snap.codex)
                }
                if settings.enabledProviders.contains("claude") {
                    claudeProviderBlock(stats: snap.claude,
                                        blocks: snap.anthropicBlocks)
                }
            } else {
                ProgressView(L10n.loading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            Divider()

            scanStatus

            HStack {
                // Single "Refresh" button: rescan local JSONL files AND
                // pull live Codex rate limits AND ask the Claude poller
                // for a fresh `/usage` snapshot. Two buttons used to
                // confuse users (Refresh = "API + KPI", Scan = "files +
                // KPI") because the difference was an implementation
                // leak. Claude `/usage` is edge-rate-limited; the
                // poller's own 60 s spam gap + 429 cooldown decide
                // whether `refreshClaudeUsage()` actually goes through,
                // so spam-clicking can't earn a 429.
                //
                // Both `isScanning` (file rescan) and `isRefreshingRateLimits`
                // (Codex /rateLimits/read) feed the spinner + disabled state
                // because runScan() and refreshRateLimits() flip independent
                // flags but visually they are one operation to the user.
                let busy = env.isScanning || env.isRefreshingRateLimits
                Button(busy ? L10n.refreshing : L10n.refresh) {
                    env.refreshRateLimits()
                    env.refreshClaudeUsage()
                    env.runScan() // tail of runScan() also calls refreshMenuBar()
                }
                .disabled(busy)
                .keyboardShortcut("r")
                Spacer()
                Button(L10n.quit) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }

            Button {
                env.activateForWindow()
                openWindow(id: "dashboard")
                env.refreshDashboard()
            } label: {
                Label(L10n.openDashboard, systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("d")

            // macOS 14+ official entry point. The previous
            // `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`
            // hack silently no-op'd because the private selector was
            // retired in macOS 14, which is why this button "did
            // nothing" before. `openSettings` is the SwiftUI environment
            // action that replaces it. activateForWindow() runs first
            // so the Settings window comes forward over the menu popover.
            Button {
                env.activateForWindow()
                openSettings()
            } label: {
                Label(L10n.settingsMenuItem, systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .keyboardShortcut(",")
        }
    }

    /// Placeholder content shown while `settings.needsProviderOnboarding`
    /// is true. The onboarding Window is auto-opened by
    /// `MenuBarLabelView.task`, but it can be dismissed via the title
    /// bar close button — when that happens we still re-open it from
    /// `onDisappear`, but the user might land here in the brief gap.
    /// "Open setup" is the explicit escape hatch.
    @ViewBuilder
    private var onboardingLock: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.setupNotComplete)
                    .font(.headline)
                Text(L10n.setupNotCompleteBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            Button {
                env.activateForWindow()
                openWindow(id: "onboarding")
            } label: {
                Label(L10n.openSetup, systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Button(L10n.quit) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack {
            // Product name — intentionally not localized (see L10n proper-noun policy).
            Text("Quota Monitor")
                .font(.headline)
            Spacer()
            if env.isLoadingMenuBar {
                ProgressView().controlSize(.small)
            }
        }
    }
}
