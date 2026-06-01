import SwiftUI

struct MainWindowView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @State private var tab: Tab = .dashboard
    /// Bumped by the toolbar Reload button. Folded into the inner view's
    /// `.id(...)` so any tab the user is looking at gets re-mounted, which
    /// in turn re-fires its `.task { refreshDashboard / reloadList }`.
    /// Without this the Reload button only refreshed the Dashboard tab —
    /// pressing it on History/Sessions did nothing.
    @State private var reloadToken: Int = 0

    enum Tab: Hashable { case dashboard, history, sessions }

    var body: some View {
        @Bindable var env = env

        Group {
            switch tab {
            case .dashboard: DashboardView()
            case .history:   HistoryView()
            case .sessions:  SessionsView()
            }
        }
        // Force inner views to reload state when:
        //   - providerFilter changes (Dashboard/History/Sessions filter chip),
        //   - Reload button is pressed (reloadToken bump).
        .id("\(env.providerFilter.rawValue)-\(reloadToken)")
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            // Provider filter — left side, compact menu. Filter cases
            // for disabled providers are hidden so the user can't pick
            // a view that would just be empty. `.all` always stays in
            // — even when only one provider is enabled it's a valid
            // (and identical) view, and keeping it keeps the picker's
            // shape stable across toggles.
            if visibleFilters.count > 1 {
                ToolbarItem(placement: .navigation) {
                    Picker("", selection: $env.providerFilter) {
                        ForEach(visibleFilters) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
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

            // Reload — right. Bumps `reloadToken` so the inner view's
            // `.id(...)` changes, which re-mounts whatever tab the user
            // is on and re-fires its `.task`:
            //   - Dashboard → refreshDashboard()
            //   - History / Sessions → their own reloadList()
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
