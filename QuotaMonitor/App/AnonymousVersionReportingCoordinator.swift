import Foundation

enum AnonymousVersionReportingDisclosureChoice: Sendable {
    case allow
    case notNow
}

struct AnonymousVersionReportingState: Equatable, Sendable {
    let consent: AnonymousVersionReportingConsent
    let hasCompletedOnboarding: Bool
    let isQARequested: Bool
    let context: DailyActiveReportingContext?

    var permitsReporting: Bool {
        consent == .enabled
            && hasCompletedOnboarding
            && !isQARequested
            && context != nil
    }

    var permitsDisclosure: Bool {
        consent == .undecided
            && hasCompletedOnboarding
            && !isQARequested
            && context != nil
    }
}

private final class AnonymousVersionReportingCoordinatorControl: @unchecked Sendable {
    private let lock = NSLock()
    private var disclosureInFlight = false
    private var terminated = false

    var isDisclosureInFlight: Bool {
        get { lock.withLock { disclosureInFlight } }
        set { lock.withLock { disclosureInFlight = newValue } }
    }

    var isTerminated: Bool {
        get { lock.withLock { terminated } }
        set { lock.withLock { terminated = newValue } }
    }
}

@MainActor
final class AnonymousVersionReportingCoordinator: NSObject {
    typealias CurrentState = @MainActor () -> AnonymousVersionReportingState
    typealias ReporterAction = @Sendable () async -> Void
    typealias Suppress = @Sendable (Date) async -> Void
    typealias PresentDisclosure = @MainActor () async
        -> AnonymousVersionReportingDisclosureChoice
    typealias ScheduledOperation = @MainActor @Sendable () -> Void
    typealias ScheduleNextTick = @MainActor (
        @escaping ScheduledOperation
    ) -> Void

    private enum Transition: Sendable {
        case evaluate
        case consentChanged(AnonymousVersionReportingConsentChange)
    }

    private let settings: SettingsStore
    private let currentState: CurrentState
    private let startReporter: ReporterAction
    private let stopReporter: ReporterAction
    private let suppressUntilNextUTCDay: Suppress
    private let presentDisclosure: PresentDisclosure
    private let notificationCenter: NotificationCenter
    private let scheduleNextTick: ScheduleNextTick
    private let control = AnonymousVersionReportingCoordinatorControl()

    private var transitionTail: Task<Void, Never>?
    private var enqueuedSequence: UInt = 0

    init(
        settings: SettingsStore,
        currentState: @escaping CurrentState,
        startReporter: @escaping ReporterAction,
        stopReporter: @escaping ReporterAction,
        suppressUntilNextUTCDay: @escaping Suppress,
        presentDisclosure: @escaping PresentDisclosure,
        notificationCenter: NotificationCenter = .default,
        scheduleNextTick: @escaping ScheduleNextTick = { operation in
            DispatchQueue.main.async(execute: operation)
        }
    ) {
        self.settings = settings
        self.currentState = currentState
        self.startReporter = startReporter
        self.stopReporter = stopReporter
        self.suppressUntilNextUTCDay = suppressUntilNextUTCDay
        self.presentDisclosure = presentDisclosure
        self.notificationCenter = notificationCenter
        self.scheduleNextTick = scheduleNextTick
        super.init()
        notificationCenter.addObserver(
            self,
            selector: #selector(consentChanged(_:)),
            name: .quotaMonitorAnonymousVersionReportingConsentChanged,
            object: nil)
    }

    deinit {
        control.isTerminated = true
        transitionTail?.cancel()
        notificationCenter.removeObserver(self)
    }

    func launch() {
        scheduleEvaluationOnNextTick()
    }

    func onboardingCompleted() {
        scheduleEvaluationOnNextTick()
    }

    func terminate() {
        guard !control.isTerminated else { return }
        control.isTerminated = true
        notificationCenter.removeObserver(self)
        enqueuedSequence &+= 1
        let previous = transitionTail
        let stopReporter = self.stopReporter
        // Do not race a cancellation-ignoring start. The final stop is part of
        // the same FIFO tail, so even a suspended old start must finish before
        // termination leaves the reporter stopped.
        transitionTail = Task {
            await previous?.value
            await stopReporter()
        }
    }

    func waitForIdle() async {
        while true {
            let observedSequence = enqueuedSequence
            let observedTail = transitionTail
            await observedTail?.value
            if observedSequence == enqueuedSequence {
                return
            }
        }
    }

    @objc private func consentChanged(_ notification: Notification) {
        guard !control.isTerminated,
              let change = notification.object as? AnonymousVersionReportingConsentChange
        else {
            return
        }
        enqueue(.consentChanged(change))
    }

    private func scheduleEvaluationOnNextTick() {
        guard !control.isTerminated else { return }
        scheduleNextTick { [weak self] in
            guard let self, !self.control.isTerminated else { return }
            self.enqueue(.evaluate)
        }
    }

    private func enqueue(_ transition: Transition) {
        guard !control.isTerminated else { return }
        enqueuedSequence &+= 1
        let previous = transitionTail
        let control = self.control
        let settings = self.settings
        let currentState = self.currentState
        let startReporter = self.startReporter
        let stopReporter = self.stopReporter
        let suppressUntilNextUTCDay = self.suppressUntilNextUTCDay
        let presentDisclosure = self.presentDisclosure
        transitionTail = Task { @MainActor in
            await previous?.value
            await Self.process(
                transition,
                control: control,
                settings: settings,
                currentState: currentState,
                startReporter: startReporter,
                stopReporter: stopReporter,
                suppressUntilNextUTCDay: suppressUntilNextUTCDay,
                presentDisclosure: presentDisclosure)
        }
    }

    private static func process(
        _ transition: Transition,
        control: AnonymousVersionReportingCoordinatorControl,
        settings: SettingsStore,
        currentState: CurrentState,
        startReporter: ReporterAction,
        stopReporter: ReporterAction,
        suppressUntilNextUTCDay: Suppress,
        presentDisclosure: PresentDisclosure
    ) async {
        switch transition {
        case .evaluate:
            await evaluateCurrentState(
                control: control,
                settings: settings,
                currentState: currentState,
                startReporter: startReporter,
                presentDisclosure: presentDisclosure)
        case .consentChanged(let change):
            await applyConsentChange(
                change,
                control: control,
                currentState: currentState,
                startReporter: startReporter,
                stopReporter: stopReporter,
                suppressUntilNextUTCDay: suppressUntilNextUTCDay)
        }
    }

    private static func evaluateCurrentState(
        control: AnonymousVersionReportingCoordinatorControl,
        settings: SettingsStore,
        currentState: CurrentState,
        startReporter: ReporterAction,
        presentDisclosure: PresentDisclosure
    ) async {
        guard !control.isTerminated else { return }
        let state = currentState()
        if state.permitsReporting {
            await startReporter()
            return
        }
        guard state.permitsDisclosure, !control.isDisclosureInFlight else { return }

        control.isDisclosureInFlight = true
        let choice = await presentDisclosure()
        control.isDisclosureInFlight = false

        // Presentation can suspend while onboarding, QA, packaging metadata,
        // consent, or termination changes. Never apply a stale answer.
        guard !control.isTerminated, currentState().permitsDisclosure else { return }
        switch choice {
        case .allow:
            settings.setAnonymousVersionReportingConsent(.enabled)
        case .notNow:
            settings.setAnonymousVersionReportingConsent(.disabled)
        }
    }

    private static func applyConsentChange(
        _ change: AnonymousVersionReportingConsentChange,
        control: AnonymousVersionReportingCoordinatorControl,
        currentState: CurrentState,
        startReporter: ReporterAction,
        stopReporter: ReporterAction,
        suppressUntilNextUTCDay: Suppress
    ) async {
        switch change.consent {
        case .disabled:
            // FIFO ordering is deliberate: revoke transport permission first,
            // then persist the captured click day's suppression boundary.
            await stopReporter()
            await suppressUntilNextUTCDay(change.changedAt)

        case .enabled:
            guard !control.isTerminated else { return }
            if currentState().permitsReporting {
                await startReporter()
            } else {
                await stopReporter()
            }

        case .undecided:
            await stopReporter()
        }
    }
}
