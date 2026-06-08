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
    private let fetchTimeout: Duration
    private var task: Task<Void, Never>?
    private let onSnapshot: @Sendable (RateLimitSnapshot) async -> Void
    private var cooldownUntil: Date?
    private var lastAttemptAt: Date?
    private var consecutiveRateLimits = 0

    init(
        fetcher: any CodexRateLimitsFetching,
        database: DatabaseManager,
        interval: Duration = .seconds(300),
        fetchTimeout: Duration = .seconds(30),
        onSnapshot: @escaping @Sendable (RateLimitSnapshot) async -> Void
    ) {
        self.fetcher = fetcher
        self.database = database
        self.interval = interval
        self.fetchTimeout = fetchTimeout
        self.onSnapshot = onSnapshot
    }

    init(
        appServer: AppServerClient,
        database: DatabaseManager,
        interval: Duration = .seconds(300),
        fetchTimeout: Duration = .seconds(30),
        onSnapshot: @escaping @Sendable (RateLimitSnapshot) async -> Void
    ) {
        self.init(
            fetcher: appServer,
            database: database,
            interval: interval,
            fetchTimeout: fetchTimeout,
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

        lastAttemptAt = now
        do {
            let fetcher = self.fetcher
            let payload = try await Self.withTimeout(
                fetchTimeout,
                context: "Codex rate-limit fetch"
            ) {
                try await fetcher.readRateLimits()
            }
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

    /// Scan only the upstream RPC message for rate-limit signals when we
    /// have one. `String(describing:)` of the whole error also serializes
    /// the Swift type names, request ids, and any nested `data`, any of
    /// which can carry a stray "429" that would wrongly trip a long cooldown.
    private static func rateLimitProbeText(for error: any Error) -> String {
        if let client = error as? AppServerClient.ClientError,
           case .rpcError(let rpc) = client {
            return rpc.message
        }
        if let rpc = error as? JSONRPCError {
            return rpc.message
        }
        return String(describing: error)
    }

    private static func isRateLimitError(_ error: any Error) -> Bool {
        let text = rateLimitProbeText(for: error)
        if text.localizedCaseInsensitiveContains("Too Many Requests")
            || text.localizedCaseInsensitiveContains("rate-limited")
            || text.localizedCaseInsensitiveContains("rate limited") {
            return true
        }
        // A standalone HTTP 429 (e.g. "... failed: 429"), but not a "429"
        // buried inside a larger number such as a byte offset (14290) or a
        // request id — those must not be mistaken for rate limiting.
        return firstMatch(#"(?<![0-9])429(?![0-9])"#, in: text) != nil
    }

    private static func retryAfterSeconds(from error: any Error) -> TimeInterval? {
        let text = rateLimitProbeText(for: error)
        let patterns = [
            #"(?i)retry[- ]?after[:= ]+([0-9]+(?:\.[0-9]+)?)"#,
            #"(?i)retry in ~?([0-9]+(?:\.[0-9]+)?)s"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: text),
                  match.numberOfRanges >= 2,
                  let capture = Range(match.range(at: 1), in: text),
                  let seconds = TimeInterval(text[capture])
            else { continue }
            return seconds
        }
        return nil
    }

    private static func firstMatch(
        _ pattern: String,
        in text: String
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }

    private static func withTimeout<R: Sendable>(
        _ duration: Duration,
        context: String,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        let race = RateLimitPollerTimeoutRace<R>()
        let workTask = Task {
            do {
                let value = try await operation()
                await race.finish(.success(value))
            } catch {
                await race.finish(.failure(error))
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await race.finish(.failure(RateLimitPollerTimeoutError(context: context)))
        }

        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            workTask.cancel()
            timeoutTask.cancel()
            Task {
                await race.finish(.failure(CancellationError()))
            }
        }
        workTask.cancel()
        timeoutTask.cancel()
        return try result.get()
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

private struct RateLimitPollerTimeoutError: LocalizedError, CustomStringConvertible, Sendable {
    let context: String
    var description: String { "\(context) timed out" }
    var errorDescription: String? { description }
}

private actor RateLimitPollerTimeoutRace<R: Sendable> {
    private var result: Result<R, any Error>?
    private var continuation: CheckedContinuation<Result<R, any Error>, Never>?

    func wait() async -> Result<R, any Error> {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ newResult: Result<R, any Error>) {
        guard result == nil else { return }
        result = newResult
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: newResult)
    }
}
