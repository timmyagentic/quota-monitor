import AppKit
import SwiftUI

/// Owns the AppKit `NSStatusItem` that replaced the SwiftUI
/// `MenuBarExtra`. AppKit is required for two things `MenuBarExtra`
/// cannot do: open the popover programmatically (first-run auto-open)
/// and read the status item's on-screen geometry (clip detection).
///
/// The existing SwiftUI views are reused verbatim:
///   - menu-bar label  → `NSHostingView(HostedLabel)`
///   - popover content → `NSHostingController(HostedContent)`
///
/// The two `Hosted*` wrappers read `loc.tickForceRedraw` in their body so
/// a language switch re-renders the hosted tree (a bare `NSHostingView`
/// captures its rootView once and would otherwise miss the static-`L10n`
/// refresh that `.id(tickForceRedraw)` drives).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let env: AppEnvironment
    private let settings: SettingsStore

    /// Invoked when the display configuration changes (external monitor,
    /// resolution, notch) so the owner can re-run the clip check.
    var onScreenChange: (() -> Void)?

    init(env: AppEnvironment,
         localization: LocalizationStore,
         settings: SettingsStore) {
        self.env = env
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        statusItem.autosaveName = "QuotaMonitor"   // nudge placement only

        let host = NSHostingView(rootView: HostedLabel()
            .environment(env)
            .environment(localization)
            .environment(settings)
            .environment(\.locale, localization.locale))
        host.translatesAutoresizingMaskIntoConstraints = false
        if let button = statusItem.button {
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                host.topAnchor.constraint(equalTo: button.topAnchor),
                host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: HostedContent()
                .environment(env)
                .environment(localization)
                .environment(settings)
                .environment(\.locale, localization.locale))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// Open the popover anchored to the status button. Used both by the
    /// button click and by the first-run auto-open.
    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds,
                     of: button,
                     preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// `NSPopoverDelegate` — the authoritative "popover opened" hook now
    /// that we own the popover. Mirrors the old
    /// `MenuBarContentView.onAppear` refresh-on-open (which depended on
    /// `MenuBarExtra` re-mounting its content each open).
    func popoverWillShow(_ notification: Notification) {
        guard !settings.needsProviderOnboarding else { return }
        env.refreshAll(throttle: true, trigger: "popover")
    }

    // MARK: - visibility

    /// Live clip check. Wraps the pure `MenuBarVisibilityEvaluator` with
    /// the AppKit geometry: the status button's window frame and the
    /// frame of the screen hosting it (falling back to the main screen).
    func currentVisibility() -> StatusItemVisibility {
        guard statusItem.isVisible,
              let win = statusItem.button?.window else { return .clipped }
        let screenFrame = (win.screen ?? NSScreen.main)?.frame
        return MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: win.frame, hostScreenFrame: screenFrame)
    }

    @objc private func screenParamsChanged() { onScreenChange?() }
}

// MARK: - hosted SwiftUI wrappers

/// Wraps `MenuBarLabelView` so reading `loc.tickForceRedraw` in the body
/// re-renders the `NSHostingView` on a language switch.
private struct HostedLabel: View {
    @Environment(LocalizationStore.self) private var loc
    var body: some View {
        MenuBarLabelView().id(loc.tickForceRedraw)
    }
}

private struct HostedContent: View {
    @Environment(LocalizationStore.self) private var loc
    var body: some View {
        MenuBarContentView().id(loc.tickForceRedraw)
    }
}
