import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex RateLimitPoller state machine")
struct RateLimitPollerTests {
    actor MockCodexRateLimitsFetcher: CodexRateLimitsFetching {
        enum Step: Sendable {
            case success(RateLimitsPayload)
            case failure(any Error)
            case hang
        }

        private var script: [Step]
        private var calls = 0

        init(script: [Step]) {
            self.script = script
        }

        func readRateLimits() async throws -> RateLimitsPayload {
            calls += 1
            let step = script.count > 1 ? script.removeFirst() : script[0]
            switch step {
            case .success(let payload):
                return payload
            case .failure(let error):
                throw error
            case .hang:
                return await withUnsafeContinuation { (_: UnsafeContinuation<RateLimitsPayload, Never>) in }
            }
        }

        var callCount: Int { calls }
    }

    final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [RateLimitSnapshot] = []

        func append(_ snapshot: RateLimitSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            snapshots.append(snapshot)
        }

        var all: [RateLimitSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots
        }
    }

    actor CompletionBox<T: Sendable> {
        private var continuation: CheckedContinuation<T, Never>?
        private var result: T?

        func wait() async -> T {
            if let result {
                return result
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(_ value: T) {
            guard result == nil else { return }
            result = value
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: value)
        }
    }

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "codex-poller-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    private func makePayload(
        primary: Double = 10,
        secondary: Double = 20,
        resetCreditsAvailable: Int? = nil
    ) throws -> RateLimitsPayload {
        let reset = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
        let resetCredits = resetCreditsAvailable.map {
            #""rateLimitResetCredits": { "availableCount": \#($0) },"#
        } ?? ""
        let json = """
        {
          \(resetCredits)
          "planType": "pro",
          "rateLimits": {
            "planType": "pro",
            "primary": {
              "usedPercent": \(primary),
              "windowDurationMins": 300,
              "resetsAt": \(reset)
            },
            "secondary": {
              "usedPercent": \(secondary),
              "windowDurationMins": 10080,
              "resetsAt": \(reset)
            }
          }
        }
        """
        return try JSONDecoder().decode(RateLimitsPayload.self, from: Data(json.utf8))
    }

    private func makePoller(
        fetcher: any CodexRateLimitsFetching,
        db: DatabaseManager,
        snapshots: SnapshotBox,
        fetchTimeout: Duration = .seconds(30)
    ) -> RateLimitPoller {
        RateLimitPoller(
            fetcher: fetcher,
            database: db,
            interval: .seconds(300),
            fetchTimeout: fetchTimeout,
            onSnapshot: { snapshot in
                snapshots.append(snapshot)
            })
    }

    private func completeWithin(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> RateLimitPoller.PollOutcome
    ) async -> RateLimitPoller.PollOutcome? {
        let box = CompletionBox<RateLimitPoller.PollOutcome?>()
        Task {
            let outcome = await operation()
            await box.finish(outcome)
        }
        Task {
            try? await Task.sleep(for: duration)
            await box.finish(nil)
        }
        return await box.wait()
    }

    @Test("two rapid pollOnce calls collapse to one Codex usage fetch")
    func minimumGapCollapsesRapidCalls() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [
            .success(try makePayload())
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        await poller.pollOnce()
        await poller.pollOnce()

        let calls = await mock.callCount
        #expect(calls == 1, "second pollOnce inside the Codex minimum gap must not hit app-server")
        #expect(snapshots.all.count == 1)
    }

    @Test("poller publishes reset credit count through RateLimitSnapshot")
    func pollerPublishesResetCreditCount() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [
            .success(try makePayload(resetCreditsAvailable: 2))
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        await poller.pollOnce()

        #expect(snapshots.all.first?.resetCreditsAvailable == 2)
    }

    @Test("forced pollOnce bypasses the minimum gap for manual refresh")
    func forcedPollBypassesMinimumGap() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [
            .success(try makePayload(primary: 10, secondary: 20)),
            .success(try makePayload(primary: 15, secondary: 25))
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        await poller.pollOnce()
        await poller.pollOnce(bypassMinimumGap: true)

        let calls = await mock.callCount
        #expect(calls == 2, "manual refresh must be able to force a fresh Codex usage fetch")
        #expect(snapshots.all.count == 2)
        #expect(snapshots.all.last?.primary?.usedPercent == 15)
    }

    @Test("429 cooldown blocks even a forced manual refresh")
    func rateLimitCooldownBlocksForcedFetches() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [
            .failure(AppServerClient.ClientError.rpcError(
                JSONRPCError(
                    code: -32603,
                    message: "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 429 Too Many Requests",
                    data: nil))),
            .success(try makePayload(primary: 12, secondary: 22))
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        await poller.pollOnce()
        let next = await poller._nextDelayOverrideSecondsForTest
        await poller.pollOnce(bypassMinimumGap: true)

        let calls = await mock.callCount
        let cooldown = await poller._cooldownUntilForTest
        #expect(calls == 1, "active 429 cooldown must block manual and scheduled callers")
        #expect(cooldown != nil)
        #expect(next == 300, "first 429 without Retry-After backs off for 5 minutes")
        #expect(snapshots.all.isEmpty, "429 should not publish a new snapshot")
    }

    @Test("active 429 cooldown is reported before the minimum gap")
    func activeCooldownTakesPrecedenceOverMinimumGap() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [
            .failure(AppServerClient.ClientError.rpcError(
                JSONRPCError(
                    code: -32603,
                    message: "failed to fetch codex rate limits: 429 Too Many Requests",
                    data: nil)))
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        await poller.pollOnce()
        let outcome = await poller.pollOnce()

        guard case .skipped(.rateLimitCooldown) = outcome else {
            Issue.record("expected active 429 cooldown to win over minimum-gap skip")
            return
        }
    }

    @Test("hung fetch returns failure instead of stranding pollOnce")
    func hungFetchTimesOut() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [.hang])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(
            fetcher: mock,
            db: db,
            snapshots: snapshots,
            fetchTimeout: .milliseconds(50))

        let outcome = await completeWithin(.seconds(1)) {
            await poller.pollOnce(trigger: "manual")
        }

        guard case .failure(let message) = outcome else {
            Issue.record("expected hung Codex usage fetch to return failure before the UI refresh can be stranded")
            return
        }

        #expect(message.contains("timed out"))
        #expect(snapshots.all.isEmpty)
    }

    @Test("success after an elapsed 429 cooldown clears the cooldown")
    func successAfterCooldownClearsState() async throws {
        let mock = MockCodexRateLimitsFetcher(script: [
            .failure(AppServerClient.ClientError.rpcError(
                JSONRPCError(
                    code: -32603,
                    message: "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 429 Too Many Requests",
                    data: nil))),
            .success(try makePayload(primary: 12, secondary: 22))
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        await poller.pollOnce()
        await poller._clearLastAttemptForTest()
        await poller._setCooldownToPastForTest()
        await poller.pollOnce()

        let calls = await mock.callCount
        let cooldown = await poller._cooldownUntilForTest
        #expect(calls == 2)
        #expect(cooldown == nil)
        #expect(snapshots.all.count == 1)
        #expect(snapshots.all.first?.primary?.usedPercent == 12)
    }

    @Test("an incidental '429' inside a larger number is not treated as rate limiting")
    func incidentalDigitsDoNotTripCooldown() async throws {
        // "14290" and "4291003" both embed the substring "429" but are not an
        // HTTP 429. A naive contains("429") check would wrongly start a long
        // cooldown and silently stall quota updates.
        let mock = MockCodexRateLimitsFetcher(script: [
            .failure(AppServerClient.ClientError.rpcError(
                JSONRPCError(
                    code: -32000,
                    message: "decode failed: unexpected token at offset 14290 (request 4291003)",
                    data: nil)))
        ])
        let db = try makeDatabase()
        let snapshots = SnapshotBox()
        let poller = makePoller(fetcher: mock, db: db, snapshots: snapshots)

        let outcome = await poller.pollOnce()
        let cooldown = await poller._cooldownUntilForTest
        let count = await poller._consecutiveRateLimitsForTest

        guard case .failure = outcome else {
            Issue.record("a non-rate-limit error must surface as .failure, not a 429 cooldown")
            return
        }
        #expect(cooldown == nil, "an incidental 429-like substring must not start a cooldown")
        #expect(count == 0)
    }
}
