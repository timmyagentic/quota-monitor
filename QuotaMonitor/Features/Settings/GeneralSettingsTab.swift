import SwiftUI

/// General preferences. Deliberately kept short — only the two knobs
/// regular users actually touch:
///   1. Language
///   2. Menu bar headline window (7d / 30d)
///
/// Path overrides, keychain policy, database location, CSV export, and
/// the Codex rate-limit poll interval all moved to `AdvancedSettingsTab`
/// so first-time users aren't intimidated.
struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        @Bindable var settings = settings
        Form {
            // Appearance — placed first because the Dock-icon toggle
            // is the only path back to Cmd+Tab visibility when a
            // user wants it. Default OFF (pure menu-bar agent).
            Section(L10n.sectionAppearance) {
                Toggle(L10n.showDockIconLabel, isOn: Binding(
                    get: { settings.showDockIconForWindows },
                    set: { newValue in
                        settings.showDockIconForWindows = newValue
                        env.applyDockIconPolicy()
                    }
                ))
                Text(L10n.showDockIconHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // English already renders B/M/K natively — there's
                // nothing to flip — so the picker is Chinese-only.
                // Keeping the row hidden in English mode avoids a
                // useless control that would surface a setting whose
                // both options produce identical output.
                if loc.currentLanguage == .simplifiedChinese {
                    LabeledContent(L10n.tokenUnitLanguageLabel) {
                        Picker("", selection: $settings.tokenUnitLanguage) {
                            Text(L10n.tokenUnitLanguageFollow)
                                .tag(SettingsStore.TokenUnitLanguage.followLanguage)
                            Text(L10n.tokenUnitLanguageEnglish)
                                .tag(SettingsStore.TokenUnitLanguage.english)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240, alignment: .trailing)
                    }
                    Text(L10n.tokenUnitLanguageHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Codex Fast-Mode billing. QuotaMonitor tags Codex rows from
            // rollout JSONL fast_mode / quick_mode markers when present;
            // this toggle is only the fallback for unclassified rows.
            if settings.enabledProviders.contains("codex") {
                Section(L10n.sectionCodexBilling) {
                    Toggle(L10n.codexFastModeBillingLabel,
                           isOn: $settings.codexFastModeBilling)
                        .onChange(of: settings.codexFastModeBilling) { _, _ in
                            env.applyCodexFastModeBilling()
                        }
                    Text(L10n.codexFastModeBillingHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.sectionLanguage) {
                LabeledContent(L10n.languagePickerLabel) {
                    Picker("", selection: Binding(
                        get: { loc.currentLanguage },
                        set: { loc.set($0) }
                    )) {
                        ForEach(LocalizationStore.Language.allCases) { lang in
                            Text(lang.nativeName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                Text(L10n.languagePickerHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Menu bar headline window — controls both the menu bar's
            // "API equivalent" $ on each provider block and the Dashboard
            // statline. Keep them in lock-step so the user never sees
            // two different "this is the period we mean" values in one
            // glance.
            Section(L10n.sectionMenuBar) {
                LabeledContent(L10n.menuBarHeadlineWindowLabel) {
                    Picker("", selection: $settings.menuBarHeadlineWindow) {
                        ForEach(HeadlineWindow.allCases) { w in
                            Text(L10n.headlineWindowLabel(w)).tag(w)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                Text(L10n.menuBarHeadlineWindowHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L10n.menuBarStyleLabel) {
                    Picker("", selection: $settings.menuBarLabelStyle) {
                        ForEach(SettingsStore.MenuBarLabelStyle.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                Text(L10n.menuBarStyleHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent(L10n.quotaDisplayModeLabel) {
                    Picker("", selection: $settings.quotaDisplayMode) {
                        Text(L10n.quotaDisplayModeUsed)
                            .tag(SettingsStore.QuotaDisplayMode.used)
                        Text(L10n.quotaDisplayModeRemaining)
                            .tag(SettingsStore.QuotaDisplayMode.remaining)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                Text(L10n.quotaDisplayModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Which provider(s) the menu-bar slot displays. Multi-
                // select: pick one, both (when both are tracked), or
                // neither — an empty set is a valid resting state and
                // falls back to the gauge SF Symbol. Only render a
                // toggle for each currently-tracked provider; a
                // disabled tool can't sensibly appear in the menu bar.
                LabeledContent(L10n.menuBarIconProviderLabel) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if settings.enabledProviders.contains("codex") {
                            iconProviderToggle(id: "codex", label: L10n.codex)
                        }
                        if settings.enabledProviders.contains("claude") {
                            iconProviderToggle(id: "claude", label: L10n.claudeCode)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                // Swap the help copy when only one provider is tracked —
                // the default text talks about "choose both" which is
                // nonsensical when there's nothing else to choose.
                Text(settings.enabledProviders.count > 1
                     ? L10n.menuBarIconProviderHelp
                     : L10n.menuBarIconProviderHelpSingle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Always-available entry to the recovery guide — not only
                // when the icon is clipped, so a user who dismissed the
                // auto-popped window can reopen it here.
                LabeledContent(L10n.menuBarHelpSettingsRow) {
                    Button(L10n.menuBarHelpSettingsOpen) {
                        WindowManager.shared.show("menubar-help")
                    }
                }
            }

            // Tracked tools — let users hide a CLI they don't have
            // installed. Toggling stops the matching background poller
            // (no more spurious 429s / "codex CLI not found" errors)
            // and removes the provider's cards from the menu bar +
            // dashboard. The "at least one" rule is enforced by
            // `SettingsStore.setProviderEnabled` returning false; the
            // toggle binding swallows that and stays visually ON.
            Section(L10n.sectionTrackedTools) {
                providerToggle(id: "codex", label: L10n.codex)
                providerToggle(id: "claude", label: L10n.claudeCode)
                Text(L10n.trackedToolsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.enabledProviders.count == 1 {
                    Text(L10n.trackedToolsKeepOne)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .padding(20)
    }

    @ViewBuilder
    private func providerToggle(id: String, label: String) -> some View {
        let isOn = settings.enabledProviders.contains(id)
        Toggle(label, isOn: Binding(
            get: { isOn },
            set: { wantOn in
                guard settings.setProviderEnabled(id, enabled: wantOn) else {
                    // Blocked by the "at least one" constraint. Don't
                    // mutate; the help text under the section explains
                    // why the click had no effect.
                    return
                }
                env.applyEnabledProviders()
            }
        ))
    }

    /// Toggle for the menu-bar-icon multi-select. Same shape as
    /// `providerToggle` but bound against `menuBarIconProviders`.
    /// Blocked changes (would empty the set) silently no-op so the
    /// toggle stays visually ON.
    @ViewBuilder
    private func iconProviderToggle(id: String, label: String) -> some View {
        let isOn = settings.menuBarIconProviders.contains(id)
        Toggle(label, isOn: Binding(
            get: { isOn },
            set: { wantOn in
                _ = settings.setMenuBarIconProviderEnabled(id, enabled: wantOn)
            }
        ))
        .toggleStyle(.checkbox)
    }
}
