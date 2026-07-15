import AppKit
import SwiftUI

enum HistoryScrollPhase: Equatable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

struct HistoryScrollGeometry {
    static func footerIsVisible(footerFrame: CGRect, visibleRect: CGRect) -> Bool {
        !footerFrame.isEmpty && footerFrame.intersects(visibleRect)
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
}

struct HistoryScrollLoadGate {
    static let phaseLessIdleInterval: TimeInterval = 0.250

    private var generation = 0
    private var activeGeneration: Int?
    private var consumedGeneration: Int?
    private var lastPhaseLessWheelAt: TimeInterval?
    private var footerVisible = false
    private var isEnabled = false
    private var isLoading = false
    private var hasDownwardIntent = false

    mutating func updateAvailability(isEnabled: Bool, isLoading: Bool) {
        self.isEnabled = isEnabled
        self.isLoading = isLoading
    }

    mutating func updateFooterVisibility(_ visible: Bool) {
        footerVisible = visible
    }

    mutating func registerWheel(
        isInsideScrollView: Bool,
        downwardIntent: Bool,
        phase: HistoryScrollPhase,
        momentumPhase: HistoryScrollPhase,
        timestamp: TimeInterval
    ) {
        guard isEnabled, !isLoading, isInsideScrollView, downwardIntent else {
            return
        }
        if momentumPhase != .none {
            if activeGeneration == nil, generation > 0 {
                activeGeneration = generation
            }
            hasDownwardIntent = true
            return
        }
        let isPhaseLess = phase == .none && momentumPhase == .none
        if isPhaseLess {
            if lastPhaseLessWheelAt.map({
                timestamp - $0 > Self.phaseLessIdleInterval
            }) ?? true {
                startGeneration()
            } else if activeGeneration == nil, generation > 0 {
                activeGeneration = generation
            }
            lastPhaseLessWheelAt = timestamp
        } else if phase == .began {
            startGeneration()
        } else if activeGeneration == nil {
            if generation == 0 {
                startGeneration()
            } else {
                activeGeneration = generation
            }
        }
        hasDownwardIntent = true
    }

    mutating func beginLiveScroll() {
        guard isEnabled, !isLoading else { return }
        if activeGeneration == nil {
            startGeneration()
        }
    }

    mutating func registerLiveMovement(isDownward: Bool) {
        guard isEnabled, !isLoading, isDownward else { return }
        if activeGeneration == nil {
            startGeneration()
        }
        hasDownwardIntent = true
    }

    mutating func endLiveScroll() {
        activeGeneration = nil
        hasDownwardIntent = false
    }

    mutating func consumeIfEligible() -> Bool {
        guard isEnabled, !isLoading, footerVisible, hasDownwardIntent,
              let activeGeneration,
              consumedGeneration != activeGeneration else { return false }
        consumedGeneration = activeGeneration
        return true
    }

    private mutating func startGeneration() {
        generation &+= 1
        activeGeneration = generation
        hasDownwardIntent = false
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
    let onLoadMore: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadMore: onLoadMore)
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
        private weak var probe: FooterProbeView?
        private weak var scrollView: NSScrollView?
        private var eventMonitor: Any?
        private var notificationTokens: [NSObjectProtocol] = []
        private var gate = HistoryScrollLoadGate()
        private var lastVisibleRect = CGRect.zero
        private var onLoadMore: @MainActor () -> Void

        init(onLoadMore: @escaping @MainActor () -> Void) {
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
            onLoadMore: @escaping @MainActor () -> Void
        ) {
            self.probe = probe
            self.onLoadMore = onLoadMore
            gate.updateAvailability(isEnabled: isEnabled, isLoading: isLoading)
            installEventMonitorIfNeeded()
            rebindIfNeeded()
            refreshFooterVisibility()
            evaluate()
        }

        func detach() {
            probe?.hierarchyDidChange = nil
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            removeScrollObservers()
            probe = nil
            scrollView = nil
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
            guard let candidate, scrollView !== candidate else { return }
            removeScrollObservers()
            scrollView = candidate
            lastVisibleRect = candidate.documentVisibleRect
            let center = NotificationCenter.default
            notificationTokens = [
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
            ]
        }

        private func removeScrollObservers() {
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
        }

        private func observeWheel(_ event: NSEvent) {
            guard let scrollView else { return }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            let inside = HistoryScrollGeometry.eventIsInsideScrollView(
                windowMatches: event.window === scrollView.window,
                location: point,
                scrollViewBounds: scrollView.bounds)
            gate.registerWheel(
                isInsideScrollView: inside,
                downwardIntent: HistoryScrollGeometry.hasDownwardIntent(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY),
                phase: Self.phase(event.phase),
                momentumPhase: Self.phase(event.momentumPhase),
                timestamp: event.timestamp)
            refreshFooterVisibility()
            evaluate()
        }

        private func beginLiveScroll() {
            lastVisibleRect = scrollView?.documentVisibleRect ?? .zero
            gate.beginLiveScroll()
        }

        private func observeLiveScroll() {
            guard let scrollView else { return }
            let current = scrollView.documentVisibleRect
            gate.registerLiveMovement(isDownward: current.maxY > lastVisibleRect.maxY)
            lastVisibleRect = current
            refreshFooterVisibility()
            evaluate()
        }

        private func endLiveScroll() {
            gate.endLiveScroll()
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

        private func evaluate() {
            if gate.consumeIfEligible() {
                onLoadMore()
            }
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
