import Foundation
import GRDB

/// Mirror of `RateLimitPoller` for the Claude OAuth `/usage` endpoint.
/// Same lifecycle (start / stop / hot-reload interval), same persistence
/// pattern (writes into `rate_limit_samples` so existing analytics keep
/// working), different transport.
///
/// Failures are intentionally swallowed: the menu bar already surfaces
/// `lastClaudeUsageError`, so noisy retries on a missing-token machine
/// don't help. We back off from the default 2-hour cadence to 30 min
/// after the first auth failure (avoid keychain-prompt storms) and to
/// 30 min — or `Retry-After` — after a 429.
///
/// `/usage` is **not** intended to be hit on every menu open. The endpoint
/// is rate-limited at the Anthropic edge; calling it from a UI refresh
/// button reliably triggers HTTP 429 within a session. `pollOnce()`
/// enforces a 30-minute min-gap regardless of caller, in addition to the
/// scheduled cadence.
actor ClaudeUsagePoller {
    /// Min seconds between any two `pollOnce()` invocations, including
    /// programmatic / manual ones. Just enough to absorb double-clicks
    /// or accidental rapid retries — the real cadence guard is the 2 h
    /// scheduled `interval`.
    static let minimumGap: Duration = .seconds(60)

    private let client: any ClaudeUsageFetching
    private let database: DatabaseManager
    private var interval: Duration
    private var task: Task<Void, Never>?
    private let onSnapshot: @Sendable (Result<ClaudeUsageSnapshot, any Error>) async -> Void
    private var consecutiveAuthFailures = 0
    /// When non-nil, overrides `currentInterval()` for the next poll only.
    /// Set after a 429 to honour Anthropic's `Retry-After` (or fall back
    /// to 30 min) so we stop self-amplifying the rate-limit storm.
    private var nextDelayOverride: Duration?
    /// Wall-clock time of the last attempted `pollOnce`. Drives the
    /// `minimumGap` throttle so a UI bug (e.g. wiring `pollOnce` to a
    /// click handler) can't accidentally hammer the endpoint.
    private var lastAttemptAt: Date?
    /// Counts consecutive 429s. The first one (often a cold-start clash
    /// with another Anthropic client) gets a short retry; persistent
    /// limiting gets the full 30-min back-off.
    private var consecutiveRateLimits = 0

    init(
        client: any ClaudeUsageFetching = ClaudeUsageClient(),
        database: DatabaseManager,
        interval: Duration = .seconds(7200),
        onSnapshot: @escaping @Sendable (Result<ClaudeUsageSnapshot, any Error>) async -> Void
    ) {
        self.client = client
        self.database = database
        self.interval = interval
        self.onSnapshot = onSnapshot
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Stagger from the Codex poller so they don't both fire at boot.
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                await self.pollOnce()
                let nextInterval = await self.currentInterval()
                try? await Task.sleep(for: nextInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func updateInterval(_ newInterval: Duration) {
        self.interval = newInterval
    }

    // MARK: - test inspection (internal — used only by ClaudeUsagePollerTests).
    // The poller's interesting state is private, but the tests need to
    // assert "after a 429, the next sleep would be N seconds". Exposing
    // these as `internal` lets the test target read them via `@testable
    // import` without mutating production callers.
    var _consecutiveRateLimitsForTest: Int { consecutiveRateLimits }
    var _consecutiveAuthFailuresForTest: Int { consecutiveAuthFailures }
    var _nextDelayOverrideSecondsForTest: Int64? {
        nextDelayOverride.map(\.components.seconds)
    }
    var _lastAttemptAtForTest: Date? { lastAttemptAt }
    /// Clears the minimum-gap timestamp so a test can issue two
    /// `pollOnce()` calls back-to-back without waiting 60 real seconds.
    func _resetThrottleForTest() { lastAttemptAt = nil }

    /// Use a longer cool-off after auth failures so we don't poke the
    /// keychain (potentially prompting the user) every 5 minutes. A 429
    /// from the previous poll wins over both.
    private func currentInterval() -> Duration {
        if let override = nextDelayOverride {
            nextDelayOverride = nil
            return override
        }
        return consecutiveAuthFailures >= 1 ? .seconds(1800) : interval
    }

    func pollOnce() async {
        // Hard min-gap: even manual / programmatic callers must respect
        // it. The endpoint's edge rate limit gives us no useful behaviour
        // for sub-30-min polling and silently degrades to 429.
        if let last = lastAttemptAt {
            let elapsed = Date().timeIntervalSince(last)
            let gapSec = Double(Self.minimumGap.components.seconds)
            if elapsed < gapSec {
                Log.poller.info("claude /usage skipped — last attempt \(Int(elapsed), privacy: .public)s ago, min gap \(Int(gapSec), privacy: .public)s")
                return
            }
        }
        lastAttemptAt = Date()
        do {
            let snapshot = try await client.fetch()
            consecutiveAuthFailures = 0
            consecutiveRateLimits = 0
            await onSnapshot(.success(snapshot))
            try await persist(snapshot: snapshot)
            Log.poller.info("claude /usage ok 5h=\(snapshot.fiveHour?.usedPercent ?? -1, privacy: .public)% 7d=\(snapshot.sevenDay?.usedPercent ?? -1, privacy: .public)%")
        } catch {
            // Track auth-class failures separately so the back-off only
            // triggers on persistent misconfig, not transient network errors.
            switch error {
            case ClaudeUsageClient.FetchError.noCredentials,
                 ClaudeUsageClient.FetchError.unauthorized,
                 ClaudeUsageClient.FetchError.insufficientScope:
                consecutiveAuthFailures += 1
                await onSnapshot(.failure(error))
            case ClaudeUsageClient.FetchError.rateLimited(let retryAfter):
                // Server told us to slow down. Honour Retry-After if present.
                // Otherwise: first 429 in a row often resolves quickly (a
                // sibling Anthropic client just hit the bucket), so try
                // again in 5 min. Persistent 429s back off to 30 min.
                consecutiveRateLimits += 1
                let fallback: TimeInterval = consecutiveRateLimits == 1 ? 300 : 1800
                let seconds = max(retryAfter ?? fallback, 60)
                nextDelayOverride = .seconds(seconds)
                // Do NOT surface to UI: 429 is a transient, non-actionable
                // signal (the retry happens automatically). Showing it as
                // an "error" leads users to think something is broken.
                Log.poller.info("claude /usage 429 (#\(self.consecutiveRateLimits, privacy: .public)), backing off \(seconds, privacy: .public)s")
                return
            default:
                await onSnapshot(.failure(error))
            }
            Log.poller.error("claude /usage failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist(snapshot: ClaudeUsageSnapshot) async throws {
        let captured = ISO8601.fractional.string(from: snapshot.capturedAt)
        let plan = snapshot.tier
        try await database.pool.write { db in
            // We persist all four windows under bucket=primary/secondary
            // to share queries with the Codex pollers, distinguished by
            // source_kind ("claude_oauth") + limit_name (model breakdown).
            if let w = snapshot.fiveHour {
                try Self.insert(db, captured: captured, plan: plan,
                                bucket: "primary", limitName: nil, window: w)
            }
            if let w = snapshot.sevenDay {
                try Self.insert(db, captured: captured, plan: plan,
                                bucket: "secondary", limitName: nil, window: w)
            }
            if let w = snapshot.sevenDayOpus {
                try Self.insert(db, captured: captured, plan: plan,
                                bucket: "secondary", limitName: "opus", window: w)
            }
            if let w = snapshot.sevenDaySonnet {
                try Self.insert(db, captured: captured, plan: plan,
                                bucket: "secondary", limitName: "sonnet", window: w)
            }
        }
    }

    private static func insert(
        _ db: Database, captured: String, plan: String?,
        bucket: String, limitName: String?,
        window: ClaudeUsageSnapshot.Window
    ) throws {
        let resetIso = ISO8601.fractional.string(from: window.resetAt)
        try db.execute(sql: """
            INSERT INTO rate_limit_samples
              (source_kind, source_session_id, bucket, sample_timestamp,
               plan_type, limit_name, window_start, resets_at,
               used_percent, remaining_percent)
            VALUES (?, NULL, ?, ?, ?, ?, NULL, ?, ?, ?)
            """, arguments: [
                "claude_oauth",
                bucket, captured, plan, limitName,
                resetIso,
                window.usedPercent,
                max(0, 100 - window.usedPercent),
            ])
    }
}
