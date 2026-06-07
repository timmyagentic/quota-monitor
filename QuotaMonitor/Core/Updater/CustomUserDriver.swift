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
    private lazy var windowController = UpdateWindowController(state: state)

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
        let s = self.state
        s.reset()

        s.newVersion = appcastItem.displayVersionString
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

        s.phase = .updateAvailable

        s.onInstall = { reply(.install) }
        s.onSkip    = { reply(.skip) }
        s.onDismiss = { reply(.dismiss) }

        windowController.show()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes are embedded in the appcast description, so
        // this method is typically not called.  If Sparkle does call
        // it (e.g. for a `releaseNotesURL` item), append the data.
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
        // We already have the embedded description — nothing to do.
    }

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
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
        state.phase = .extracting
        state.extractionProgress = 0
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state.extractionProgress = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state.phase = .readyToInstall
        state.onInstall = { reply(.install) }
        state.onDismiss = { reply(.dismiss) }
        state.onSkip    = { reply(.skip) }
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
        state.phase = .done
        acknowledgement()
        windowController.close()
    }

    func dismissUpdateInstallation() {
        state.reset()
        windowController.close()
    }

    // MARK: - Optional

    func showUpdateInFocus() {
        windowController.bringToFront()
    }
}
