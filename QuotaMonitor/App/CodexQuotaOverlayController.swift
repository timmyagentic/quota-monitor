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
    private var trackedCodexPID: pid_t?
    private var lastCodexWindowNumber: Int?
    private var lastCodexWindowFrame: CGRect?
    private var helpControlAnchor: CodexHelpControlAnchor?
    private var helpControlDiscoveryTask: Task<Void, Never>?
    private var helpControlDiscoveryGeneration = 0
    private var helpControlDiscoveryFailureCount = 0
    private var helpControlNextDiscoveryAt: Date?
    private var helpControlDiscoveryPID: pid_t?
    private var helpControlDiscoveryWindowNumber: Int?
    private var helpControlDiscoveryWindowBounds: CGRect?
    private var isCodexFrontmost = false
    private var isSummaryHovered = false
    private var isDetailsHovered = false
    private var detailsCloseTask: Task<Void, Never>?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var summaryDragStartFrame: CGRect?
    private var summaryDragStartMouseLocation: CGPoint?
    private var summaryDragFrame: CGRect?
    private var summaryDragDidMove = false
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
            NSWorkspace.activeSpaceDidChangeNotification,
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
        resetHelpControlDiscovery(clearAnchor: true)
        shouldShowDetailsForLocalQA = true
        refreshLocalQAOverlay()
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
        if shouldShowDetailsForLocalQA {
            refreshLocalQAOverlay(now: now)
            return
        }
        guard settings.shouldShowCodexSidebarQuota else {
            lastFrontmostPID = nil
            trackedCodexPID = nil
            isCodexFrontmost = false
            hideOverlay()
            setStatus(.disabled)
            updateTrackingInterval(Self.backgroundTrackingInterval)
            return
        }

        let runningCodexProcessIdentifiers = Set(
            workspace.runningApplications.compactMap { application -> pid_t? in
                guard let bundleIdentifier = application.bundleIdentifier,
                      Self.supportedBundleIdentifiers.contains(bundleIdentifier),
                      !application.isTerminated else {
                    return nil
                }
                return application.processIdentifier
            })
        guard !runningCodexProcessIdentifiers.isEmpty else {
            lastFrontmostPID = nil
            trackedCodexPID = nil
            isCodexFrontmost = false
            hideOverlay()
            setStatus(.waitingForCodex)
            // Application launch notifications wake the scanner when Codex
            // starts, so there is no reason to enumerate windows while idle.
            updateTrackingInterval(nil)
            return
        }
        if let trackedCodexPID,
           !runningCodexProcessIdentifiers.contains(trackedCodexPID) {
            self.trackedCodexPID = nil
        }

        let frontmostApplication = workspace.frontmostApplication
        let frontmostCodexPID: pid_t?
        if let frontmostApplication,
           let bundleIdentifier = frontmostApplication.bundleIdentifier,
           Self.supportedBundleIdentifiers.contains(bundleIdentifier),
           !frontmostApplication.isTerminated {
            frontmostCodexPID = frontmostApplication.processIdentifier
        } else {
            frontmostCodexPID = nil
        }
        isCodexFrontmost = frontmostCodexPID != nil

        let becameFrontmost: Bool
        if let frontmostCodexPID {
            becameFrontmost = lastFrontmostPID != frontmostCodexPID
            lastFrontmostPID = frontmostCodexPID
            trackedCodexPID = frontmostCodexPID
            requestQuotaRefreshIfNeeded(
                becameFrontmost: becameFrontmost,
                now: now)
        } else {
            becameFrontmost = false
            lastFrontmostPID = nil
            dismissDetailsForBackground()
        }

        let onScreenWindows = Self.onScreenWindows()
        let window = trackedCodexPID.flatMap {
            CodexWindowSelectionPolicy.trackedWindow(
                for: $0,
                lastWindowNumber: lastCodexWindowNumber,
                codexIsFrontmost: isCodexFrontmost,
                candidates: onScreenWindows)
        }
        let placement = CodexQuotaOverlayVisibilityPolicy.placement(
            codexIsFrontmost: isCodexFrontmost,
            trackedWindowIsOnScreen: window != nil,
            overlayIsVisible: panel?.isVisible == true)
        guard placement != .hidden,
              let window,
              let appKitWindowFrame = CodexWindowFrameConverter.appKitFrame(
                for: window.bounds,
                displays: Self.displayGeometries()) else {
            if !isCodexFrontmost {
                trackedCodexPID = nil
            }
            hideOverlay()
            setStatus(.waitingForCodex)
            updateTrackingInterval(
                isCodexFrontmost
                    ? Self.foregroundTrackingInterval
                    : Self.backgroundTrackingInterval)
            return
        }

        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now)
        let overlayIsAboveCodex = panel.map {
            CodexWindowSelectionPolicy.isWindow(
                $0.windowNumber,
                above: window.windowNumber,
                candidates: onScreenWindows)
        } ?? false
        refreshHelpControlAnchorIfNeeded(
            for: window,
            processIdentifier: trackedCodexPID,
            becameFrontmost: becameFrontmost,
            now: now)
        let helpControlLeadingX = helpControlAnchor?.leadingX(
            in: appKitWindowFrame)
        showOverlay(
            in: appKitWindowFrame,
            presentation: presentation,
            helpControlLeadingX: helpControlLeadingX,
            placement: placement,
            relativeTo: window.windowNumber,
            shouldRaise: becameFrontmost
                || lastCodexWindowNumber != window.windowNumber
                || !overlayIsAboveCodex)
        lastCodexWindowNumber = window.windowNumber
        if !presentation.hasQuota {
            setStatus(.quotaUnavailable)
        } else if presentation.isCached {
            setStatus(.showingCached)
        } else {
            setStatus(.active)
        }
        updateTrackingInterval(
            isCodexFrontmost
                ? Self.foregroundTrackingInterval
                : Self.backgroundTrackingInterval)
    }

    private func refreshHelpControlAnchorIfNeeded(
        for window: CodexWindowCandidate,
        processIdentifier: pid_t?,
        becameFrontmost: Bool,
        now: Date
    ) {
        guard let processIdentifier else {
            resetHelpControlDiscovery(clearAnchor: true)
            return
        }

        let targetChanged = helpControlDiscoveryPID != processIdentifier
            || helpControlDiscoveryWindowNumber != window.windowNumber
        let layoutChanged = !targetChanged
            && helpControlDiscoveryWindowBounds != window.bounds

        if targetChanged {
            resetHelpControlDiscovery(clearAnchor: true)
            helpControlDiscoveryPID = processIdentifier
            helpControlDiscoveryWindowNumber = window.windowNumber
            helpControlDiscoveryWindowBounds = window.bounds
        } else if layoutChanged {
            helpControlDiscoveryWindowBounds = window.bounds
            helpControlNextDiscoveryAt = now
        }

        guard isCodexFrontmost,
              CodexHelpControlDiscoveryPolicy.shouldStart(
                now: now,
                nextAttemptAt: helpControlNextDiscoveryAt,
                isRunning: helpControlDiscoveryTask != nil,
                force: becameFrontmost || targetChanged || layoutChanged) else {
            return
        }
        startHelpControlDiscovery(
            processIdentifier: processIdentifier,
            windowNumber: window.windowNumber,
            windowBounds: window.bounds)
    }

    private func startHelpControlDiscovery(
        processIdentifier: pid_t,
        windowNumber: Int,
        windowBounds: CGRect
    ) {
        helpControlDiscoveryGeneration &+= 1
        let generation = helpControlDiscoveryGeneration
        helpControlDiscoveryTask = Task.detached(priority: .utility) { [weak self] in
            let anchor = CodexHelpControlAccessibility.anchor(
                for: processIdentifier,
                in: windowBounds)
            guard !Task.isCancelled else { return }
            await self?.completeHelpControlDiscovery(
                anchor: anchor,
                processIdentifier: processIdentifier,
                windowNumber: windowNumber,
                windowBounds: windowBounds,
                generation: generation,
                completedAt: Date())
        }
    }

    private func completeHelpControlDiscovery(
        anchor: CodexHelpControlAnchor?,
        processIdentifier: pid_t,
        windowNumber: Int,
        windowBounds: CGRect,
        generation: Int,
        completedAt: Date
    ) {
        guard helpControlDiscoveryGeneration == generation else { return }
        helpControlDiscoveryTask = nil
        guard isStarted,
              isCodexFrontmost,
              trackedCodexPID == processIdentifier,
              helpControlDiscoveryPID == processIdentifier,
              helpControlDiscoveryWindowNumber == windowNumber else {
            return
        }
        guard helpControlDiscoveryWindowBounds == windowBounds else {
            helpControlNextDiscoveryAt = completedAt
            refreshOverlay(now: completedAt)
            return
        }

        if let anchor {
            helpControlAnchor = anchor
            helpControlDiscoveryFailureCount = 0
            helpControlNextDiscoveryAt = completedAt.addingTimeInterval(
                CodexHelpControlDiscoveryPolicy.anchoredRefreshInterval)
        } else {
            helpControlDiscoveryFailureCount += 1
            if helpControlDiscoveryFailureCount
                >= CodexHelpControlDiscoveryPolicy.preservedAnchorMissLimit {
                helpControlAnchor = nil
            }
            helpControlNextDiscoveryAt = completedAt.addingTimeInterval(
                CodexHelpControlDiscoveryPolicy.retryInterval(
                    afterFailureCount: helpControlDiscoveryFailureCount))
        }
        refreshOverlay(now: completedAt)
    }

    private func resetHelpControlDiscovery(clearAnchor: Bool) {
        helpControlDiscoveryGeneration &+= 1
        helpControlDiscoveryTask?.cancel()
        helpControlDiscoveryTask = nil
        helpControlDiscoveryFailureCount = 0
        helpControlNextDiscoveryAt = nil
        helpControlDiscoveryPID = nil
        helpControlDiscoveryWindowNumber = nil
        helpControlDiscoveryWindowBounds = nil
        if clearAnchor {
            helpControlAnchor = nil
        }
    }

    private func refreshLocalQAOverlay(now: Date = Date()) {
        guard let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame else {
            return
        }
        // Match a full-screen Codex window so fallback screenshots retain the
        // shipping layout's original 12 pt bottom baseline.
        let qaFrame = screenFrame
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now)
        showOverlay(
            in: qaFrame,
            presentation: presentation,
            helpControlLeadingX: nil,
            placement: .foreground,
            relativeTo: nil,
            shouldRaise: true)
        showDetails(now: now, installClickAwayMonitors: false)
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

    private func updateTrackingInterval(_ interval: TimeInterval?) {
        guard trackingInterval != interval else { return }
        trackingTimer?.invalidate()
        trackingTimer = nil
        trackingInterval = interval
        guard let interval else { return }
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
        presentation: CodexQuotaOverlayPresentation,
        helpControlLeadingX: CGFloat?,
        placement: CodexQuotaOverlayPlacement,
        relativeTo codexWindowNumber: Int?,
        shouldRaise: Bool
    ) {
        guard placement != .hidden else { return }
        lastCodexWindowFrame = codexWindowFrame
        let frame = summaryDragFrame ?? CodexQuotaOverlayLayout.frame(
            in: codexWindowFrame,
            presentation: presentation,
            helpControlLeadingX: helpControlLeadingX,
            manualPosition: settings.codexSidebarQuotaPosition)
        let panel = panel ?? makePanel()
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
        panel.ignoresMouseEvents = !placement.allowsInteraction
        switch placement {
        case .foreground where shouldRaise || !panel.isVisible:
            if let codexWindowNumber {
                panel.order(.above, relativeTo: codexWindowNumber)
            } else {
                panel.orderFrontRegardless()
            }
        case .background:
            if let codexWindowNumber {
                panel.order(.above, relativeTo: codexWindowNumber)
            }
        case .foreground, .hidden:
            break
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
        resetSummaryDrag()
        lastCodexWindowNumber = nil
        lastCodexWindowFrame = nil
        resetHelpControlDiscovery(clearAnchor: true)
        closeDetails()
        panel?.orderOut(nil)
    }

    private func summaryHoverChanged(_ hovering: Bool) {
        isSummaryHovered = hovering
        if hovering, detailsAreAllowed {
            showDetails()
        } else if hovering {
            closeDetails()
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
        guard detailsAreAllowed else { return }
        showDetails()
    }

    private func summaryPressBegan() {
        closeDetails()
    }

    private func summaryDragBegan() {
        guard detailsAreAllowed,
              let panel else {
            return
        }
        summaryDragStartFrame = panel.frame
        summaryDragStartMouseLocation = NSEvent.mouseLocation
        summaryDragFrame = panel.frame
        summaryDragDidMove = false
        closeDetails()
    }

    private func summaryDragChanged() {
        guard detailsAreAllowed,
              let panel,
              let codexWindowFrame = lastCodexWindowFrame else {
            return
        }
        guard let summaryDragStartFrame,
              let summaryDragStartMouseLocation else {
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let candidate = CGRect(
            x: summaryDragStartFrame.minX
                + mouseLocation.x
                - summaryDragStartMouseLocation.x,
            y: summaryDragStartFrame.minY
                + mouseLocation.y
                - summaryDragStartMouseLocation.y,
            width: summaryDragStartFrame.width,
            height: summaryDragStartFrame.height)
        let frame = CodexQuotaOverlayLayout.clampedFrame(
            candidate,
            in: codexWindowFrame)
        summaryDragFrame = frame
        summaryDragDidMove = true
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func summaryDragEnded() {
        guard summaryDragDidMove,
              let summaryDragFrame,
              let codexWindowFrame = lastCodexWindowFrame else {
            resetSummaryDrag()
            return
        }
        settings.codexSidebarQuotaPosition =
            CodexQuotaOverlayLayout.manualPosition(
                for: summaryDragFrame,
                in: codexWindowFrame)
        resetSummaryDrag()
        refreshOverlay()
    }

    private func resetSummaryDrag() {
        summaryDragStartFrame = nil
        summaryDragStartMouseLocation = nil
        summaryDragFrame = nil
        summaryDragDidMove = false
    }

    private var detailsAreAllowed: Bool {
        isCodexFrontmost || shouldShowDetailsForLocalQA
    }

    private func dismissDetailsForBackground() {
        isSummaryHovered = false
        isDetailsHovered = false
        closeDetails()
    }

    private func showDetails(
        now: Date = Date(),
        installClickAwayMonitors: Bool = true
    ) {
        detailsCloseTask?.cancel()
        detailsCloseTask = nil
        guard detailsAreAllowed,
              panel?.isVisible == true,
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
        if installClickAwayMonitors {
            installClickAwayMonitorsIfNeeded()
        }
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
        guard let detailsPanel,
              let summaryFrame = panel?.frame else { return }
        let resetCredits = resetCreditsPresentation()
        let contentHeight = CodexQuotaOverlayLayout.detailsContentHeight(
            presentation: presentation,
            resetCredits: resetCredits)
        let frame = CodexQuotaOverlayLayout.detailsFrame(
            in: codexWindowFrame,
            summaryFrame: summaryFrame,
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
            identifier: CodexQuotaOverlayLayout.windowIdentifier,
            ignoresMouseEvents: true)

        let rootView = CodexQuotaOverlayView(
            onHoverChanged: { [weak self] hovering in
                self?.summaryHoverChanged(hovering)
            },
            onActivate: { [weak self] in
                self?.activateDetails()
            },
            onPressBegan: { [weak self] in
                self?.summaryPressBegan()
            },
            onDragBegan: { [weak self] in
                self?.summaryDragBegan()
            },
            onDragChanged: { [weak self] in
                self?.summaryDragChanged()
            },
            onDragEnded: { [weak self] in
                self?.summaryDragEnded()
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
            identifier: CodexQuotaOverlayLayout.detailsWindowIdentifier,
            ignoresMouseEvents: false)

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
        identifier: String,
        ignoresMouseEvents: Bool
    ) {
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .normal
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
    }

    private static func onScreenWindows() -> [CodexWindowCandidate] {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap(Self.candidate(from:))
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
