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
    var isDeferred: Bool

    init(
        internalVersion: String,
        displayVersion: String,
        phase: Phase,
        firstSeenAt: Date,
        isDeferred: Bool
    ) {
        self.internalVersion = internalVersion
        self.displayVersion = displayVersion
        self.phase = phase
        self.firstSeenAt = firstSeenAt
        self.isDeferred = isDeferred
    }

    private enum CodingKeys: String, CodingKey {
        case internalVersion
        case displayVersion
        case phase
        case firstSeenAt
        case isDeferred
        // Read-only migration key from the unreleased reminder scheduler.
        case nextReminderAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        internalVersion = try container.decode(String.self, forKey: .internalVersion)
        displayVersion = try container.decode(String.self, forKey: .displayVersion)
        phase = try container.decode(Phase.self, forKey: .phase)
        firstSeenAt = try container.decode(Date.self, forKey: .firstSeenAt)
        if let deferred = try container.decodeIfPresent(Bool.self, forKey: .isDeferred) {
            isDeferred = deferred
        } else {
            isDeferred = try container.decodeIfPresent(Date.self, forKey: .nextReminderAt) != nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(internalVersion, forKey: .internalVersion)
        try container.encode(displayVersion, forKey: .displayVersion)
        try container.encode(phase, forKey: .phase)
        try container.encode(firstSeenAt, forKey: .firstSeenAt)
        try container.encode(isDeferred, forKey: .isDeferred)
    }
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
        let storedFields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let needsDeferredStateMigration = storedFields.map {
            !$0.keys.contains("isDeferred")
        } ?? false
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
        // Re-encode once so snapshots from the unreleased reminder scheduler
        // migrate to the smaller deferred-state schema immediately. Current
        // snapshots remain byte-for-byte untouched during a read-only restore.
        if needsDeferredStateMigration {
            persistSnapshot()
        }
    }

    @discardableResult
    func recordDiscovery(
        internalVersion: String,
        displayVersion: String,
        userInitiated: Bool,
        now: Date = Date()) -> DiscoveryPresentation
    {
        guard !internalVersion.isEmpty else {
            clear()
            return .presentWindow
        }
        let visibleVersion = displayVersion.isEmpty ? internalVersion : displayVersion
        let dismissSilently = !userInitiated
            && snapshot?.internalVersion == internalVersion
            && snapshot?.isDeferred == true

        if let existing = snapshot, existing.internalVersion == internalVersion {
            snapshot = PendingUpdateSnapshot(
                internalVersion: existing.internalVersion,
                displayVersion: visibleVersion,
                phase: existing.phase,
                firstSeenAt: existing.firstSeenAt,
                isDeferred: existing.isDeferred)
        } else {
            snapshot = PendingUpdateSnapshot(
                internalVersion: internalVersion,
                displayVersion: visibleVersion,
                phase: .available,
                firstSeenAt: now,
                isDeferred: false)
        }
        primaryAction = .install
        persistSnapshot()
        return dismissSilently ? .dismissSilently : .presentWindow
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
                isDeferred: existing.isDeferred)
            persistSnapshot()
        } else if let version, !version.isEmpty {
            snapshot = PendingUpdateSnapshot(
                internalVersion: version,
                displayVersion: version,
                phase: .readyToInstall,
                firstSeenAt: Date(),
                isDeferred: false)
            persistSnapshot()
        }
        primaryAction = .installAndRelaunch
    }

    func markDismissed() {
        // Legacy dismissals preserve the badge without scheduling a reminder.
    }

    func markLater() {
        guard var snapshot else { return }
        snapshot.isDeferred = true
        self.snapshot = snapshot
        persistSnapshot()
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
    }
}
