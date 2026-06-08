import SwiftUI

extension Notification.Name {
    /// Posted by the recovery guide's "Re-check" button. `AppDelegate`
    /// observes it, re-runs the clip check (updating
    /// `AppEnvironment.menuBarUnreachable`), and pops the popover if the
    /// icon is now visible.
    static let quotaMonitorRecheckVisibility =
        Notification.Name("dev.tjzhou.QuotaMonitor.recheckVisibility")
}

/// Dedicated window shown when the menu-bar status item is clipped/hidden.
/// Teaches the user how to free up menu-bar space so the icon reappears —
/// a fully clipped item can't be dragged directly, so the actionable fix
/// is making room, after which macOS shows the item automatically.
struct MenuBarHelpView: View {
    @Environment(AppEnvironment.self) private var env

    /// Becomes true after the first "Re-check" so the status line only
    /// appears once the user has actually tried.
    @State private var didRecheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.menuBarHelpHeadline, systemImage: "menubar.rectangle")
                    .font(.title3.weight(.semibold))
                Text(L10n.menuBarHelpIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text(L10n.menuBarHelpStepsTitle).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                step("command", L10n.menuBarHelpStep1)
                step("xmark.circle", L10n.menuBarHelpStep2)
                step("slider.horizontal.3", L10n.menuBarHelpStep3)
                step("rectangle.topthird.inset.filled", L10n.menuBarHelpStep4)
            }

            if didRecheck {
                Text(env.menuBarUnreachable
                     ? L10n.menuBarHelpStillClipped
                     : L10n.menuBarHelpRecovered)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(env.menuBarUnreachable ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L10n.menuBarHelpDockFooter)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button(L10n.menuBarHelpRecheck) {
                    didRecheck = true
                    NotificationCenter.default.post(
                        name: .quotaMonitorRecheckVisibility, object: nil)
                }
                Spacer()
                Button(L10n.openDashboard) {
                    WindowManager.shared.show("dashboard")
                    env.refreshDashboard()
                }
                Button(L10n.menuBarHiddenHintDismiss) {
                    WindowManager.shared.close("menubar-help")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // Focus-on-open and demote-on-close are owned by `WindowManager` /
        // `AppWindowController` now that this is an AppKit-hosted window.
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
