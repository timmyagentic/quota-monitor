import Foundation
import AppKit
import Testing
@testable import QuotaMonitor

/// The onboarding window is a hard gate: its red-button close is allowed only
/// once onboarding is fully complete. `AppWindowController.windowShouldClose`
/// delegates that decision to this pure helper.
@MainActor
@Suite("Window onboarding close gate")
struct WindowOnboardingGateTests {

    @Test
    func blockedWhileLanguageOnboardingPending() {
        #expect(WindowManager.shouldAllowOnboardingClose(
            needsOnboarding: true, needsProvider: false) == false)
    }

    @Test
    func blockedWhileProviderOnboardingPending() {
        #expect(WindowManager.shouldAllowOnboardingClose(
            needsOnboarding: false, needsProvider: true) == false)
    }

    @Test
    func blockedWhileBothPending() {
        #expect(WindowManager.shouldAllowOnboardingClose(
            needsOnboarding: true, needsProvider: true) == false)
    }

    @Test
    func allowedOnceComplete() {
        #expect(WindowManager.shouldAllowOnboardingClose(
            needsOnboarding: false, needsProvider: false) == true)
    }

    @Test("AppKit windows reuse SwiftUI autosave frame names")
    func frameAutosaveNamesMatchPreviousSwiftUIWindowIDs() {
        #expect(WindowManager.frameAutosaveName(for: "dashboard") == "dashboard")
        #expect(WindowManager.frameAutosaveName(for: "settings") == "settings")
        #expect(WindowManager.frameAutosaveName(for: "whats-new") == "whats-new")
        #expect(WindowManager.frameAutosaveName(for: "menubar-help") == nil)
    }

    @Test("Miniaturized windows still count as app windows")
    func miniaturizedWindowsStillNeedDockPresence() {
        #expect(WindowManager.shouldCountManagedWindow(
            isVisible: false,
            isMiniaturized: true) == true)
        #expect(WindowManager.shouldCountManagedWindow(
            isVisible: true,
            isMiniaturized: false) == true)
        #expect(WindowManager.shouldCountManagedWindow(
            isVisible: false,
            isMiniaturized: false) == false)
    }

    @Test("Managed window close defers Dock policy reconciliation")
    func managedWindowCloseDefersDockPolicyReconciliation() async {
        var events = ["windowWillClose"]

        await withCheckedContinuation { continuation in
            WindowManager.shared.handleWillClose {
                events.append("reconcileDockPolicy")
                continuation.resume()
            }
            #expect(events == ["windowWillClose"])
        }

        #expect(events == ["windowWillClose", "reconcileDockPolicy"])
    }

    @Test("App window delegate forwards close lifecycle")
    func appWindowDelegateForwardsCloseLifecycle() {
        _ = NSApplication.shared
        var callbackCount = 0
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        let controller = AppWindowController(
            window: window,
            id: "dashboard",
            onWindowWillClose: { callbackCount += 1 })

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification))

        #expect(callbackCount == 1)
    }
}
