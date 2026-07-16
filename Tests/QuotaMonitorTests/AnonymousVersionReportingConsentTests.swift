import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Anonymous version reporting consent")
struct AnonymousVersionReportingConsentTests {
    @Test("Missing and invalid values stay undecided")
    func missingAndInvalidValuesFailClosed() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(makeStore(defaults: defaults).anonymousVersionReportingConsent == .undecided)

        defaults.set("enabled-typo", forKey: SettingsStore.anonymousVersionReportingConsentStorageKey)
        #expect(makeStore(defaults: defaults).anonymousVersionReportingConsent == .undecided)

        defaults.set(true, forKey: SettingsStore.anonymousVersionReportingConsentStorageKey)
        #expect(makeStore(defaults: defaults).anonymousVersionReportingConsent == .undecided)
    }

    @Test("Explicit choice is persisted before synchronous notification")
    func setterPersistsBeforeNotification() throws {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let clickedAt = Date(timeIntervalSince1970: 1_784_202_900)
        let store = makeStore(
            defaults: defaults,
            notificationCenter: center,
            now: { clickedAt })
        let probe = ConsentNotificationProbe(defaults: defaults)
        let token = center.addObserver(
            forName: .quotaMonitorAnonymousVersionReportingConsentChanged,
            object: nil,
            queue: nil
        ) { notification in
            probe.receive(notification)
        }
        defer { center.removeObserver(token) }

        store.setAnonymousVersionReportingConsent(.enabled)

        let snapshot = probe.snapshot
        #expect(store.anonymousVersionReportingConsent == .enabled)
        #expect(snapshot.storedValue == AnonymousVersionReportingConsent.enabled.rawValue)
        #expect(snapshot.change == AnonymousVersionReportingConsentChange(
            consent: .enabled,
            changedAt: clickedAt))
    }

    @Test("Setting the same explicit choice is idempotent")
    func setterDoesNotNotifyForUnchangedChoice() {
        let (defaults, suiteName) = makeDefaults(named: #function)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let store = makeStore(defaults: defaults, notificationCenter: center)
        let probe = ConsentNotificationProbe(defaults: defaults)
        let token = center.addObserver(
            forName: .quotaMonitorAnonymousVersionReportingConsentChanged,
            object: nil,
            queue: nil
        ) { _ in
            probe.increment()
        }
        defer { center.removeObserver(token) }

        store.setAnonymousVersionReportingConsent(.disabled)
        store.setAnonymousVersionReportingConsent(.disabled)

        #expect(probe.snapshot.count == 1)
        #expect(makeStore(defaults: defaults).anonymousVersionReportingConsent == .disabled)
    }

    private func makeStore(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> SettingsStore {
        SettingsStore(
            defaults: defaults,
            appVersion: "0.2.41",
            hasExistingAppData: { false },
            notificationCenter: notificationCenter,
            now: now)
    }

    private func makeDefaults(named testName: String) -> (UserDefaults, String) {
        let suiteName = "AnonymousVersionReportingConsentTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private final class ConsentNotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: DailyActiveUserDefaults
    private var change: AnonymousVersionReportingConsentChange?
    private var storedValue: String?
    private var count = 0

    init(defaults: UserDefaults) {
        self.defaults = DailyActiveUserDefaults(defaults)
    }

    func receive(_ notification: Notification) {
        lock.withLock {
            change = notification.object as? AnonymousVersionReportingConsentChange
            storedValue = defaults.value.string(
                forKey: SettingsStore.anonymousVersionReportingConsentStorageKey)
            count += 1
        }
    }

    func increment() {
        lock.withLock { count += 1 }
    }

    var snapshot: (
        change: AnonymousVersionReportingConsentChange?,
        storedValue: String?,
        count: Int
    ) {
        lock.withLock { (change, storedValue, count) }
    }
}
