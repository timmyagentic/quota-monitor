import SwiftUI

/// The "an update is waiting" affordance shown after the user opens a
/// QuotaMonitor surface — the menu-bar popover, main window, or Settings.
///
/// One definition keeps the requested blue `Update` text, tooltip,
/// accessibility label, and install action in lockstep. Visibility is gated by
/// the caller (`UpdaterController.updateAvailability.isVisible`).
struct PersistentUpdateBadge: View {
    @Environment(UpdaterController.self) private var updater

    private var version: String? { updater.updateAvailability.version }

    var body: some View {
        Button(action: install) {
            Text(L10n.updateEntryTitle)
                .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.blue)
        .help(L10n.updateBadgeHelp(version))
        .accessibilityLabel(L10n.updateBadgeTitle(version))
    }

    private func install() {
        updater.installAvailableUpdate()
    }
}
