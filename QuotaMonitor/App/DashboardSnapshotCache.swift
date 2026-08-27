import Foundation

struct DashboardSnapshotCacheKey: Sendable, Hashable, Codable {
    let providerFilter: ProviderFilter
    let enabledProviders: [String]
    let timeZoneIdentifier: String

    init(
        providerFilter: ProviderFilter,
        enabledProviders: Set<String>,
        timeZoneIdentifier: String
    ) {
        self.providerFilter = providerFilter
        self.enabledProviders = enabledProviders.sorted()
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

enum DashboardSnapshotCacheReason: String, Sendable, Equatable {
    case missing
    case fresh
    case generationChanged = "generation-changed"
    case expired
    case restored
}

struct DashboardSnapshotCacheDecision: Sendable, Equatable {
    let snapshot: DashboardSnapshot?
    let needsRefresh: Bool
    let reason: DashboardSnapshotCacheReason
}

private struct DashboardSnapshotMemoryEntry: Sendable {
    let snapshot: DashboardSnapshot
    let generation: Int?
    let generatedAt: Date
}

struct DashboardSnapshotMemoryCache: Sendable {
    private var entries: [DashboardSnapshotCacheKey: DashboardSnapshotMemoryEntry] = [:]

    mutating func store(
        _ snapshot: DashboardSnapshot,
        for key: DashboardSnapshotCacheKey,
        generation: Int,
        generatedAt: Date
    ) {
        entries[key] = DashboardSnapshotMemoryEntry(
            snapshot: snapshot,
            generation: generation,
            generatedAt: generatedAt)
    }

    mutating func restore(_ envelope: DashboardSnapshotCacheEnvelope) {
        entries[envelope.key] = DashboardSnapshotMemoryEntry(
            snapshot: envelope.snapshot,
            generation: nil,
            generatedAt: envelope.generatedAt)
    }

    func snapshot(for key: DashboardSnapshotCacheKey) -> DashboardSnapshot? {
        entries[key]?.snapshot
    }

    func decision(
        for key: DashboardSnapshotCacheKey,
        currentGeneration: Int,
        now: Date,
        maxAge: TimeInterval
    ) -> DashboardSnapshotCacheDecision {
        guard let entry = entries[key] else {
            return DashboardSnapshotCacheDecision(
                snapshot: nil,
                needsRefresh: true,
                reason: .missing)
        }
        guard let generation = entry.generation else {
            return DashboardSnapshotCacheDecision(
                snapshot: entry.snapshot,
                needsRefresh: true,
                reason: .restored)
        }
        guard generation == currentGeneration else {
            return DashboardSnapshotCacheDecision(
                snapshot: entry.snapshot,
                needsRefresh: true,
                reason: .generationChanged)
        }
        guard now.timeIntervalSince(entry.generatedAt) <= maxAge else {
            return DashboardSnapshotCacheDecision(
                snapshot: entry.snapshot,
                needsRefresh: true,
                reason: .expired)
        }
        return DashboardSnapshotCacheDecision(
            snapshot: entry.snapshot,
            needsRefresh: false,
            reason: .fresh)
    }
}

struct DashboardSnapshotCacheEnvelope: Sendable, Equatable, Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let key: DashboardSnapshotCacheKey
    let generatedAt: Date
    let snapshot: DashboardSnapshot

    init(
        schemaVersion: Int = currentSchemaVersion,
        key: DashboardSnapshotCacheKey,
        generatedAt: Date,
        snapshot: DashboardSnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.key = key
        self.generatedAt = generatedAt
        self.snapshot = snapshot
    }
}

struct DashboardSnapshotStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = DashboardSnapshotStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() -> DashboardSnapshotCacheEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let envelope = try? decoder.decode(
            DashboardSnapshotCacheEnvelope.self,
            from: data),
              envelope.schemaVersion == DashboardSnapshotCacheEnvelope.currentSchemaVersion
        else {
            return nil
        }
        return envelope
    }

    func save(_ envelope: DashboardSnapshotCacheEnvelope) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }

    static func defaultFileURL() -> URL {
        LocalQAEnvironment.applicationSupportDirectory()
            .appendingPathComponent("QuotaMonitor", isDirectory: true)
            .appendingPathComponent("dashboard-snapshot-v1.json", isDirectory: false)
    }
}

actor DashboardSnapshotPersistence {
    private let store: DashboardSnapshotStore
    private var latestSequence = 0

    init(store: DashboardSnapshotStore = DashboardSnapshotStore()) {
        self.store = store
    }

    func save(_ envelope: DashboardSnapshotCacheEnvelope, sequence: Int) -> Bool {
        guard sequence > latestSequence else { return true }
        latestSequence = sequence
        do {
            try store.save(envelope)
            return true
        } catch {
            return false
        }
    }
}
