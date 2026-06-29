import SwiftUI

/// The "an update is waiting" affordance shown on QuotaMonitor's primary
/// surfaces — the main-window toolbar and the menu-bar popover header.
///
/// One definition so the icon, orange tint, tooltip, accessibility label, and
/// install action stay in lockstep across surfaces. Visibility is gated by the
/// caller (`UpdaterController.updateAvailability.isVisible`); this view only
/// renders the button. Tapping it routes through
/// `UpdaterController.installAvailableUpdate()`.
struct PersistentUpdateBadge: View {
    enum Style {
        /// Window toolbar: an icon-only `Label` using the default toolbar button.
        case toolbar
        /// Inline header (menu popover): a hierarchical, borderless symbol.
        case menu
    }

    @Environment(UpdaterController.self) private var updater
    let style: Style

    private static let symbol = "arrow.down.circle.fill"
    private var version: String? { updater.updateAvailability.version }

    var body: some View {
        Group {
            switch style {
            case .toolbar:
                Button(action: install) {
                    Label(L10n.updateBadgeTitle(version), systemImage: Self.symbol)
                        .labelStyle(.iconOnly)
                }
            case .menu:
                Button(action: install) {
                    Image(systemName: Self.symbol)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
            }
        }
        .foregroundStyle(.orange)
        .help(L10n.updateBadgeHelp(version))
        .accessibilityLabel(L10n.updateBadgeTitle(version))
    }

    private func install() {
        updater.installAvailableUpdate()
    }
}
