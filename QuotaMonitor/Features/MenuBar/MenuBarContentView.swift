import SwiftUI
import AppKit

// Top-level menu-bar popover. Only chrome + provider-block delegation here;
// the heavy view code lives in:
//   - ProviderBlock.swift   (codex / claude blocks + shared chrome)
//   - ScanStatusView.swift  (active scan progress)
//   - QuotaRow.swift / Claude5hRow.swift / CopyButton.swift (atoms)

struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(SettingsStore.self) var settings
    @Environment(UpdaterController.self) private var updater
    private let windowActions: @MainActor (AppEnvironment) -> MenuBarWindowActions

    init(windowActions: @escaping @MainActor (AppEnvironment) -> MenuBarWindowActions = MenuBarWindowActions.live) {
        self.windowActions = windowActions
    }

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
        .fixedSize(horizontal: false, vertical: true)
        // Allow click-and-drag to select any number / label in the popover.
        // Buttons stay clickable — `.textSelection` only affects standalone
        // Text views, not text inside Button labels. Lets the user copy
        // a USD figure or a token count without screenshotting.
        .textSelection(.enabled)
        // Refresh-on-open is now owned by `StatusItemController`'s
        // `popoverWillShow` delegate callback — the authoritative "popover
        // opened" hook now that we drive an AppKit `NSPopover` rather than
        // a SwiftUI `MenuBarExtra` (whose `.window` style re-mounted this
        // view on each open, which this `.onAppear` used to rely on). The
        // controller applies the same `refreshAll(throttle: true)` and the
        // same onboarding gate.
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
                // Button busy state is bound to `env.isScanning` — same
                // source of truth as `ScanStatusView`'s progress bar.
                // That way the button label and the progress bar appear
                // / disappear together: if there's a progress bar, the
                // button says "Refreshing…"; if the button says
                // "Refresh", there's no progress bar.
                //
                // We deliberately don't OR in `isRefreshingRateLimits`:
                // that call is sub-second and has its own ProgressView
                // inside the Codex provider block, so adding it here
                // would just cause the button to flicker briefly without
                // the user being able to see a corresponding scan
                // progress bar.
                Button(env.isScanning ? L10n.refreshing : L10n.refresh) {
                    env.refreshAll(throttle: false, trigger: "manual")
                }
                .disabled(env.isScanning)
                .keyboardShortcut("r")
                Spacer()
                Button(L10n.quit) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }

            Button {
                windowActions(env).openDashboard()
            } label: {
                Label(L10n.openDashboard, systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("d")

            // Settings is an AppKit `NSWindow` owned by `WindowManager`
            // (not a SwiftUI `Settings { }` scene), so we open it by id via
            // `WindowManager.show`, which also brings it forward over the
            // menu popover.
            Button {
                windowActions(env).openSettings()
            } label: {
                Label(L10n.settingsMenuItem, systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .keyboardShortcut(",")
        }
    }

    /// Placeholder content shown while `settings.needsProviderOnboarding`
    /// is true. The onboarding window is auto-opened by `AppDelegate`, and its
    /// red close button is blocked by `AppWindowController.windowShouldClose`
    /// until onboarding completes, so it can't be dismissed early. "Open setup"
    /// re-focuses the already-open onboarding window.
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
                windowActions(env).openOnboarding()
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
            Text(Branding.appDisplayName)
                .font(.headline)
            Spacer()
            if updater.updateAvailability.isVisible {
                PersistentUpdateBadge()
            }
            if env.isLoadingMenuBar {
                ProgressView().controlSize(.small)
            }
        }
    }
}
