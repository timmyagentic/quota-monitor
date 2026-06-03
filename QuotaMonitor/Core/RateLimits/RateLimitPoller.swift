import Foundation
import GRDB

protocol CodexRateLimitsFetching: Sendable {
    func readRateLimits() async throws -> RateLimitsPayload
}

extension AppServerClient: CodexRateLimitsFetching {}

// Long-running background task that polls `account/rateLimits/read` on a fixed
// interval, persists live samples into `rate_limit_samples`, and updates the
// shared snapshot so the menu bar / charts react in real time.
//
// We keep this separate from `AppServerClient` because it owns lifecycle
// (cancellation, retry-on-failure) and writes to the database — concerns the
// stateless RPC client should not have.

actor RateLimitPoller {
    static let minimumGap: Duration = .seconds(60)

    enum SkipReason: Sendable {
        case minimumGap(elapsedSeconds: Int, minimumSeconds: Int)
        case rateLimitCooldown(remainingSeconds: Int, until: Date)
    }

    enum PollOutcome: Sendable {
        case success(RateLimitSnapshot)
        case skipped(SkipReason)
        case failure(String)
    }

    private let fetcher: any CodexRateLimitsFetching
    private let database: DatabaseManager
    private var interval: Duration
    private var task: Task<Void, Never>?
    private let onSnapshot: @Sendable (RateLimitSnapshot) async -> Void
    private var cooldownUntil: Date?
    private var lastAttemptAt: Date?
    private var consecutiveRateLimits = 0

    init(
        fetcher: any CodexRateLimitsFetching,
        database: DatabaseManager,
        interval: Duration = .seconds(300),
        onSnapshot: @escaping @Sendable (RateLimitSnapshot) async -> Void
    ) {
        self.fetcher = fetcher
        self.database = database
        self.interval = interval
        self.onSnapshot = onSnapshot
    }

    init(
        appServer: AppServerClient,
        database: DatabaseManager,
        interval: Duration = .seconds(300),
        onSnapshot: @escaping @Sendable (RateLimitSnapshot) async -> Void
    ) {
        self.init(
            fetcher: appServer,
            database: database,
            interval: interval,
            onSnapshot: onSnapshot)
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
                let nextInterval = await self.scheduledSleepDuration()
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

    // MARK: - test inspection

    var _cooldownUntilForTest: Date? { cooldownUntil }
    var _consecutiveRateLimitsForTest: Int { consecutiveRateLimits }
    var _lastAttemptAtForTest: Date? { lastAttemptAt }
    var _nextDelayOverrideSecondsForTest: Int64? {
        guard let cooldownUntil, let lastAttemptAt else { return nil }
        let diff = cooldownUntil.timeIntervalSince(lastAttemptAt)
        return diff > 0 ? Int64(diff.rounded()) : nil
    }

    func _clearLastAttemptForTest() {
        lastAttemptAt = nil
    }

    func _setCooldownToPastForTest() {
        cooldownUntil = Date(timeIntervalSinceNow: -1)
    }

    func _resetThrottleForTest() {
        lastAttemptAt = nil
        cooldownUntil = nil
    }

    // MARK: - Single poll

    @discardableResult
    func pollOnce(
        trigger: String? = nil,
        bypassMinimumGap: Bool = false
    ) async -> PollOutcome {
        let now = Date()
        if !bypassMinimumGap, let last = lastAttemptAt {
            let elapsed = now.timeIntervalSince(last)
            let gapSec = Double(Self.minimumGap.components.seconds)
            if elapsed < gapSec {
                Log.poller.info("codex usage skipped — last attempt \(Int(elapsed), privacy: .public)s ago, min gap \(Int(gapSec), privacy: .public)s")
                DeveloperLog.eventRecord(
                    "ratelimits.poll.skip",
                    category: "poller",
                    trigger: trigger,
                    provider: "codex",
                    result: "skipped",
                    fields: [
                        "reason": "minimum-gap",
                        "elapsed_seconds": .int(Int(elapsed)),
                        "minimum_gap_seconds": .int(Int(gapSec))
                    ])
                return .skipped(.minimumGap(
                    elapsedSeconds: Int(elapsed),
                    minimumSeconds: Int(gapSec)))
            }
        }

        if let until = cooldownUntil, until > now {
            let remaining = until.timeIntervalSince(now)
            Log.poller.info("codex usage skipped — in 429 cooldown for \(Int(remaining), privacy: .public)s more")
            DeveloperLog.eventRecord(
                "ratelimits.poll.skip",
                category: "poller",
                trigger: trigger,
                provider: "codex",
                result: "skipped",
                fields: [
                    "reason": "rate-limit-cooldown",
                    "remaining_seconds": .int(Int(remaining)),
                    "cooldown_until": .string(ISO8601.fractional.string(from: until))
                ])
            return .skipped(.rateLimitCooldown(
                remainingSeconds: Int(remaining),
                until: until))
        }

        lastAttemptAt = now
        do {
            let payload = try await fetcher.readRateLimits()
            let snapshot = RateLimitSnapshot(from: payload)
            consecutiveRateLimits = 0
            cooldownUntil = nil
            await onSnapshot(snapshot)
            try await persist(snapshot: snapshot)
            Log.poller.info("poll ok primary=\(snapshot.primary?.usedPercent ?? -1, privacy: .public)% secondary=\(snapshot.secondary?.usedPercent ?? -1, privacy: .public)%")
            DeveloperLog.eventRecord(
                "ratelimits.poll.finish",
                category: "poller",
                provider: "codex",
                result: "success",
                fields: [
                    "plan_type": .string(snapshot.planType ?? ""),
                    "primary_used_percent": .double(snapshot.primary?.usedPercent ?? -1),
                    "secondary_used_percent": .double(snapshot.secondary?.usedPercent ?? -1)
                ])
            return .success(snapshot)
        } catch {
            if Self.isRateLimitError(error) {
                consecutiveRateLimits += 1
                let fallback: TimeInterval = consecutiveRateLimits == 1 ? 300 : 1800
                let seconds = max(Self.retryAfterSeconds(from: error) ?? fallback, 60)
                let until = now.addingTimeInterval(seconds)
                cooldownUntil = until
                Log.poller.info("codex usage 429 (#\(self.consecutiveRateLimits, privacy: .public)), backing off \(seconds, privacy: .public)s")
                DeveloperLog.eventRecord(
                    "ratelimits.poll.rate_limited",
                    category: "poller",
                    trigger: trigger,
                    provider: "codex",
                    result: "rate_limited",
                    fields: [
                        "count": .int(self.consecutiveRateLimits),
                        "backoff_seconds": .double(seconds),
                        "bypass_minimum_gap": .bool(bypassMinimumGap),
                        "cooldown_until": .string(ISO8601.fractional.string(from: until))
                    ])
                return .skipped(.rateLimitCooldown(
                    remainingSeconds: Int(seconds),
                    until: until))
            }
            // Swallow — connection blips happen. Next interval will retry.
            Log.poller.error("poll failed: \(String(describing: error), privacy: .public)")
            let message = String(describing: error)
            DeveloperLog.eventRecord(
                "ratelimits.poll.fail",
                level: .error,
                category: "poller",
                provider: "codex",
                result: "failure",
                message: String(describing: error),
                fields: [
                    "error_type": .string(String(describing: type(of: error))),
                    "error_message": .string(error.localizedDescription)
                ])
            return .failure(message)
        }
    }

    private func scheduledSleepDuration() -> Duration {
        guard let cooldownUntil else { return interval }
        let now = Date()
        guard cooldownUntil > now else { return interval }
        let remaining = cooldownUntil.timeIntervalSince(now)
        return .seconds(max(1.0, remaining))
    }

    private static func isRateLimitError(_ error: any Error) -> Bool {
        let text = String(describing: error)
        return text.contains("429")
            || text.localizedCaseInsensitiveContains("Too Many Requests")
            || text.localizedCaseInsensitiveContains("rate-limited")
            || text.localizedCaseInsensitiveContains("rate limited")
    }

    private static func retryAfterSeconds(from error: any Error) -> TimeInterval? {
        let text = String(describing: error)
        let patterns = [
            #"(?i)retry[- ]?after[:= ]+([0-9]+(?:\.[0-9]+)?)"#,
            #"(?i)retry in ~?([0-9]+(?:\.[0-9]+)?)s"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2,
                  let capture = Range(match.range(at: 1), in: text),
                  let seconds = TimeInterval(text[capture])
            else { continue }
            return seconds
        }
        return nil
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
