import Foundation
import Observation

struct PendingUpdateSnapshot: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case available
        case readyToInstall
    }

    let internalVersion: String
    let displayVersion: String
    var phase: Phase
    let firstSeenAt: Date
    var nextReminderAt: Date?
    var deliveredReminderCount: Int
}

/// Observable update state that survives window dismissal and, when explicitly
/// configured with a defaults suite, application relaunches.
///
/// Sparkle reply closures remain in `CustomUserDriver`; this type persists only
/// version-scoped data and keeps the live installer action in memory.
@MainActor
@Observable
final class PersistentUpdateAvailability {
    enum PrimaryAction: Equatable {
        case install
        case installAndRelaunch
    }

    enum DiscoveryPresentation: Equatable {
        case presentWindow
        case dismissSilently
    }

    private static let storageKey = "app.pendingUpdateSnapshot.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistenceEnabled: Bool

    private(set) var snapshot: PendingUpdateSnapshot?
    private(set) var primaryAction: PrimaryAction?

    var version: String? {
        snapshot?.displayVersion
    }

    var isVisible: Bool {
        snapshot != nil || primaryAction != nil
    }

    /// Existing call sites remain deliberately ephemeral until the updater
    /// controller injects its production or Local QA defaults suite.
    convenience init() {
        self.init(
            defaults: .standard,
            currentInternalVersion: "0",
            persistenceEnabled: false)
    }

    init(
        defaults: UserDefaults,
        currentInternalVersion: String,
        persistenceEnabled: Bool = true)
    {
        self.defaults = defaults
        self.persistenceEnabled = persistenceEnabled
        snapshot = nil
        primaryAction = nil

        guard persistenceEnabled else { return }
        guard let storedValue = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = storedValue as? Data else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard
            let restored = try? JSONDecoder().decode(PendingUpdateSnapshot.self, from: data),
            Self.isValid(restored),
            currentInternalVersion.compare(
                restored.internalVersion,
                options: .numeric) == .orderedAscending
        else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }

        snapshot = restored
        // Sparkle's installer callback cannot be persisted. Rediscovery must
        // rehydrate it before Install & Relaunch becomes available again.
        primaryAction = .install
    }

    @discardableResult
    func recordDiscovery(
        internalVersion: String,
        displayVersion: String,
        userInitiated: Bool,
        now: Date = Date()) -> DiscoveryPresentation
    {
        _ = userInitiated
        guard !internalVersion.isEmpty else {
            clear()
            return .presentWindow
        }
        let visibleVersion = displayVersion.isEmpty ? internalVersion : displayVersion

        if let existing = snapshot, existing.internalVersion == internalVersion {
            snapshot = PendingUpdateSnapshot(
                internalVersion: existing.internalVersion,
                displayVersion: visibleVersion,
                phase: existing.phase,
                firstSeenAt: existing.firstSeenAt,
                nextReminderAt: existing.nextReminderAt,
                deliveredReminderCount: existing.deliveredReminderCount)
        } else {
            snapshot = PendingUpdateSnapshot(
                internalVersion: internalVersion,
                displayVersion: visibleVersion,
                phase: .available,
                firstSeenAt: now,
                nextReminderAt: nil,
                deliveredReminderCount: 0)
        }
        primaryAction = .install
        persistSnapshot()
        return .presentWindow
    }

    func markAvailable(version: String) {
        guard !version.isEmpty else {
            clear()
            return
        }
        recordDiscovery(
            internalVersion: version,
            displayVersion: version,
            userInitiated: false)
    }

    func markReadyToInstall(version: String? = nil) {
        if let existing = snapshot {
            let visibleVersion = version.flatMap { $0.isEmpty ? nil : $0 }
                ?? existing.displayVersion
            snapshot = PendingUpdateSnapshot(
                internalVersion: existing.internalVersion,
                displayVersion: visibleVersion,
                phase: .readyToInstall,
                firstSeenAt: existing.firstSeenAt,
                nextReminderAt: existing.nextReminderAt,
                deliveredReminderCount: existing.deliveredReminderCount)
            persistSnapshot()
        } else if let version, !version.isEmpty {
            snapshot = PendingUpdateSnapshot(
                internalVersion: version,
                displayVersion: version,
                phase: .readyToInstall,
                firstSeenAt: Date(),
                nextReminderAt: nil,
                deliveredReminderCount: 0)
            persistSnapshot()
        }
        primaryAction = .installAndRelaunch
    }

    func markDismissed() {
        // Legacy dismissals preserve the badge without scheduling a reminder.
    }

    func markLater(now: Date = Date()) {
        guard var snapshot else { return }
        snapshot.nextReminderAt = UpdateReminderPolicy.nextDate(
            after: now,
            deliveredCount: snapshot.deliveredReminderCount)
        self.snapshot = snapshot
        persistSnapshot()
    }

    func consumeDueReminder(now: Date = Date()) -> String? {
        guard var snapshot, UpdateReminderPolicy.isDue(snapshot, at: now) else {
            return nil
        }

        snapshot.deliveredReminderCount += 1
        snapshot.nextReminderAt = UpdateReminderPolicy.nextDate(
            after: now,
            deliveredCount: snapshot.deliveredReminderCount)
        let displayVersion = snapshot.displayVersion
        self.snapshot = snapshot
        persistSnapshot()
        return displayVersion
    }

    func markSkipped() {
        clear()
    }

    func clear() {
        snapshot = nil
        primaryAction = nil
        guard persistenceEnabled else { return }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persistSnapshot() {
        guard persistenceEnabled, let snapshot else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func isValid(_ snapshot: PendingUpdateSnapshot) -> Bool {
        !snapshot.internalVersion.isEmpty
            && !snapshot.displayVersion.isEmpty
            && snapshot.deliveredReminderCount >= 0
    }
}
