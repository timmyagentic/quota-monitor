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
    private var activity: PersistentUpdateAvailability.Activity {
        updater.updateAvailability.activity
    }

    var body: some View {
        Button(action: install) {
            if updater.updateAvailability.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10, weight: .medium))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .buttonStyle(PersistentUpdateDownloadButtonStyle())
        .help(statusText)
        .accessibilityLabel(statusText)
        .disabled(updater.updateAvailability.isBusy)
    }

    private func install() {
        updater.installAvailableUpdate()
    }

    private var statusText: String {
        switch activity {
        case .idle:
            L10n.updateBadgeHelp(version)
        case .checking:
            L10n.updateChecking
        case .downloading:
            L10n.updateDownloading
        case .extracting:
            L10n.updateExtracting
        case .installing:
            L10n.updateInstalling
        }
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
