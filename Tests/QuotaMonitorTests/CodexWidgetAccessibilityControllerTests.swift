import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex widget required Accessibility permission")
@MainActor
struct CodexWidgetAccessibilityControllerTests {
    @MainActor
    private final class Harness {
        var trusted = false
        var choice = CodexWidgetAccessibilityController.Choice.openSettings
        var prompts = 0
        var requests = 0
        var disabled = 0
        var openedURLs: [URL] = []
        var pending: [@MainActor () -> Void] = []
        lazy var controller = CodexWidgetAccessibilityController(
            disableWidget: { self.disabled += 1 },
            isTrusted: { self.trusted },
            presentGuide: { self.prompts += 1; return self.choice },
            requestPermission: { self.requests += 1 },
            openURL: { self.openedURLs.append($0) },
            schedule: { self.pending.append($0) })

        @discardableResult
        func refresh(enabled: Bool = true, canPrompt: Bool = true) -> Bool {
            controller.refresh(isEnabled: enabled, canPrompt: canPrompt)
        }

        func presentPendingGuide() {
            let actions = pending
            pending.removeAll()
            for action in actions { action() }
        }
    }

    @Test("An enabled widget offers a guide without opening Dashboard, and does not stack prompts")
    func missingPermissionPromptsOnce() {
        let h = Harness()
        #expect(!h.refresh())
        for _ in 0..<20 { h.refresh() }
        #expect(h.pending.count == 1)
        #expect(h.requests == 0)
        h.presentPendingGuide()
        #expect(h.prompts == 1)
        #expect(h.requests == 1)
        #expect(h.openedURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ])
        #expect(h.disabled == 0)
        h.refresh()
        #expect(h.pending.isEmpty)
    }

    @Test("Refusing permission disables the widget without requesting system access")
    func refusalDisablesWidget() {
        let h = Harness()
        h.choice = .disableWidget
        h.refresh()
        h.presentPendingGuide()
        #expect(h.disabled == 1)
        #expect(h.requests == 0)
        #expect(h.openedURLs.isEmpty)
        h.refresh(enabled: false)
        h.presentPendingGuide()
        #expect(h.prompts == 1)
        h.refresh()
        h.presentPendingGuide()
        #expect(h.prompts == 2)
    }

    @Test("Returning without granting access requires a choice again")
    func returningWithoutPermissionCannotSilentlyDefer() {
        let h = Harness()
        h.refresh()
        h.presentPendingGuide()
        h.controller.systemSettingsDidActivate()
        h.controller.returnedFromSystemSettings()
        #expect(!h.refresh())
        h.choice = .disableWidget
        h.presentPendingGuide()
        #expect(h.prompts == 2)
        #expect(h.disabled == 1)
    }

    @Test("Activating the guide itself cannot trigger a second prompt before Settings opens")
    func guideActivationDoesNotCountAsReturningFromSettings() {
        let h = Harness()
        h.refresh()
        h.presentPendingGuide()
        h.controller.returnedFromSystemSettings()
        h.refresh()
        h.presentPendingGuide()
        #expect(h.prompts == 1)
        #expect(h.openedURLs.count == 1)
    }

    @Test("Granting access resumes tracking; revoking it offers the required guide again")
    func grantingAndRevokingPermission() {
        let h = Harness()
        h.refresh()
        h.presentPendingGuide()
        h.trusted = true
        h.controller.returnedFromSystemSettings()
        #expect(h.refresh())
        h.presentPendingGuide()
        #expect(h.prompts == 1)
        h.trusted = false
        #expect(!h.refresh())
        h.presentPendingGuide()
        #expect(h.prompts == 2)
    }

    @Test("Disabled or already authorized widgets do not request permission")
    func noPromptWhenNotNeeded() {
        let h = Harness()
        h.refresh(enabled: false)
        h.trusted = true
        #expect(h.refresh())
        h.presentPendingGuide()
        #expect(h.prompts == 0)
        #expect(h.requests == 0)
    }

    @Test("The guide waits until onboarding is complete")
    func onboardingDeferral() {
        let h = Harness()
        h.refresh(canPrompt: false)
        #expect(h.pending.isEmpty)
        h.refresh()
        h.presentPendingGuide()
        #expect(h.prompts == 1)
    }

    @Test("Disabling the widget or granting permission cancels a queued guide")
    func queuedGuideRechecksEligibility() {
        let h = Harness()
        h.refresh()
        h.refresh(enabled: false)
        h.presentPendingGuide()
        #expect(h.prompts == 0)
        h.refresh()
        h.trusted = true
        h.presentPendingGuide()
        #expect(h.prompts == 0)
    }

    @Test("Manual Settings retry cancels the queued guide and opens the same permission page")
    func manualRetryDoesNotStackGuide() {
        let h = Harness()
        h.refresh()
        h.controller.openSettings()
        h.presentPendingGuide()
        #expect(h.prompts == 0)
        #expect(h.requests == 1)
        #expect(h.openedURLs == [CodexWidgetAccessibilityController.settingsURL])
    }
}
