import AppKit
@preconcurrency import ApplicationServices

/// Offers permission guidance once per enabled session, independently of app windows.
@MainActor
final class CodexWidgetAccessibilityController {
    enum Choice { case openSettings, disableWidget }

    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let isTrusted: @MainActor () -> Bool
    private let presentGuide: (@MainActor (@escaping @MainActor (Choice) -> Void) -> Void)?
    private let requestPermission: @MainActor () -> Void
    private let openURL: @MainActor (URL) -> Void
    private let disableWidget: @MainActor () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var isEnabled = false
    private var canPrompt = false
    private var hasOfferedGuide = false
    private var isAwaitingAuthorization = false
    private var hasVisitedSystemSettings = false
    private var generation = 0
    private var guide: CodexWidgetAccessibilityGuide?

    init(
        disableWidget: @escaping @MainActor () -> Void,
        isTrusted: @escaping @MainActor () -> Bool = {
            LocalQAEnvironment.isQARequested() || AXIsProcessTrusted()
        },
        presentGuide: (@MainActor (@escaping @MainActor (Choice) -> Void) -> Void)? = nil,
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
            guide?.dismiss()
            guide = nil
            hasOfferedGuide = false
            isAwaitingAuthorization = false
            hasVisitedSystemSettings = false
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
            let completion: @MainActor (Choice) -> Void = { [weak self] choice in
                guard let self, self.generation == scheduledGeneration, self.isEnabled else { return }
                self.guide = nil
                self.handle(choice)
            }
            if let presentGuide = self.presentGuide {
                presentGuide(completion)
            } else {
                let guide = CodexWidgetAccessibilityGuide(onChoice: completion)
                self.guide = guide
                guide.show()
            }
        }
        return false
    }

    private func handle(_ choice: Choice) {
        switch choice {
        case .openSettings:
            openSettings()
        case .disableWidget:
            isEnabled = false
            isAwaitingAuthorization = false
            generation &+= 1
            disableWidget()
        }
    }

    func openSettings() {
        guard isEnabled else { return }
        guide?.dismiss()
        guide = nil
        // A manual retry also suppresses any queued automatic guide.
        hasOfferedGuide = true
        isAwaitingAuthorization = true
        hasVisitedSystemSettings = false
        generation &+= 1
        if !isTrusted() { requestPermission() }
        openURL(Self.settingsURL)
    }

    func returnedFromSystemSettings() {
        guard isAwaitingAuthorization, hasVisitedSystemSettings else { return }
        isAwaitingAuthorization = false
        hasVisitedSystemSettings = false
        hasOfferedGuide = false
    }

    func systemSettingsDidActivate() {
        if isAwaitingAuthorization { hasVisitedSystemSettings = true }
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

/// Displays the native alert without blocking the menu-bar app's main dispatch queue.
@MainActor
private final class CodexWidgetAccessibilityGuide: NSObject {
    private let alert = NSAlert()
    private let onChoice: @MainActor (CodexWidgetAccessibilityController.Choice) -> Void

    init(onChoice: @escaping @MainActor (CodexWidgetAccessibilityController.Choice) -> Void) {
        self.onChoice = onChoice
        super.init()
        alert.alertStyle = .informational
        alert.messageText = L10n.codexOverlayAccessibilityTitle
        alert.window.title = L10n.codexOverlayAccessibilityTitle
        alert.informativeText = L10n.codexOverlayAccessibilityGuide
        let openButton = alert.addButton(withTitle: L10n.codexOverlayAccessibilityOpenSettings)
        openButton.target = self
        openButton.action = #selector(openSettings)
        openButton.keyEquivalent = "\r"
        let disableButton = alert.addButton(withTitle: L10n.codexOverlayAccessibilityDisable)
        disableButton.target = self
        disableButton.action = #selector(disableWidget)
        disableButton.keyEquivalent = "\u{1b}"
    }

    func show() {
        alert.layout()
        alert.window.center()
        AppEnvironment.shared.activateForWindow()
        alert.window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        alert.window.orderOut(nil)
        AppEnvironment.shared.demoteToAccessory()
    }

    @objc private func openSettings() {
        dismiss()
        onChoice(.openSettings)
    }

    @objc private func disableWidget() {
        dismiss()
        onChoice(.disableWidget)
    }
}

extension Notification.Name {
    static let quotaMonitorOpenWidgetAccessibilitySettings = Notification.Name(
        "quotaMonitorOpenWidgetAccessibilitySettings")
}
