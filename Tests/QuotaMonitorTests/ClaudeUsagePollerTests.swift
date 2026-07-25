import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// State-machine tests for `ClaudeUsagePoller`. We exercise the actor by
/// driving `pollOnce()` directly with a scripted mock fetcher and asserting
/// on the actor-internal state via the `_*ForTest` accessors.
///
/// What this test pins down (each was a real production behaviour that
/// either shipped broken or was easy to break):
///
///   1. **Single-flight throttle** — two `pollOnce()` calls inside one
///      `minimumGap` window must collapse to one network call. Pre-fix,
///      a UI bug that wired pollOnce to a click handler hit the endpoint
///      every click and earned 429s within seconds.
///   2. **429 ladder** — first 429 → 5-minute backoff (often a transient
///      collision), subsequent 429s → 30-minute backoff. Success resets.
///   3. **Retry-After honoured** — server hint wins as long as it's >= 60s.
///   4. **Auth-class errors surface** — `noCredentials` / `unauthorized` /
///      `insufficientScope` MUST call `onSnapshot(.failure)` so the menu
///      bar can show a hint. 429 must NOT surface (it's transient).
///   5. **Successful fetch resets counters** — both rate-limit and auth.
///   6. **Cooldown gates manual pollOnce** — once 429'd, a manual caller
///      (the Refresh button) must be blocked until the cooldown lifts,
///      not just by the 60-second spam gap. Naively respecting only
///      `minimumGap` would let the button re-trigger 60 s after a 429
///      and earn another one.
///   7. **Cooldown callback** — onCooldownChange fires with a future
///      Date on 429 and with nil on the next successful fetch, so the
///      menu bar can render an inline "limited, retry in X" notice.
@Suite("ClaudeUsagePoller state machine")
struct ClaudeUsagePollerTests {

    // MARK: - mock fetcher

    /// Scripted responder. Each call to `fetch()` consumes the next entry
    /// from `script`. If the script is exhausted, returns the last entry
    /// (so a "always succeed" test only needs one entry).
    actor MockFetcher: ClaudeUsageFetching {
        enum Step: Sendable {
            case success(ClaudeUsageSnapshot)
            case failure(any Error)
        }
        private var script: [Step]
        private var calls = 0
        init(script: [Step]) { self.script = script }

        func fetch() async throws -> ClaudeUsageSnapshot {
            calls += 1
            let step = script.count > 1 ? script.removeFirst() : (script.first ?? .failure(ClaudeUsageClient.FetchError.malformed("empty script")))
            switch step {
            case .success(let snap): return snap
            case .failure(let err):  throw err
            }
        }
        var callCount: Int { calls }
    }

    // MARK: - shared helpers

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "poller-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    private func emptySnapshot() -> ClaudeUsageSnapshot {
        // Empty windows are easier than a full fixture and exercise the
        // persist path without putting anything interesting in the DB.
        ClaudeUsageSnapshot(
            capturedAt: Date(),
            tier: nil,
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)
    }

    /// Box for capturing the result of `onSnapshot` callbacks across
    /// async boundaries. Sendable + locked so concurrent calls don't race.
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var inner: [Result<ClaudeUsageSnapshot, any Error>] = []
        func append(_ r: Result<ClaudeUsageSnapshot, any Error>) {
            lock.lock(); defer { lock.unlock() }
            inner.append(r)
        }
        var all: [Result<ClaudeUsageSnapshot, any Error>] {
            lock.lock(); defer { lock.unlock() }
            return inner
        }
    }

    private func makePoller(
        fetcher: any ClaudeUsageFetching,
        db: DatabaseManager,
        results: ResultBox
    ) -> ClaudeUsagePoller {
        ClaudeUsagePoller(
            client: fetcher,
            database: db,
            interval: .seconds(7200),
            onSnapshot: { result in
                results.append(result)
            })
    }

    // MARK: - 1. minimum-gap throttle

    @Test("two pollOnce() calls within minimumGap collapse to one fetch")
    func minimumGap_collapsesRapidCalls() async throws {
        let mock = MockFetcher(script: [.success(emptySnapshot())])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        await poller.pollOnce()  // < 60s after the first → must be skipped

        let calls = await mock.callCount
        #expect(calls == 1, "second pollOnce inside minimumGap must NOT hit the network")
        #expect(results.all.count == 1)
    }

    @Test("force bypasses the minimumGap so the Refresh button always polls")
    func force_bypassesMinimumGap() async throws {
        let mock = MockFetcher(script: [.success(emptySnapshot())])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        await poller.pollOnce(force: true)  // manual Refresh < 60s later

        let calls = await mock.callCount
        #expect(calls == 2, "force must bypass the 60s spam gap")
    }

    @Test("structured Fable weekly limit persists with scoped provenance")
    func fable5ScopedLimitPersists() async throws {
        let resetAt = Date(timeIntervalSince1970: 1_777_600_000)
        let window = ClaudeUsageSnapshot.Window(
            usedPercent: 37,
            resetAt: resetAt,
            windowDuration: 7 * 86400)
        let snapshot = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000),
            tier: "max20x",
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            weeklyScoped: [.init(key: "fable", window: window)])
        let mock = MockFetcher(script: [.success(snapshot)])
        let db = try makeDatabase()
        let poller = makePoller(fetcher: mock, db: db, results: ResultBox())

        await poller.pollOnce()

        let row = try #require(try await db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT bucket, limit_name, plan_type, used_percent, resets_at
                FROM rate_limit_samples
                WHERE source_kind = 'claude_oauth'
                  AND limit_name = 'scoped:Fable 5'
                """)
        })
        #expect((row["bucket"] as String?) == "secondary")
        #expect((row["limit_name"] as String?) == "scoped:Fable 5")
        #expect((row["plan_type"] as String?) == "max20x")
        #expect(abs((row["used_percent"] as Double? ?? -1) - 37) < 0.0001)
        let resetString = try #require(row["resets_at"] as String?)
        #expect(ISO8601.parse(resetString) == resetAt)
    }

    @Test("structured zero-percent Opus stays visible after persist and hydrate")
    func structuredZeroOpusPersistsAndHydratesAsScoped() async throws {
        let window = ClaudeUsageSnapshot.Window(
            usedPercent: 0,
            resetAt: Date(timeIntervalSince1970: 1_777_600_000),
            windowDuration: 7 * 86400)
        let snapshot = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000),
            tier: "max20x",
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            weeklyScoped: [.init(key: "opus", window: window)])
        let db = try makeDatabase()
        let poller = makePoller(
            fetcher: MockFetcher(script: [.success(snapshot)]),
            db: db,
            results: ResultBox())

        await poller.pollOnce()

        let hydrated = try #require(
            try await ClaudeUsageHydrator.loadLatest(database: db))
        #expect(hydrated.sevenDayOpus == nil)
        #expect(hydrated.weeklyScoped.map(\.key) == ["opus"])
        let row = try #require(ClaudeScopedQuotaRows.visibleRows(for: hydrated).first)
        #expect(row.displayName == "Opus")
        #expect(row.window.usedPercent == 0)
    }

    @Test("force still respects an active 429 cooldown")
    func force_respectsRateLimitCooldown() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil)),
            .success(emptySnapshot()),
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()             // 429 → cooldown set (fetch #1)
        await poller.pollOnce(force: true)  // must stay blocked by the cooldown

        let calls = await mock.callCount
        #expect(calls == 1, "force must NOT punch through a 429 cooldown")
    }

    // MARK: - 1b. scheduled cadence

    @Test("default Claude /usage cadence is 10 minutes, not the old 2h")
    func defaultCadenceIsTenMinutes() async throws {
        // Shortened from 7200s so the live 5h/7d quota meter is at most ~10
        // minutes stale (the 429 cooldown ladder still defends the endpoint).
        #expect(ClaudeUsagePoller.defaultInterval == .seconds(600))
        let db = try makeDatabase()
        let poller = ClaudeUsagePoller(database: db, onSnapshot: { _ in })
        #expect(await poller._intervalForTest == .seconds(600))
    }

    // MARK: - 2. 429 ladder

    @Test("first 429: short 5-min backoff, no UI failure surface")
    func firstRateLimit_shortBackoff_noUIError() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil))
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()

        let count = await poller._consecutiveRateLimitsForTest
        let next = await poller._nextDelayOverrideSecondsForTest
        #expect(count == 1)
        #expect(next == 300, "1st 429 with no Retry-After → exactly 5-min override")
        #expect(results.all.isEmpty,
                "429 must NOT call onSnapshot — UI would lie about a transient signal")
    }

    @Test("second consecutive 429: long 30-min backoff")
    func secondRateLimit_longBackoff() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil)),
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil))
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        // Reset minimumGap clock so the second pollOnce doesn't get
        // throttled out by the throttle test above.
        await poller._resetThrottleForTest()
        await poller.pollOnce()

        let count = await poller._consecutiveRateLimitsForTest
        let next = await poller._nextDelayOverrideSecondsForTest
        #expect(count == 2)
        #expect(next == 1800, "2nd consecutive 429 → 30-min override")
    }

    @Test("Retry-After header honoured (clamped to >= 60s)")
    func retryAfter_honoured() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: 900))
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        let next = await poller._nextDelayOverrideSecondsForTest
        #expect(next == 900, "Retry-After:900 must win over the 5-min default")
    }

    @Test("Retry-After below floor clamps to 60s")
    func retryAfter_belowFloor_clampsTo60() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: 5))
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        let next = await poller._nextDelayOverrideSecondsForTest
        #expect(next == 60, "must clamp to 60s floor — sub-minute polling earns more 429s")
    }

    // MARK: - 3. auth-class errors

    @Test("noCredentials surfaces to UI")
    func noCredentials_surfacesToUI() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.noCredentials)
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()

        let auth = await poller._consecutiveAuthFailuresForTest
        #expect(auth == 1)
        #expect(results.all.count == 1, "noCredentials MUST hit onSnapshot so the menu bar can prompt")
        if case .failure(let err) = results.all.first {
            #expect(err is ClaudeUsageClient.FetchError)
            if let fe = err as? ClaudeUsageClient.FetchError,
               case .noCredentials = fe {
                // good
            } else {
                Issue.record("expected noCredentials error, got \(err)")
            }
        } else {
            Issue.record("expected onSnapshot(.failure(noCredentials))")
        }
    }

    @Test("unauthorized surfaces to UI and bumps auth counter")
    func unauthorized_surfacesAndCounts() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.unauthorized)
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()

        let auth = await poller._consecutiveAuthFailuresForTest
        #expect(auth == 1)
        #expect(results.all.count == 1)
    }

    // MARK: - 4. success resets both counters

    @Test("success after 429 resets the rate-limit counter")
    func success_resetsRateLimitCounter() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil)),
            .success(emptySnapshot())
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        await poller._resetThrottleForTest()
        await poller.pollOnce()

        let rl = await poller._consecutiveRateLimitsForTest
        let auth = await poller._consecutiveAuthFailuresForTest
        #expect(rl == 0, "successful fetch must reset rate-limit counter")
        #expect(auth == 0)
        #expect(results.all.count == 1, "only the success surfaces; the 429 was suppressed")
        if case .success = results.all.first {} else {
            Issue.record("expected the surfaced result to be the success")
        }
    }

    @Test("429 after a successful snapshot does not replace the last surfaced data")
    func rateLimitAfterSuccess_keepsLastSurfacedSnapshot() async throws {
        let successfulSnapshot = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000),
            tier: "max5x",
            fiveHour: .init(
                usedPercent: 42,
                resetAt: Date(timeIntervalSince1970: 1_777_010_000),
                windowDuration: 5 * 3600),
            sevenDay: .init(
                usedPercent: 12,
                resetAt: Date(timeIntervalSince1970: 1_777_600_000),
                windowDuration: 7 * 86400),
            sevenDayOpus: nil,
            sevenDaySonnet: nil)
        let mock = MockFetcher(script: [
            .success(successfulSnapshot),
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil))
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        await poller._clearLastAttemptForTest()
        await poller.pollOnce()

        #expect(results.all.count == 1, "429 must not surface an error that blanks the last live quota snapshot")
        if case .success(let surfaced)? = results.all.first {
            #expect(surfaced == successfulSnapshot)
        } else {
            Issue.record("expected the last surfaced callback to remain the successful snapshot")
        }
        #expect(await poller._cooldownUntilForTest != nil)
    }

    @Test("success after auth failure resets the auth counter")
    func success_resetsAuthCounter() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.unauthorized),
            .success(emptySnapshot())
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()
        await poller._resetThrottleForTest()
        await poller.pollOnce()

        let auth = await poller._consecutiveAuthFailuresForTest
        #expect(auth == 0)
    }

    // MARK: - 5. cooldown gates manual callers

    /// Box for capturing onCooldownChange notifications across the
    /// actor boundary. Same shape as ResultBox.
    final class CooldownBox: @unchecked Sendable {
        private let lock = NSLock()
        private var inner: [Date?] = []
        func append(_ v: Date?) {
            lock.lock(); defer { lock.unlock() }
            inner.append(v)
        }
        var all: [Date?] {
            lock.lock(); defer { lock.unlock() }
            return inner
        }
    }

    private func makePollerWithCooldown(
        fetcher: any ClaudeUsageFetching,
        db: DatabaseManager,
        results: ResultBox,
        cooldowns: CooldownBox
    ) -> ClaudeUsagePoller {
        ClaudeUsagePoller(
            client: fetcher,
            database: db,
            interval: .seconds(7200),
            onSnapshot: { result in results.append(result) },
            onCooldownChange: { until in cooldowns.append(until) })
    }

    @Test("active 429 cooldown blocks a manual pollOnce even after the 60 s gap clears")
    func cooldownBlocksManualPoll() async throws {
        // Pre-fix, _only_ minimumGap gated pollOnce. A Refresh-button
        // click 60 s after a 429 would re-fire the request and earn
        // another 429. The cooldown gate must be checked too.
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: 600)),
            // The next script entry would be consumed only if the
            // cooldown gate failed to block us. We assert callCount==1
            // below to prove it didn't.
            .success(emptySnapshot())
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()                          // earns the 429
        await poller._clearLastAttemptForTest()          // bypass 60 s gap only
        await poller.pollOnce()                          // must be blocked by cooldown

        let calls = await mock.callCount
        let cooldown = await poller._cooldownUntilForTest
        #expect(calls == 1, "the 2nd pollOnce MUST NOT hit the network — cooldown active")
        #expect(cooldown != nil, "cooldown should still be set")
        #expect(results.all.isEmpty, "no onSnapshot — 429 was suppressed, no success arrived")
    }

    @Test("once the cooldown has elapsed, pollOnce proceeds normally")
    func cooldownExpired_pollProceeds() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: nil)),
            .success(emptySnapshot())
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let poller = makePoller(fetcher: mock, db: db, results: results)

        await poller.pollOnce()                          // earns the 429
        await poller._clearLastAttemptForTest()          // bypass 60 s gap
        await poller._setCooldownToPastForTest()         // simulate cooldown elapsed
        await poller.pollOnce()                          // must succeed

        let calls = await mock.callCount
        #expect(calls == 2, "with cooldown elapsed, the 2nd pollOnce must hit the network")
        #expect(results.all.count == 1)
        if case .success = results.all.first {} else {
            Issue.record("expected the surfaced result to be the success")
        }
    }

    // MARK: - 6. cooldown callback

    @Test("onCooldownChange fires future-Date on 429 and nil on the next success")
    func cooldownChange_firesOnSetAndClear() async throws {
        let mock = MockFetcher(script: [
            .failure(ClaudeUsageClient.FetchError.rateLimited(retryAfter: 600)),
            .success(emptySnapshot())
        ])
        let db = try makeDatabase()
        let results = ResultBox()
        let cooldowns = CooldownBox()
        let poller = makePollerWithCooldown(
            fetcher: mock, db: db, results: results, cooldowns: cooldowns)

        await poller.pollOnce()                          // 429 → fires(.some(future))
        await poller._clearLastAttemptForTest()
        await poller._setCooldownToPastForTest()         // simulate elapsed; cooldown still != nil
        await poller.pollOnce()                          // success → fires(nil)

        let events = cooldowns.all
        #expect(events.count == 2,
                "expected one event per state transition (set, clear), got \(events.count)")
        #expect(events.first.flatMap { $0 } != nil,
                "first event must be a non-nil future Date (cooldown set)")
        #expect(events.last == .some(nil),
                "second event must be nil (cooldown cleared by success)")
        let stillSet = await poller._cooldownUntilForTest
        #expect(stillSet == nil, "successful fetch must clear cooldownUntil")
    }
}
