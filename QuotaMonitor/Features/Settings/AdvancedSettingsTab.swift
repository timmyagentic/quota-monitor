import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Power-user / debugging knobs. Anything that 95% of users never need
/// but 5% absolutely require lives here. Sections:
///
///   - Codex CLI: rate-limit poll interval
///   - Claude Code: credential refresh status + prompt-reduction toggle
///   - Database: location + reveal in Finder
///   - Export: usage_events.csv dump
///   - Pricing: LiteLLM sync + Restore Defaults + view catalog
///
/// Path resolution (codex binary, CODEX_HOME, Claude home) is the
/// app's problem to solve — we autoprobe env vars and well-known
/// install locations rather than asking the user to type a path.
struct AdvancedSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(UpdaterController.self) private var updater
    @State private var exportStatus: String?
    @State private var exporting = false
    @State private var pricingRows: [PricingCatalogRow] = []
    @State private var pricingLoaded = false
    @State private var refreshingPricing = false
    @State private var restoringPricing = false
    @State private var pricingStatusMessage: String?
    @State private var pricingErrorMessage: String?
    @State private var showingUninstallConfirm = false
    @State private var showingPricingSheet = false

    var body: some View {
        @Bindable var settings = settings
        // Hide a provider's whole section once it's untracked in
        // General → Tracked tools. The poller is already off for
        // disabled providers, so leaving keychain knobs visible would
        // just be dead controls — same logic that hides the
        // provider's card from the menu bar and Dashboard.
        let showCodex = settings.enabledProviders.contains("codex")
        let showClaude = settings.enabledProviders.contains("claude")
        Form {
            if DistributionChannel.current != .appStore {
                // Updates lives at the top: it's the single most useful
                // control for end users (vs. provider polling cadence
                // / database paths / pricing which are power-user knobs).
                Section(L10n.sectionUpdates) {
                    if updater.updateAvailability.isVisible {
                        HStack(spacing: 8) {
                            Label(L10n.updateBadgeTitle(updater.updateAvailability.version),
                                  systemImage: "arrow.down.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(updateActionTitle) {
                                updater.installAvailableUpdate()
                            }
                        }
                    }

                    // Automatic-check toggle. Two-way bound through the
                    // wrapper so flipping it both updates Sparkle's
                    // schedule and persists to UserDefaults under
                    // SUEnableAutomaticChecks. The KVO publisher then
                    // mirrors the new value back into `updater.auto…` so
                    // the toggle reflects external changes too (e.g. a
                    // user running `defaults write` manually).
                    Toggle(L10n.updatesAutoCheckLabel,
                           isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticallyChecks($0) }))
                    Text(L10n.updatesAutoCheckHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(L10n.updatesCheckNow) { updater.checkNow() }
                            .disabled(!updater.canCheckForUpdates)
                        Spacer()
                        LabeledContent(L10n.updatesLastCheckedLabel) {
                            Text(lastCheckedLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if showCodex {
            Section(L10n.sectionCodexCLI) {
                // Codex rate-limit poll cadence. Codex CLI IPC only;
                // Claude /usage is a separate timer hard-coded to 2 h.
                LabeledContent(L10n.interval) {
                    HStack(spacing: 8) {
                        Text(L10n.minutesShort(settings.pollIntervalSeconds / 60))
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                        Stepper("",
                                value: $settings.pollIntervalSeconds,
                                in: 60...3600, step: 60)
                            .labelsHidden()
                            .onChange(of: settings.pollIntervalSeconds) { _, _ in
                                env.applySettings()
                            }
                    }
                }
                Text(L10n.codexPollingHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }

            if showClaude {
            Section(L10n.sectionClaudeCode) {
                Text(L10n.claudeOAuthExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.keychainPolicy == .never {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.claudeCredentialFileOnlyWarning,
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.restoreAutomaticClaudeCredentialsMode) {
                            settings.keychainPolicy = .fallback
                        }
                    }
                }

                Toggle(L10n.mirrorClaudeCredsLabel,
                       isOn: $settings.mirrorClaudeKeychainToFile)
                Text(L10n.mirrorClaudeCredsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }

            Section(L10n.sectionDatabase) {
                LabeledContent(L10n.location) {
                    Text(DatabaseManager.defaultURL().path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button(L10n.revealInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([DatabaseManager.defaultURL()])
                }
            }

            Section(L10n.sectionExport) {
                Button(L10n.exportUsageEventsCsv) {
                    Task { await exportCSV() }
                }
                .disabled(exporting)
                if let exportStatus {
                    Text(exportStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L10n.settingsTabPricing) {
                Text(lastPricingRefreshedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.pricingFetchLiteLLM) {
                        Task { await refreshPricingFromLiteLLM() }
                    }
                    .disabled(restoringPricing || refreshingPricing)
                    if refreshingPricing { ProgressView().controlSize(.small) }
                    Button(L10n.pricingViewCatalog) {
                        showingPricingSheet = true
                    }
                    .disabled(pricingRows.isEmpty)
                    Spacer()
                    Button(L10n.pricingRestoreDefaults) {
                        Task { await restorePricingDefaults() }
                    }
                    .disabled(restoringPricing || refreshingPricing)
                }
                if let pricingStatusMessage {
                    Text(pricingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let pricingErrorMessage {
                    Text(pricingErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            // Developer Mode sits just above Uninstall — it's
            // diagnostic plumbing 95% of users never touch, so it
            // belongs adjacent to the other "rarely needed" section
            // rather than mixed in with the everyday settings.
            Section(L10n.sectionDeveloperMode) {
                Toggle(L10n.developerModeLabel,
                       isOn: $settings.developerModeEnabled)
                    .onChange(of: settings.developerModeEnabled) { _, enabled in
                        DeveloperLog.modeChanged(enabled: enabled)
                    }
                Text(L10n.developerModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(L10n.developerLogFileLabel) {
                    Text(DeveloperLog.logFileURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button(L10n.revealLogFile) {
                    revealDeveloperLog()
                }
            }

            // Destructive — kept at the very bottom and behind a
            // confirm alert. Replaces the (impossible-for-non-techies)
            // task of cleaning ~/Library/Application Support,
            // ~/Library/Preferences, etc. by hand after dragging the
            // .app to Trash. See UninstallController.swift for the
            // full list of paths.
            Section(L10n.sectionUninstall) {
                Button(role: .destructive) {
                    showingUninstallConfirm = true
                } label: {
                    Text(L10n.uninstallButton)
                        .foregroundStyle(.red)
                }
                Text(L10n.uninstallExplain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .sheet(isPresented: $showingPricingSheet) {
            PricingCatalogSheet(rows: pricingRows,
                                onDismiss: { showingPricingSheet = false })
        }
        .alert(L10n.uninstallConfirmTitle,
               isPresented: $showingUninstallConfirm) {
            Button(L10n.uninstallConfirmAction, role: .destructive) {
                env.performUninstall()
            }
            Button(L10n.cancel, role: .cancel) { }
        } message: {
            Text(L10n.uninstallConfirmBody)
        }
        .task {
            if !pricingLoaded {
                pricingLoaded = true
                await reloadPricing()
            }
        }
    }

    private func exportCSV() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "codex-events.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exporting = true
        defer { exporting = false }
        do {
            let count = try await env.exportUsageEventsCSV(to: url)
            exportStatus = L10n.exportedEventsTo(count, fileName: url.lastPathComponent)
        } catch {
            exportStatus = L10n.exportFailed(String(describing: error))
        }
    }

    private var lastPricingRefreshedLabel: String {
        let latest = pricingRows.compactMap { $0.fetchedAt }.max()
        guard let latest, let date = ISO8601.parse(latest) else {
            return L10n.neverRefreshed
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.unitsStyle = .short
        return L10n.lastRefreshed(formatter.localizedString(for: date, relativeTo: Date()))
    }

    private var updateActionTitle: String {
        updater.updateAvailability.primaryAction == .installAndRelaunch
            ? L10n.updateInstallAndRelaunch
            : L10n.updateInstallButton
    }

    private var lastCheckedLabel: String {
        guard let date = updater.lastUpdateCheckDate else {
            return L10n.updatesNeverChecked
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func reloadPricing() async {
        do {
            pricingRows = try await env.loadPricingCatalog()
        } catch {
            pricingErrorMessage = String(describing: error)
        }
    }

    private func restorePricingDefaults() async {
        restoringPricing = true
        defer { restoringPricing = false }
        do {
            try await env.restorePricingDefaults()
            await reloadPricing()
            pricingErrorMessage = nil
            pricingStatusMessage = L10n.restoredSeedPrices
        } catch {
            pricingErrorMessage = String(describing: error)
        }
    }

    private func refreshPricingFromLiteLLM() async {
        refreshingPricing = true
        defer { refreshingPricing = false }
        do {
            let updated = try await env.refreshPricingFromLiteLLM()
            await reloadPricing()
            pricingErrorMessage = nil
            pricingStatusMessage = updated == 0
                ? L10n.litellmNoMatch
                : L10n.litellmUpdated(updated)
        } catch {
            pricingErrorMessage = L10n.litellmRefreshFailed(error.localizedDescription)
        }
    }

    private func revealDeveloperLog() {
        let fileURL = DeveloperLog.logFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
