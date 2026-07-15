import Foundation
import Testing
@testable import QuotaMonitor

@Suite("History pagination scroll bridge")
struct HistoryPaginationScrollBridgeTests {
    @Test("visible footer alone never loads")
    func visibleFooterNeedsGesture() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)

        let didLoad = gate.consumeIfEligible()
        #expect(!didLoad)
    }

    @Test("downward gesture can arrive before footer geometry")
    func gestureBeforeGeometry() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 10)

        let didLoadBeforeGeometry = gate.consumeIfEligible()
        #expect(!didLoadBeforeGeometry)
        gate.updateFooterVisibility(true)
        let didLoadAfterGeometry = gate.consumeIfEligible()
        #expect(didLoadAfterGeometry)
    }

    @Test("one downward gesture generation loads once across momentum")
    func oneLoadPerGesture() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 10)
        let didLoadInitially = gate.consumeIfEligible()
        #expect(didLoadInitially)

        gate.updateAvailability(isEnabled: true, isLoading: true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .changed,
            momentumPhase: .changed,
            timestamp: 10.1)
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .changed,
            momentumPhase: .changed,
            timestamp: 10.2)

        let didLoadFromMomentum = gate.consumeIfEligible()
        #expect(!didLoadFromMomentum)
    }

    @Test("a new phased gesture can load after the prior generation")
    func newPhasedGesture() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 20)
        let didLoadFirstGesture = gate.consumeIfEligible()
        #expect(didLoadFirstGesture)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 20.1)
        let didLoadAtEnd = gate.consumeIfEligible()
        #expect(!didLoadAtEnd)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 21)
        let didLoadSecondGesture = gate.consumeIfEligible()
        #expect(didLoadSecondGesture)
    }

    @Test("phase-less wheels within 100 milliseconds stay in one generation")
    func phaseLessWheelWithinIdleBoundary() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 30)
        let didLoadInitially = gate.consumeIfEligible()
        #expect(didLoadInitially)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 30.1)
        let didLoadRepeatedWheel = gate.consumeIfEligible()
        #expect(!didLoadRepeatedWheel)
    }

    @Test("phase-less wheel after 251 milliseconds starts a new generation")
    func phaseLessWheelAfterIdleBoundary() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 40)
        let didLoadInitially = gate.consumeIfEligible()
        #expect(didLoadInitially)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 40.251)
        let didLoadAfterIdle = gate.consumeIfEligible()
        #expect(didLoadAfterIdle)
    }

    @Test("upward horizontal outside and wrong-window wheel input is ignored")
    func ineligibleWheelInput() {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 500)
        let inside = HistoryScrollGeometry.eventIsInsideScrollView(
            windowMatches: true,
            location: CGPoint(x: 100, y: 100),
            scrollViewBounds: bounds)
        let outside = HistoryScrollGeometry.eventIsInsideScrollView(
            windowMatches: true,
            location: CGPoint(x: 250, y: 100),
            scrollViewBounds: bounds)
        let wrongWindow = HistoryScrollGeometry.eventIsInsideScrollView(
            windowMatches: false,
            location: CGPoint(x: 100, y: 100),
            scrollViewBounds: bounds)
        let upward = HistoryScrollGeometry.hasDownwardIntent(
            deltaX: 0, deltaY: 4)
        let horizontalDominant = HistoryScrollGeometry.hasDownwardIntent(
            deltaX: 5, deltaY: -4)

        #expect(inside)
        #expect(!outside)
        #expect(!wrongWindow)
        #expect(!upward)
        #expect(!horizontalDominant)

        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            isInsideScrollView: inside,
            downwardIntent: upward,
            phase: .began,
            momentumPhase: .none,
            timestamp: 50)
        let didLoadUpward = gate.consumeIfEligible()
        #expect(!didLoadUpward)
        gate.registerWheel(
            isInsideScrollView: inside,
            downwardIntent: horizontalDominant,
            phase: .began,
            momentumPhase: .none,
            timestamp: 51)
        let didLoadHorizontal = gate.consumeIfEligible()
        #expect(!didLoadHorizontal)
        gate.registerWheel(
            isInsideScrollView: outside,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 52)
        let didLoadOutside = gate.consumeIfEligible()
        #expect(!didLoadOutside)
        gate.registerWheel(
            isInsideScrollView: wrongWindow,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 53)
        let didLoadWrongWindow = gate.consumeIfEligible()
        #expect(!didLoadWrongWindow)
    }

    @Test("loading-time and disabled wheel input cannot arm a future load")
    func unavailableWheelInput() {
        var gate = HistoryScrollLoadGate()
        gate.updateFooterVisibility(true)
        gate.updateAvailability(isEnabled: true, isLoading: true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 60)
        gate.updateAvailability(isEnabled: true, isLoading: false)
        let didLoadAfterLoading = gate.consumeIfEligible()
        #expect(!didLoadAfterLoading)

        gate.updateAvailability(isEnabled: false, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 61)
        gate.updateAvailability(isEnabled: true, isLoading: false)
        let didLoadAfterDisabled = gate.consumeIfEligible()
        #expect(!didLoadAfterDisabled)
    }

    @Test("scrollbar live scroll needs downward document movement")
    func scrollbarLiveScroll() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.beginLiveScroll()
        let didLoadWithoutMovement = gate.consumeIfEligible()
        #expect(!didLoadWithoutMovement)

        gate.registerLiveMovement(isDownward: false)
        let didLoadUpward = gate.consumeIfEligible()
        #expect(!didLoadUpward)
        gate.registerLiveMovement(isDownward: true)
        let didLoadDownward = gate.consumeIfEligible()
        #expect(didLoadDownward)
        gate.registerLiveMovement(isDownward: true)
        let didLoadRepeatedMovement = gate.consumeIfEligible()
        #expect(!didLoadRepeatedMovement)

        gate.endLiveScroll()
        gate.beginLiveScroll()
        gate.registerLiveMovement(isDownward: true)
        let didLoadSecondLiveScroll = gate.consumeIfEligible()
        #expect(didLoadSecondLiveScroll)
    }

    @Test("footer visibility requires a nonempty intersection")
    func footerGeometry() {
        let visibleRect = CGRect(x: 0, y: 0, width: 240, height: 500)

        #expect(HistoryScrollGeometry.footerIsVisible(
            footerFrame: CGRect(x: 0, y: 480, width: 240, height: 40),
            visibleRect: visibleRect))
        #expect(!HistoryScrollGeometry.footerIsVisible(
            footerFrame: CGRect(x: 0, y: 520, width: 240, height: 40),
            visibleRect: visibleRect))
        #expect(!HistoryScrollGeometry.footerIsVisible(
            footerFrame: .zero,
            visibleRect: visibleRect))
    }

    @Test("bridge source scopes events and removes every lifecycle hook")
    func bridgeLifecycleSourceContract() throws {
        let source = try Self.source(named:
            "QuotaMonitor/Features/History/HistoryPaginationScrollBridge.swift")

        #expect(Self.occurrences(
            of: "NSScrollView.willStartLiveScrollNotification", in: source) == 1)
        #expect(Self.occurrences(
            of: "NSScrollView.didLiveScrollNotification", in: source) == 1)
        #expect(Self.occurrences(
            of: "NSScrollView.didEndLiveScrollNotification", in: source) == 1)
        #expect(Self.occurrences(of: "LiveScrollNotification", in: source) == 3)
        #expect(Self.occurrences(of: "object: candidate", in: source) == 3)
        #expect(Self.occurrences(of: "MainActor.assumeIsolated", in: source) == 3)

        #expect(source.contains(
            "NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)"))
        #expect(source.contains("NSEvent.removeMonitor(eventMonitor)"))
        #expect(source.contains("NotificationCenter.default.removeObserver(token)"))
        #expect(source.contains("return event"))

        #expect(source.contains("event.window === scrollView.window"))
        #expect(source.contains(
            "scrollView.convert(event.locationInWindow, from: nil)"))
        #expect(source.contains("scrollViewBounds: scrollView.bounds"))
        #expect(source.contains("scrollView.documentVisibleRect"))
        #expect(source.contains("probe.convert(probe.bounds, to: documentView)"))

        #expect(!source.contains("NSView.boundsDidChangeNotification"))
        #expect(!source.contains("object: nil"))
    }

    private static func source(named relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
