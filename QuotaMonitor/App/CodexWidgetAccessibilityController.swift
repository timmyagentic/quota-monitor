import AppKit
@preconcurrency import ApplicationServices

/// Offers permission guidance once per enabled session, independently of app windows.
@MainActor
final class CodexWidgetAccessibilityController {
    enum Choice { case openSettings, disableWidget }

    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let isTrusted: @MainActor () -> Bool
    private let presentGuide: @MainActor () -> Choice
    private let requestPermission: @MainActor () -> Void
    private let openURL: @MainActor (URL) -> Void
    private let disableWidget: @MainActor () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var isEnabled = false
    private var canPrompt = false
    private var hasOfferedGuide = false
    private var isAwaitingAuthorization = false
    private var generation = 0

    init(
        disableWidget: @escaping @MainActor () -> Void,
        isTrusted: @escaping @MainActor () -> Bool = {
            LocalQAEnvironment.isQARequested() || AXIsProcessTrusted()
        },
        presentGuide: @escaping @MainActor () -> Choice = CodexWidgetAccessibilityController.showGuide,
        requestPermission: @escaping @MainActor () -> Void = CodexWidgetAccessibilityController.requestSystemPermission,
        openURL: @escaping @MainActor (URL) -> Void = CodexWidgetAccessibilityController.openSystemSettings,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        }
    ) {
        self.isTrusted = isTrusted
        self.disableWidget = disableWidget
        self.presentGuide = presentGuide
        self.requestPermission = requestPermission
        self.openURL = openURL
        self.schedule = schedule
    }

    /// Called by the overlay's existing lifecycle and tracking timer; owns no polling.
    @discardableResult
    func refresh(isEnabled: Bool, canPrompt: Bool) -> Bool {
        self.isEnabled = isEnabled
        self.canPrompt = canPrompt
        let trusted = isTrusted()
        guard isEnabled, !trusted else {
            hasOfferedGuide = false
            isAwaitingAuthorization = false
            generation &+= 1
            return trusted
        }
        guard canPrompt, !hasOfferedGuide else { return false }
        hasOfferedGuide = true
        generation &+= 1
        let scheduledGeneration = generation
        // Defer until launch/onboarding has finished creating its windows.
        schedule { [weak self] in
            guard let self,
                  self.generation == scheduledGeneration,
                  self.isEnabled, !self.isTrusted() else { return }
            guard self.canPrompt else {
                self.hasOfferedGuide = false
                return
            }
            switch self.presentGuide() {
            case .openSettings:
                self.openSettings()
            case .disableWidget:
                self.isEnabled = false
                self.isAwaitingAuthorization = false
                self.generation &+= 1
                self.disableWidget()
            }
        }
        return false
    }

    func openSettings() {
        guard isEnabled else { return }
        // A manual retry also suppresses any queued automatic guide.
        hasOfferedGuide = true
        isAwaitingAuthorization = true
        generation &+= 1
        if !isTrusted() { requestPermission() }
        openURL(Self.settingsURL)
    }

    func returnedFromSystemSettings() {
        guard isAwaitingAuthorization else { return }
        isAwaitingAuthorization = false
        hasOfferedGuide = false
    }

    private static func showGuide() -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.codexOverlayAccessibilityTitle
        alert.informativeText = L10n.codexOverlayAccessibilityGuide
        alert.addButton(withTitle: L10n.codexOverlayAccessibilityOpenSettings)
        alert.addButton(withTitle: L10n.codexOverlayAccessibilityDisable)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .openSettings : .disableWidget
    }

    private static func requestSystemPermission() {
        guard !LocalQAEnvironment.isQARequested() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private static func openSystemSettings(_ url: URL) {
        if LocalQAEnvironment.isQARequested() {
            DeveloperLog.eventRecord("qa.widget.accessibility-settings",
                category: "qa", trigger: "user", result: "simulated",
                fields: ["url": .string(url.absoluteString)])
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let quotaMonitorOpenWidgetAccessibilitySettings = Notification.Name(
        "quotaMonitorOpenWidgetAccessibilitySettings")
}
