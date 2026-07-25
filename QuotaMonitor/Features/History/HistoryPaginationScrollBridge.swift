import AppKit
import SwiftUI

// The gesture-aware footer probe was introduced for History, but its callback
// contract is list-agnostic and is also used by Sessions pagination.
typealias PaginationScrollBridge = HistoryPaginationScrollBridge

enum HistoryScrollPhase: Equatable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

struct HistoryScrollGeometry {
    private static let viewportFillTolerance: CGFloat = 1

    static func footerIsVisible(footerFrame: CGRect, visibleRect: CGRect) -> Bool {
        !footerFrame.isEmpty && footerFrame.intersects(visibleRect)
    }

    static func documentUnderfillsViewport(
        documentFrame: CGRect,
        visibleRect: CGRect
    ) -> Bool {
        !documentFrame.isEmpty &&
            visibleRect.height > 0 &&
            documentFrame.height <= visibleRect.height + viewportFillTolerance
    }

    static func eventIsInsideScrollView(
        windowMatches: Bool,
        location: CGPoint,
        scrollViewBounds: CGRect
    ) -> Bool {
        windowMatches && scrollViewBounds.contains(location)
    }

    static func hasDownwardIntent(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        let downward = -deltaY
        return downward > 0 && downward > abs(deltaX)
    }

    static func isDownwardDocumentMovement(
        previousVisibleRect: CGRect,
        currentVisibleRect: CGRect,
        documentIsFlipped: Bool
    ) -> Bool {
        if documentIsFlipped {
            return currentVisibleRect.minY > previousVisibleRect.minY
        }
        return currentVisibleRect.minY < previousVisibleRect.minY
    }
}

struct HistoryScrollLoadGate {
    static let phaseLessIdleInterval: TimeInterval = 0.250

    private enum GestureKind {
        case phasedWheel
        case phaseLessWheel
        case liveScroll
    }

    private var generation = 0
    private var activeGeneration: Int?
    private var consumedGeneration: Int?
    private var activeGestureKind: GestureKind?
    private var activeGenerationIsConsumable = false
    private var pendingMomentumGeneration: Int?
    private var pendingMomentumIsConsumable = false
    private var pendingMomentumHasDownwardIntent = false
    private var lastPhaseLessWheelAt: TimeInterval?
    private var footerVisible = false
    private var isEnabled = false
    private var isLoading = false
    private var hasDownwardIntent = false

    var phaseLessExpiryDeadline: TimeInterval? {
        guard activeGestureKind == .phaseLessWheel,
              let lastPhaseLessWheelAt else { return nil }
        return lastPhaseLessWheelAt + Self.phaseLessIdleInterval
    }

    mutating func updateAvailability(isEnabled: Bool, isLoading: Bool) {
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        guard isEnabled, !isLoading else {
            if activeGeneration != nil {
                quarantineActiveGeneration()
            }
            pendingMomentumIsConsumable = false
            pendingMomentumHasDownwardIntent = false
            return
        }
    }

    mutating func updateFooterVisibility(_ visible: Bool) {
        footerVisible = visible
    }

    mutating func registerWheel(
        windowMatches: Bool = true,
        isInsideScrollView: Bool,
        downwardIntent: Bool,
        phase: HistoryScrollPhase,
        momentumPhase: HistoryScrollPhase,
        timestamp: TimeInterval
    ) {
        guard windowMatches else { return }
        let isAvailable = isEnabled && !isLoading

        if momentumPhase != .none {
            if activeGeneration == nil {
                guard resumePendingMomentumGeneration() else { return }
            }
            updateIntent(
                isAvailable: isAvailable,
                downwardIntent: isInsideScrollView && downwardIntent)
            return
        }

        let isPhaseLess = phase == .none && momentumPhase == .none
        if isPhaseLess {
            let startsNewBurst = activeGestureKind != .phaseLessWheel ||
                lastPhaseLessWheelAt.map {
                    timestamp - $0 > Self.phaseLessIdleInterval
                } ?? true
            if startsNewBurst {
                startGeneration(
                    kind: .phaseLessWheel,
                    isConsumable: isAvailable && isInsideScrollView)
            }
            lastPhaseLessWheelAt = timestamp
            updateIntent(
                isAvailable: isAvailable,
                downwardIntent: isInsideScrollView && downwardIntent)
            return
        }

        if phase == .began {
            startGeneration(
                kind: .phasedWheel,
                isConsumable: isAvailable && isInsideScrollView)
        } else if activeGeneration == nil {
            return
        }
        updateIntent(
            isAvailable: isAvailable,
            downwardIntent: isInsideScrollView && downwardIntent)
    }

    mutating func finishWheelEvent(
        windowMatches: Bool = true,
        isInsideScrollView _: Bool,
        phase: HistoryScrollPhase,
        momentumPhase: HistoryScrollPhase
    ) {
        guard windowMatches else { return }
        if momentumPhase == .ended || momentumPhase == .cancelled ||
           phase == .cancelled {
            closeActiveGesture()
        } else if phase == .ended, momentumPhase == .none {
            suspendActiveGestureForMomentum()
        }
    }

    mutating func expirePhaseLessGesture(at timestamp: TimeInterval) {
        guard let deadline = phaseLessExpiryDeadline,
              timestamp > deadline else { return }
        closeActiveGesture()
    }

    mutating func beginLiveScroll() {
        let isAvailable = isEnabled && !isLoading
        if activeGeneration == nil {
            startGeneration(kind: .liveScroll, isConsumable: isAvailable)
        } else if !isAvailable {
            quarantineActiveGeneration()
        }
    }

    mutating func registerLiveMovement(isDownward: Bool) {
        let isAvailable = isEnabled && !isLoading
        if activeGeneration == nil {
            if pendingMomentumGeneration != nil {
                guard resumePendingMomentumGeneration() else { return }
            } else {
                startGeneration(kind: .liveScroll, isConsumable: isAvailable)
            }
        }
        updateIntent(
            isAvailable: isAvailable,
            downwardIntent: isDownward)
    }

    mutating func endLiveScroll() {
        closeActiveGesture()
    }

    mutating func consumeIfEligible() -> Bool {
        guard isEnabled, !isLoading, footerVisible, hasDownwardIntent,
              activeGenerationIsConsumable,
              let activeGeneration,
              consumedGeneration != activeGeneration else { return false }
        consumedGeneration = activeGeneration
        return true
    }

    mutating func resetGestureState() {
        generation = 0
        activeGeneration = nil
        consumedGeneration = nil
        activeGestureKind = nil
        activeGenerationIsConsumable = false
        pendingMomentumGeneration = nil
        pendingMomentumIsConsumable = false
        pendingMomentumHasDownwardIntent = false
        lastPhaseLessWheelAt = nil
        footerVisible = false
        hasDownwardIntent = false
    }

    private mutating func startGeneration(
        kind: GestureKind,
        isConsumable: Bool
    ) {
        generation &+= 1
        activeGeneration = generation
        activeGestureKind = kind
        activeGenerationIsConsumable = isConsumable
        pendingMomentumGeneration = nil
        pendingMomentumIsConsumable = false
        pendingMomentumHasDownwardIntent = false
        lastPhaseLessWheelAt = nil
        hasDownwardIntent = false
    }

    private mutating func updateIntent(
        isAvailable: Bool,
        downwardIntent: Bool
    ) {
        guard activeGeneration != nil else { return }
        guard isAvailable else {
            quarantineActiveGeneration()
            return
        }
        guard activeGenerationIsConsumable, downwardIntent else { return }
        hasDownwardIntent = true
    }

    private mutating func quarantineActiveGeneration() {
        activeGenerationIsConsumable = false
        hasDownwardIntent = false
    }

    private mutating func closeActiveGesture() {
        activeGeneration = nil
        activeGestureKind = nil
        activeGenerationIsConsumable = false
        pendingMomentumGeneration = nil
        pendingMomentumIsConsumable = false
        pendingMomentumHasDownwardIntent = false
        lastPhaseLessWheelAt = nil
        hasDownwardIntent = false
    }

    private mutating func suspendActiveGestureForMomentum() {
        guard activeGestureKind == .phasedWheel,
              let activeGeneration else {
            closeActiveGesture()
            return
        }
        pendingMomentumGeneration = activeGeneration
        pendingMomentumIsConsumable = activeGenerationIsConsumable
        pendingMomentumHasDownwardIntent = hasDownwardIntent
        self.activeGeneration = nil
        activeGestureKind = nil
        activeGenerationIsConsumable = false
        hasDownwardIntent = false
    }

    private mutating func resumePendingMomentumGeneration() -> Bool {
        guard let pendingMomentumGeneration else { return false }
        activeGeneration = pendingMomentumGeneration
        activeGestureKind = .phasedWheel
        activeGenerationIsConsumable = pendingMomentumIsConsumable
        hasDownwardIntent = pendingMomentumHasDownwardIntent
        self.pendingMomentumGeneration = nil
        pendingMomentumIsConsumable = false
        pendingMomentumHasDownwardIntent = false
        return true
    }
}

@MainActor
final class FooterProbeView: NSView {
    var hierarchyDidChange: (() -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hierarchyDidChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hierarchyDidChange?()
    }
}

struct HistoryPaginationScrollBridge: NSViewRepresentable {
    let isEnabled: Bool
    let isLoading: Bool
    let canFillViewport: Bool
    let onViewportFill: @MainActor () -> Void
    let onLoadMore: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onViewportFill: onViewportFill,
            onLoadMore: onLoadMore)
    }

    func makeNSView(context: Context) -> FooterProbeView {
        let view = FooterProbeView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: FooterProbeView, context: Context) {
        context.coordinator.update(
            probe: view,
            isEnabled: isEnabled,
            isLoading: isLoading,
            canFillViewport: canFillViewport,
            onViewportFill: onViewportFill,
            onLoadMore: onLoadMore)
    }

    static func dismantleNSView(
        _ view: FooterProbeView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }
}

extension HistoryPaginationScrollBridge {
    @MainActor
    final class Coordinator {
        private static let phaseLessExpiryBoundaryDelay: TimeInterval = 0.001

        private weak var probe: FooterProbeView?
        private weak var scrollView: NSScrollView?
        private weak var observedDocumentView: NSView?
        private var eventMonitor: Any?
        private var notificationTokens: [NSObjectProtocol] = []
        private var phaseLessExpiryTimer: Timer?
        private var scheduledPhaseLessExpiry: TimeInterval?
        private var viewportFillEvaluationScheduled = false
        private var gate = HistoryScrollLoadGate()
        private var lastVisibleRect = CGRect.zero
        private var isEnabled = false
        private var isLoading = false
        private var canFillViewport = false
        private var onViewportFill: @MainActor () -> Void
        private var onLoadMore: @MainActor () -> Void

        init(
            onViewportFill: @escaping @MainActor () -> Void,
            onLoadMore: @escaping @MainActor () -> Void
        ) {
            self.onViewportFill = onViewportFill
            self.onLoadMore = onLoadMore
        }

        func attach(to probe: FooterProbeView) {
            self.probe = probe
            probe.hierarchyDidChange = { [weak self, weak probe] in
                guard let probe else { return }
                self?.probe = probe
                self?.rebindIfNeeded()
            }
            installEventMonitorIfNeeded()
            rebindIfNeeded()
        }

        func update(
            probe: FooterProbeView,
            isEnabled: Bool,
            isLoading: Bool,
            canFillViewport: Bool,
            onViewportFill: @escaping @MainActor () -> Void,
            onLoadMore: @escaping @MainActor () -> Void
        ) {
            self.probe = probe
            self.isEnabled = isEnabled
            self.isLoading = isLoading
            self.canFillViewport = canFillViewport
            self.onViewportFill = onViewportFill
            self.onLoadMore = onLoadMore
            gate.updateAvailability(isEnabled: isEnabled, isLoading: isLoading)
            installEventMonitorIfNeeded()
            rebindIfNeeded()
            refreshFooterVisibility()
            let timestamp = ProcessInfo.processInfo.systemUptime
            evaluate(at: timestamp)
            synchronizePhaseLessExpiry(referenceTimestamp: timestamp)
            scheduleViewportFillEvaluation()
        }

        func detach() {
            probe?.hierarchyDidChange = nil
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            removeScrollObservers()
            scrollView = nil
            observedDocumentView = nil
            cancelPhaseLessExpiry()
            gate.resetGestureState()
            lastVisibleRect = .zero
            isEnabled = false
            isLoading = false
            canFillViewport = false
            probe = nil
        }

        private func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.observeWheel(event)
                return event
            }
        }

        private func rebindIfNeeded() {
            guard let probe else { return }
            var ancestor: NSView? = probe
            var candidate: NSScrollView?
            while let view = ancestor {
                if let found = view as? NSScrollView {
                    candidate = found
                    break
                }
                ancestor = view.superview
            }
            let bindingIsUnchanged = scrollView === candidate &&
                observedDocumentView === candidate?.documentView &&
                (candidate != nil || notificationTokens.isEmpty)
            guard !bindingIsUnchanged else { return }

            removeScrollObservers()
            scrollView = nil
            observedDocumentView = nil
            cancelPhaseLessExpiry()
            gate.resetGestureState()
            lastVisibleRect = .zero

            guard let candidate else { return }
            scrollView = candidate
            observedDocumentView = candidate.documentView
            lastVisibleRect = candidate.documentVisibleRect
            let center = NotificationCenter.default
            let clipView = candidate.contentView
            clipView.postsBoundsChangedNotifications = true
            candidate.documentView?.postsFrameChangedNotifications = true
            var tokens = [
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: candidate,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.beginLiveScroll() }
                    },
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: candidate,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.observeLiveScroll() }
                    },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: candidate,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.endLiveScroll() }
                    },
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.geometryDidChange() }
                    },
            ]
            if let documentView = candidate.documentView {
                tokens.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.geometryDidChange() }
                    })
            }
            notificationTokens = tokens
        }

        private func removeScrollObservers() {
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
        }

        private func synchronizePhaseLessExpiry(referenceTimestamp: TimeInterval) {
            let deadline = gate.phaseLessExpiryDeadline
            guard scheduledPhaseLessExpiry != deadline else { return }
            cancelPhaseLessExpiry()
            guard let deadline else { return }

            scheduledPhaseLessExpiry = deadline
            let delay = max(deadline - referenceTimestamp, 0) +
                Self.phaseLessExpiryBoundaryDelay
            phaseLessExpiryTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                        repeats: false) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.scheduledPhaseLessExpiry == deadline else { return }
                    self.phaseLessExpiryTimer = nil
                    self.scheduledPhaseLessExpiry = nil
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    self.gate.expirePhaseLessGesture(at: timestamp)
                    self.synchronizePhaseLessExpiry(referenceTimestamp: timestamp)
                }
            }
        }

        private func cancelPhaseLessExpiry() {
            phaseLessExpiryTimer?.invalidate()
            phaseLessExpiryTimer = nil
            scheduledPhaseLessExpiry = nil
        }

        private func observeWheel(_ event: NSEvent) {
            guard let scrollView else { return }
            let windowMatches = event.window === scrollView.window
            guard windowMatches else { return }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            let inside = HistoryScrollGeometry.eventIsInsideScrollView(
                windowMatches: windowMatches,
                location: point,
                scrollViewBounds: scrollView.bounds)
            let phase = Self.phase(event.phase)
            let momentumPhase = Self.phase(event.momentumPhase)
            gate.expirePhaseLessGesture(at: event.timestamp)
            gate.registerWheel(
                windowMatches: windowMatches,
                isInsideScrollView: inside,
                downwardIntent: HistoryScrollGeometry.hasDownwardIntent(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY),
                phase: phase,
                momentumPhase: momentumPhase,
                timestamp: event.timestamp)
            refreshFooterVisibility()
            evaluate(at: event.timestamp)
            gate.finishWheelEvent(
                windowMatches: windowMatches,
                isInsideScrollView: inside,
                phase: phase,
                momentumPhase: momentumPhase)
            synchronizePhaseLessExpiry(referenceTimestamp: event.timestamp)
        }

        private func beginLiveScroll() {
            let timestamp = ProcessInfo.processInfo.systemUptime
            gate.expirePhaseLessGesture(at: timestamp)
            lastVisibleRect = scrollView?.documentVisibleRect ?? .zero
            gate.beginLiveScroll()
            synchronizePhaseLessExpiry(referenceTimestamp: timestamp)
        }

        private func observeLiveScroll() {
            guard let scrollView else { return }
            let timestamp = ProcessInfo.processInfo.systemUptime
            gate.expirePhaseLessGesture(at: timestamp)
            let current = scrollView.documentVisibleRect
            let isDownward: Bool
            if let documentView = scrollView.documentView {
                isDownward = HistoryScrollGeometry.isDownwardDocumentMovement(
                    previousVisibleRect: lastVisibleRect,
                    currentVisibleRect: current,
                    documentIsFlipped: documentView.isFlipped)
            } else {
                isDownward = false
            }
            gate.registerLiveMovement(isDownward: isDownward)
            lastVisibleRect = current
            refreshFooterVisibility()
            evaluate(at: timestamp)
            synchronizePhaseLessExpiry(referenceTimestamp: timestamp)
        }

        private func endLiveScroll() {
            gate.endLiveScroll()
            synchronizePhaseLessExpiry(
                referenceTimestamp: ProcessInfo.processInfo.systemUptime)
        }

        private func geometryDidChange() {
            refreshFooterVisibility()
            scheduleViewportFillEvaluation()
        }

        private func refreshFooterVisibility() {
            guard let probe,
                  let scrollView,
                  let documentView = scrollView.documentView else {
                gate.updateFooterVisibility(false)
                return
            }
            gate.updateFooterVisibility(HistoryScrollGeometry.footerIsVisible(
                footerFrame: probe.convert(probe.bounds, to: documentView),
                visibleRect: scrollView.documentVisibleRect))
        }

        private func evaluate(at timestamp: TimeInterval) {
            gate.expirePhaseLessGesture(at: timestamp)
            if gate.consumeIfEligible() {
                onLoadMore()
            }
        }

        private func scheduleViewportFillEvaluation() {
            guard isEnabled, !isLoading, canFillViewport,
                  !viewportFillEvaluationScheduled else { return }
            viewportFillEvaluationScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewportFillEvaluationScheduled = false
                self.evaluateViewportFill()
            }
        }

        private func evaluateViewportFill() {
            guard isEnabled, !isLoading, canFillViewport,
                  let probe,
                  let scrollView,
                  let documentView = scrollView.documentView else { return }
            let visibleRect = scrollView.documentVisibleRect
            let footerFrame = probe.convert(probe.bounds, to: documentView)
            guard HistoryScrollGeometry.footerIsVisible(
                footerFrame: footerFrame,
                visibleRect: visibleRect
            ), HistoryScrollGeometry.documentUnderfillsViewport(
                documentFrame: documentView.bounds,
                visibleRect: visibleRect
            ) else { return }

            canFillViewport = false
            onViewportFill()
        }

        private static func phase(_ phase: NSEvent.Phase) -> HistoryScrollPhase {
            if phase.contains(.began) { return .began }
            if phase.contains(.changed) || phase.contains(.stationary) {
                return .changed
            }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.cancelled) { return .cancelled }
            return .none
        }
    }
}
