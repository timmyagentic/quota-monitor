import Foundation
import GRDB

/// Mirror of `RateLimitPoller` for the Claude OAuth `/usage` endpoint.
/// Same lifecycle (start / stop / hot-reload interval), same persistence
/// pattern (writes into `rate_limit_samples` so existing analytics keep
/// working), different transport.
///
/// Failures are intentionally swallowed when transient: the menu bar
/// already surfaces `lastClaudeUsageError` for auth-class problems, so
/// noisy retries on a missing-token machine don't help. We back off
/// from the default 2-hour cadence to 30 min after the first auth
/// failure (avoid keychain-prompt storms) and run the 5/30-min 429
/// ladder via `cooldownUntil` below.
///
/// `/usage` may be triggered from the menu-bar Refresh button — the
/// 60-second spam gap plus the `cooldownUntil` gate keep that safe:
/// spam-clicking can't earn a 429, and once we *have* been 429'd both
/// the scheduled loop and any manual caller honour the same cooldown.
/// Without this two-gate setup a manual refresh 60 seconds after a
/// 429 would immediately step on the limit again.
actor ClaudeUsagePoller {
    /// Min seconds between any two `pollOnce()` invocations, including
    /// programmatic / manual ones. Just enough to absorb double-clicks
    /// or accidental rapid retries — the real cadence guard is the
    /// scheduled `interval`, and the real rate-limit defense is
    /// `cooldownUntil`.
    static let minimumGap: Duration = .seconds(60)

    /// Default scheduled cadence for the live `/api/oauth/usage` poll.
    /// 10 minutes keeps the 5h/7d quota meter fresh (the old value was
    /// 2 h, which left the meter stale for hours). Polling the endpoint
    /// this often is safe because the 429 cooldown ladder (`cooldownUntil`,
    /// 5 min → 30 min, honouring `Retry-After`) backs off automatically if
    /// Anthropic edge-rate-limits us — the same approach other clients of
    /// this endpoint use.
    static let defaultInterval: Duration = .seconds(600)

    private let client: any ClaudeUsageFetching
    private let database: DatabaseManager
    private var interval: Duration
    private var task: Task<Void, Never>?
    private let onSnapshot: @Sendable (Result<ClaudeUsageSnapshot, any Error>) async -> Void
    /// Notified whenever the 429 cooldown is set (future Date) or
    /// cleared (nil). Lets the UI render a "limited, retry in X"
    /// indicator on the Claude block without poking the actor on every
    /// frame. Default no-op for tests that don't care.
    private let onCooldownChange: @Sendable (Date?) async -> Void
    private var consecutiveAuthFailures = 0
    /// Earliest wall-clock time at which the next poll attempt is
    /// allowed. Set by a 429 to `now + max(Retry-After, fallback,
    /// 60 s)` where `fallback` is 5 min for the first 429 in a streak
    /// and 30 min for any subsequent one. Cleared by a successful
    /// fetch.
    ///
    /// Gates both the scheduled loop and any manual caller — without
    /// this, the UI Refresh button would step on a fresh 429 the
    /// moment the 60-second spam gap elapsed.
    private var cooldownUntil: Date?
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
        interval: Duration = ClaudeUsagePoller.defaultInterval,
        onSnapshot: @escaping @Sendable (Result<ClaudeUsageSnapshot, any Error>) async -> Void,
        onCooldownChange: @escaping @Sendable (Date?) async -> Void = { _ in }
    ) {
        self.client = client
        self.database = database
        self.interval = interval
        self.onSnapshot = onSnapshot
        self.onCooldownChange = onCooldownChange
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Stagger from the Codex poller so they don't both fire at boot.
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                await self.pollOnce()
                let nextSleep = await self.scheduledSleepDuration()
                try? await Task.sleep(for: nextSleep)
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
    var _cooldownUntilForTest: Date? { cooldownUntil }
    var _intervalForTest: Duration { interval }
    /// Back-compat derived value: seconds between the latest poll
    /// attempt and the cooldown deadline it produced. Returns nil when
    /// either is missing or the cooldown has already elapsed. Lets
    /// existing tests keep asserting on "the backoff window was N
    /// seconds" without caring how it's stored internally.
    var _nextDelayOverrideSecondsForTest: Int64? {
        guard let cooldownUntil, let lastAttemptAt else { return nil }
        let diff = cooldownUntil.timeIntervalSince(lastAttemptAt)
        return diff > 0 ? Int64(diff.rounded()) : nil
    }
    var _lastAttemptAtForTest: Date? { lastAttemptAt }
    /// Clears the 60-second spam-gap timestamp so a test can issue two
    /// `pollOnce()` calls back-to-back without waiting in real time.
    func _clearLastAttemptForTest() { lastAttemptAt = nil }
    /// Pretends an active 429 cooldown has already elapsed (rewinds to
    /// "just past"). The cooldown is left non-nil so a subsequent
    /// successful fetch still exercises the "clear + notify" branch.
    func _setCooldownToPastForTest() {
        cooldownUntil = Date(timeIntervalSinceNow: -1)
    }
    /// Convenience for tests that want a fully clean slate between
    /// pollOnce calls (no spam gap, no cooldown). Equivalent to
    /// calling both `_clearLastAttemptForTest` and a no-callback
    /// cooldown clear.
    func _resetThrottleForTest() {
        lastAttemptAt = nil
        cooldownUntil = nil
    }

    /// How long the scheduled loop should sleep before its next
    /// attempt. Auth failures stretch the cadence to 30 min; an active
    /// 429 cooldown collapses it to "until the cooldown lifts" so we
    /// recover as soon as the server lets us. With no special state,
    /// returns the configured `interval` (default 10 min).
    private func scheduledSleepDuration() -> Duration {
        let base = consecutiveAuthFailures >= 1 ? Duration.seconds(1800) : interval
        guard let cooldownUntil else { return base }
        let now = Date()
        guard cooldownUntil > now else { return base }
        let remaining = cooldownUntil.timeIntervalSince(now)
        return .seconds(max(1.0, remaining))
    }

    /// `force` bypasses the 60-second spam gap so the explicit Refresh
    /// button always re-polls. It does NOT bypass the 429 cooldown — a real
    /// rate-limit must still be honoured, or the button would earn more 429s.
    func pollOnce(force: Bool = false) async {
        let now = Date()
        // 60-second spam gap. Applies to scheduled and (non-forced) manual
        // callers alike. The endpoint's edge rate limit has no useful
        // response to sub-minute polling beyond silent 429s.
        if !force, let last = lastAttemptAt {
            let elapsed = now.timeIntervalSince(last)
            let gapSec = Double(Self.minimumGap.components.seconds)
            if elapsed < gapSec {
                Log.poller.info("claude /usage skipped — last attempt \(Int(elapsed), privacy: .public)s ago, min gap \(Int(gapSec), privacy: .public)s")
                DeveloperLog.eventRecord(
                    "claude_usage.poll.skip",
                    category: "poller",
                    provider: "claude",
                    result: "skipped",
                    fields: [
                        "reason": "minimum-gap",
                        "elapsed_seconds": .int(Int(elapsed)),
                        "minimum_gap_seconds": .int(Int(gapSec))
                    ])
                return
            }
        }
        // 429 cooldown gate. Gates manual callers (Refresh button) AND
        // protects the scheduled loop against early wake-ups (clock
        // adjustments, debug pauses). Outlives any single pollOnce
        // call — only success or the cooldown elapsing clears it.
        if let until = cooldownUntil, until > now {
            let remaining = until.timeIntervalSince(now)
            Log.poller.info("claude /usage skipped — in 429 cooldown for \(Int(remaining), privacy: .public)s more")
            DeveloperLog.eventRecord(
                "claude_usage.poll.skip",
                category: "poller",
                provider: "claude",
                result: "skipped",
                fields: [
                    "reason": "rate-limit-cooldown",
                    "remaining_seconds": .int(Int(remaining)),
                    "cooldown_until": .string(ISO8601.fractional.string(from: until))
                ])
            return
        }
        lastAttemptAt = now
        do {
            let snapshot = try await client.fetch()
            consecutiveAuthFailures = 0
            consecutiveRateLimits = 0
            // Fire the cooldown-cleared notice BEFORE the snapshot so
            // the UI doesn't briefly render fresh data while still
            // showing "rate-limited, retry in X".
            if cooldownUntil != nil {
                cooldownUntil = nil
                await onCooldownChange(nil)
            }
            await onSnapshot(.success(snapshot))
            try await persist(snapshot: snapshot)
            Log.poller.info("claude /usage ok 5h=\(snapshot.fiveHour?.usedPercent ?? -1, privacy: .public)% 7d=\(snapshot.sevenDay?.usedPercent ?? -1, privacy: .public)%")
            DeveloperLog.eventRecord(
                "claude_usage.poll.finish",
                category: "poller",
                provider: "claude",
                result: "success",
                fields: [
                    "five_hour_used_percent": .double(snapshot.fiveHour?.usedPercent ?? -1),
                    "seven_day_used_percent": .double(snapshot.sevenDay?.usedPercent ?? -1),
                    "tier": .string(snapshot.tier ?? "")
                ])
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
                let until = now.addingTimeInterval(seconds)
                cooldownUntil = until
                await onCooldownChange(until)
                // Do NOT surface to UI as an `onSnapshot` failure: 429 is a
                // transient, non-actionable signal. The cooldown callback
                // gives the UI the actionable bit ("limited, retry in X").
                Log.poller.info("claude /usage 429 (#\(self.consecutiveRateLimits, privacy: .public)), backing off \(seconds, privacy: .public)s")
                DeveloperLog.eventRecord(
                    "claude_usage.poll.rate_limited",
                    category: "poller",
                    provider: "claude",
                    result: "rate_limited",
                    fields: [
                        "count": .int(self.consecutiveRateLimits),
                        "backoff_seconds": .double(seconds),
                        "cooldown_until": .string(ISO8601.fractional.string(from: until))
                    ])
                return
            default:
                await onSnapshot(.failure(error))
            }
            Log.poller.error("claude /usage failed: \(String(describing: error), privacy: .public)")
            DeveloperLog.eventRecord(
                "claude_usage.poll.fail",
                level: .error,
                category: "poller",
                provider: "claude",
                result: "failure",
                message: String(describing: error),
                fields: [
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
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
            // Trim stale samples in the same transaction so the table stays
            // bounded — only writes grow it, so only writes need to prune.
            try RateLimitSampleRetention.prune(db: db)
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
