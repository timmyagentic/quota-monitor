import SwiftUI

/// First-launch onboarding window. Up to three steps:
///   1. **Language** — pick the UI language. Self-readable: both buttons
///      display in the language they would activate.
///   2. **Tools** — pick which CLIs to track. Codex defaults on,
///      Claude Code defaults off (Claude triggers a one-time macOS
///      Keychain prompt and many users won't have it installed).
///   3. **Menu bar** — only when step 2 picked **both** CLIs: choose
///      which of them appears in the menu-bar readout. Single-provider
///      picks skip this step (the question is degenerate).
///
/// **Why a standalone Window scene, not a sheet on the popover.** The
/// menu-bar popover is 360pt wide and showing a sheet on top of it
/// looked cramped + cropped — the language buttons ran into the
/// popover's edges and the tool toggles wrapped awkwardly. A
/// dedicated centered window gives the layout room and matches the
/// usual "first launch wizard" affordance users expect.
///
/// **Hard requirement: cannot be dismissed without finishing both
/// steps.** No close button on the action area, and if the user hits
/// the red titlebar button we re-open the window from `onDisappear`
/// while the underlying `needs*` flags are still true. The window
/// gets cleanly closed once Continue runs and the flags clear.
///
/// **Existing-installation upgrade path.** `SettingsStore.init` sets
/// `hasCompletedProviderOnboarding = true` whenever any prior settings
/// key exists, so users who already had the app installed never see
/// the new step.
struct OnboardingView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Flips to `true` when step 2's Continue is clicked with **both**
    /// providers selected, transitioning the wizard to the menu-bar
    /// step. Session-scoped on purpose — closing and re-opening the
    /// window resets it to `false`, which is what we want (re-do step 2).
    @State private var providersCommitted = false

    private var step: Step {
        if loc.needsOnboarding { return .language }
        if !providersCommitted { return .providers }
        return .menuBar
    }

    var body: some View {
        Group {
            switch step {
            case .language: languageStep
            case .providers: providerStep
            case .menuBar:  menuBarStep
            }
        }
        .padding(20)
        .frame(width: 340)
        // Re-open the window if the user closes it before completing
        // both steps — `onDisappear` fires both on legitimate
        // completion (we dismissed it ourselves, in which case the
        // flags are clear and this no-ops) and on the user closing
        // the titlebar (in which case the flags are still set).
        .onDisappear {
            if loc.needsOnboarding || settings.needsProviderOnboarding {
                openWindow(id: "onboarding")
            }
        }
    }

    // MARK: - language step

    @ViewBuilder
    private var languageStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text("Welcome to Quota Monitor")
                    .font(.title3.weight(.semibold))
                Text("欢迎使用 Quota Monitor")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Pick your language. You can change it later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("请选择语言，稍后可在设置中更改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                Button {
                    loc.set(.english)
                } label: {
                    Label("Continue in English", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    loc.set(.simplifiedChinese)
                } label: {
                    Label("使用简体中文继续", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - provider step

    /// Local working copy of the picked set. We don't mutate
    /// `SettingsStore.enabledProviders` until the user clicks Continue
    /// — that way the live UI (menu bar + dashboard) doesn't flicker
    /// as they tick boxes.
    ///
    /// Defaults: Codex on, Claude Code off. Codex is the lower-friction
    /// default (no Keychain prompt, simpler setup); users who actually
    /// have Claude Code installed will tick its switch on this same
    /// screen, and users who don't will be spared the macOS Keychain
    /// password prompt that fires the first time we read Claude creds.
    @State private var pickedCodex = true
    @State private var pickedClaude = false

    @ViewBuilder
    private var providerStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text(L10n.onboardingProvidersHeadline)
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 12)

            Text(L10n.onboardingProvidersSubhead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                Toggle(isOn: $pickedCodex) {
                    Label("Codex", systemImage: "terminal")
                }
                .toggleStyle(.switch)
                Toggle(isOn: $pickedClaude) {
                    Label("Claude Code", systemImage: "sparkles")
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 8)

            // The Continue button stays disabled until at least one
            // toggle is on. The implicit "you can't track nothing"
            // constraint matches the runtime invariant in
            // SettingsStore.setProviderEnabled — keeping the rule in
            // one mental place.
            Button {
                var picked = Set<String>()
                if pickedCodex { picked.insert("codex") }
                if pickedClaude { picked.insert("claude") }
                finishOnboarding(providers: picked, iconProviders: picked)
            } label: {
                Text(L10n.onboardingContinue)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!pickedCodex && !pickedClaude)
            .padding(.horizontal, 8)
        }
    }

    /// Single commit path for the whole onboarding wizard. Called once
    /// per completion — either from step 2 (direct close, where
    /// `iconProviders == providers`) or from step 3 (the user picked
    /// both providers and chose the menu-bar subset explicitly).
    /// Writes are ordered so the reconcile inside
    /// `replaceEnabledProviders` can't fight the explicit menu-bar
    /// toggles: enable the providers first, then drive the icon set.
    private func finishOnboarding(providers: Set<String>,
                                  iconProviders: Set<String>) {
        settings.replaceEnabledProviders(providers)
        // Explicitly sync the menu-bar subset. Without this we'd inherit
        // the SettingsStore default (a copy of enabledProviders) and
        // over-show on a "user picked both but only wants Codex on the
        // menu bar" flow.
        for id in SettingsStore.knownIconProviders {
            _ = settings.setMenuBarIconProviderEnabled(
                id, enabled: iconProviders.contains(id))
        }
        settings.markProviderOnboardingDone()
        env.applyEnabledProviders()
        // Both `needs*` flags are now false, so closing here is the
        // legitimate path; the `onDisappear` re-opener sees the
        // cleared flags and stays silent.
        dismissWindow(id: "onboarding")
    }

    // MARK: - menu-bar step

    /// Local working copy for step 3 — only consumed by `finishOnboarding`
    /// on Continue. Defaults: Codex on, Claude off. The user can flip
    /// both off; an empty icon set is legal and means "show the gauge
    /// SF Symbol" (see SettingsStore.menuBarIconProviders docs).
    @State private var iconCodex = true
    @State private var iconClaude = false

    @ViewBuilder
    private var menuBarStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "menubar.dock.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text(L10n.menuBarIconProviderLabel)
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 12)

            Text(L10n.menuBarIconProviderHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                Toggle(isOn: $iconCodex) {
                    Label(L10n.codex, systemImage: "terminal")
                }
                .toggleStyle(.switch)
                Toggle(isOn: $iconClaude) {
                    Label(L10n.claudeCode, systemImage: "sparkles")
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 8)

            // Unlike step 2's Continue, this one is always enabled —
            // an empty icon set is a legal resting state (gauge-icon
            // fallback) per SettingsStore.menuBarIconProviders semantics.
            Button {
                var icons = Set<String>()
                if iconCodex { icons.insert("codex") }
                if iconClaude { icons.insert("claude") }
                finishOnboarding(providers: ["codex", "claude"],
                                 iconProviders: icons)
            } label: {
                Text(L10n.onboardingContinue)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 8)
        }
    }

    private enum Step { case language, providers, menuBar }
}
