import AppKit
import Observation
import SwiftUI

@MainActor
final class CodexAttachedCapsuleController: NSObject {
    private let environment: AppEnvironment
    private let settings: SettingsStore
    private let locator: CodexWindowLocator
    private let workspaceNotificationCenter: NotificationCenter
    private let model: CodexAttachedCapsuleViewModel

    private var panel: CodexAttachedPanel!
    private var trackingTimer: Timer?
    private var isEnabled = false
    private var lastTargetFrame: CGRect?

    init(
        environment: AppEnvironment = .shared,
        settings: SettingsStore = .shared,
        locator: CodexWindowLocator = CodexWindowLocator(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.environment = environment
        self.settings = settings
        self.locator = locator
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.model = CodexAttachedCapsuleViewModel(
            presentation: CodexAttachedCapsulePresentation(snapshot: nil))
        super.init()
        panel = makePanel()
    }

    func start() {
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationChanged),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil)
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationChanged),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil)
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationChanged),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil)
        observeQuotaState()
    }

    func stop() {
        workspaceNotificationCenter.removeObserver(self)
        stopTracking()
        panel.orderOut(nil)
    }

    @objc private func workspaceApplicationChanged(_ notification: Notification) {
        syncLifecycle()
    }

    @objc private func trackingTick(_ timer: Timer) {
        guard isEnabled, locator.isCodexFrontmost else {
            syncLifecycle()
            return
        }
        updatePanel()
    }

    private func observeQuotaState() {
        withObservationTracking {
            let enabled = settings.codexAttachedCapsuleEnabled
                && settings.enabledProviders.contains("codex")
            let snapshot = environment.latestRateLimits
            isEnabled = enabled
            model.presentation = makePresentation(snapshot: snapshot)
            syncLifecycle()
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observeQuotaState()
            }
        }
    }

    private func syncLifecycle() {
        guard isEnabled, locator.isCodexFrontmost else {
            stopTracking()
            panel.orderOut(nil)
            lastTargetFrame = nil
            if model.isExpanded { setExpanded(false) }
            return
        }
        startTracking()
        updatePanel()
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(trackingTick),
            userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updatePanel() {
        guard let targetFrame = locator.frontmostWindowFrame() else {
            panel.orderOut(nil)
            lastTargetFrame = nil
            return
        }

        model.presentation = makePresentation(snapshot: environment.latestRateLimits)
        lastTargetFrame = targetFrame
        let size = model.isExpanded
            ? CodexAttachedCapsuleGeometry.expandedSize
            : CodexAttachedCapsuleGeometry.compactSize
        let frame = CodexAttachedCapsuleGeometry.panelFrame(
            targetWindow: targetFrame,
            panelSize: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.isExpanded != expanded else { return }
        model.isExpanded = expanded
        guard let targetFrame = lastTargetFrame else { return }
        let size = expanded
            ? CodexAttachedCapsuleGeometry.expandedSize
            : CodexAttachedCapsuleGeometry.compactSize
        panel.setFrame(
            CodexAttachedCapsuleGeometry.panelFrame(
                targetWindow: targetFrame,
                panelSize: size),
            display: true)
    }

    private func makePresentation(
        snapshot: RateLimitSnapshot?
    ) -> CodexAttachedCapsulePresentation {
        CodexAttachedCapsulePresentation(
            snapshot: snapshot,
            maximumFreshAge: max(
                CodexAttachedCapsulePresentation.maximumFreshAge,
                TimeInterval(settings.pollIntervalSeconds * 2)))
    }

    private func makePanel() -> CodexAttachedPanel {
        let panel = CodexAttachedPanel(
            contentRect: CGRect(origin: .zero, size: CodexAttachedCapsuleGeometry.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient
        ]
        panel.identifier = NSUserInterfaceItemIdentifier("codex-attached-capsule")

        let root = CodexAttachedCapsuleView(
            model: model,
            onHoverChange: { [weak self] expanded in
                self?.setExpanded(expanded)
            })
            .environment(LocalizationStore.shared)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        return panel
    }
}

private final class CodexAttachedPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
