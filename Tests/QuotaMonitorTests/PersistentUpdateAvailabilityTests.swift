import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Persistent update availability")
struct PersistentUpdateAvailabilityTests {
    private let storageKey = "app.pendingUpdateSnapshot.v1"

    @Test
    func freshObjectRestoresTheSameVersionScopedSnapshot() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        let presentation = first.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 100))

        #expect(presentation == .presentWindow)
        let restored = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        #expect(restored.snapshot == first.snapshot)
        #expect(restored.snapshot?.internalVersion == "41")
        #expect(restored.version == "0.2.41")
        #expect(restored.primaryAction == .install)
    }

    @Test
    func corruptPayloadSelfClears() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: storageKey)

        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")

        #expect(availability.snapshot == nil)
        #expect(availability.isVisible == false)
        #expect(defaults.object(forKey: storageKey) == nil)
    }

    @Test
    func wrongTypedPayloadSelfClears() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-data", forKey: storageKey)

        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")

        #expect(availability.snapshot == nil)
        #expect(defaults.object(forKey: storageKey) == nil)
    }

    @Test
    func currentBuildAtOrAboveStoredInternalVersionRemovesIt() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        first.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 100))

        let equalBuild = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "41")
        #expect(equalBuild.snapshot == nil)
        #expect(defaults.object(forKey: storageKey) == nil)

        first.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 100))
        let newerBuild = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "42")
        #expect(newerBuild.snapshot == nil)
        #expect(defaults.object(forKey: storageKey) == nil)
    }

    @Test
    func replacementVersionResetsVersionScopedReminderState() throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldSnapshot = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41",
            phase: .readyToInstall,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            nextReminderAt: Date(timeIntervalSince1970: 150),
            deliveredReminderCount: 2)
        defaults.set(try JSONEncoder().encode(oldSnapshot), forKey: storageKey)
        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")

        availability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 200))

        #expect(availability.snapshot == PendingUpdateSnapshot(
            internalVersion: "42",
            displayVersion: "0.2.42",
            phase: .available,
            firstSeenAt: Date(timeIntervalSince1970: 200),
            nextReminderAt: nil,
            deliveredReminderCount: 0))
        #expect(availability.primaryAction == .install)
    }

    @Test
    func readyToInstallPersistsPhaseButNotTheLiveInstallerAction() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 100))

        availability.markReadyToInstall()

        #expect(availability.snapshot?.phase == .readyToInstall)
        #expect(availability.primaryAction == .installAndRelaunch)
        let restored = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        #expect(restored.snapshot?.phase == .readyToInstall)
        #expect(restored.version == "0.2.41")
        #expect(restored.primaryAction == .install)
    }

    @Test
    func skippedAndClearedUpdatesRemovePersistedState() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40")
        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false)

        availability.markSkipped()

        #expect(availability.snapshot == nil)
        #expect(defaults.object(forKey: storageKey) == nil)

        availability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42",
            userInitiated: false)
        availability.clear()

        #expect(availability.snapshot == nil)
        #expect(defaults.object(forKey: storageKey) == nil)
    }

    @Test
    func disabledPersistenceNeitherRestoresNorWrites() throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storedSnapshot = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41",
            phase: .available,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            nextReminderAt: nil,
            deliveredReminderCount: 0)
        let storedData = try JSONEncoder().encode(storedSnapshot)
        defaults.set(storedData, forKey: storageKey)

        let availability = PersistentUpdateAvailability(
            defaults: defaults,
            currentInternalVersion: "40",
            persistenceEnabled: false)
        #expect(availability.snapshot == nil)

        availability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42",
            userInitiated: false)
        availability.clear()

        #expect(defaults.data(forKey: storageKey) == storedData)
    }

    @Test
    func noArgumentInitializationIsEphemeral() {
        let first = PersistentUpdateAvailability()
        first.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false)

        let fresh = PersistentUpdateAvailability()

        #expect(first.version == "0.2.41")
        #expect(fresh.snapshot == nil)
        #expect(fresh.isVisible == false)
    }

    @Test
    func discoveredUpdateRemainsVisibleAfterDismissal() {
        let availability = PersistentUpdateAvailability()

        availability.markAvailable(version: "0.2.36")
        availability.markDismissed()

        #expect(availability.isVisible == true)
        #expect(availability.version == "0.2.36")
        #expect(availability.primaryAction == .install)
    }

    @Test
    func readyToInstallKeepsBadgeWithRelaunchAction() {
        let availability = PersistentUpdateAvailability()

        availability.markAvailable(version: "0.2.36")
        availability.markReadyToInstall()

        #expect(availability.isVisible == true)
        #expect(availability.version == "0.2.36")
        #expect(availability.primaryAction == .installAndRelaunch)
    }

    @Test
    func terminalClearRemovesBadge() {
        let availability = PersistentUpdateAvailability()

        availability.markAvailable(version: "0.2.36")
        availability.clear()

        #expect(availability.isVisible == false)
        #expect(availability.version == nil)
        #expect(availability.primaryAction == nil)
    }

    private func makeDefaults(named testName: String) -> (UserDefaults, String) {
        let suiteName = "PersistentUpdateAvailabilityTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
