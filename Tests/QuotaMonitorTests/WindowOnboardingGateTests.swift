import Foundation
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
        #expect(WindowManager.frameAutosaveName(for: "menubar-help") == nil)
    }
}
