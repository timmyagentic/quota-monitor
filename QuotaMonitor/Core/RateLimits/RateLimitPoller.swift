import Foundation
import GRDB

// Long-running background task that polls `account/rateLimits/read` on a fixed
// interval, persists live samples into `rate_limit_samples`, and updates the
// shared snapshot so the menu bar / charts react in real time.
//
// We keep this separate from `AppServerClient` because it owns lifecycle
// (cancellation, retry-on-failure) and writes to the database — concerns the
// stateless RPC client should not have.

actor RateLimitPoller {
    private let appServer: AppServerClient
    private let database: DatabaseManager
    private var interval: Duration
    private var task: Task<Void, Never>?
    private let onSnapshot: @Sendable (RateLimitSnapshot) async -> Void

    init(
        appServer: AppServerClient,
        database: DatabaseManager,
        interval: Duration = .seconds(300),
        onSnapshot: @escaping @Sendable (RateLimitSnapshot) async -> Void
    ) {
        self.appServer = appServer
        self.database = database
        self.interval = interval
        self.onSnapshot = onSnapshot
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Small startup delay so the menu bar's eager refresh isn't immediately
            // shadowed by a duplicate poll.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self.pollOnce()
                let nextInterval = await self.interval
                try? await Task.sleep(for: nextInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Hot-update the polling interval. Takes effect after the current sleep.
    func updateInterval(_ newInterval: Duration) {
        self.interval = newInterval
    }

    // MARK: - Single poll

    func pollOnce() async {
        do {
            let payload = try await appServer.readRateLimits()
            let snapshot = RateLimitSnapshot(from: payload)
            await onSnapshot(snapshot)
            try await persist(snapshot: snapshot)
            Log.poller.info("poll ok primary=\(snapshot.primary?.usedPercent ?? -1, privacy: .public)% secondary=\(snapshot.secondary?.usedPercent ?? -1, privacy: .public)%")
        } catch {
            // Swallow — connection blips happen. Next interval will retry.
            Log.poller.error("poll failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist(snapshot: RateLimitSnapshot) async throws {
        let captured = ISO8601.fractional.string(from: snapshot.capturedAt)
        let plan = snapshot.planType
        try await database.pool.write { db in
            if let p = snapshot.primary {
                try Self.insertSample(
                    db: db, captured: captured, plan: plan,
                    bucket: "primary", limitName: nil, window: p)
            }
            if let s = snapshot.secondary {
                try Self.insertSample(
                    db: db, captured: captured, plan: plan,
                    bucket: "secondary", limitName: nil, window: s)
            }
            for extra in snapshot.additional {
                if let p = extra.primary {
                    try Self.insertSample(
                        db: db, captured: captured, plan: plan,
                        bucket: "primary", limitName: extra.limitName, window: p)
                }
                if let s = extra.secondary {
                    try Self.insertSample(
                        db: db, captured: captured, plan: plan,
                        bucket: "secondary", limitName: extra.limitName, window: s)
                }
            }
        }
    }

    private static func insertSample(
        db: Database,
        captured: String,
        plan: String?,
        bucket: String,
        limitName: String?,
        window: RateLimitSnapshot.Window
    ) throws {
        let resetIso = ISO8601.fractional.string(from: window.resetAt)
        try db.execute(sql: """
            INSERT INTO rate_limit_samples
              (source_kind, source_session_id, bucket, sample_timestamp,
               plan_type, limit_name, window_start, resets_at,
               used_percent, remaining_percent)
            VALUES (?, NULL, ?, ?, ?, ?, NULL, ?, ?, ?)
            """, arguments: [
                "live",
                bucket,
                captured,
                plan,
                limitName,
                resetIso,
                window.usedPercent,
                max(0, 100 - window.usedPercent)
            ])
    }
}
