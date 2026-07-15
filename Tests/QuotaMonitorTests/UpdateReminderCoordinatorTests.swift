import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Update reminder coordinator")
struct UpdateReminderCoordinatorTests {
    @Test("Startup consumes an overdue reminder before presenting and arms recurrence")
    func startupConsumesOverdueBeforePresenting() async throws {
        let availability = makeAvailability(firstSeenAt: 100)
        availability.markLater(now: Date(timeIntervalSince1970: 100))
        let due = try #require(availability.snapshot?.nextReminderAt)
        let clock = ReminderTestClock(due)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        var snapshotAtPresentation: PendingUpdateSnapshot?
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { version in
                snapshotAtPresentation = availability.snapshot
                presentations.append(version)
            })

        coordinator.start()

        #expect(presentations == ["0.2.41"])
        #expect(snapshotAtPresentation?.deliveredReminderCount == 1)
        #expect(snapshotAtPresentation?.nextReminderAt
            == due.addingTimeInterval(UpdateReminderPolicy.recurringDelay))
        let durations = await waitForRequests(1, from: sleeper)
        #expect(durations == [.seconds(UpdateReminderPolicy.recurringDelay)])
        for _ in 0..<10 { await Task.yield() }
        #expect(await sleeper.requestedDurations().count == 1)
        coordinator.stop()
        await sleeper.resumeAll()
    }

    @Test("A future reminder sleeps once and presents at the exact wall-clock boundary")
    func futureReminderPresentsAtExactBoundary() async throws {
        let initial = Date(timeIntervalSince1970: 1_000)
        let availability = makeAvailability(firstSeenAt: initial.timeIntervalSince1970)
        availability.markLater(now: initial)
        let due = try #require(availability.snapshot?.nextReminderAt)
        let clock = ReminderTestClock(initial)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { presentations.append($0) })

        coordinator.start()
        let durations = await waitForRequests(1, from: sleeper)
        #expect(durations == [.seconds(UpdateReminderPolicy.initialDelay)])
        #expect(presentations.isEmpty)

        clock.now = due
        await sleeper.resume(request: 0)
        await waitUntil { !presentations.isEmpty }

        #expect(presentations == ["0.2.41"])
        #expect(availability.snapshot?.deliveredReminderCount == 1)
        coordinator.stop()
        await sleeper.resumeAll()
    }

    @Test("Reschedule rejects an old sleeper even when it ignores cancellation")
    func rescheduleRejectsCancellationIgnoringSleeper() async throws {
        let initial = Date(timeIntervalSince1970: 2_000)
        let availability = makeAvailability(firstSeenAt: initial.timeIntervalSince1970)
        availability.markLater(now: initial)
        let firstDue = try #require(availability.snapshot?.nextReminderAt)
        let clock = ReminderTestClock(initial)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { presentations.append($0) })

        coordinator.start()
        _ = await waitForRequests(1, from: sleeper)
        clock.now = initial.addingTimeInterval(100)
        availability.markLater(now: clock.now)
        _ = await waitForRequests(2, from: sleeper)
        await waitForCancellation(of: 0, from: sleeper)

        clock.now = firstDue
        await sleeper.resume(request: 0)
        await waitUntil { await sleeper.completedRequestCount() >= 1 }
        #expect(presentations.isEmpty)

        let replacementDue = try #require(availability.snapshot?.nextReminderAt)
        clock.now = replacementDue
        await sleeper.resume(request: 1)
        await waitUntil { !presentations.isEmpty }
        #expect(presentations == ["0.2.41"])
        coordinator.stop()
        await sleeper.resumeAll()
    }

    @Test("Stop invalidates a pending sleeper and prevents presentation")
    func stopPreventsPresentation() async throws {
        let initial = Date(timeIntervalSince1970: 3_000)
        let availability = makeAvailability(firstSeenAt: initial.timeIntervalSince1970)
        availability.markLater(now: initial)
        let due = try #require(availability.snapshot?.nextReminderAt)
        let clock = ReminderTestClock(initial)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { presentations.append($0) })

        coordinator.start()
        _ = await waitForRequests(1, from: sleeper)
        coordinator.stop()
        await waitForCancellation(of: 0, from: sleeper)
        clock.now = due
        await sleeper.resume(request: 0)
        await waitUntil { await sleeper.completedRequestCount() >= 1 }

        #expect(presentations.isEmpty)
    }

    @Test("Observation arms after Later and cancels after Skip and clear")
    func observationTracksAllReminderStateMutations() async throws {
        let initial = Date(timeIntervalSince1970: 4_000)
        let availability = PersistentUpdateAvailability()
        let clock = ReminderTestClock(initial)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { presentations.append($0) })
        coordinator.start()

        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: initial)
        availability.markLater(now: initial)
        let firstDurations = await waitForRequests(1, from: sleeper)
        #expect(firstDurations == [.seconds(UpdateReminderPolicy.initialDelay)])

        availability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42",
            userInitiated: false,
            now: initial.addingTimeInterval(1))
        await waitForCancellation(of: 0, from: sleeper)
        clock.now = initial.addingTimeInterval(UpdateReminderPolicy.initialDelay)
        await sleeper.resume(request: 0)
        await waitUntil { await sleeper.completedRequestCount() >= 1 }
        #expect(presentations.isEmpty)

        let replacementStart = clock.now.addingTimeInterval(10)
        clock.now = replacementStart
        availability.markLater(now: replacementStart)
        _ = await waitForRequests(2, from: sleeper)
        availability.markSkipped()
        await waitForCancellation(of: 1, from: sleeper)
        clock.now = replacementStart.addingTimeInterval(UpdateReminderPolicy.initialDelay)
        await sleeper.resume(request: 1)
        await waitUntil { await sleeper.completedRequestCount() >= 2 }

        let clearStart = clock.now.addingTimeInterval(10)
        clock.now = clearStart
        availability.recordDiscovery(
            internalVersion: "43",
            displayVersion: "0.2.43",
            userInitiated: false,
            now: clearStart)
        availability.markLater(now: clearStart)
        _ = await waitForRequests(3, from: sleeper)
        availability.clear()
        await waitForCancellation(of: 2, from: sleeper)
        clock.now = clearStart.addingTimeInterval(UpdateReminderPolicy.initialDelay)
        await sleeper.resume(request: 2)
        await waitUntil { await sleeper.completedRequestCount() >= 3 }

        #expect(presentations.isEmpty)
        coordinator.stop()
    }

    @Test("A forward wall-clock jump consumes once and a backward jump rearms the remainder")
    func wakeAlwaysReevaluatesTheWallClock() async throws {
        let initial = Date(timeIntervalSince1970: 5_000)
        let availability = makeAvailability(firstSeenAt: initial.timeIntervalSince1970)
        availability.markLater(now: initial)
        let due = try #require(availability.snapshot?.nextReminderAt)
        let clock = ReminderTestClock(initial)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { presentations.append($0) })

        coordinator.start()
        _ = await waitForRequests(1, from: sleeper)
        clock.now = initial.addingTimeInterval(1_000)
        await sleeper.resume(request: 0)
        let backwardDurations = await waitForRequests(2, from: sleeper)
        #expect(backwardDurations[1] == .seconds(UpdateReminderPolicy.initialDelay - 1_000))
        #expect(presentations.isEmpty)

        clock.now = due.addingTimeInterval(600)
        await sleeper.resume(request: 1)
        await waitUntil { !presentations.isEmpty }
        #expect(presentations == ["0.2.41"])
        #expect(availability.snapshot?.deliveredReminderCount == 1)

        _ = await waitForRequests(3, from: sleeper)
        await sleeper.resume(request: 1)
        await Task.yield()
        #expect(presentations == ["0.2.41"])
        coordinator.stop()
        await sleeper.resumeAll()
    }

    @Test("Repeated start and stop calls stay idempotent")
    func repeatedLifecycleCallsAreSafe() async {
        let initial = Date(timeIntervalSince1970: 6_000)
        let availability = makeAvailability(firstSeenAt: initial.timeIntervalSince1970)
        availability.markLater(now: initial)
        let clock = ReminderTestClock(initial)
        let sleeper = ControlledReminderSleeper()
        var presentations: [String] = []
        let coordinator = UpdateReminderCoordinator(
            availability: availability,
            now: { clock.now },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { presentations.append($0) })

        coordinator.start()
        coordinator.start()
        let durations = await waitForRequests(1, from: sleeper)
        #expect(durations.count == 1)
        coordinator.stop()
        coordinator.stop()
        await sleeper.resumeAll()
        #expect(presentations.isEmpty)
    }

    @Test("Updater owns reminder scheduling and refuses presentation when the runtime disables it")
    func updaterOwnsAndGatesReminderCoordinator() async throws {
        let due = Date(timeIntervalSince1970: 7_000)

        let disabledAvailability = makeAvailability(firstSeenAt: 100)
        disabledAvailability.markLater(
            now: due.addingTimeInterval(-UpdateReminderPolicy.initialDelay))
        let disabledRuntime = UpdaterController.RuntimeConfiguration(
            updateAvailability: disabledAvailability,
            sparkleEnabled: false,
            reminderPresentationEnabled: false)
        let disabledUpdater = UpdaterController(runtimeConfiguration: disabledRuntime)
        var disabledPresentations: [String] = []
        disabledUpdater.startUpdateReminders(
            now: { due },
            sleep: { _ in },
            present: { disabledPresentations.append($0) })
        #expect(disabledPresentations.isEmpty)

        let enabledAvailability = makeAvailability(firstSeenAt: 100)
        enabledAvailability.markLater(
            now: due.addingTimeInterval(-UpdateReminderPolicy.initialDelay))
        let enabledRuntime = UpdaterController.RuntimeConfiguration(
            updateAvailability: enabledAvailability,
            sparkleEnabled: false,
            reminderPresentationEnabled: true)
        let enabledUpdater = UpdaterController(runtimeConfiguration: enabledRuntime)
        let sleeper = ControlledReminderSleeper()
        var enabledPresentations: [String] = []
        enabledUpdater.startUpdateReminders(
            now: { due },
            sleep: { duration in try await sleeper.sleep(duration) },
            present: { enabledPresentations.append($0) })

        #expect(enabledPresentations == ["0.2.41"])
        _ = await waitForRequests(1, from: sleeper)
        enabledUpdater.stopUpdateReminders()
        await waitForCancellation(of: 0, from: sleeper)
        await sleeper.resumeAll()
    }

    private func makeAvailability(firstSeenAt: TimeInterval) -> PersistentUpdateAvailability {
        let availability = PersistentUpdateAvailability()
        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: firstSeenAt))
        return availability
    }

    private func waitForRequests(
        _ count: Int,
        from sleeper: ControlledReminderSleeper
    ) async -> [Duration] {
        for _ in 0..<500 {
            let durations = await sleeper.requestedDurations()
            if durations.count >= count { return durations }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) sleep requests")
        return await sleeper.requestedDurations()
    }

    private func waitForCancellation(
        of request: Int,
        from sleeper: ControlledReminderSleeper
    ) async {
        await waitUntil { await sleeper.wasCancelled(request: request) }
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous condition")
    }
}

@MainActor
private final class ReminderTestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private actor ControlledReminderSleeper {
    private struct Request {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var nextID = 0
    private var requests: [Int: Request] = [:]
    private var durations: [Duration] = []
    private var cancelled: Set<Int> = []
    private var completed = 0

    func sleep(_ duration: Duration) async throws {
        let id = nextID
        nextID += 1
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests[id] = Request(duration: duration, continuation: continuation)
            }
            completed += 1
        } onCancel: {
            Task { await self.recordCancellation(id) }
        }
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    func wasCancelled(request id: Int) -> Bool {
        cancelled.contains(id)
    }

    func completedRequestCount() -> Int {
        completed
    }

    func resume(request id: Int) {
        requests.removeValue(forKey: id)?.continuation.resume()
    }

    func resumeAll() {
        let pending = requests.values.map(\.continuation)
        requests.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func recordCancellation(_ id: Int) {
        cancelled.insert(id)
    }
}
