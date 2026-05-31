import AppKit
import SwiftUI

/// Manages the lifecycle of the update window (an `NSWindow` hosting
/// `UpdateWindowView`).  QuotaMonitor is `LSUIElement = true`, so we
/// must call `NSApp.activate(ignoringOtherApps:)` to bring the window
/// to the front.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let state: UpdateWindowState

    init(state: UpdateWindowState) {
        self.state = state
        super.init()
    }

    // MARK: - Public

    /// Creates (if needed) and shows the update window, bringing it to
    /// front.
    func show() {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            newWindow.title = L10n.updateWindowTitle
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            newWindow.delegate = self
            newWindow.contentView = NSHostingView(
                rootView: UpdateWindowView(state: state))

            self.window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Brings an already-visible window to the front.
    func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes and releases the window.
    func close() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    /// The user clicked the title-bar close button. Map it to the
    /// phase-appropriate Sparkle reply before the window goes away so the
    /// updater isn't left blocked. `windowShouldClose(_:)` fires only on a
    /// user-driven close — programmatic `close()` does not call it — so a
    /// `dismissUpdateInstallation` → `close()` from Sparkle can't re-fire a
    /// reply here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state.handleWindowClose()
        return true
    }

    /// Drop our reference once the window actually closes (whether the user
    /// closed it or we did) so the next `show()` builds a fresh window.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
