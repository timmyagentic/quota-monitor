import AppKit
import SwiftUI

/// Owns the menu-bar status item and the launch-time discoverability
/// orchestration. Attached via `@NSApplicationDelegateAdaptor` in
/// `QuotaMonitorApp`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    /// Sparkle updater. Constructed in `applicationDidFinishLaunching`, NOT as a
    /// stored-property initializer: `@NSApplicationDelegateAdaptor` builds this
    /// delegate during `QuotaMonitorApp.init`'s prologue, *before* the init body
    /// runs `UserDefaultsMigration.runIfNeeded()`. `UpdaterController.init` reads
    /// UserDefaults via Sparkle, so it must run *after* the migration — which is
    /// guaranteed by the time `applicationDidFinishLaunching` fires.
    private var updater: UpdaterController!
    private var localQAController: LocalQAController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.shared
        let loc = LocalizationStore.shared
        let settings = SettingsStore.shared

        // Now that the migration has run (in QuotaMonitorApp.init), it's safe to
        // let Sparkle read UserDefaults. AppKit owns the four app windows (see
        // WindowManager); hand it the updater so Settings can wire "Check Now".
        updater = UpdaterController(
            onUpdateWindowClosed: {
                AppEnvironment.shared.demoteToAccessory()
            })
        WindowManager.shared.configure(updater: updater)

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

        // Close the inert placeholder `Window` SwiftUI auto-opens at launch.
        // Unconditional: on a fresh install (onboarding path) it must still be
        // closed, or the tiny `__inert__` window lingers under the onboarding
        // window for the whole wizard.
        closeStrayWindows()

        // Onboarding window on launch (previously MenuBarLabelView.task).
        let onboardingNeeded = loc.needsOnboarding || settings.needsProviderOnboarding
        Log.discover.info("launch onboardingNeeded=\(onboardingNeeded, privacy: .public)")
        if onboardingNeeded {
            WindowManager.shared.show("onboarding")
            // A brand-new user is mid-wizard; defer the discoverability
            // check until they finish (see notification observer below).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onboardingCompleted),
                name: .quotaMonitorOnboardingCompleted,
                object: nil)
        } else {
            // Pure menu-bar agent: windows open on demand only.
            scheduleDiscoverabilityCheck()
        }

        if let qa = LocalQAConfiguration() {
            let qaController = LocalQAController(
                configuration: qa,
                environment: env,
                statusItemController: controller)
            localQAController = qaController
            qaController.start()
        }
    }

    /// Close the inert SwiftUI placeholder `Window` that macOS auto-opens at
    /// launch. A SwiftUI `App` must declare at least one `Scene`; ours is a
    /// hidden `Window(id: "__inert__")` that exists only to satisfy that
    /// requirement (the four real windows are AppKit-owned via `WindowManager`).
    /// Runs on the next runloop tick because the scene's `NSWindow` may not
    /// exist yet inside `applicationDidFinishLaunching`.
    private func closeStrayWindows() {
        DispatchQueue.main.async {
            let ids: Set<String> = ["__inert__"]
            for win in NSApp.windows {
                guard let id = win.identifier?.rawValue, ids.contains(id) else { continue }
                Log.discover.info("closing stray auto-opened window id=\(id, privacy: .public)")
                win.close()
            }
        }
    }

    /// Dock-icon click (the Dock icon is our clipped-menu-bar fallback).
    /// AppKit's default reopen-with-no-windows would open the *first* SwiftUI
    /// scene — now the inert hidden `__inert__` placeholder, which is useless
    /// (and a fully-onboarded user must land on the dashboard, not the wizard).
    /// Open the right window ourselves via `WindowManager` and suppress the
    /// default.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }   // bring the existing window forward
        let needsOnboarding = LocalizationStore.shared.needsOnboarding
            || SettingsStore.shared.needsProviderOnboarding
        // `show` already does activate-then-order-front.
        WindowManager.shared.show(needsOnboarding ? "onboarding" : "dashboard")
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            WindowManager.shared.show("menubar-help")
        case .none:
            break
        }
        if action != .none {
            SettingsStore.shared.hasShownFirstRunPresentation = true
        }
    }

    /// Per-launch / on-screen-change enforcement of the Dock fallback,
    /// without the one-time presentation.
    private func enforceClipFallback(attempt: Int = 1) {
        guard let controller = statusItemController else { return }
        let visibility = controller.currentVisibility()
        switch MenuBarVisibilityEnforcement.decide(
            visibility: visibility, attempt: attempt) {
        case .retry:
            Log.discover.info("screen-change clipped on attempt \(attempt, privacy: .public); re-checking once")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.enforceClipFallback(attempt: attempt + 1)
            }
        case .applyUnreachable(let clipped):
            applyUnreachableState(clipped: clipped)
        }
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
        let policy = AppEnvironment.activationPolicyForMenuBarReachability(
            clipped: clipped,
            showDockIconForWindows: SettingsStore.shared.showDockIconForWindows,
            hasVisibleAppWindow: AppEnvironment.hasVisibleAppWindow())
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
