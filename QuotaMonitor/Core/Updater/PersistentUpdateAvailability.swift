import Observation

/// Small observable state that outlives the Sparkle update window.
///
/// Sparkle asks the user driver for one immediate choice when an update is
/// found. If the user closes that window or chooses "Later", QuotaMonitor still
/// needs a durable in-app affordance so the available update does not disappear
/// from the main UI.
@MainActor
@Observable
final class PersistentUpdateAvailability {
    enum PrimaryAction: Equatable {
        case install
        case installAndRelaunch
    }

    private(set) var version: String?
    private(set) var primaryAction: PrimaryAction?

    var isVisible: Bool {
        version != nil || primaryAction != nil
    }

    func markAvailable(version: String) {
        self.version = version.isEmpty ? nil : version
        primaryAction = .install
    }

    func markReadyToInstall(version: String? = nil) {
        if let version, !version.isEmpty {
            self.version = version
        }
        primaryAction = .installAndRelaunch
    }

    func markDismissed() {
        // "Later" means the user has not updated. Keep the badge visible.
    }

    func clear() {
        version = nil
        primaryAction = nil
    }
}
