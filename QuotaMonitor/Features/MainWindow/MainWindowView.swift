import SwiftUI

struct MainWindowView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(UpdaterController.self) private var updater
    @State private var tab: Tab = .dashboard
    /// Bumped by the toolbar Reload button. Folded into the inner view's
    /// `.id(...)` so any tab the user is looking at gets re-mounted, which
    /// in turn re-fires its Dashboard, History, or Sessions initial task.
    /// Without this the Reload button only refreshed the Dashboard tab —
    /// pressing it on History/Sessions did nothing.
    @State private var reloadToken: Int = 0

    enum Tab: Hashable { case dashboard, history, sessions }

    var body: some View {
        @Bindable var env = env

        content
        // Force inner views to reload state when:
        //   - providerFilter changes (Dashboard/History/Sessions filter chip),
        //   - Reload button is pressed (reloadToken bump).
        .id("\(env.providerFilter.rawValue)-\(reloadToken)")
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            // Provider filter — titlebar leading side. Keep an explicit
            // label so AppKit gets a stable intrinsic width before the
            // titlebar lays out around the window title and traffic lights.
            if visibleFilters.count > 1 {
                ToolbarItem(placement: .navigation) {
                    providerToolbarFilter(selection: $env.providerFilter)
                }
            }

            // Inner section switch — center, segmented with icon + title.
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    Label(L10n.dashboardTitle, systemImage: "chart.bar.xaxis").tag(Tab.dashboard)
                    Label(L10n.historyTitle,   systemImage: "calendar").tag(Tab.history)
                    Label(L10n.sessionsTitle,  systemImage: "list.bullet.rectangle").tag(Tab.sessions)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
                .fixedSize()
            }

            if updater.updateAvailability.isVisible {
                ToolbarItem(placement: .primaryAction) {
                    PersistentUpdateBadge()
                }
            }

            // Reload — right. Bumps `reloadToken` so the inner view's
            // `.id(...)` changes, which re-mounts whatever tab the user
            // is on and re-fires its `.task`:
            //   - Dashboard → refreshDashboard()
            //   - History / Sessions → reset their pagination state
            // SwiftUI cancels the prior `.task` on id change, so spam-
            // clicking is safe; no explicit disabled gate needed.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reloadToken &+= 1
                } label: {
                    Label(L10n.reload, systemImage: "arrow.clockwise")
                }
                .help(L10n.reload)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    WindowCrossLinkActions.scene(
                        env: env,
                        openWindow: { WindowManager.shared.show($0) }
                    ).openSettingsFromDashboard()
                } label: {
                    Label(L10n.openSettings, systemImage: "gearshape")
                }
                .quickHoverHelp(L10n.openSettingsTooltip)
            }
        }
        // Demote-on-close is owned by `AppWindowController.windowWillClose`
        // now that this is an AppKit-hosted window.
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .dashboard: DashboardView()
        case .history:   HistoryView()
        case .sessions:  SessionsView()
        }
    }

    private func providerToolbarFilter(selection: Binding<ProviderFilter>) -> some View {
        Menu {
            ForEach(visibleFilters) { filter in
                Button {
                    selection.wrappedValue = filter
                } label: {
                    if selection.wrappedValue == filter {
                        Label(filter.label, systemImage: "checkmark")
                    } else {
                        Text(filter.label)
                    }
                }
            }
        } label: {
            Text(selection.wrappedValue.label)
        }
        .fixedSize()
        .accessibilityLabel(L10n.providerFilterLabel)
        .help(L10n.providerFilterHelp)
    }

    /// Filter cases the user is allowed to choose. Always includes
    /// `.all`; per-provider cases only appear when the matching
    /// provider is enabled in Settings.
    private var visibleFilters: [ProviderFilter] {
        let enabled = settings.enabledProviders
        return ProviderFilter.allCases.filter { f in
            f == .all || enabled.contains(f.rawValue)
        }
    }
}
