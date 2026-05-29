import AppKit
import SwiftUI

/// Owns the menu-bar status item and the launch-time discoverability
/// orchestration. Attached via `@NSApplicationDelegateAdaptor` in
/// `QuotaMonitorApp`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.shared
        let loc = LocalizationStore.shared
        let settings = SettingsStore.shared

        let controller = StatusItemController(
            env: env, localization: loc, settings: settings)
        controller.onScreenChange = { [weak self] in
            self?.enforceClipFallback()
        }
        self.statusItemController = controller

        // The recovery guide's "Re-check" button asks us to re-evaluate.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recheckRequested),
            name: .quotaMonitorRecheckVisibility,
            object: nil)

        // Launch fan-out previously carried by the MenuBarExtra `.task`.
        env.refreshAll(throttle: false, trigger: "launch")
        env.refreshDashboard()
        env.refreshMenuBar(trigger: "launch")
        env.startBackgroundPolling()

        // Onboarding window on launch (previously MenuBarLabelView.task).
        let onboardingNeeded = loc.needsOnboarding || settings.needsProviderOnboarding
        Log.discover.info("launch onboardingNeeded=\(onboardingNeeded, privacy: .public)")
        if onboardingNeeded {
            WindowRouter.shared.request("onboarding")
            // A brand-new user is mid-wizard; defer the discoverability
            // check until they finish (see notification observer below).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onboardingCompleted),
                name: .quotaMonitorOnboardingCompleted,
                object: nil)
        } else {
            // This is a pure menu-bar agent: windows open on demand only.
            // After removing `MenuBarExtra` (which was the non-opening
            // primary scene), SwiftUI auto-opens the FIRST `Window` scene
            // at launch — close any such stray window so an existing user
            // doesn't get the onboarding/dashboard window every launch.
            closeStrayWindows()
            scheduleDiscoverabilityCheck()
        }
    }

    /// Close any SwiftUI `Window` scene that macOS auto-opened at launch.
    /// Runs on the next runloop tick because the scene's `NSWindow` may
    /// not exist yet inside `applicationDidFinishLaunching`.
    private func closeStrayWindows() {
        DispatchQueue.main.async {
            let ids: Set<String> = ["onboarding", "dashboard", "settings", "menubar-help"]
            for win in NSApp.windows {
                guard let id = win.identifier?.rawValue, ids.contains(id) else { continue }
                Log.discover.info("closing stray auto-opened window id=\(id, privacy: .public)")
                win.close()
            }
        }
    }

    /// Dock-icon click (the Dock icon is our clipped-menu-bar fallback).
    /// AppKit's default reopen-with-no-windows opens the *first* `Window`
    /// scene — which is onboarding — so a fully-onboarded user clicking the
    /// Dock icon would wrongly get the wizard. Open the right window
    /// ourselves and suppress the default.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }   // bring the existing window forward
        let needsOnboarding = LocalizationStore.shared.needsOnboarding
            || SettingsStore.shared.needsProviderOnboarding
        AppEnvironment.shared.activateForWindow()
        WindowRouter.shared.request(needsOnboarding ? "onboarding" : "dashboard")
        return false
    }

    @objc private func onboardingCompleted() {
        NotificationCenter.default.removeObserver(
            self, name: .quotaMonitorOnboardingCompleted, object: nil)
        scheduleDiscoverabilityCheck()
    }

    /// Give the status item a beat to lay out before we read its frame.
    private func scheduleDiscoverabilityCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.runDiscoverabilityCheck(attempt: 1)
        }
    }

    /// One-time first-run presentation + per-launch clip fallback.
    ///
    /// Guards against a *false* `.clipped` from a status item that simply
    /// hasn't finished laying out yet (its button window can be nil for a
    /// beat after launch): a first-pass `.clipped` triggers one re-check
    /// before we commit to the Dock fallback, so a normal launch doesn't
    /// spuriously sprout a Dock icon + Dashboard window.
    private func runDiscoverabilityCheck(attempt: Int) {
        guard let controller = statusItemController else { return }
        let visibility = controller.currentVisibility()

        if visibility == .clipped && attempt < 2 {
            Log.discover.info("clipped on attempt \(attempt, privacy: .public); re-checking once")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.runDiscoverabilityCheck(attempt: attempt + 1)
            }
            return
        }

        // Per-launch: clipped → permanent Dock icon + mark unreachable so
        // closing the last window can't drop the only visible entry.
        applyUnreachableState(clipped: visibility == .clipped)

        // One-time presentation.
        let action = MenuBarPresentation.decide(
            visibility: visibility,
            hasShownFirstRun: SettingsStore.shared.hasShownFirstRunPresentation)
        Log.discover.info(
            "discoverability visibility=\(String(describing: visibility), privacy: .public) action=\(String(describing: action), privacy: .public)")
        switch action {
        case .showPopover:
            controller.showPopover()
        case .openFallbackWindow:
            AppEnvironment.shared.activateForWindow()
            WindowRouter.shared.request("menubar-help")
        case .none:
            break
        }
        if action != .none {
            SettingsStore.shared.hasShownFirstRunPresentation = true
        }
    }

    /// Per-launch / on-screen-change enforcement of the Dock fallback,
    /// without the one-time presentation.
    private func enforceClipFallback() {
        guard let controller = statusItemController else { return }
        applyUnreachableState(clipped: controller.currentVisibility() == .clipped)
    }

    /// "Re-check" in the recovery guide: re-evaluate visibility (which
    /// updates `env.menuBarUnreachable` for the guide to reflect) and, if
    /// the icon is now visible, pop the popover to point the user at it.
    @objc private func recheckRequested() {
        guard let controller = statusItemController else { return }
        let visibility = controller.currentVisibility()
        applyUnreachableState(clipped: visibility == .clipped)
        if visibility == .visible {
            controller.showPopover()
        }
    }

    private func applyUnreachableState(clipped: Bool) {
        let env = AppEnvironment.shared
        env.menuBarUnreachable = clipped
        if clipped {
            NSApp.setActivationPolicy(.regular)
        }
        // When reachable we leave the activation policy to the existing
        // Dock-icon-for-windows logic; we never force `.accessory` here
        // (a window may legitimately be holding `.regular`).
    }
}
