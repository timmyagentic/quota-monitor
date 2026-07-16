import AppKit
import Sparkle
import OSLog

/// Custom `SPUUserDriver` implementation that presents a SwiftUI-based
/// update window instead of Sparkle's standard system dialog.
///
/// **Thread safety.** Every `SPUUserDriver` method is called on the main
/// thread (documented by Sparkle).  The `@MainActor` annotation enforces
/// this at compile time.
///
/// **Architecture.** This class is a thin bridge: Sparkle calls protocol
/// methods here, and we translate each call into a mutation of
/// `UpdateWindowState` (an `@Observable` class that drives the SwiftUI
/// view).  Window lifecycle is managed by `UpdateWindowController`.
@MainActor
final class CustomUserDriver: NSObject, SPUUserDriver {

    private let state = UpdateWindowState()
    private let updateAvailability: PersistentUpdateAvailability
    private let onUpdateWindowClosed: @MainActor () -> Void
    private var installReplyIsActive = false
    private lazy var windowController = UpdateWindowController(
        state: state,
        onWindowClosed: onUpdateWindowClosed)

    init(
        updateAvailability: PersistentUpdateAvailability = PersistentUpdateAvailability(),
        onUpdateWindowClosed: @escaping @MainActor () -> Void = {}
    ) {
        self.updateAvailability = updateAvailability
        self.onUpdateWindowClosed = onUpdateWindowClosed
        super.init()
    }

    /// Whether the update window is currently on screen. Forwarded up to
    /// `UpdaterController` so `WindowManager` can count it as an app window.
    /// Touching `windowController` forces its lazy init, but the controller
    /// builds no `NSWindow` until `show()`, so this stays false (and cheap)
    /// until an update is actually presented.
    var isUpdateWindowVisible: Bool { windowController.isWindowVisible }

    func installAvailableUpdateIfPossible() -> Bool {
        guard installReplyIsActive, state.onInstall != nil else { return false }
        switch state.phase {
        case .updateAvailable, .readyToInstall:
            windowController.show()
            // `fireInstall()` consumes the sibling reply closures, so a window
            // close right after this can't fire a second `.dismiss` reply.
            state.fireInstall()
            return true
        default:
            return false
        }
    }

    private static let log = Logger(
        subsystem: Log.subsystem, category: "updater")

    // MARK: - Helpers

    /// Detects whether the app is currently in dark mode.
    private var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(
            from: [NSAppearance.Name.darkAqua, .aqua]) == .darkAqua
    }

    /// Current locale identifier for HTML lang attribute.
    private var localeID: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    // MARK: - SPUUserDriver — required methods

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // QuotaMonitor ships with SUEnableAutomaticChecks = true in
        // Info.plist, so this should rarely fire.  Auto-accept with
        // automatic checks on and no system profile.
        Self.log.info("Auto-accepting update permission request")
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(
        cancellation: @escaping () -> Void
    ) {
        state.reset()
        state.phase = .checking
        state.onCancel = cancellation
        windowController.show()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let presentation = updateAvailability.recordDiscovery(
            internalVersion: appcastItem.versionString,
            displayVersion: appcastItem.displayVersionString,
            userInitiated: state.userInitiated)
        if presentation == .dismissSilently {
            installReplyIsActive = false
            reply(.dismiss)
            return
        }

        let s = self.state
        s.reset()

        let displayVersion = appcastItem.displayVersionString
        installReplyIsActive = true

        s.newVersion = displayVersion
        s.currentVersion = Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"] as? String ?? "?"
        s.isCritical = appcastItem.isCriticalUpdate

        // Build the full HTML document for the WKWebView — but only when the
        // appcast item actually carried a description. An empty/missing
        // description shows a graceful fallback instead of a blank WebView.
        let rawHTML = appcastItem.itemDescription ?? ""
        s.hasReleaseNotes = ReleaseNotesCSS.hasContent(rawHTML)
        s.releaseNotesHTML = s.hasReleaseNotes
            ? ReleaseNotesCSS.wrapHTML(rawHTML, isDark: isDarkMode, locale: localeID)
            : ""
        // The appcast links notes (sparkle:releaseNotesLink) instead of
        // inlining them, so itemDescription is empty here and the notes
        // arrive later via showUpdateReleaseNotes(with:). Flag them pending
        // so the window shows a loading state rather than briefly flashing
        // the "no release notes" placeholder before the download lands.
        s.releaseNotesPending = !s.hasReleaseNotes
            && appcastItem.releaseNotesURL != nil

        s.phase = .updateAvailable

        s.onInstall = { [weak self] in
            self?.installReplyIsActive = false
            reply(.install)
        }
        s.onSkip    = { [weak self, updateAvailability] in
            self?.installReplyIsActive = false
            updateAvailability.markSkipped()
            reply(.skip)
        }
        s.onDismiss = { [weak self, updateAvailability] in
            self?.installReplyIsActive = false
            updateAvailability.markLater()
            reply(.dismiss)
        }

        windowController.show()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The appcast links release notes (sparkle:releaseNotesLink), so
        // Sparkle downloads them and delivers the data here after
        // showUpdateFound has already shown the window. Clear the pending
        // flag first so every exit path leaves the loading state: empty or
        // undecodable notes fall through to the "no release notes"
        // placeholder instead of spinning forever.
        state.releaseNotesPending = false
        guard let text = String(data: downloadData.data,
                                encoding: .utf8),
              ReleaseNotesCSS.hasContent(text) else { return }
        state.hasReleaseNotes = true
        state.releaseNotesHTML = ReleaseNotesCSS.wrapHTML(
            text, isDark: isDarkMode, locale: localeID)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(
        _ error: Error
    ) {
        Self.log.warning(
            "Release notes download failed: \(error.localizedDescription)")
        // Stop the loading state so the window falls back to the calm
        // "no release notes" placeholder instead of spinning forever.
        state.releaseNotesPending = false
    }

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        updateAvailability.clear()
        installReplyIsActive = false
        state.reset()
        state.phase = .upToDate
        state.onAcknowledge = acknowledgement
        windowController.show()

        // Auto-dismiss after 2 seconds.
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard self.state.phase == .upToDate else { return }
            self.state.onAcknowledge?()
            self.windowController.close()
        }
    }

    func showUpdaterError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        installReplyIsActive = false
        state.reset()
        state.phase = .error(error.localizedDescription)
        state.onAcknowledge = acknowledgement
        windowController.show()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        state.phase = .downloading
        state.totalBytes = 0
        state.downloadedBytes = 0
        state.onCancel = cancellation
    }

    func showDownloadDidReceiveExpectedContentLength(
        _ expectedContentLength: UInt64
    ) {
        state.totalBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        state.downloadedBytes += length
    }

    func showDownloadDidStartExtractingUpdate() {
        // Sparkle documents the download cancellation callback as valid only
        // until extraction begins. Drop it before entering the non-cancellable
        // phase so no later UI path can invoke an expired callback.
        state.onCancel = nil
        state.phase = .extracting
        state.extractionProgress = 0
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state.extractionProgress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateAvailability.markReadyToInstall(version: state.newVersion)
        installReplyIsActive = true
        state.phase = .readyToInstall
        state.onInstall = { [weak self] in
            self?.installReplyIsActive = false
            reply(.install)
        }
        state.onDismiss = { [weak self, updateAvailability] in
            self?.installReplyIsActive = false
            updateAvailability.markLater()
            reply(.dismiss)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        state.phase = .installing
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        updateAvailability.clear()
        installReplyIsActive = false
        state.phase = .done
        acknowledgement()
        windowController.close()
    }

    func dismissUpdateInstallation() {
        installReplyIsActive = false
        state.reset()
        windowController.close()
    }

    // MARK: - Optional

    func showUpdateInFocus() {
        windowController.bringToFront()
    }
}
