import Foundation
import Observation

@MainActor
final class UpdateReminderCoordinator {
    typealias Present = @MainActor (_ displayVersion: String) -> Void
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private let availability: PersistentUpdateAvailability
    private let now: @MainActor () -> Date
    private let sleep: Sleep
    private let present: Present

    private var isStarted = false
    private var observationGeneration: UInt = 0
    private var taskGeneration: UInt = 0
    private var sleepTask: Task<Void, Never>?

    init(
        availability: PersistentUpdateAvailability,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping Sleep = { duration in
            try await Task<Never, Never>.sleep(for: duration)
        },
        present: @escaping Present
    ) {
        self.availability = availability
        self.now = now
        self.sleep = sleep
        self.present = present
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        armObservation()
        replaceSchedule()
    }

    func reschedule() {
        guard isStarted else { return }
        replaceSchedule()
    }

    func stop() {
        guard isStarted || sleepTask != nil else { return }
        isStarted = false
        observationGeneration &+= 1
        taskGeneration &+= 1
        sleepTask?.cancel()
        sleepTask = nil
    }

    private func armObservation() {
        guard isStarted else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = availability.snapshot?.internalVersion
            _ = availability.snapshot?.nextReminderAt
            _ = availability.snapshot?.deliveredReminderCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleObservedChange(generation: generation)
            }
        }
    }

    private func handleObservedChange(generation: UInt) {
        guard isStarted, generation == observationGeneration else { return }
        armObservation()
        replaceSchedule()
    }

    private func replaceSchedule() {
        taskGeneration &+= 1
        let generation = taskGeneration
        sleepTask?.cancel()
        sleepTask = nil
        evaluateAndArm(generation: generation)
    }

    private func evaluateAndArm(generation: UInt) {
        guard isStarted, generation == taskGeneration,
              let nextReminderAt = availability.snapshot?.nextReminderAt else {
            return
        }

        let currentDate = now()
        guard nextReminderAt <= currentDate else {
            armSleep(
                duration: .seconds(nextReminderAt.timeIntervalSince(currentDate)),
                generation: generation)
            return
        }

        // Observation fires before the mutation is applied. Invalidate that
        // callback before consuming, then track the persisted recurring date.
        observationGeneration &+= 1
        guard let version = availability.consumeDueReminder(now: currentDate) else {
            armObservation()
            return
        }
        armObservation()
        if let recurringDate = availability.snapshot?.nextReminderAt {
            armSleep(
                duration: .seconds(max(0, recurringDate.timeIntervalSince(currentDate))),
                generation: generation)
        }
        present(version)
    }

    private func armSleep(duration: Duration, generation: UInt) {
        let sleep = self.sleep
        sleepTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.handleWake(generation: generation)
        }
    }

    private func handleWake(generation: UInt) {
        guard isStarted, generation == taskGeneration, !Task.isCancelled else { return }
        sleepTask = nil
        taskGeneration &+= 1
        evaluateAndArm(generation: taskGeneration)
    }
}
