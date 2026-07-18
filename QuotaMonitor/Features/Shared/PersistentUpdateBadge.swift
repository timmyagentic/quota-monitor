import SwiftUI

/// The "an update is waiting" affordance shown after the user opens a
/// QuotaMonitor surface — the menu-bar popover, main window, or Settings.
///
/// One definition keeps the compact blue download icon, tooltip,
/// accessibility label, and install action in lockstep. Visibility is gated by
/// the caller (`UpdaterController.updateAvailability.isVisible`).
struct PersistentUpdateBadge: View {
    @Environment(UpdaterController.self) private var updater

    private var version: String? { updater.updateAvailability.version }

    var body: some View {
        Button(action: install) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 10, weight: .medium))
                .symbolRenderingMode(.monochrome)
        }
        .buttonStyle(PersistentUpdateDownloadButtonStyle())
        .help(L10n.updateBadgeHelp(version))
        .accessibilityLabel(L10n.updateBadgeTitle(version))
    }

    private func install() {
        updater.installAvailableUpdate()
    }
}

private struct PersistentUpdateDownloadButtonStyle: ButtonStyle {
    private static let fill = Color(
        red: 51.0 / 255.0,
        green: 156.0 / 255.0,
        blue: 1.0)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Self.fill)
            .clipShape(Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.78 : 1.0)
    }
}
