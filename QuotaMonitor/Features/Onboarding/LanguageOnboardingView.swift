import SwiftUI

/// First-launch onboarding sheet. Two steps:
///   1. **Language** — pick the UI language. Self-readable: both buttons
///      display in the language they would activate.
///   2. **Tools** — pick which CLIs to track. Defaults to all known
///      providers ON; user can untick the ones they don't use.
///
/// **Why a sheet, not a full-screen dialog.** The menu bar popover is
/// only 360pt wide and `.sheet` works inside it. A full window would
/// fight `MenuBarExtra(.window)`'s auto-dismiss-on-outside-click.
///
/// **Hard requirement: cannot be dismissed without finishing both
/// steps.** No close button, no escape — `isPresented` is bound to
/// `needsOnboarding || needsProviderOnboarding`, so the sheet only
/// vanishes when both are satisfied.
///
/// **Existing-installation upgrade path.** `SettingsStore.init` sets
/// `hasCompletedProviderOnboarding = true` whenever any prior settings
/// key exists, so users who already had the app installed never see
/// the new step.
struct OnboardingView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env

    /// `language` while the user hasn't picked a language yet, then
    /// auto-advances to `providers` if there's a remaining step. The
    /// view's `body` re-derives the step on each render so existing
    /// users (already-set language, missing providers flag) jump
    /// straight to step 2.
    private var step: Step {
        loc.needsOnboarding ? .language : .providers
    }

    var body: some View {
        Group {
            switch step {
            case .language: languageStep
            case .providers: providerStep
            }
        }
        .padding(20)
        .frame(width: 340)
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
                settings.replaceEnabledProviders(picked)
                settings.markProviderOnboardingDone()
                env.applyEnabledProviders()
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

    private enum Step { case language, providers }
}
