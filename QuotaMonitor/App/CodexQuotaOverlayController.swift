import AppKit
import CoreGraphics
import SwiftUI

struct CodexQuotaOverlayMetric: Equatable {
    enum Severity: Equatable {
        case healthy
        case warning
        case critical
    }

    let percent: Int
    let severity: Severity
}

struct CodexQuotaOverlayPresentation: Equatable {
    let fiveHour: CodexQuotaOverlayMetric?
    let weekly: CodexQuotaOverlayMetric?
    let isCached: Bool

    var hasQuota: Bool {
        fiveHour != nil || weekly != nil
    }

    static func make(
        snapshot: RateLimitSnapshot?,
        displayMode: SettingsStore.QuotaDisplayMode,
        now: Date = Date(),
        staleAfter: TimeInterval = 15 * 60
    ) -> CodexQuotaOverlayPresentation {
        guard let snapshot else {
            return CodexQuotaOverlayPresentation(
                fiveHour: nil,
                weekly: nil,
                isCached: false)
        }

        let fiveHour = snapshot.primary.map {
            metric(window: $0, displayMode: displayMode)
        }
        let weekly = snapshot.secondary.map {
            metric(window: $0, displayMode: displayMode)
        }
        let age = max(0, now.timeIntervalSince(snapshot.capturedAt))
        let containsExpiredWindow = [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .contains { $0.resetAt <= now }

        return CodexQuotaOverlayPresentation(
            fiveHour: fiveHour,
            weekly: weekly,
            isCached: age > staleAfter || containsExpiredWindow)
    }

    private static func metric(
        window: RateLimitSnapshot.Window,
        displayMode: SettingsStore.QuotaDisplayMode
    ) -> CodexQuotaOverlayMetric {
        let displayPercent = displayMode.displayPercent(
            forUsedPercent: window.usedPercent)
        let severity: CodexQuotaOverlayMetric.Severity
        switch window.usedPercent {
        case ..<60:
            severity = .healthy
        case ..<85:
            severity = .warning
        default:
            severity = .critical
        }
        return CodexQuotaOverlayMetric(
            percent: Int(displayPercent.rounded()),
            severity: severity)
    }
}

struct CodexWindowCandidate: Equatable {
    let windowNumber: Int
    let ownerPID: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

enum CodexWindowSelectionPolicy {
    static let minimumWindowSize = CGSize(width: 480, height: 320)

    /// `CGWindowListCopyWindowInfo` returns windows front-to-back. Keeping
    /// that order selects the active Codex document when more than one is
    /// open, while the size and layer checks reject Electron helper surfaces.
    static func frontWindow(
        for processIdentifier: pid_t,
        candidates: [CodexWindowCandidate]
    ) -> CodexWindowCandidate? {
        candidates.first {
            $0.ownerPID == processIdentifier
                && $0.layer == 0
                && $0.alpha > 0.01
                && $0.bounds.width >= minimumWindowSize.width
                && $0.bounds.height >= minimumWindowSize.height
        }
    }
}

struct CodexDisplayGeometry: Equatable {
    let quartzFrame: CGRect
    let appKitFrame: CGRect
}

enum CodexWindowFrameConverter {
    /// Quartz window coordinates grow downward from each display's top edge;
    /// AppKit coordinates grow upward. Map through the display containing the
    /// largest part of the window so secondary displays and negative origins
    /// behave the same as the primary display.
    static func appKitFrame(
        for quartzWindowFrame: CGRect,
        displays: [CodexDisplayGeometry]
    ) -> CGRect? {
        guard let display = displays.max(by: {
            intersectionArea(quartzWindowFrame, $0.quartzFrame)
                < intersectionArea(quartzWindowFrame, $1.quartzFrame)
        }), intersectionArea(quartzWindowFrame, display.quartzFrame) > 0 else {
            return nil
        }

        let horizontalOffset = quartzWindowFrame.minX - display.quartzFrame.minX
        let verticalOffsetFromTop = quartzWindowFrame.minY - display.quartzFrame.minY
        return CGRect(
            x: display.appKitFrame.minX + horizontalOffset,
            y: display.appKitFrame.maxY
                - verticalOffsetFromTop
                - quartzWindowFrame.height,
            width: quartzWindowFrame.width,
            height: quartzWindowFrame.height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

enum CodexQuotaOverlayLayout {
    static let size = CGSize(width: 132, height: 25)
    static let windowIdentifier = "codex-quota-overlay"

    /// Codex's account row is 260 pt wide. Right-align before its help button
    /// so the widget follows the window without covering the avatar or row
    /// actions; mouse events pass through to Codex regardless.
    static func frame(in codexWindowFrame: CGRect) -> CGRect {
        CGRect(
            x: codexWindowFrame.minX + 100,
            y: codexWindowFrame.minY + 12,
            width: size.width,
            height: size.height)
    }
}

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
    private var trackingTimer: Timer?
    private var trackingInterval: TimeInterval?
    private var lastRefreshRequestAt: Date?
    private var lastFrontmostPID: pid_t?
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
        setStatus(.disabled)
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
        guard settings.codexSidebarQuotaEnabled else {
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
        showOverlay(at: CodexQuotaOverlayLayout.frame(in: appKitWindowFrame))
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

    private func showOverlay(at frame: CGRect) {
        let panel = panel ?? makePanel()
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hideOverlay() {
        panel?.orderOut(nil)
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
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier(
            CodexQuotaOverlayLayout.windowIdentifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]

        let rootView = CodexQuotaOverlayView()
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

private final class CodexQuotaOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CodexQuotaOverlayView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = CodexQuotaOverlayPresentation.make(
                snapshot: environment.latestRateLimits,
                displayMode: settings.quotaDisplayMode,
                now: context.date)

            Group {
                if presentation.hasQuota {
                    HStack(spacing: 6) {
                        metric("5h", presentation.fiveHour)
                        Rectangle()
                            .fill(.primary.opacity(0.14))
                            .frame(width: 1, height: 11)
                        metric(L10n.codexOverlayWeeklyCompact, presentation.weekly)
                        if presentation.isCached {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L10n.codexOverlayCachedStatus)
                        }
                    }
                    .opacity(presentation.isCached ? 0.72 : 1)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(L10n.codexOverlayUnavailableCompact)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(
                width: CodexQuotaOverlayLayout.size.width,
                height: CodexQuotaOverlayLayout.size.height)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.primary.opacity(0.11), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .accessibilityElement(children: .combine)
            .id(localization.currentLanguage)
        }
    }

    private func metric(
        _ label: String,
        _ value: CodexQuotaOverlayMetric?
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0.percent)%" } ?? "—")
                .monospacedDigit()
                .foregroundStyle(value.map(metricColor) ?? .secondary)
        }
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
    }

    private func metricColor(_ metric: CodexQuotaOverlayMetric) -> Color {
        switch metric.severity {
        case .healthy:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}
