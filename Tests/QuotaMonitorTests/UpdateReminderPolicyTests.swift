import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Update reminder policy")
struct UpdateReminderPolicyTests {
    private let storageKey = "app.pendingUpdateSnapshot.v1"

    @Test
    func nextDateUsesExactInitialAndRecurringDelays() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(UpdateReminderPolicy.nextDate(after: now, deliveredCount: 0)
            == now.addingTimeInterval(86_400))
        #expect(UpdateReminderPolicy.nextDate(after: now, deliveredCount: 1)
            == now.addingTimeInterval(259_200))
    }

    @Test(arguments: [0, 1])
    func dueBoundaryIsFalseOneSecondBeforeAndTrueAtOrAfter(deliveredCount: Int) {
        let now = Date(timeIntervalSince1970: 1_000)
        let due = UpdateReminderPolicy.nextDate(after: now, deliveredCount: deliveredCount)
        let snapshot = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41",
            phase: .available,
            firstSeenAt: now,
            nextReminderAt: due,
            deliveredReminderCount: deliveredCount)

        #expect(UpdateReminderPolicy.isDue(snapshot, at: due.addingTimeInterval(-1)) == false)
        #expect(UpdateReminderPolicy.isDue(snapshot, at: due) == true)
        #expect(UpdateReminderPolicy.isDue(snapshot, at: due.addingTimeInterval(1)) == true)
    }

    @Test
    func markLaterUsesInitialDelayBeforeAnyReminderWasDelivered() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000)
        let availability = makeAvailability(defaults: defaults, now: now)

        availability.markLater(now: now)

        #expect(availability.snapshot?.deliveredReminderCount == 0)
        #expect(availability.snapshot?.nextReminderAt == now.addingTimeInterval(86_400))
        let restored = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        #expect(restored.snapshot == availability.snapshot)
    }

    @Test
    func markLaterUsesRecurringDelayAfterAReminderWasDelivered() throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000)
        let stored = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41",
            phase: .available,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            nextReminderAt: nil,
            deliveredReminderCount: 1)
        defaults.set(try JSONEncoder().encode(stored), forKey: storageKey)
        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")

        availability.markLater(now: now)

        #expect(availability.snapshot?.deliveredReminderCount == 1)
        #expect(availability.snapshot?.nextReminderAt == now.addingTimeInterval(259_200))
        let restored = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        #expect(restored.snapshot == availability.snapshot)
    }

    @Test
    func consumeDueReminderReturnsOnceAndPersistsRecurringSchedule() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let later = Date(timeIntervalSince1970: 1_000)
        let due = later.addingTimeInterval(86_400)
        let availability = makeAvailability(defaults: defaults, now: later)
        availability.markLater(now: later)

        #expect(availability.consumeDueReminder(now: due.addingTimeInterval(-1)) == nil)
        #expect(availability.snapshot?.deliveredReminderCount == 0)
        #expect(availability.snapshot?.nextReminderAt == due)

        #expect(availability.consumeDueReminder(now: due) == "0.2.41")
        #expect(availability.snapshot?.deliveredReminderCount == 1)
        #expect(availability.snapshot?.nextReminderAt == due.addingTimeInterval(259_200))
        #expect(availability.consumeDueReminder(now: due) == nil)

        let restored = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        #expect(restored.snapshot == availability.snapshot)
        #expect(restored.consumeDueReminder(now: due) == nil)
    }

    @Test
    func disabledPersistenceReminderTransitionsDoNotTouchSuppliedDefaults() throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stored = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41",
            phase: .available,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            nextReminderAt: nil,
            deliveredReminderCount: 0)
        let storedData = try JSONEncoder().encode(stored)
        defaults.set(storedData, forKey: storageKey)
        let later = Date(timeIntervalSince1970: 1_000)
        let due = later.addingTimeInterval(86_400)
        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40",
            persistenceEnabled: false)
        availability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42",
            userInitiated: false,
            now: later)

        availability.markLater(now: later)
        #expect(availability.consumeDueReminder(now: due) == "0.2.42")

        #expect(defaults.data(forKey: storageKey) == storedData)
    }

    private func makeAvailability(defaults: UserDefaults, now: Date) -> PersistentUpdateAvailability {
        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: now)
        return availability
    }

    private func makeDefaults(named testName: String) -> (UserDefaults, String) {
        let suiteName = "UpdateReminderPolicyTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
