import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class CodexQuotaOverlayController: NSObject {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex"
    ]
    private static let foregroundTrackingInterval: TimeInterval = 0.1
    private static let backgroundTrackingInterval: TimeInterval = 1
    private static let refreshRequestMinimumGap: TimeInterval = 60

    private let environment: AppEnvironment
    private let settings: SettingsStore
    private let workspace: NSWorkspace
    private var panel: CodexQuotaOverlayPanel?
    private var detailsPanel: CodexQuotaOverlayPanel?
    private var trackingTimer: Timer?
    private var trackingInterval: TimeInterval?
    private var lastRefreshRequestAt: Date?
    private var lastFrontmostPID: pid_t?
    private var lastCodexWindowFrame: CGRect?
    private var isSummaryHovered = false
    private var isDetailsHovered = false
    private var detailsCloseTask: Task<Void, Never>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var shouldShowDetailsForLocalQA = false
    private var isStarted = false

    init(
        environment: AppEnvironment,
        settings: SettingsStore,
        workspace: NSWorkspace = .shared
    ) {
        self.environment = environment
        self.settings = settings
        self.workspace = workspace
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let workspaceCenter = workspace.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification
        ] {
            workspaceCenter.addObserver(
                self,
                selector: #selector(workspaceStateDidChange),
                name: name,
                object: nil)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        refreshOverlay()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        trackingInterval = nil
        workspace.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        hideOverlay()
        panel = nil
        detailsPanel = nil
        setStatus(.disabled)
    }

    func showDetailsForLocalQA() {
        guard LocalQAEnvironment.isQARequested() else { return }
        shouldShowDetailsForLocalQA = true
        refreshOverlay()
        showDetails()
    }

    @objc private func workspaceStateDidChange(_ notification: Notification) {
        refreshOverlay()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        refreshOverlay()
    }

    @objc private func trackingTimerFired(_ timer: Timer) {
        refreshOverlay()
    }

    private func refreshOverlay(now: Date = Date()) {
        guard isStarted else { return }
        guard settings.shouldShowCodexSidebarQuota else {
            lastFrontmostPID = nil
            hideOverlay()
            setStatus(.disabled)
            updateTrackingInterval(Self.backgroundTrackingInterval)
            return
        }

        guard let frontmostApplication = workspace.frontmostApplication,
              let bundleIdentifier = frontmostApplication.bundleIdentifier,
              Self.supportedBundleIdentifiers.contains(bundleIdentifier),
              !frontmostApplication.isTerminated else {
            lastFrontmostPID = nil
            hideOverlay()
            setStatus(.waitingForCodex)
            updateTrackingInterval(Self.backgroundTrackingInterval)
            return
        }

        let processIdentifier = frontmostApplication.processIdentifier
        let becameFrontmost = lastFrontmostPID != processIdentifier
        lastFrontmostPID = processIdentifier
        requestQuotaRefreshIfNeeded(becameFrontmost: becameFrontmost, now: now)

        guard let window = Self.frontWindow(for: processIdentifier),
              let appKitWindowFrame = CodexWindowFrameConverter.appKitFrame(
                for: window.bounds,
                displays: Self.displayGeometries()) else {
            hideOverlay()
            setStatus(.waitingForCodex)
            updateTrackingInterval(Self.foregroundTrackingInterval)
            return
        }

        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now)
        showOverlay(
            in: appKitWindowFrame,
            presentation: presentation)
        if shouldShowDetailsForLocalQA {
            showDetails(now: now)
        }
        if !presentation.hasQuota {
            setStatus(.quotaUnavailable)
        } else if presentation.isCached {
            setStatus(.showingCached)
        } else {
            setStatus(.active)
        }
        updateTrackingInterval(Self.foregroundTrackingInterval)
    }

    private func requestQuotaRefreshIfNeeded(becameFrontmost: Bool, now: Date) {
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now)
        guard becameFrontmost || !presentation.hasQuota || presentation.isCached else {
            return
        }
        if let lastRefreshRequestAt,
           now.timeIntervalSince(lastRefreshRequestAt)
                < Self.refreshRequestMinimumGap {
            return
        }
        lastRefreshRequestAt = now
        environment.refreshRateLimits(
            minInterval: Self.refreshRequestMinimumGap,
            trigger: "codex-overlay")
    }

    private func updateTrackingInterval(_ interval: TimeInterval) {
        guard trackingInterval != interval else { return }
        trackingTimer?.invalidate()
        trackingInterval = interval
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(trackingTimerFired),
            userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func showOverlay(
        in codexWindowFrame: CGRect,
        presentation: CodexQuotaOverlayPresentation
    ) {
        lastCodexWindowFrame = codexWindowFrame
        let frame = CodexQuotaOverlayLayout.frame(
            in: codexWindowFrame,
            presentation: presentation)
        let panel = panel ?? makePanel()
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if detailsPanel?.isVisible == true {
            if presentation.hasQuota {
                updateDetailsPanelFrame(
                    in: codexWindowFrame,
                    presentation: presentation)
            } else {
                closeDetails()
            }
        }
    }

    private func hideOverlay() {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        isSummaryHovered = false
        isDetailsHovered = false
        lastCodexWindowFrame = nil
        closeDetails()
        panel?.orderOut(nil)
    }

    private func summaryHoverChanged(_ hovering: Bool) {
        isSummaryHovered = hovering
        if hovering {
            showDetails()
        } else {
            scheduleDetailsClose()
        }
    }

    private func detailsHoverChanged(_ hovering: Bool) {
        isDetailsHovered = hovering
        if hovering {
            detailsCloseTask?.cancel()
            detailsCloseTask = nil
        } else {
            scheduleDetailsClose()
        }
    }

    private func activateDetails() {
        showDetails()
    }

    private func showDetails(now: Date = Date()) {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        guard panel?.isVisible == true,
              let codexWindowFrame = lastCodexWindowFrame else {
            return
        }
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now)
        guard presentation.hasQuota else { return }

        let panel = detailsPanel ?? makeDetailsPanel()
        updateDetailsPanelFrame(
            in: codexWindowFrame,
            presentation: presentation)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        installClickAwayMonitorsIfNeeded()
    }

    private func scheduleDetailsClose() {
        detailsCloseTask?.cancel()
        detailsCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let self,
                  !self.isSummaryHovered,
                  !self.isDetailsHovered else {
                return
            }
            self.closeDetails()
        }
    }

    private func closeDetails() {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        removeClickAwayMonitors()
        detailsPanel?.orderOut(nil)
    }

    private func installClickAwayMonitorsIfNeeded() {
        if localMouseDownMonitor == nil {
            localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                let identifier = event.window?.identifier?.rawValue
                if CodexQuotaOverlayInteractionPolicy.shouldDismissDetails(
                    afterMouseDownIn: identifier) {
                    self.closeDetails()
                }
                return event
            }
        }
        if globalMouseDownMonitor == nil {
            globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closeDetails()
                }
            }
        }
    }

    private func removeClickAwayMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func updateDetailsPanelFrame(
        in codexWindowFrame: CGRect,
        presentation: CodexQuotaOverlayPresentation
    ) {
        guard let detailsPanel else { return }
        let resetCredits = resetCreditsPresentation()
        let contentHeight = CodexQuotaOverlayLayout.detailsContentHeight(
            presentation: presentation,
            resetCredits: resetCredits)
        let frame = CodexQuotaOverlayLayout.detailsFrame(
            in: codexWindowFrame,
            contentHeight: contentHeight)
        if detailsPanel.frame != frame {
            detailsPanel.setFrame(frame, display: detailsPanel.isVisible)
        }
    }

    private func resetCreditsPresentation()
        -> CodexQuotaOverlayResetCreditsPresentation? {
        CodexQuotaOverlayResetCreditsPresentation.make(
            snapshot: environment.latestCodexResetCredits,
            fallbackAvailableCount: environment.latestRateLimits?
                .resetCreditsAvailable)
    }

    private func setStatus(_ status: CodexSidebarQuotaStatus) {
        guard settings.codexSidebarQuotaStatus != status else { return }
        settings.codexSidebarQuotaStatus = status
    }

    private func makePanel() -> CodexQuotaOverlayPanel {
        let panel = CodexQuotaOverlayPanel(
            contentRect: CGRect(origin: .zero, size: CodexQuotaOverlayLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        configure(
            panel,
            identifier: CodexQuotaOverlayLayout.windowIdentifier)

        let rootView = CodexQuotaOverlayView(
            onHoverChanged: { [weak self] hovering in
                self?.summaryHoverChanged(hovering)
            },
            onActivate: { [weak self] in
                self?.activateDetails()
            })
            .environment(environment)
            .environment(settings)
            .environment(LocalizationStore.shared)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: CodexQuotaOverlayLayout.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func makeDetailsPanel() -> CodexQuotaOverlayPanel {
        let initialSize = CGSize(
            width: CodexQuotaOverlayLayout.detailsWidth,
            height: 88)
        let panel = CodexQuotaOverlayPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        configure(
            panel,
            identifier: CodexQuotaOverlayLayout.detailsWindowIdentifier)

        let rootView = CodexQuotaOverlayDetailsView(
            onHoverChanged: { [weak self] hovering in
                self?.detailsHoverChanged(hovering)
            })
            .environment(environment)
            .environment(settings)
            .environment(LocalizationStore.shared)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.detailsPanel = panel
        return panel
    }

    private func configure(
        _ panel: CodexQuotaOverlayPanel,
        identifier: String
    ) {
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
    }

    private static func frontWindow(for processIdentifier: pid_t) -> CodexWindowCandidate? {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates = rows.compactMap(Self.candidate(from:))
        return CodexWindowSelectionPolicy.frontWindow(
            for: processIdentifier,
            candidates: candidates)
    }

    private static func candidate(from row: [String: Any]) -> CodexWindowCandidate? {
        guard let windowNumber = row[kCGWindowNumber as String] as? NSNumber,
              let ownerPID = row[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = row[kCGWindowLayer as String] as? NSNumber,
              let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return CodexWindowCandidate(
            windowNumber: windowNumber.intValue,
            ownerPID: pid_t(ownerPID.int32Value),
            layer: layer.intValue,
            alpha: alpha,
            bounds: bounds)
    }

    private static func displayGeometries() -> [CodexDisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            return CodexDisplayGeometry(
                quartzFrame: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                appKitFrame: screen.frame)
        }
    }
}
