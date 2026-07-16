import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Anonymous version reporting coordinator")
struct AnonymousVersionReportingCoordinatorTests {
    @Test("Disclosure waits for completed onboarding and the next scheduled tick")
    func disclosureWaitsForOnboarding() async {
        let harness = Harness(consent: .undecided, onboardingComplete: false)
        harness.presenter.choice = .allow

        harness.coordinator.launch()
        harness.scheduler.runAll()
        await harness.coordinator.waitForIdle()

        #expect(harness.presenter.presentationCount == 0)
        #expect(await harness.lifecycle.events == [])

        harness.state.onboardingComplete = true
        harness.coordinator.onboardingCompleted()
        #expect(harness.presenter.presentationCount == 0)

        harness.scheduler.runAll()
        await harness.coordinator.waitForIdle()

        #expect(harness.presenter.presentationCount == 1)
        #expect(harness.settings.anonymousVersionReportingConsent == .enabled)
        #expect(await harness.lifecycle.events == ["start"])
    }

    @Test("Declining stops first and suppresses from the captured choice time")
    func declineStopsThenSuppresses() async {
        let clickedAt = Date(timeIntervalSince1970: 1_784_246_340)
        let harness = Harness(
            consent: .undecided,
            onboardingComplete: true,
            now: clickedAt)
        harness.presenter.choice = .notNow

        harness.coordinator.launch()
        harness.scheduler.runAll()
        await harness.coordinator.waitForIdle()

        #expect(harness.settings.anonymousVersionReportingConsent == .disabled)
        #expect(await harness.lifecycle.events == [
            "stop",
            "suppress:\(clickedAt.timeIntervalSince1970)",
        ])
    }

    @Test("Fast off then on is FIFO and preserves same-day suppression")
    func fastOffOnIsFIFO() async throws {
        let clickedAt = Date(timeIntervalSince1970: 1_784_246_340)
        let harness = Harness(
            consent: .enabled,
            onboardingComplete: true,
            now: clickedAt)

        harness.coordinator.launch()
        harness.scheduler.runAll()
        await harness.coordinator.waitForIdle()
        await harness.lifecycle.clear()

        harness.settings.setAnonymousVersionReportingConsent(.disabled)
        harness.settings.setAnonymousVersionReportingConsent(.enabled)
        await harness.coordinator.waitForIdle()

        #expect(await harness.lifecycle.events == [
            "stop",
            "suppress:\(clickedAt.timeIntervalSince1970)",
            "start",
        ])
    }

    @Test("Fast off then on sends zero requests with the shared real token store")
    func fastOffOnWithReporterSendsNothingSameDay() async throws {
        let suiteName = "AnonymousVersionReportingCoordinatorTests.real.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            AnonymousVersionReportingConsent.enabled.rawValue,
            forKey: SettingsStore.anonymousVersionReportingConsentStorageKey)
        let center = NotificationCenter()
        let date = Date(timeIntervalSince1970: 1_784_202_900)
        let settings = SettingsStore(
            defaults: defaults,
            appVersion: "0.2.41",
            hasExistingAppData: { false },
            notificationCenter: center,
            now: { date })
        let store = DailyActiveTokenStore(
            defaults: DailyActiveUserDefaults(defaults))
        let transport = CountingDailyActiveTransport()
        let sleeper = ReporterPeriodicSleepProbe()
        let context = DailyActiveReportingContext(
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id")
        let reporter = DailyActiveReporter(
            store: store,
            transport: transport,
            now: { date },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { .zero },
            eligibility: {
                await MainActor.run {
                    settings.anonymousVersionReportingConsent == .enabled
                        ? .enabled : .disabled
                }
            },
            context: { context })
        let coordinator = AnonymousVersionReportingCoordinator(
            settings: settings,
            currentState: {
                AnonymousVersionReportingState(
                    consent: settings.anonymousVersionReportingConsent,
                    hasCompletedOnboarding: true,
                    isQARequested: false,
                    context: context)
            },
            startReporter: { await reporter.start() },
            stopReporter: { await reporter.stop() },
            suppressUntilNextUTCDay: { clickedAt in
                await store.suppressUntilNextUTCDay(from: clickedAt)
            },
            presentDisclosure: { .notNow },
            notificationCenter: center)

        settings.setAnonymousVersionReportingConsent(.disabled)
        settings.setAnonymousVersionReportingConsent(.enabled)
        await coordinator.waitForIdle()
        await sleeper.waitForFirstCall()

        #expect(await transport.requestCount == 0)
        #expect(defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) == nil)
        #expect(defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
            == "2026-07-16")

        coordinator.terminate()
        await coordinator.waitForIdle()
    }

    @Test("A transition delayed past midnight still suppresses the click day")
    func delayedTransitionUsesCapturedClickTime() async {
        let beforeMidnight = Date(timeIntervalSince1970: 1_784_246_340)
        let afterMidnight = beforeMidnight.addingTimeInterval(120)
        let harness = Harness(
            consent: .enabled,
            onboardingComplete: true,
            now: beforeMidnight)

        harness.coordinator.launch()
        harness.scheduler.runAll()
        await harness.coordinator.waitForIdle()
        await harness.lifecycle.clear()
        await harness.lifecycle.suspendNextStop()

        harness.settings.setAnonymousVersionReportingConsent(.disabled)
        await harness.lifecycle.waitUntilStopIsSuspended()
        harness.clock.value = afterMidnight
        await harness.lifecycle.resumeStop()
        await harness.coordinator.waitForIdle()

        #expect(await harness.lifecycle.suppressedDates == [beforeMidnight])
    }

    @Test("QA and unavailable App Store context never present or start")
    func ineligibleRuntimeNeverPresentsOrStarts() async {
        let qaHarness = Harness(
            consent: .undecided,
            onboardingComplete: true,
            isQARequested: true)
        qaHarness.coordinator.launch()
        qaHarness.scheduler.runAll()
        await qaHarness.coordinator.waitForIdle()

        #expect(qaHarness.presenter.presentationCount == 0)
        #expect(await qaHarness.lifecycle.events == [])

        let unavailableHarness = Harness(
            consent: .undecided,
            onboardingComplete: true,
            context: nil)
        unavailableHarness.coordinator.launch()
        unavailableHarness.scheduler.runAll()
        await unavailableHarness.coordinator.waitForIdle()

        #expect(unavailableHarness.presenter.presentationCount == 0)
        #expect(await unavailableHarness.lifecycle.events == [])
    }

    @Test("Termination during a suspended disclosure prevents consent and start")
    func terminationDuringDisclosurePreventsStart() async {
        let harness = Harness(consent: .undecided, onboardingComplete: true)
        harness.presenter.suspendNextPresentation()

        harness.coordinator.launch()
        harness.scheduler.runAll()
        await harness.presenter.waitUntilSuspended()

        harness.coordinator.terminate()
        harness.presenter.resume(with: .allow)
        await harness.coordinator.waitForIdle()

        #expect(harness.settings.anonymousVersionReportingConsent == .undecided)
        #expect(await harness.lifecycle.events.contains("start") == false)
        #expect(await harness.lifecycle.events.contains("stop"))
    }

    @Test("Termination queues stop after a cancellation-ignoring suspended start")
    func terminationFinishesWithStopAfterSuspendedStart() async {
        let harness = Harness(consent: .enabled, onboardingComplete: true)
        await harness.lifecycle.suspendNextStart()

        harness.coordinator.launch()
        harness.scheduler.runAll()
        await harness.lifecycle.waitUntilStartIsSuspended()

        harness.coordinator.terminate()
        await harness.lifecycle.resumeStart()
        await harness.coordinator.waitForIdle()

        #expect(await harness.lifecycle.events == ["start", "stop"])
    }

    @Test("A suspended transition does not retain its coordinator")
    func suspendedDisclosureDoesNotRetainCoordinator() async throws {
        let suiteName = "AnonymousVersionReportingCoordinatorTests.release.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let settings = SettingsStore(
            defaults: defaults,
            appVersion: "0.2.41",
            hasExistingAppData: { false },
            notificationCenter: center)
        let scheduler = ManualNextTickScheduler()
        let presenter = DisclosurePresenterProbe()
        presenter.suspendNextPresentation()
        let context = DailyActiveReportingContext(
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id")
        var coordinator: AnonymousVersionReportingCoordinator? =
            AnonymousVersionReportingCoordinator(
                settings: settings,
                currentState: {
                    AnonymousVersionReportingState(
                        consent: settings.anonymousVersionReportingConsent,
                        hasCompletedOnboarding: true,
                        isQARequested: false,
                        context: context)
                },
                startReporter: {},
                stopReporter: {},
                suppressUntilNextUTCDay: { _ in },
                presentDisclosure: { await presenter.present() },
                notificationCenter: center,
                scheduleNextTick: { operation in scheduler.schedule(operation) })
        weak var weakCoordinator = coordinator

        coordinator?.launch()
        scheduler.runAll()
        await presenter.waitUntilSuspended()
        autoreleasepool { coordinator = nil }
        for _ in 0 ..< 100 where weakCoordinator != nil {
            await Task.yield()
        }

        #expect(weakCoordinator == nil)
        presenter.resume(with: .allow)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(settings.anonymousVersionReportingConsent == .undecided)
    }

    @Test("A retained explicit choice starts without showing disclosure after relaunch")
    func retainedChoiceSkipsDisclosure() async {
        let first = Harness(consent: .enabled, onboardingComplete: true)
        let defaults = first.defaults
        let suiteName = first.suiteName
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let relaunched = Harness(
            defaults: defaults,
            suiteName: suiteName,
            onboardingComplete: true)

        relaunched.coordinator.launch()
        relaunched.scheduler.runAll()
        await relaunched.coordinator.waitForIdle()

        #expect(relaunched.presenter.presentationCount == 0)
        #expect(await relaunched.lifecycle.events == ["start"])
    }
}

@MainActor
private final class Harness {
    let defaults: UserDefaults
    let suiteName: String
    let settings: SettingsStore
    let state: CoordinatorStateBox
    let scheduler = ManualNextTickScheduler()
    let lifecycle = CoordinatorLifecycleProbe()
    let presenter = DisclosurePresenterProbe()
    let clock: CoordinatorClock
    let notificationCenter = NotificationCenter()
    let coordinator: AnonymousVersionReportingCoordinator

    init(
        consent: AnonymousVersionReportingConsent? = nil,
        onboardingComplete: Bool,
        isQARequested: Bool = false,
        context: DailyActiveReportingContext? = DailyActiveReportingContext(
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id"),
        now: Date = Date(timeIntervalSince1970: 1_784_202_900)
    ) {
        let suiteName = "AnonymousVersionReportingCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let consent {
            defaults.set(
                consent.rawValue,
                forKey: SettingsStore.anonymousVersionReportingConsentStorageKey)
        }
        self.defaults = defaults
        self.suiteName = suiteName
        self.clock = CoordinatorClock(value: now)
        self.settings = SettingsStore(
            defaults: defaults,
            appVersion: "0.2.41",
            hasExistingAppData: { false },
            notificationCenter: notificationCenter,
            now: { [clock] in clock.value })
        self.state = CoordinatorStateBox(
            onboardingComplete: onboardingComplete,
            isQARequested: isQARequested,
            context: context)
        self.coordinator = AnonymousVersionReportingCoordinator(
            settings: settings,
            currentState: { [settings, state] in
                AnonymousVersionReportingState(
                    consent: settings.anonymousVersionReportingConsent,
                    hasCompletedOnboarding: state.onboardingComplete,
                    isQARequested: state.isQARequested,
                    context: state.context)
            },
            startReporter: { [lifecycle] in await lifecycle.start() },
            stopReporter: { [lifecycle] in await lifecycle.stop() },
            suppressUntilNextUTCDay: { [lifecycle] date in
                await lifecycle.suppress(date)
            },
            presentDisclosure: { [presenter] in
                await presenter.present()
            },
            notificationCenter: notificationCenter,
            scheduleNextTick: { [scheduler] operation in
                scheduler.schedule(operation)
            })
    }

    init(
        defaults: UserDefaults,
        suiteName: String,
        onboardingComplete: Bool
    ) {
        self.defaults = defaults
        self.suiteName = suiteName
        self.clock = CoordinatorClock(value: Date(timeIntervalSince1970: 1_784_202_900))
        self.settings = SettingsStore(
            defaults: defaults,
            appVersion: "0.2.41",
            hasExistingAppData: { false },
            notificationCenter: notificationCenter,
            now: { [clock] in clock.value })
        self.state = CoordinatorStateBox(
            onboardingComplete: onboardingComplete,
            isQARequested: false,
            context: DailyActiveReportingContext(
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "developer-id"))
        self.coordinator = AnonymousVersionReportingCoordinator(
            settings: settings,
            currentState: { [settings, state] in
                AnonymousVersionReportingState(
                    consent: settings.anonymousVersionReportingConsent,
                    hasCompletedOnboarding: state.onboardingComplete,
                    isQARequested: state.isQARequested,
                    context: state.context)
            },
            startReporter: { [lifecycle] in await lifecycle.start() },
            stopReporter: { [lifecycle] in await lifecycle.stop() },
            suppressUntilNextUTCDay: { [lifecycle] date in
                await lifecycle.suppress(date)
            },
            presentDisclosure: { [presenter] in
                await presenter.present()
            },
            notificationCenter: notificationCenter,
            scheduleNextTick: { [scheduler] operation in
                scheduler.schedule(operation)
            })
    }
}

@MainActor
private final class CoordinatorStateBox {
    var onboardingComplete: Bool
    var isQARequested: Bool
    var context: DailyActiveReportingContext?

    init(
        onboardingComplete: Bool,
        isQARequested: Bool,
        context: DailyActiveReportingContext?
    ) {
        self.onboardingComplete = onboardingComplete
        self.isQARequested = isQARequested
        self.context = context
    }
}

@MainActor
private final class CoordinatorClock {
    var value: Date

    init(value: Date) {
        self.value = value
    }
}

@MainActor
private final class ManualNextTickScheduler {
    private var operations: [@MainActor @Sendable () -> Void] = []

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        operations.append(operation)
    }

    func runAll() {
        let pending = operations
        operations.removeAll()
        for operation in pending { operation() }
    }
}

private actor CoordinatorLifecycleProbe {
    private(set) var events: [String] = []
    private(set) var suppressedDates: [Date] = []
    private var shouldSuspendStop = false
    private var stopIsSuspended = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendStart = false
    private var startIsSuspended = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    func start() async {
        if shouldSuspendStart {
            shouldSuspendStart = false
            startIsSuspended = true
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
            startIsSuspended = false
        }
        events.append("start")
    }

    func stop() async {
        events.append("stop")
        guard shouldSuspendStop else { return }
        shouldSuspendStop = false
        stopIsSuspended = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
        stopIsSuspended = false
    }

    func suppress(_ date: Date) {
        suppressedDates.append(date)
        events.append("suppress:\(date.timeIntervalSince1970)")
    }

    func clear() {
        events.removeAll()
        suppressedDates.removeAll()
    }

    func suspendNextStop() {
        shouldSuspendStop = true
    }

    func suspendNextStart() {
        shouldSuspendStart = true
    }

    func waitUntilStartIsSuspended() async {
        while !startIsSuspended {
            await Task.yield()
        }
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStopIsSuspended() async {
        while !stopIsSuspended {
            await Task.yield()
        }
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor CountingDailyActiveTransport: DailyActiveTransport {
    private(set) var requestCount = 0

    func send(_ request: URLRequest) async throws -> DailyActiveTransportResponse {
        requestCount += 1
        return DailyActiveTransportResponse(statusCode: 204)
    }
}

private actor ReporterPeriodicSleepProbe {
    private var callCount = 0
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        callCount += 1
        let waiters = firstCallWaiters
        firstCallWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await Task<Never, Never>.sleep(for: .seconds(60))
    }

    func waitForFirstCall() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }
}

@MainActor
private final class DisclosurePresenterProbe {
    var choice: AnonymousVersionReportingDisclosureChoice = .notNow
    private(set) var presentationCount = 0
    private var shouldSuspend = false
    private var isSuspended = false
    private var continuation: CheckedContinuation<
        AnonymousVersionReportingDisclosureChoice,
        Never>?

    func present() async -> AnonymousVersionReportingDisclosureChoice {
        presentationCount += 1
        guard shouldSuspend else { return choice }
        shouldSuspend = false
        isSuspended = true
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isSuspended = false
        return result
    }

    func suspendNextPresentation() {
        shouldSuspend = true
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func resume(with choice: AnonymousVersionReportingDisclosureChoice) {
        continuation?.resume(returning: choice)
        continuation = nil
    }
}
