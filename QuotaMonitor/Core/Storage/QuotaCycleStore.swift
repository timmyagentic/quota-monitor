import Foundation
import GRDB

enum QuotaCycleStore {
    private struct ProviderState: Codable {
        let capturedAt: Date
        let cycles: [QuotaCycle]
    }

    /// One bounded record per provider. An empty response retires missing
    /// windows, and an out-of-order response cannot resurrect the old ones.
    static func record(
        db: Database, provider: String, capturedAt: Date,
        observations: [QuotaCycle.Observation]
    ) throws {
        let previous = try load(db: db, provider: provider)
        guard previous == nil || capturedAt > previous!.capturedAt else { return }
        let cycles = observations.map { observation in
            QuotaCycle.resolve(observation, previous: previous?.cycles.first {
                $0.observation.bucket == observation.bucket
            })
        }
        let data = try JSONEncoder().encode(ProviderState(capturedAt: capturedAt, cycles: cycles))
        try db.execute(sql: """
            INSERT INTO quota_cycle_state (provider, state) VALUES (?, ?)
            ON CONFLICT(provider) DO UPDATE SET state = excluded.state
            """, arguments: [provider, data])
    }

    static func cycles(db: Database) throws -> [QuotaCycle] {
        try ["codex", "claude"].flatMap { try load(db: db, provider: $0)?.cycles ?? [] }
    }

    private static func load(db: Database, provider: String) throws -> ProviderState? {
        guard let data = try Data.fetchOne(db, sql:
            "SELECT state FROM quota_cycle_state WHERE provider = ?", arguments: [provider])
        else { return nil }
        return try JSONDecoder().decode(ProviderState.self, from: data)
    }

    static func record(db: Database, snapshot: RateLimitSnapshot) throws {
        let windows = [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
        try record(db: db, provider: "codex", capturedAt: snapshot.capturedAt,
                   observations: windows.compactMap { bucket, window in
            window.map { .init(provider: "codex", bucket: bucket,
                               scope: snapshot.observationScope, plan: snapshot.planType,
                               capturedAt: snapshot.capturedAt, resetAt: $0.resetAt,
                               duration: $0.windowDuration, usedPercent: $0.usedPercent) }
        })
    }

    static func record(db: Database, snapshot: ClaudeUsageSnapshot) throws {
        let windows = [("primary", snapshot.fiveHour), ("secondary", snapshot.sevenDay)]
        try record(db: db, provider: "claude", capturedAt: snapshot.capturedAt,
                   observations: windows.compactMap { bucket, window in
            window.map { .init(provider: "claude", bucket: bucket,
                               scope: snapshot.observationScope, plan: snapshot.tier,
                               capturedAt: snapshot.capturedAt, resetAt: $0.resetAt,
                               duration: $0.windowDuration, usedPercent: $0.usedPercent) }
        })
    }
}
