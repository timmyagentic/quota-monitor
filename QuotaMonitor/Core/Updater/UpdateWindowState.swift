import Foundation

/// Single source of truth for the custom Sparkle update window.
/// `CustomUserDriver` mutates this on the main thread; `UpdateWindowView`
/// observes it via SwiftUI's `@Observable` macro.
@MainActor
@Observable
final class UpdateWindowState {

    // MARK: - Phase

    /// The current stage of the update lifecycle. The SwiftUI view switches
    /// its layout on every transition.
    enum Phase: Equatable {
        case idle
        case checking                     // Indeterminate spinner
        case updateAvailable              // Release notes + action buttons
        case downloading                  // Determinate progress bar
        case extracting                   // Indeterminate or determinate
        case readyToInstall               // "Install & Relaunch" prominent
        case installing                   // Final progress
        case upToDate                     // Brief "you're up to date"
        case error(String)                // Error message
        case done                         // Window closes
    }

    var phase: Phase = .idle

    // MARK: - Update metadata

    /// The version string of the newly available update
    /// (`SUAppcastItem.displayVersionString`).
    var newVersion: String = ""

    /// The version of the currently running bundle.
    var currentVersion: String = ""

    /// `true` when `SUAppcastItem.criticalUpdate` is set.
    var isCritical: Bool = false

    /// Raw HTML from `SUAppcastItem.itemDescription`, already wrapped
    /// in a full document by `ReleaseNotesCSS.wrapHTML(…)`.
    var releaseNotesHTML: String = ""

    // MARK: - Download / extraction progress

    var totalBytes: UInt64 = 0
    var downloadedBytes: UInt64 = 0
    var extractionProgress: Double = 0

    /// 0.0 … 1.0 download progress (0 when total is unknown).
    var downloadProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    /// Human-readable downloaded / total, e.g. "3.2 MB / 8.1 MB".
    var downloadProgressLabel: String {
        guard totalBytes > 0 else { return "" }
        let d = ByteCountFormatter.string(fromByteCount: Int64(downloadedBytes),
                                          countStyle: .file)
        let t = ByteCountFormatter.string(fromByteCount: Int64(totalBytes),
                                          countStyle: .file)
        return "\(d) / \(t)"
    }

    // MARK: - Action closures

    /// Set by `CustomUserDriver`; called by the SwiftUI Install button.
    /// Replies `SPUUserUpdateChoiceInstall` to Sparkle.
    var onInstall: (() -> Void)?

    /// Replies `SPUUserUpdateChoiceSkip`.
    var onSkip: (() -> Void)?

    /// Replies `SPUUserUpdateChoiceDismiss`.
    var onDismiss: (() -> Void)?

    /// Cancels an in-flight check or download.
    var onCancel: (() -> Void)?

    /// Acknowledges an error / not-found state.
    var onAcknowledge: (() -> Void)?

    // MARK: - Helpers

    /// Reset all mutable state back to defaults. Called before showing a
    /// new update and on `dismissUpdateInstallation`.
    func reset() {
        phase = .idle
        newVersion = ""
        currentVersion = ""
        isCritical = false
        releaseNotesHTML = ""
        totalBytes = 0
        downloadedBytes = 0
        extractionProgress = 0
        onInstall = nil
        onSkip = nil
        onDismiss = nil
        onCancel = nil
        onAcknowledge = nil
    }
}
