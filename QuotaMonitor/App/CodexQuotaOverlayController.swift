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
    private var headerAnchor: CodexSidebarHeaderAnchor?
    private var headerReadResult: CodexSidebarHeaderReadResult?
    private var headerDiscoveryTask: Task<Void, Never>?
    private var headerDiscoveryGeneration = 0
    private var headerDiscoveryFailureCount = 0
    private var headerNextDiscoveryAt: Date?
    private var headerDiscoveryPID: pid_t?
    private var headerDiscoveryWindowNumber: Int?
    private var headerDiscoveryWindowBounds: CGRect?
    private var isCodexFrontmost = false
    private let viewState = CodexQuotaOverlayViewState()
    private var qaPreview: LocalQAOverlayPreview?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var summaryDragStartFrame: CGRect?
    private var summaryDragStartMouseLocation: CGPoint?
    private var summaryDragFrame: CGRect?
    private var summaryDragDidMove = false
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

    func showDetailsForLocalQA(outputDirectory: URL) {
        guard LocalQAEnvironment.isQARequested() else { return }
        hideOverlay()
        qaPreview = LocalQAOverlayPreview(environment: environment, settings: settings, outputDirectory: outputDirectory)
        qaPreview?.onLayoutChanged = { [weak self] in
            self?.refreshOverlay()
            self?.recordLocalQAPanels(event: "fixture-layout")
        }
        qaPreview?.onResetPosition = { [weak self] in self?.resetPosition() }
        qaPreview?.onInspectPanels = { [weak self] in
            guard let self, let preview = self.qaPreview else { return }
            self.showDetails()
            self.panel?.title = "Quota widget"
            self.detailsPanel?.title = "Quota details"
            preview.isInspectingPanels = true
            preview.window.orderOut(nil)
            self.recordLocalQAPanels(event: "inspect")
        }
        qaPreview?.show()
        refreshOverlay()
    }

    @objc private nonisolated func workspaceStateDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshOverlay()
        }
    }

    @objc private nonisolated func screenParametersDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshOverlay()
        }
    }

    @objc private func trackingTimerFired(_ timer: Timer) {
        refreshOverlay()
    }

    private func refreshOverlay(now: Date = Date()) {
        guard isStarted else { return }
        if let qaPreview {
            if qaPreview.isInspectingPanels { return }
            isCodexFrontmost = NSApp.isActive
            guard qaPreview.window.isVisible else { hideOverlay(); return }
            if !isCodexFrontmost { resetSummaryDrag(); closeDetails() }
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits, displayMode: settings.quotaDisplayMode)
            showOverlay(in: qaPreview.window.frame, presentation: presentation,
                header: qaPreview.header,
                placement: isCodexFrontmost ? .foreground : .background,
                relativeTo: qaPreview.window.windowNumber, shouldRaise: true)
            updateTrackingInterval(Self.foregroundTrackingInterval)
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
            now: now,
            refreshFailed: environment.rateLimitsRefreshFailed)
        let overlayIsAboveCodex = panel.map {
            CodexWindowSelectionPolicy.isWindow(
                $0.windowNumber,
                above: window.windowNumber,
                candidates: onScreenWindows)
        } ?? false
        refreshHeaderAnchorIfNeeded(
            for: window,
            processIdentifier: trackedCodexPID,
            becameFrontmost: becameFrontmost,
            now: now)
        showOverlay(
            in: appKitWindowFrame,
            presentation: presentation,
            header: headerAnchor,
            placement: placement,
            relativeTo: window.windowNumber,
            shouldRaise: becameFrontmost
                || lastCodexWindowNumber != window.windowNumber
                || !overlayIsAboveCodex)
        lastCodexWindowNumber = window.windowNumber
        if panel?.isVisible != true {
            setStatus(headerReadResult?.unavailableStatus ?? .waitingForInterface)
        } else if !presentation.hasQuota {
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

    private func refreshHeaderAnchorIfNeeded(
        for window: CodexWindowCandidate,
        processIdentifier: pid_t?,
        becameFrontmost: Bool,
        now: Date
    ) {
        guard let processIdentifier else {
            resetHeaderDiscovery(clearAnchor: true)
            return
        }

        let targetChanged = headerDiscoveryPID != processIdentifier
            || headerDiscoveryWindowNumber != window.windowNumber
        let layoutChanged = !targetChanged
            && headerDiscoveryWindowBounds != window.bounds

        if targetChanged {
            resetHeaderDiscovery(clearAnchor: true)
            headerDiscoveryPID = processIdentifier
            headerDiscoveryWindowNumber = window.windowNumber
            headerDiscoveryWindowBounds = window.bounds
        } else if layoutChanged {
            headerAnchor = nil
            headerReadResult = nil
            headerDiscoveryWindowBounds = window.bounds
            headerNextDiscoveryAt = now
        }

        guard isCodexFrontmost,
              CodexSidebarHeaderDiscoveryPolicy.shouldStart(
                now: now,
                nextAttemptAt: headerNextDiscoveryAt,
                isRunning: headerDiscoveryTask != nil,
                force: becameFrontmost || targetChanged || layoutChanged) else {
            return
        }
        startHeaderDiscovery(
            processIdentifier: processIdentifier,
            windowNumber: window.windowNumber,
            windowBounds: window.bounds)
    }

    private func startHeaderDiscovery(
        processIdentifier: pid_t,
        windowNumber: Int,
        windowBounds: CGRect
    ) {
        headerDiscoveryGeneration &+= 1
        let generation = headerDiscoveryGeneration
        headerDiscoveryTask = Task.detached(priority: .utility) { [weak self] in
            let result = CodexSidebarHeaderAccessibility.read(
                for: processIdentifier,
                in: windowBounds)
            guard !Task.isCancelled else { return }
            await self?.completeHeaderDiscovery(
                result: result,
                processIdentifier: processIdentifier,
                windowNumber: windowNumber,
                windowBounds: windowBounds,
                generation: generation,
                completedAt: Date())
        }
    }

    private func completeHeaderDiscovery(
        result: CodexSidebarHeaderReadResult,
        processIdentifier: pid_t,
        windowNumber: Int,
        windowBounds: CGRect,
        generation: Int,
        completedAt: Date
    ) {
        guard headerDiscoveryGeneration == generation else { return }
        headerDiscoveryTask = nil
        guard isStarted,
              isCodexFrontmost,
              trackedCodexPID == processIdentifier,
              headerDiscoveryPID == processIdentifier,
              headerDiscoveryWindowNumber == windowNumber else {
            return
        }
        guard headerDiscoveryWindowBounds == windowBounds else {
            headerNextDiscoveryAt = completedAt
            refreshOverlay(now: completedAt)
            return
        }

        if headerReadResult != result {
            DeveloperLog.eventRecord("codex_overlay.header_discovery", category: "codex_overlay",
                result: result.failure?.rawValue ?? "found",
                fields: ["visited": .int(result.visitedCount),
                         "candidates": .int(result.candidateCount),
                         "web_areas": .int(result.webAreaCount)])
        }
        headerReadResult = result
        if let anchor = result.anchor {
            headerAnchor = anchor
            headerDiscoveryFailureCount = 0
            headerNextDiscoveryAt = completedAt.addingTimeInterval(
                CodexSidebarHeaderDiscoveryPolicy.anchoredRefreshInterval)
        } else {
            headerDiscoveryFailureCount += 1
            headerAnchor = nil
            headerNextDiscoveryAt = completedAt.addingTimeInterval(
                CodexSidebarHeaderDiscoveryPolicy.retryInterval(
                    afterFailureCount: headerDiscoveryFailureCount))
        }
        refreshOverlay(now: completedAt)
    }

    private func resetHeaderDiscovery(clearAnchor: Bool) {
        headerDiscoveryGeneration &+= 1
        headerDiscoveryTask?.cancel()
        headerDiscoveryTask = nil
        headerDiscoveryFailureCount = 0
        headerNextDiscoveryAt = nil
        headerDiscoveryPID = nil
        headerDiscoveryWindowNumber = nil
        headerDiscoveryWindowBounds = nil
        if clearAnchor {
            headerAnchor = nil
            headerReadResult = nil
        }
    }

    private func requestQuotaRefreshIfNeeded(becameFrontmost: Bool, now: Date) {
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now,
            refreshFailed: environment.rateLimitsRefreshFailed)
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
        header: CodexSidebarHeaderAnchor?,
        placement: CodexQuotaOverlayPlacement,
        relativeTo codexWindowNumber: Int?,
        shouldRaise: Bool
    ) {
        guard placement != .hidden else { return }
        lastCodexWindowFrame = codexWindowFrame
        guard let summary = CodexQuotaOverlayLayout.summaryPlacement(
            in: codexWindowFrame, presentation: presentation, header: header,
            manualPosition: settings.codexSidebarQuotaPosition,
            activeDrag: summaryDragFrame.map { .init(frame: $0, compact: viewState.compact) }) else {
            panel?.orderOut(nil)
            closeDetails()
            return
        }
        let frame = summary.frame
        viewState.compact = summary.compact
        viewState.width = frame.width
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
                updateDetailsPanelFrame(in: codexWindowFrame, presentation: presentation)
            } else {
                closeDetails()
            }
        }
    }

    private func hideOverlay() {
        resetSummaryDrag()
        lastCodexWindowNumber = nil
        lastCodexWindowFrame = nil
        resetHeaderDiscovery(clearAnchor: true)
        closeDetails()
        panel?.orderOut(nil)
    }

    private func resetPosition() {
        settings.codexSidebarQuotaPosition = nil
        resetSummaryDrag()
        refreshOverlay()
        recordLocalQAPanels(event: "reset-position")
    }

    private func activateDetails() {
        guard detailsAreAllowed else { return }
        if detailsPanel?.isVisible == true { closeDetails() } else { showDetails() }
    }

    private func summaryPressBegan(_ location: CGPoint) {
        guard detailsAreAllowed,
              let panel else {
            resetSummaryDrag()
            return
        }
        summaryDragStartFrame = panel.frame
        summaryDragStartMouseLocation = location
        summaryDragFrame = panel.frame
        summaryDragDidMove = false
        recordLocalQAPanels(event: "press")
    }

    private func summaryDragBegan(_ location: CGPoint) {
        closeDetails()
        summaryDragChanged(location)
        recordLocalQAPanels(event: "unlock")
    }

    private func summaryDragChanged(_ location: CGPoint) {
        guard detailsAreAllowed,
              let panel,
              let codexWindowFrame = lastCodexWindowFrame else {
            return
        }
        guard let summaryDragStartFrame,
              let summaryDragStartMouseLocation else {
            return
        }
        let frame = CodexQuotaOverlayDragFramePolicy.frame(
            from: summaryDragStartFrame,
            pressLocation: summaryDragStartMouseLocation,
            currentLocation: location,
            in: codexWindowFrame)
        summaryDragFrame = frame
        summaryDragDidMove = summaryDragDidMove || frame != summaryDragStartFrame
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
        recordLocalQAPanels(event: "move")
    }

    private func summaryDragEnded() {
        guard summaryDragDidMove,
              let summaryDragFrame,
              let codexWindowFrame = lastCodexWindowFrame else {
            resetSummaryDrag()
            return
        }
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits, displayMode: settings.quotaDisplayMode)
        let restoredWidth = presentation.fiveHour != nil && presentation.weekly != nil
            ? CodexQuotaOverlayLayout.dualWindowWidth : CodexQuotaOverlayLayout.size.width
        settings.codexSidebarQuotaPosition = CodexQuotaOverlayLayout.manualPosition(
            for: summaryDragFrame, in: codexWindowFrame, restoredWidth: restoredWidth)
        resetSummaryDrag()
        refreshOverlay()
        recordLocalQAPanels(event: "drop")
    }

    private func resetSummaryDrag() {
        viewState.dragPhase = .idle
        summaryDragStartFrame = nil
        summaryDragStartMouseLocation = nil
        summaryDragFrame = nil
        summaryDragDidMove = false
    }

    private var detailsAreAllowed: Bool {
        isCodexFrontmost
    }

    private func dismissDetailsForBackground() {
        resetSummaryDrag()
        closeDetails()
    }

    private func showDetails(
        now: Date = Date(),
        installClickAwayMonitors: Bool = true
    ) {
        guard detailsAreAllowed,
              panel?.isVisible == true,
              let codexWindowFrame = lastCodexWindowFrame else {
            return
        }
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode,
            now: now,
            refreshFailed: environment.rateLimitsRefreshFailed)

        guard presentation.hasQuota else { return }
        viewState.isExpanded = true
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

    private func closeDetails() {
        viewState.isExpanded = false
        removeClickAwayMonitors()
        detailsPanel?.orderOut(nil)
    }

    private func installClickAwayMonitorsIfNeeded() {
        if localMouseDownMonitor == nil {
            localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closeDetails(); return nil }
                    return event
                }
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
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                guard event.type != .keyDown || event.keyCode == 53 else { return }
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

    private func recordLocalQAPanels(event: String) {
        guard let preview = qaPreview else { return }
        func frame(_ frame: CGRect) -> [CGFloat] {
            [frame.minX, frame.minY, frame.width, frame.height]
        }
        let windows = [panel, detailsPanel].compactMap { $0 }.map { window -> [String: Any] in
            ["identifier": window.identifier?.rawValue ?? "", "number": window.windowNumber,
             "frame": frame(window.frame), "visible": window.isVisible,
             "key": window.isKeyWindow, "ignoresMouseEvents": window.ignoresMouseEvents]
        }
        var report: [String: Any] = ["event": event, "hostFrame": frame(preview.window.frame),
            "windows": windows, "source": Bundle.main.infoDictionary?["BuildCommit"] as? String ?? "",
            "manual": settings.codexSidebarQuotaPosition.map {
                [$0.horizontalFraction, $0.verticalFraction]
            } ?? []]
        if let header = preview.header {
            report["header"] = [header.leadingInset, header.trailingXInset, header.centerYInset]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = preview.outputDirectory.appendingPathComponent("overlay-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
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
            state: viewState,
            onResetPosition: { [weak self] in
                self?.resetPosition()
            },
            onActivate: { [weak self] in
                self?.activateDetails()
            },
            onPressBegan: { [weak self] location in
                self?.summaryPressBegan(location)
            },
            onDragBegan: { [weak self] location in
                self?.summaryDragBegan(location)
            },
            onDragChanged: { [weak self] location in
                self?.summaryDragChanged(location)
            },
            onDragEnded: { [weak self] in
                self?.summaryDragEnded()
            },
            onDragCancelled: { [weak self] in
                self?.resetSummaryDrag()
                self?.refreshOverlay()
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

        panel.hasShadow = true
        let rootView = CodexQuotaOverlayDetailsView()
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
