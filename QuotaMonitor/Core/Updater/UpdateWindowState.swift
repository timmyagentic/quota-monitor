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

    enum UpdateAction: Equatable, Sendable {
        case install
        case skip
        case later
    }

    var phase: Phase = .idle

    var availableActions: [UpdateAction] {
        switch phase {
        case .updateAvailable:
            [.skip, .later, .install]
        case .readyToInstall:
            [.later, .install]
        default:
            []
        }
    }

    // MARK: - Update metadata

    /// The version string of the newly available update
    /// (`SUAppcastItem.displayVersionString`).
    var newVersion: String = ""

    /// The version of the currently running bundle.
    var currentVersion: String = ""

    /// `true` when `SUAppcastItem.criticalUpdate` is set.
    var isCritical: Bool = false

    /// Raw HTML from `SUAppcastItem.itemDescription`, already wrapped
    /// in a full document by `ReleaseNotesCSS.wrapHTML(…)`. Empty when the
    /// appcast item carried no description.
    var releaseNotesHTML: String = ""

    /// Whether this update actually shipped release notes. Tracked
    /// separately from `releaseNotesHTML` because the wrapped document is
    /// never empty (it always contains the CSS/JS shell) — so emptiness
    /// must be judged on the raw `<description>`, not the wrapped string.
    /// Drives the WebView-vs-fallback choice in `UpdateWindowView`.
    var hasReleaseNotes: Bool = false

    /// `true` while Sparkle is still downloading linked release notes
    /// (`sparkle:releaseNotesLink`). The appcast links notes instead of
    /// inlining them, so `showUpdateFound` fires before the notes arrive —
    /// this lets the window show a brief loading state instead of flashing
    /// the "no release notes" placeholder before the real notes land.
    /// Cleared when the download completes (or fails).
    var releaseNotesPending: Bool = false

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

    // MARK: - Firing replies (consume-once)

    /// Send the user's choice to Sparkle exactly once.
    ///
    /// Sparkle's `SPUUserUpdateChoice` reply must be called a single time per
    /// interaction. The action closure is captured, *all* reply closures are
    /// cleared, and only then is the captured closure invoked — so a later
    /// `handleWindowClose()` (e.g. the user closing the still-open window after
    /// the persistent badge already fired install) finds nil handlers and
    /// cannot send a second, conflicting reply.
    func fireInstall()     { consume(\.onInstall) }
    func fireSkip()        { consume(\.onSkip) }
    func fireDismiss()     { consume(\.onDismiss) }
    func fireCancel()      { consume(\.onCancel) }
    func fireAcknowledge() { consume(\.onAcknowledge) }

    private func consume(_ handler: KeyPath<UpdateWindowState, (() -> Void)?>) {
        let action = self[keyPath: handler]
        clearActionHandlers()
        action?()
    }

    /// Drop every reply closure so none can fire again.
    private func clearActionHandlers() {
        onInstall = nil
        onSkip = nil
        onDismiss = nil
        onCancel = nil
        onAcknowledge = nil
    }

    // MARK: - Helpers

    /// Translate a user-initiated window close (the title-bar close button)
    /// into the same reply the on-screen button for the current phase would
    /// send. Sparkle blocks waiting on the reply from `showUpdateFound` /
    /// `showReady(toInstallAndRelaunch:)` (and on the acknowledgement for
    /// error / up-to-date), so without this a plain window close leaves the
    /// updater stuck in an active interaction (e.g. "Check Now" stays
    /// disabled) until the app restarts.
    ///
    /// Closures are cleared afterwards so a subsequent programmatic `close()`
    /// can't fire a second, conflicting reply.
    func handleWindowClose() {
        switch phase {
        case .checking, .downloading, .extracting:
            fireCancel()
        case .updateAvailable, .readyToInstall:
            fireDismiss()
        case .error, .upToDate:
            fireAcknowledge()
        case .idle, .installing, .done:
            clearActionHandlers()   // no reply is owed to Sparkle in these phases
        }
    }

    /// Reset all mutable state back to defaults. Called before showing a
    /// new update and on `dismissUpdateInstallation`.
    func reset() {
        phase = .idle
        newVersion = ""
        currentVersion = ""
        isCritical = false
        releaseNotesHTML = ""
        hasReleaseNotes = false
        releaseNotesPending = false
        totalBytes = 0
        downloadedBytes = 0
        extractionProgress = 0
        clearActionHandlers()
    }
}
