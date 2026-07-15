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

    @Test("phase-less gesture stays armed only within its active burst")
    func phaseLessGestureBeforeGeometryWithinBurst() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 10)

        gate.expirePhaseLessGesture(at: 10.1)
        gate.updateFooterVisibility(true)
        let didLoad = gate.consumeIfEligible()
        #expect(didLoad)
    }

    @Test("phase-less intent expires before a later footer layout")
    func phaseLessIntentExpiresBeforeFooterLayout() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 20)

        gate.expirePhaseLessGesture(at: 20.251)
        gate.updateFooterVisibility(true)
        let didLoad = gate.consumeIfEligible()
        #expect(!didLoad)
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

    @Test("outside phased origin stays quarantined when the pointer enters")
    func outsidePhasedOriginStaysQuarantined() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: false,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 54)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .changed,
            momentumPhase: .none,
            timestamp: 54.1)

        let didLoadContinuation = gate.consumeIfEligible()
        #expect(!didLoadContinuation)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 54.2)
        let didLoadAtEnd = gate.consumeIfEligible()
        #expect(!didLoadAtEnd)
        gate.finishWheelEvent(
            windowMatches: true,
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 55)
        let didLoadNewOrigin = gate.consumeIfEligible()
        #expect(didLoadNewOrigin)
    }

    @Test("wrong-window origin cannot promote an orphan inside continuation")
    func wrongWindowOriginCannotPromoteContinuation() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            windowMatches: false,
            isInsideScrollView: false,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 56)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .changed,
            momentumPhase: .none,
            timestamp: 56.1)

        let didLoadOrphanContinuation = gate.consumeIfEligible()
        #expect(!didLoadOrphanContinuation)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 57)
        let didLoadObservedOrigin = gate.consumeIfEligible()
        #expect(didLoadObservedOrigin)
    }

    @Test("same-window outside momentum restores its inside origin once")
    func outsideMomentumRestoresInsideOrigin() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 58)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: false,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 58.1)
        gate.finishWheelEvent(
            windowMatches: true,
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)
        gate.updateFooterVisibility(true)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: false,
            downwardIntent: false,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 58.2)
        let didLoadMomentum = gate.consumeIfEligible()
        #expect(didLoadMomentum)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: false,
            downwardIntent: false,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 58.3)
        let didLoadFurtherMomentum = gate.consumeIfEligible()
        #expect(!didLoadFurtherMomentum)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: false,
            downwardIntent: false,
            phase: .none,
            momentumPhase: .ended,
            timestamp: 58.4)
        gate.finishWheelEvent(
            windowMatches: true,
            isInsideScrollView: false,
            phase: .none,
            momentumPhase: .ended)
        gate.registerLiveMovement(isDownward: true)
        let didLoadAfterTerminal = gate.consumeIfEligible()
        #expect(didLoadAfterTerminal)
    }

    @Test("wrong-window momentum cannot mutate a pending inside origin")
    func wrongWindowMomentumCannotMutateInsideOrigin() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 59)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: false,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 59.1)
        gate.finishWheelEvent(
            windowMatches: true,
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)
        gate.updateFooterVisibility(true)

        gate.registerWheel(
            windowMatches: false,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 59.2)
        let didLoadWrongWindow = gate.consumeIfEligible()
        #expect(!didLoadWrongWindow)
        gate.finishWheelEvent(
            windowMatches: false,
            isInsideScrollView: true,
            phase: .none,
            momentumPhase: .ended)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: false,
            downwardIntent: false,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 59.3)
        let didLoadBoundOrigin = gate.consumeIfEligible()
        #expect(didLoadBoundOrigin)
    }

    @Test("phase-less burst latches its first event scope until idle")
    func phaseLessBurstLatchesFirstEventScope() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: false,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 59.5)
        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 59.6)

        let didLoadContinuation = gate.consumeIfEligible()
        #expect(!didLoadContinuation)

        gate.registerWheel(
            windowMatches: true,
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 59.851)
        let didLoadAfterIdle = gate.consumeIfEligible()
        #expect(didLoadAfterIdle)
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

    @Test("availability transition quarantines already armed intent")
    func availabilityTransitionQuarantinesIntent() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 65)

        gate.updateAvailability(isEnabled: true, isLoading: true)
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        let didLoadAfterLoading = gate.consumeIfEligible()
        #expect(!didLoadAfterLoading)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 66)
        let didLoadNewGesture = gate.consumeIfEligible()
        #expect(didLoadNewGesture)
    }

    @Test("phased gesture begun while loading stays quarantined")
    func loadingPhasedGestureStaysQuarantined() {
        var gate = HistoryScrollLoadGate()
        gate.updateFooterVisibility(true)
        gate.updateAvailability(isEnabled: true, isLoading: true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 70)

        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .changed,
            momentumPhase: .none,
            timestamp: 70.1)
        let didLoadContinuation = gate.consumeIfEligible()
        #expect(!didLoadContinuation)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 71)
        let didLoadNewGesture = gate.consumeIfEligible()
        #expect(didLoadNewGesture)
    }

    @Test("phase-less continuation after loading stays quarantined until idle")
    func loadingPhaseLessGestureStaysQuarantined() {
        var gate = HistoryScrollLoadGate()
        gate.updateFooterVisibility(true)
        gate.updateAvailability(isEnabled: true, isLoading: true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 80)

        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 80.1)
        let didLoadContinuation = gate.consumeIfEligible()
        #expect(!didLoadContinuation)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 80.351)
        let didLoadAfterIdle = gate.consumeIfEligible()
        #expect(didLoadAfterIdle)
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

    @Test("terminal phased event remains eligible through final evaluation")
    func terminalEventEvaluatesBeforeClosing() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 90)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 90.1)
        gate.updateFooterVisibility(true)

        let didLoadAtTerminalGeometry = gate.consumeIfEligible()
        #expect(didLoadAtTerminalGeometry)
        gate.finishWheelEvent(
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)
    }

    @Test("ended and cancelled phases close stale wheel intent")
    func phasedTerminalEventsCloseIntent() {
        for terminal in [HistoryScrollPhase.ended, .cancelled] {
            var gate = HistoryScrollLoadGate()
            gate.updateAvailability(isEnabled: true, isLoading: false)
            gate.registerWheel(
                isInsideScrollView: true,
                downwardIntent: true,
                phase: .began,
                momentumPhase: .none,
                timestamp: 100)
            gate.finishWheelEvent(
                isInsideScrollView: true,
                phase: terminal,
                momentumPhase: .none)
            gate.updateFooterVisibility(true)

            let didLoadAfterTerminal = gate.consumeIfEligible()
            #expect(!didLoadAfterTerminal)
        }
    }

    @Test("terminal outside bounds still closes an originating gesture")
    func outsideTerminalClosesOriginatingGesture() {
        for terminal in [HistoryScrollPhase.ended, .cancelled] {
            var gate = HistoryScrollLoadGate()
            gate.updateAvailability(isEnabled: true, isLoading: false)
            gate.registerWheel(
                isInsideScrollView: true,
                downwardIntent: true,
                phase: .began,
                momentumPhase: .none,
                timestamp: 105)
            gate.finishWheelEvent(
                isInsideScrollView: false,
                phase: terminal,
                momentumPhase: .none)
            gate.updateFooterVisibility(true)

            let didLoadAfterTerminal = gate.consumeIfEligible()
            #expect(!didLoadAfterTerminal)
            gate.beginLiveScroll()
            gate.registerLiveMovement(isDownward: true)
            let didLoadLiveScroll = gate.consumeIfEligible()
            #expect(didLoadLiveScroll)
        }
    }

    @Test("orphan momentum cannot create a generation and live scroll can")
    func orphanMomentumThenLiveScroll() {
        for terminal in [HistoryScrollPhase.ended, .cancelled] {
            var gate = HistoryScrollLoadGate()
            gate.updateAvailability(isEnabled: true, isLoading: false)
            gate.updateFooterVisibility(true)
            gate.registerWheel(
                isInsideScrollView: true,
                downwardIntent: true,
                phase: .none,
                momentumPhase: terminal,
                timestamp: 110.1)
            let didLoadMomentum = gate.consumeIfEligible()
            #expect(!didLoadMomentum)
            gate.finishWheelEvent(
                isInsideScrollView: true,
                phase: .none,
                momentumPhase: terminal)

            gate.beginLiveScroll()
            gate.registerLiveMovement(isDownward: true)
            let didLoadLiveScroll = gate.consumeIfEligible()
            #expect(didLoadLiveScroll)
        }
    }

    @Test("momentum resumes its pending phased generation exactly once")
    func momentumResumesPendingGeneration() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 115)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 115.1)
        gate.finishWheelEvent(
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)

        gate.updateFooterVisibility(true)
        let didLoadFromUnrelatedLayout = gate.consumeIfEligible()
        #expect(!didLoadFromUnrelatedLayout)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 115.2)
        let didLoadMomentum = gate.consumeIfEligible()
        #expect(didLoadMomentum)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 115.3)
        let didLoadFurtherMomentum = gate.consumeIfEligible()
        #expect(!didLoadFurtherMomentum)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .ended,
            timestamp: 115.4)
        gate.finishWheelEvent(
            isInsideScrollView: true,
            phase: .none,
            momentumPhase: .ended)

        gate.beginLiveScroll()
        gate.registerLiveMovement(isDownward: true)
        let didLoadLiveScroll = gate.consumeIfEligible()
        #expect(didLoadLiveScroll)
    }

    @Test("new live-scroll start supersedes a pending wheel without momentum")
    func liveScrollStartSupersedesPendingWheel() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 116)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 116.1)
        gate.finishWheelEvent(
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)

        gate.beginLiveScroll()
        gate.registerLiveMovement(isDownward: true)
        gate.updateFooterVisibility(true)
        let didLoadLiveScroll = gate.consumeIfEligible()
        #expect(didLoadLiveScroll)
    }

    @Test("live movement without a new start resumes the pending wheel")
    func liveMovementResumesPendingWheel() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 116.5)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 116.6)
        gate.finishWheelEvent(
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)
        gate.updateFooterVisibility(true)

        gate.registerLiveMovement(isDownward: true)
        let didLoadFinalGeometry = gate.consumeIfEligible()
        #expect(didLoadFinalGeometry)
        gate.registerLiveMovement(isDownward: true)
        let didLoadAgain = gate.consumeIfEligible()
        #expect(!didLoadAgain)
    }

    @Test("momentum restores originating downward intent when its delta is zero")
    func momentumRestoresOriginatingIntent() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 117)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: false,
            phase: .ended,
            momentumPhase: .none,
            timestamp: 117.1)
        gate.finishWheelEvent(
            isInsideScrollView: true,
            phase: .ended,
            momentumPhase: .none)
        gate.updateFooterVisibility(true)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: false,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 117.2)
        let didLoadMomentum = gate.consumeIfEligible()
        #expect(didLoadMomentum)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: false,
            phase: .none,
            momentumPhase: .changed,
            timestamp: 117.3)
        let didLoadFurtherMomentum = gate.consumeIfEligible()
        #expect(!didLoadFurtherMomentum)
    }

    @Test("live scroll direction follows flipped document coordinates")
    func liveScrollDirection() {
        let previous = CGRect(x: 0, y: 100, width: 240, height: 500)
        let increasingY = CGRect(x: 0, y: 120, width: 240, height: 500)
        let decreasingY = CGRect(x: 0, y: 80, width: 240, height: 500)

        #expect(HistoryScrollGeometry.isDownwardDocumentMovement(
            previousVisibleRect: previous,
            currentVisibleRect: increasingY,
            documentIsFlipped: true))
        #expect(!HistoryScrollGeometry.isDownwardDocumentMovement(
            previousVisibleRect: previous,
            currentVisibleRect: decreasingY,
            documentIsFlipped: true))
        #expect(HistoryScrollGeometry.isDownwardDocumentMovement(
            previousVisibleRect: previous,
            currentVisibleRect: decreasingY,
            documentIsFlipped: false))
        #expect(!HistoryScrollGeometry.isDownwardDocumentMovement(
            previousVisibleRect: previous,
            currentVisibleRect: increasingY,
            documentIsFlipped: false))
    }

    @Test("reset clears footer and gesture state but preserves availability")
    func resetGestureState() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .none,
            momentumPhase: .none,
            timestamp: 120)
        #expect(gate.phaseLessExpiryDeadline != nil)

        gate.resetGestureState()
        #expect(gate.phaseLessExpiryDeadline == nil)
        gate.updateFooterVisibility(true)
        let didLoadStaleGesture = gate.consumeIfEligible()
        #expect(!didLoadStaleGesture)

        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 121)
        let didLoadNewGesture = gate.consumeIfEligible()
        #expect(didLoadNewGesture)
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
        #expect(Self.occurrences(of: "MainActor.assumeIsolated", in: source) >= 4)

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
        #expect(source.contains("documentView.isFlipped"))
        #expect(source.contains(
            "HistoryScrollGeometry.isDownwardDocumentMovement"))

        #expect(source.contains("private var phaseLessExpiryTimer: Timer?"))
        #expect(source.contains("Timer.scheduledTimer(withTimeInterval:"))
        #expect(source.contains("gate.expirePhaseLessGesture(at: deadline)"))
        #expect(source.contains("phaseLessExpiryTimer?.invalidate()"))
        #expect(source.contains("ProcessInfo.processInfo.systemUptime"))

        let detach = try Self.sourceSlice(
            source,
            from: "func detach()",
            to: "private func installEventMonitorIfNeeded")
        #expect(detach.contains("cancelPhaseLessExpiry()"))
        #expect(detach.contains("gate.resetGestureState()"))

        let rebind = try Self.sourceSlice(
            source,
            from: "private func rebindIfNeeded()",
            to: "private func removeScrollObservers()")
        let removeObservers = try Self.offset(
            of: "removeScrollObservers()", in: rebind)
        let clearReference = try Self.offset(of: "scrollView = nil", in: rebind)
        let cancelExpiry = try Self.offset(
            of: "cancelPhaseLessExpiry()", in: rebind)
        let resetGate = try Self.offset(of: "gate.resetGestureState()", in: rebind)
        let unwrapCandidate = try Self.offset(
            of: "guard let candidate else { return }", in: rebind)
        let bindCandidate = try Self.offset(of: "scrollView = candidate", in: rebind)
        #expect(removeObservers < clearReference)
        #expect(clearReference < cancelExpiry)
        #expect(cancelExpiry < resetGate)
        #expect(resetGate < unwrapCandidate)
        #expect(unwrapCandidate < bindCandidate)

        let observeWheel = try Self.sourceSlice(
            source,
            from: "private func observeWheel(_ event: NSEvent)",
            to: "private func beginLiveScroll()")
        #expect(observeWheel.contains(
            "let windowMatches = event.window === scrollView.window"))
        #expect(Self.occurrences(
            of: "windowMatches: windowMatches", in: observeWheel) == 3)
        let rejectWrongWindow = try Self.offset(
            of: "guard windowMatches else { return }", in: observeWheel)
        let convertLocation = try Self.offset(
            of: "scrollView.convert(event.locationInWindow, from: nil)",
            in: observeWheel)
        #expect(rejectWrongWindow < convertLocation)
        let refreshGeometry = try Self.offset(
            of: "refreshFooterVisibility()", in: observeWheel)
        let evaluate = try Self.offset(of: "evaluate(at:", in: observeWheel)
        let finishGesture = try Self.offset(
            of: "gate.finishWheelEvent", in: observeWheel)
        #expect(refreshGeometry < evaluate)
        #expect(evaluate < finishGesture)

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

    private static func sourceSlice(
        _ source: String,
        from startSignature: String,
        to endSignature: String
    ) throws -> String {
        let start = try #require(source.range(of: startSignature)?.lowerBound)
        let remainder = source[start...]
        let end = try #require(remainder.range(of: endSignature)?.lowerBound)
        return String(remainder[..<end])
    }

    private static func offset(
        of needle: String,
        in source: String
    ) throws -> String.Index {
        try #require(source.range(of: needle)?.lowerBound)
    }
}
