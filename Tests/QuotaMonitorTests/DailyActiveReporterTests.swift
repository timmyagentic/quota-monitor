import Foundation
import Network
import Testing
@testable import QuotaMonitor

@Suite("Anonymous daily-active reporter", .serialized)
struct DailyActiveReporterTests {
    private static let firstDay = Date(timeIntervalSince1970: 1_784_203_200) // 2026-07-16T00:00:00Z
    private static let secondDay = Date(timeIntervalSince1970: 1_784_289_600) // 2026-07-17T00:00:00Z

    @Test("Undecided, disabled, and Local QA eligibility send nothing", arguments: [
        DailyActiveReportingEligibility.undecided,
        .disabled,
        .localQA,
    ])
    func ineligibleStatesSendNothing(eligibility: DailyActiveReportingEligibility) async {
        let fixture = StoreFixture(testName: "\(#function).\(eligibility)")
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            eligibility: TestValue(eligibility))

        await reporter.start()
        _ = await waitForSleeps(1, sleeper: sleeper)

        #expect(await transport.requestCount() == 0)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("A missing strict reporting context sends nothing")
    func missingContextSendsNothing() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            context: TestValue<DailyActiveReportingContext?>(nil))

        await reporter.start()
        _ = await waitForSleeps(1, sleeper: sleeper)

        #expect(await transport.requestCount() == 0)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("A 204 sends the exact request and suppresses the same fingerprint")
    func successSendsExactRequestAndDeduplicates() async throws {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let context = TestValue<DailyActiveReportingContext?>(validContext)
        let eligibility = TestValue(DailyActiveReportingEligibility.enabled)
        let firstTransport = ScriptedDailyActiveTransport([.response(204)])
        let firstSleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: firstTransport,
            sleeper: firstSleeper,
            eligibility: eligibility,
            context: context)

        await reporter.start()
        let requests = await waitForRequests(1, transport: firstTransport)
        let request = try #require(requests.first)
        await waitUntil {
            await fixture.store.hasSucceeded(
                day: "2026-07-16",
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "developer-id",
                operationDate: Self.firstDay)
        }

        #expect(request.url == DailyActiveReporter.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")
            == "quota-monitor/0.2.41 daily-active/1")
        let body = try #require(request.httpBody)
        let payload = try JSONDecoder().decode(DecodedDailyActivePayload.self, from: body)
        #expect(payload.day == "2026-07-16")
        #expect(payload.version == "0.2.41")
        #expect(payload.brand == "quota-monitor")
        #expect(payload.channel == "developer-id")
        await reporter.stop()
        await firstSleeper.resumeAll()

        let secondTransport = ScriptedDailyActiveTransport([.response(204)])
        let secondSleeper = ControlledDailyActiveSleeper()
        let secondReporter = makeReporter(
            store: fixture.store,
            transport: secondTransport,
            sleeper: secondSleeper,
            eligibility: eligibility,
            context: context)
        await secondReporter.start()
        _ = await waitForSleeps(1, sleeper: secondSleeper)

        #expect(await secondTransport.requestCount() == 0)
        await secondReporter.stop()
        await secondSleeper.resumeAll()
    }

    @Test("Same-day context changes resend with the same day token", arguments: [
        DailyActiveReportingContext(
            version: "0.2.42", brand: "quota-monitor", channel: "developer-id"),
        DailyActiveReportingContext(
            version: "0.2.41", brand: "codex-monitor", channel: "developer-id"),
        DailyActiveReportingContext(
            version: "0.2.41", brand: "quota-monitor", channel: "app-store"),
    ])
    func changedFingerprintResendsWithSameToken(changedContext: DailyActiveReportingContext) async throws {
        let fixture = StoreFixture(testName: "\(#function).\(changedContext)")
        defer { fixture.cleanUp() }
        let eligibility = TestValue(DailyActiveReportingEligibility.enabled)
        let context = TestValue<DailyActiveReportingContext?>(validContext)
        let firstTransport = ScriptedDailyActiveTransport([.response(204)])
        let firstSleeper = ControlledDailyActiveSleeper()
        let firstReporter = makeReporter(
            store: fixture.store,
            transport: firstTransport,
            sleeper: firstSleeper,
            eligibility: eligibility,
            context: context)
        await firstReporter.start()
        let firstRequest = try #require(await waitForRequests(
            1, transport: firstTransport).first)
        await waitUntil {
            await fixture.store.hasSucceeded(
                day: "2026-07-16",
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "developer-id",
                operationDate: Self.firstDay)
        }
        await firstReporter.stop()
        await firstSleeper.resumeAll()

        context.value = changedContext
        let secondTransport = ScriptedDailyActiveTransport([.response(204)])
        let secondSleeper = ControlledDailyActiveSleeper()
        let secondReporter = makeReporter(
            store: fixture.store,
            transport: secondTransport,
            sleeper: secondSleeper,
            eligibility: eligibility,
            context: context)
        await secondReporter.start()
        let secondRequest = try #require(await waitForRequests(
            1, transport: secondTransport).first)

        let firstPayload = try requestPayload(firstRequest)
        let secondPayload = try requestPayload(secondRequest)
        #expect(firstPayload.token == secondPayload.token)
        #expect(firstPayload.day == secondPayload.day)
        #expect((firstPayload.version, firstPayload.brand, firstPayload.channel)
            != (secondPayload.version, secondPayload.brand, secondPayload.channel))
        await secondReporter.stop()
        await secondSleeper.resumeAll()
    }

    @Test("A non-retryable response waits for the next six-hour lifecycle trigger")
    func nonRetryable4xxWaitsForPeriodicTrigger() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([.response(400), .response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        let sleeps = await waitForSleeps(1, sleeper: sleeper)
        #expect(sleeps == [DailyActiveReporter.periodicInterval])
        #expect(await transport.requestCount() == 1)

        await sleeper.resume(request: 0)
        _ = await waitForRequests(2, transport: transport)
        #expect(await transport.requestCount() == 2)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("HTTP 200 is not success and waits for the next lifecycle trigger")
    func only204MarksSuccess() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([.response(200), .response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        _ = await waitForSleeps(1, sleeper: sleeper)
        #expect(await fixture.store.hasSucceeded(
            day: "2026-07-16",
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: Self.firstDay) == false)

        await sleeper.resume(request: 0)
        _ = await waitForRequests(2, transport: transport)
        await waitUntil {
            await fixture.store.hasSucceeded(
                day: "2026-07-16",
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "developer-id",
                operationDate: Self.firstDay)
        }
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Network and 5xx failures use three bounded exponential retries")
    func transientFailuresUseBoundedExponentialRetries() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([
            .networkFailure,
            .response(503),
            .response(502),
            .response(204),
        ])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        for retry in 0 ..< 3 {
            _ = await waitForRequests(retry + 1, transport: transport)
            _ = await waitForSleeps(retry + 1, sleeper: sleeper)
            await sleeper.resume(request: retry)
        }
        _ = await waitForRequests(4, transport: transport)
        let sleeps = await waitForSleeps(4, sleeper: sleeper)

        #expect(sleeps == [
            .seconds(30),
            .seconds(60),
            .seconds(120),
            DailyActiveReporter.periodicInterval,
        ])
        #expect(await transport.requestCount() == 4)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Transient retries stop after the bounded retry budget")
    func transientRetryBudgetIsBounded() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([
            .response(503), .response(503), .response(503), .response(503), .response(204),
        ])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        for retry in 0 ..< 3 {
            _ = await waitForRequests(retry + 1, transport: transport)
            _ = await waitForSleeps(retry + 1, sleeper: sleeper)
            await sleeper.resume(request: retry)
        }
        _ = await waitForRequests(4, transport: transport)
        let sleeps = await waitForSleeps(4, sleeper: sleeper)

        #expect(sleeps.last == DailyActiveReporter.periodicInterval)
        #expect(await transport.requestCount() == 4)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Retry-After is honored but clamped to the shared maximum", arguments: [
        "999999",
        "Fri, 17 Jul 2026 00:00:00 GMT",
    ])
    func retryAfterIsBounded(retryAfter: String) async {
        let fixture = StoreFixture(testName: "\(#function).\(retryAfter)")
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([
            .response(429, retryAfter: retryAfter),
            .response(204),
        ])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        let sleeps = await waitForSleeps(1, sleeper: sleeper)
        #expect(sleeps == [DailyActiveReporter.maximumRetryAfter])
        await sleeper.resume(request: 0)
        _ = await waitForRequests(2, transport: transport)

        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("A 409 recomputes the UTC day and token once without sleeping")
    func conflictRecomputesCurrentDayOnce() async throws {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let clock = TestValue(Self.firstDay)
        let transport = ScriptedDailyActiveTransport(
            [.response(409), .response(204)],
            onSend: { requestIndex, _ in
                if requestIndex == 0 { clock.value = Self.secondDay }
            })
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            clock: clock)

        await reporter.start()
        let requests = await waitForRequests(2, transport: transport)
        let first = try requestPayload(try #require(requests.first))
        let second = try requestPayload(try #require(requests.dropFirst().first))

        #expect(first.day == "2026-07-16")
        #expect(second.day == "2026-07-17")
        #expect(first.token != second.token)
        let sleeps = await waitForSleeps(1, sleeper: sleeper)
        #expect(sleeps == [DailyActiveReporter.periodicInterval])
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("A 409 immediately rereads every context dimension with the same-day token", arguments: [
        DailyActiveReportingContext(
            version: "0.2.42", brand: "quota-monitor", channel: "developer-id"),
        DailyActiveReportingContext(
            version: "0.2.41", brand: "codex-monitor", channel: "developer-id"),
        DailyActiveReportingContext(
            version: "0.2.41", brand: "quota-monitor", channel: "app-store"),
    ])
    func conflictRereadsContext(changedContext: DailyActiveReportingContext) async throws {
        let fixture = StoreFixture(testName: "\(#function).\(changedContext)")
        defer { fixture.cleanUp() }
        let context = TestValue<DailyActiveReportingContext?>(validContext)
        let transport = ScriptedDailyActiveTransport(
            [.response(409), .response(204)],
            onSend: { requestIndex, _ in
                if requestIndex == 0 { context.value = changedContext }
            })
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            context: context)

        await reporter.start()
        let requests = await waitForRequests(2, transport: transport)
        let first = try requestPayload(try #require(requests.first))
        let second = try requestPayload(try #require(requests.dropFirst().first))

        #expect(first.day == second.day)
        #expect(first.token == second.token)
        #expect(second.version == changedContext.version)
        #expect(second.brand == changedContext.brand)
        #expect(second.channel == changedContext.channel)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("A second 409 stops until the next lifecycle trigger")
    func conflictRetriesOnlyOnce() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([
            .response(409), .response(409), .response(204),
        ])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        _ = await waitForRequests(2, transport: transport)
        let sleeps = await waitForSleeps(1, sleeper: sleeper)

        #expect(sleeps == [DailyActiveReporter.periodicInterval])
        #expect(await transport.requestCount() == 2)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("The six-hour trigger rotates the token after UTC rollover")
    func periodicTriggerHandlesUTCRollover() async throws {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let clock = TestValue(Self.firstDay)
        let transport = ScriptedDailyActiveTransport([.response(204), .response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            clock: clock)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        _ = await waitForSleeps(1, sleeper: sleeper)
        clock.value = Self.secondDay
        await sleeper.resume(request: 0)
        let requests = await waitForRequests(2, transport: transport)

        let first = try requestPayload(try #require(requests.first))
        let second = try requestPayload(try #require(requests.dropFirst().first))
        #expect(first.day == "2026-07-16")
        #expect(second.day == "2026-07-17")
        #expect(first.token != second.token)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Eligibility is rechecked after jitter before the transport boundary")
    func eligibilityFlipDuringJitterPreventsRequest() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let eligibility = TestValue(DailyActiveReportingEligibility.enabled)
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            eligibility: eligibility,
            initialJitter: .seconds(30))

        await reporter.start()
        _ = await waitForSleeps(1, sleeper: sleeper)
        eligibility.value = .localQA
        await sleeper.resume(request: 0)
        _ = await waitForSleeps(2, sleeper: sleeper)

        #expect(await transport.requestCount() == 0)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Stop invalidates cancellation-ignoring jitter, backoff, and periodic sleepers")
    func stopInvalidatesEverySleepPhase() async {
        await assertStopPreventsRequestAfterSleep(
            testName: "\(#function).jitter",
            outcomes: [.response(204)],
            initialJitter: .seconds(30),
            expectedRequestsBeforeStop: 0)
        await assertStopPreventsRequestAfterSleep(
            testName: "\(#function).backoff",
            outcomes: [.networkFailure, .response(204)],
            initialJitter: .zero,
            expectedRequestsBeforeStop: 1)
        await assertStopPreventsRequestAfterSleep(
            testName: "\(#function).periodic",
            outcomes: [.response(204), .response(204)],
            initialJitter: .zero,
            expectedRequestsBeforeStop: 1)
    }

    @Test("Stop and restart reject an old in-flight success by generation")
    func restartRejectsOldInflightSuccess() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([.blocked, .blocked])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(store: fixture.store, transport: transport, sleeper: sleeper)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        await reporter.stop()
        await reporter.start()
        _ = await waitForRequests(2, transport: transport)
        await transport.resumeBlocked(request: 0, with: .init(statusCode: 204))
        await Task.yield()

        #expect(await fixture.store.hasSucceeded(
            day: "2026-07-16",
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: Self.firstDay) == false)

        await transport.resumeBlocked(request: 1, with: .init(statusCode: 204))
        await waitUntil {
            await fixture.store.hasSucceeded(
                day: "2026-07-16",
                version: "0.2.41",
                brand: "quota-monitor",
                channel: "developer-id",
                operationDate: Self.firstDay)
        }
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("An eligibility change while a request is in flight prevents success persistence")
    func responseEligibilityGuard() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let eligibility = TestValue(DailyActiveReportingEligibility.enabled)
        let transport = ScriptedDailyActiveTransport([.blocked])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            eligibility: eligibility)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        eligibility.value = .disabled
        await transport.resumeBlocked(request: 0, with: .init(statusCode: 204))
        _ = await waitForSleeps(1, sleeper: sleeper)

        #expect(await fixture.store.hasSucceeded(
            day: "2026-07-16",
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: Self.firstDay) == false)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Success persistence uses the injected operation clock, not the payload day")
    func successPersistenceUsesInjectedOperationClock() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let clock = TestValue(Self.firstDay)
        let transport = ScriptedDailyActiveTransport([.blocked])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            clock: clock)

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        fixture.setSuppressionMarker("corrupt")
        clock.value = Self.secondDay
        await transport.resumeBlocked(request: 0, with: .init(statusCode: 204))
        _ = await waitForSleeps(1, sleeper: sleeper)

        #expect(fixture.suppressionMarker == "2026-07-17")
        #expect(fixture.hasStoredToken == false)
        #expect(fixture.hasStoredSuccess == false)
        await reporter.stop()
        await sleeper.resumeAll()
    }

    @Test("Stop after a suspended eligibility check cannot cross the transport boundary")
    func stopDuringSuspendedEligibilityPreventsTransport() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let eligibility = CancellationIgnoringValueGate<DailyActiveReportingEligibility>(
            values: [.enabled])
        let context = CountingTestValue<DailyActiveReportingContext?>(validContext)
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = DailyActiveReporter(
            store: fixture.store,
            transport: transport,
            now: { Self.firstDay },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { .zero },
            eligibility: { await eligibility.next() },
            context: { context.read() })

        await reporter.start()
        await waitUntil { await eligibility.isWaiting }
        #expect(context.readCount == 1)
        await reporter.stop()
        await eligibility.resume(with: .enabled)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(context.readCount == 1)
        #expect(await transport.requestCount() == 0)
        await sleeper.resumeAll()
    }

    @Test("Stop after the initial eligibility check cannot read context")
    func stopDuringInitialEligibilityPreventsContextRead() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let eligibility = CancellationIgnoringValueGate<DailyActiveReportingEligibility>(
            values: [])
        let context = CountingTestValue<DailyActiveReportingContext?>(validContext)
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = DailyActiveReporter(
            store: fixture.store,
            transport: transport,
            now: { Self.firstDay },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { .zero },
            eligibility: { await eligibility.next() },
            context: { context.read() })

        await reporter.start()
        await waitUntil { await eligibility.isWaiting }
        await reporter.stop()
        await eligibility.resume(with: .enabled)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(context.readCount == 0)
        #expect(await transport.requestCount() == 0)
        await sleeper.resumeAll()
    }

    @Test("Stop after the initial context check cannot create a token")
    func stopDuringInitialContextPreventsTokenCreation() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let context = CancellationIgnoringValueGate<DailyActiveReportingContext?>(
            values: [])
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = DailyActiveReporter(
            store: fixture.store,
            transport: transport,
            now: { Self.firstDay },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { .zero },
            eligibility: { .enabled },
            context: { await context.next() })

        await reporter.start()
        await waitUntil { await context.isWaiting }
        await reporter.stop()
        await context.resume(with: validContext)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(fixture.hasStoredToken == false)
        #expect(await transport.requestCount() == 0)
        await sleeper.resumeAll()
    }

    @Test("Stop after a suspended context check cannot cross the transport boundary")
    func stopDuringSuspendedContextPreventsTransport() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let context = CancellationIgnoringValueGate<DailyActiveReportingContext?>(
            values: [validContext])
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = DailyActiveReporter(
            store: fixture.store,
            transport: transport,
            now: { Self.firstDay },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { .zero },
            eligibility: { .enabled },
            context: { await context.next() })

        await reporter.start()
        await waitUntil { await context.isWaiting }
        await reporter.stop()
        await context.resume(with: validContext)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(await transport.requestCount() == 0)
        await sleeper.resumeAll()
    }

    @Test("A stopped generation cannot persist success after its final context gate resumes")
    func stopDuringFinalContextGatePreventsSuccess() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let context = CancellationIgnoringValueGate<DailyActiveReportingContext?>(
            values: [validContext, validContext])
        let transport = ScriptedDailyActiveTransport([.response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = DailyActiveReporter(
            store: fixture.store,
            transport: transport,
            now: { Self.firstDay },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { .zero },
            eligibility: { .enabled },
            context: { await context.next() })

        await reporter.start()
        _ = await waitForRequests(1, transport: transport)
        await waitUntil { await context.isWaiting }
        await reporter.stop()
        await context.resume(with: validContext)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(await fixture.store.hasSucceeded(
            day: "2026-07-16",
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id",
            operationDate: Self.firstDay) == false)
        await sleeper.resumeAll()
    }

    @Test("The periodic runner does not retain a started reporter")
    func periodicRunnerReleasesReporter() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([.response(204), .response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        var reporter: DailyActiveReporter? = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper)
        weak let weakReporter = reporter

        await reporter?.start()
        _ = await waitForRequests(1, transport: transport)
        _ = await waitForSleeps(1, sleeper: sleeper)
        autoreleasepool { reporter = nil }
        for _ in 0 ..< 1_000 where weakReporter != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(weakReporter == nil)
        await sleeper.resume(request: 0)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(await transport.requestCount() == 1)
        if let leakedReporter = weakReporter {
            await leakedReporter.stop()
        }
        await sleeper.resumeAll()
    }

    @Test("The retry runner does not retain a started reporter during backoff")
    func retryRunnerReleasesReporter() async {
        let fixture = StoreFixture(testName: #function)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport([.response(503), .response(204)])
        let sleeper = ControlledDailyActiveSleeper()
        var reporter: DailyActiveReporter? = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper)
        weak let weakReporter = reporter

        await reporter?.start()
        _ = await waitForRequests(1, transport: transport)
        let sleeps = await waitForSleeps(1, sleeper: sleeper)
        #expect(sleeps == [.seconds(30)])
        autoreleasepool { reporter = nil }
        for _ in 0 ..< 1_000 where weakReporter != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(weakReporter == nil)
        await sleeper.resume(request: 0)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await transport.requestCount() == 1)
        if let leakedReporter = weakReporter {
            await leakedReporter.stop()
        }
        await sleeper.resumeAll()
    }

    @Test("The production session is ephemeral and has no ambient state")
    func productionSessionConfiguration() {
        let configuration = DailyActiveURLSessionTransport.makeEphemeralConfiguration()
        let delegate = DailyActiveURLSessionDelegate()

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(delegate.responds(to: NSSelectorFromString(
            "URLSession:dataTask:didReceiveResponse:completionHandler:")))
    }

    @Test("Production transport completes at headers without buffering a held body", arguments: [
        HeldResponseCase(mode: .declaredLarge, expectedStatus: 200),
        HeldResponseCase(mode: .chunked, expectedStatus: 503),
    ])
    func productionTransportDoesNotBufferBody(testCase: HeldResponseCase) async throws {
        let server = try LoopbackHeldResponseServer(mode: testCase.mode)
        defer { server.stop() }
        let configuration = DailyActiveURLSessionTransport.makeEphemeralConfiguration()
        configuration.timeoutIntervalForRequest = 0.6
        configuration.timeoutIntervalForResource = 0.6
        let transport = DailyActiveURLSessionTransport(configuration: configuration)
        let request = URLRequest(url: server.sourceURL)

        let response = try await transport.send(request)
        try await Task.sleep(for: .milliseconds(50))

        #expect(response.statusCode == testCase.expectedStatus)
        #expect(server.requestCount == 1)
    }

    @Test("Cancelling a production transport request resumes its pending send once")
    func cancellingProductionTransportRequest() async throws {
        let server = try LoopbackHeldResponseServer(mode: .noResponse)
        defer { server.stop() }
        let configuration = DailyActiveURLSessionTransport.makeEphemeralConfiguration()
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let transport = DailyActiveURLSessionTransport(configuration: configuration)
        let request = URLRequest(url: server.sourceURL)
        let send = Task { try await transport.send(request) }

        await waitUntil { server.requestCount == 1 }
        send.cancel()

        do {
            _ = try await send.value
            Issue.record("A cancelled transport request unexpectedly succeeded")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.requestCount == 1)
    }

    @Test("A completed transport releases despite its session delegate")
    func productionTransportHasNoDelegateRetainCycle() async throws {
        let server = try LoopbackRedirectServer(status: 307, kind: .sameHostOtherPath)
        defer { server.stop() }
        var transport: DailyActiveURLSessionTransport? = autoreleasepool {
            DailyActiveURLSessionTransport()
        }
        weak let weakTransport = transport

        let response = try await transport?.send(URLRequest(url: server.sourceURL))
        #expect(response?.statusCode == 307)
        autoreleasepool { transport = nil }
        for _ in 0 ..< 1_000 where weakTransport != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(weakTransport == nil)
    }

    @Test("All 307 and 308 redirects are rejected without replaying the POST body", arguments: [
        RedirectCase(status: 307, kind: .foreignHTTPS),
        RedirectCase(status: 308, kind: .foreignHTTPS),
        RedirectCase(status: 307, kind: .plainHTTP),
        RedirectCase(status: 308, kind: .plainHTTP),
        RedirectCase(status: 307, kind: .sameHostOtherPath),
        RedirectCase(status: 308, kind: .sameHostOtherPath),
    ])
    func redirectsAreNeverFollowed(testCase: RedirectCase) async throws {
        let configuration = DailyActiveURLSessionTransport.makeEphemeralConfiguration()
        let transport = DailyActiveURLSessionTransport(configuration: configuration)
        let redirectDelegate = DailyActiveURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: DailyActiveReporter.endpoint)
        original.httpMethod = "POST"
        original.httpBody = Data("sensitive-body".utf8)
        let task = session.dataTask(with: original)
        let response = try #require(HTTPURLResponse(
            url: DailyActiveReporter.endpoint,
            statusCode: testCase.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": testCase.target]))
        var redirected = original
        redirected.url = URL(string: testCase.target)!
        let recorder = RedirectDecisionRecorder()

        redirectDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected,
            completionHandler: { recorder.record($0) })

        #expect(recorder.completionCount == 1)
        #expect(recorder.acceptedRequests.isEmpty)
        #expect(recorder.acceptedBodies.isEmpty)

        // Exercise the real URLSession redirect stack against loopback. A
        // same-host redirect would hit this listener twice if the delegate
        // accepted it; foreign targets would make `send` leave loopback.
        let server = try LoopbackRedirectServer(
            status: testCase.status,
            kind: testCase.kind)
        defer { server.stop() }
        var liveRequest = URLRequest(url: server.sourceURL)
        liveRequest.httpMethod = "POST"
        liveRequest.httpBody = Data("sensitive-body".utf8)
        let liveResponse = try await transport.send(liveRequest)
        try await Task.sleep(for: .milliseconds(25))

        #expect(liveResponse.statusCode == testCase.status)
        #expect(server.requestPaths == ["/source"])
        #expect(server.targetRequestBodies.isEmpty)
    }

    private var validContext: DailyActiveReportingContext {
        DailyActiveReportingContext(
            version: "0.2.41",
            brand: "quota-monitor",
            channel: "developer-id")
    }

    private func makeReporter(
        store: DailyActiveTokenStore,
        transport: any DailyActiveTransport,
        sleeper: ControlledDailyActiveSleeper,
        eligibility: TestValue<DailyActiveReportingEligibility> = TestValue(.enabled),
        context: TestValue<DailyActiveReportingContext?> = TestValue(DailyActiveReportingContext(
            version: "0.2.41", brand: "quota-monitor", channel: "developer-id")),
        clock: TestValue<Date> = TestValue(Self.firstDay),
        initialJitter: Duration = .zero
    ) -> DailyActiveReporter {
        DailyActiveReporter(
            store: store,
            transport: transport,
            now: { clock.value },
            sleep: { duration in try await sleeper.sleep(duration) },
            initialJitter: { initialJitter },
            eligibility: { eligibility.value },
            context: { context.value })
    }

    private func requestPayload(_ request: URLRequest) throws -> DecodedDailyActivePayload {
        try JSONDecoder().decode(
            DecodedDailyActivePayload.self,
            from: try #require(request.httpBody))
    }

    private func waitForRequests(
        _ count: Int,
        transport: ScriptedDailyActiveTransport
    ) async -> [URLRequest] {
        for _ in 0 ..< 1_000 {
            let requests = await transport.requests()
            if requests.count >= count { return requests }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(count) daily-active requests")
        return await transport.requests()
    }

    private func waitForSleeps(
        _ count: Int,
        sleeper: ControlledDailyActiveSleeper
    ) async -> [Duration] {
        for _ in 0 ..< 1_000 {
            let durations = await sleeper.durations()
            if durations.count >= count { return durations }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for \(count) daily-active sleeps")
        return await sleeper.durations()
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0 ..< 1_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for daily-active condition")
    }

    private func assertStopPreventsRequestAfterSleep(
        testName: String,
        outcomes: [ScriptedDailyActiveTransport.Outcome],
        initialJitter: Duration,
        expectedRequestsBeforeStop: Int
    ) async {
        let fixture = StoreFixture(testName: testName)
        defer { fixture.cleanUp() }
        let transport = ScriptedDailyActiveTransport(outcomes)
        let sleeper = ControlledDailyActiveSleeper()
        let reporter = makeReporter(
            store: fixture.store,
            transport: transport,
            sleeper: sleeper,
            initialJitter: initialJitter)
        await reporter.start()
        if expectedRequestsBeforeStop > 0 {
            _ = await waitForRequests(expectedRequestsBeforeStop, transport: transport)
        }
        _ = await waitForSleeps(1, sleeper: sleeper)

        await reporter.stop()
        await sleeper.resume(request: 0)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(await transport.requestCount() == expectedRequestsBeforeStop)
        await sleeper.resumeAll()
    }
}

private struct DecodedDailyActivePayload: Decodable, Sendable {
    let schema: Int
    let day: String
    let token: String
    let version: String
    let brand: String
    let channel: String
}

struct RedirectCase: Sendable, CustomTestStringConvertible {
    let status: Int
    let kind: RedirectTargetKind

    var target: String {
        switch kind {
        case .foreignHTTPS: "https://collector.example/foreign"
        case .plainHTTP: "http://quota-monitor.timmyagentic.com/plain-http"
        case .sameHostOtherPath:
            "https://quota-monitor.timmyagentic.com/other-path"
        }
    }

    var testDescription: String { "\(status) -> \(target)" }
}

enum RedirectTargetKind: Sendable {
    case foreignHTTPS
    case plainHTTP
    case sameHostOtherPath
}

struct HeldResponseCase: Sendable, CustomTestStringConvertible {
    let mode: HeldResponseMode
    let expectedStatus: Int

    var testDescription: String { "\(mode)" }
}

enum HeldResponseMode: Sendable {
    case declaredLarge
    case chunked
    case noResponse
}

private final class TestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class CountingTestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let storedValue: Value
    private var reads = 0

    init(_ value: Value) {
        storedValue = value
    }

    func read() -> Value {
        lock.withLock {
            reads += 1
            return storedValue
        }
    }

    var readCount: Int {
        lock.withLock { reads }
    }
}

private actor CancellationIgnoringValueGate<Value: Sendable> {
    private var values: [Value]
    private var continuation: CheckedContinuation<Value, Never>?

    init(values: [Value]) {
        self.values = values
    }

    var isWaiting: Bool { continuation != nil }

    func next() async -> Value {
        if !values.isEmpty {
            return values.removeFirst()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            // Deliberately ignore cancellation so generation checks must reject
            // the eventual value after stop/restart.
        }
    }

    func resume(with value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class StoreFixture: @unchecked Sendable {
    let store: DailyActiveTokenStore
    private let defaults: UserDefaults
    private let suiteName: String

    init(testName: String) {
        suiteName = "DailyActiveReporterTests.\(testName).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let source = SequentialRandomSource()
        store = DailyActiveTokenStore(
            defaults: DailyActiveUserDefaults(defaults),
            randomBytes: { source.next() })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var hasStoredToken: Bool {
        defaults.object(forKey: DailyActiveTokenStore.tokenStorageKey) != nil
    }

    var hasStoredSuccess: Bool {
        defaults.object(forKey: DailyActiveTokenStore.successStorageKey) != nil
    }

    var suppressionMarker: String? {
        defaults.string(forKey: DailyActiveTokenStore.suppressedDayStorageKey)
    }

    func setSuppressionMarker(_ marker: Any) {
        defaults.set(marker, forKey: DailyActiveTokenStore.suppressedDayStorageKey)
    }
}

private final class SequentialRandomSource: @unchecked Sendable {
    private let lock = NSLock()
    private var nextByte: UInt8 = 0

    func next() -> [UInt8]? {
        lock.withLock {
            let first = nextByte
            nextByte &+= 16
            return (0 ..< 16).map { first &+ UInt8($0) }
        }
    }
}

private actor ControlledDailyActiveSleeper {
    private struct Pending {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var requestedDurations: [Duration] = []
    private var cancelled: Set<Int> = []

    func sleep(_ duration: Duration) async throws {
        let id = nextID
        nextID += 1
        requestedDurations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(continuation: continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation(id) }
        }
    }

    func durations() -> [Duration] {
        requestedDurations
    }

    func resume(request id: Int) {
        pending.removeValue(forKey: id)?.continuation.resume()
    }

    func resumeAll() {
        let continuations = pending.values.map(\.continuation)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func recordCancellation(_ id: Int) {
        cancelled.insert(id)
    }
}

private actor ScriptedDailyActiveTransport: DailyActiveTransport {
    enum Outcome: Sendable {
        case response(Int, retryAfter: String? = nil)
        case networkFailure
        case blocked
    }

    private let onSend: @Sendable (Int, URLRequest) -> Void
    private var outcomes: [Outcome]
    private var recordedRequests: [URLRequest] = []
    private var blocked: [Int: CheckedContinuation<DailyActiveTransportResponse, Never>] = [:]

    init(
        _ outcomes: [Outcome],
        onSend: @escaping @Sendable (Int, URLRequest) -> Void = { _, _ in }
    ) {
        self.outcomes = outcomes
        self.onSend = onSend
    }

    func send(_ request: URLRequest) async throws -> DailyActiveTransportResponse {
        let index = recordedRequests.count
        recordedRequests.append(request)
        onSend(index, request)
        let outcome = outcomes.isEmpty ? .blocked : outcomes.removeFirst()
        switch outcome {
        case let .response(statusCode, retryAfter):
            return DailyActiveTransportResponse(
                statusCode: statusCode,
                retryAfter: retryAfter)
        case .networkFailure:
            throw URLError(.networkConnectionLost)
        case .blocked:
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    blocked[index] = continuation
                }
            } onCancel: {
                // Deliberately ignore cancellation. Reporter generation checks
                // must still reject a late response from this dependency.
            }
        }
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }

    func requestCount() -> Int {
        recordedRequests.count
    }

    func resumeBlocked(request index: Int, with response: DailyActiveTransportResponse) {
        blocked.removeValue(forKey: index)?.resume(returning: response)
    }
}

private final class LoopbackRedirectServer: @unchecked Sendable {
    private struct ReceivedRequest: Sendable {
        let path: String
        let body: Data
    }

    private enum ServerError: Error {
        case failedToStart
    }

    private let status: Int
    private let kind: RedirectTargetKind
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DailyActiveReporterTests.redirect-server")
    private let lock = NSLock()
    private var received: [ReceivedRequest] = []

    init(status: Int, kind: RedirectTargetKind) throws {
        self.status = status
        self.kind = kind
        listener = try NWListener(using: .tcp, on: .any)

        let ready = DispatchSemaphore(value: 0)
        let state = ListenerStartState()
        listener.stateUpdateHandler = { update in
            switch update {
            case .ready:
                state.succeed()
                ready.signal()
            case .failed:
                state.fail()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard
            ready.wait(timeout: .now() + 2) == .success,
            state.didSucceed,
            listener.port != nil
        else {
            listener.cancel()
            throw ServerError.failedToStart
        }
    }

    var sourceURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/source")!
    }

    var requestPaths: [String] {
        lock.withLock { received.map(\.path) }
    }

    var targetRequestBodies: [Data] {
        lock.withLock {
            received.filter { $0.path != "/source" }.map(\.body)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let request = self.parseRequest(data)
            self.lock.withLock { self.received.append(request) }

            let response: String
            if request.path == "/source" {
                let location = self.location()
                let reason = self.status == 307 ? "Temporary Redirect" : "Permanent Redirect"
                response = "HTTP/1.1 \(self.status) \(reason)\r\n"
                    + "Location: \(location)\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n\r\n"
            } else {
                response = "HTTP/1.1 204 No Content\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n\r\n"
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func location() -> String {
        switch kind {
        case .foreignHTTPS:
            "https://collector.invalid/foreign"
        case .plainHTTP:
            "http://collector.invalid/plain-http"
        case .sameHostOtherPath:
            "http://127.0.0.1:\(listener.port!.rawValue)/other-path"
        }
    }

    private func parseRequest(_ data: Data) -> ReceivedRequest {
        guard let text = String(data: data, encoding: .utf8) else {
            return ReceivedRequest(path: "", body: Data())
        }
        let sections = text.components(separatedBy: "\r\n\r\n")
        let requestLine = sections.first?.components(separatedBy: "\r\n").first ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let body = sections.count > 1 ? Data(sections[1].utf8) : Data()
        return ReceivedRequest(path: path, body: body)
    }
}

private final class LoopbackHeldResponseServer: @unchecked Sendable {
    private enum ServerError: Error {
        case failedToStart
    }

    private let mode: HeldResponseMode
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DailyActiveReporterTests.held-body-server")
    private let lock = NSLock()
    private var requests = 0
    private var heldConnections: [NWConnection] = []

    init(mode: HeldResponseMode) throws {
        self.mode = mode
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        listener = try NWListener(
            using: NWParameters(tls: nil, tcp: tcp),
            on: .any)

        let ready = DispatchSemaphore(value: 0)
        let state = ListenerStartState()
        listener.stateUpdateHandler = { update in
            switch update {
            case .ready:
                state.succeed()
                ready.signal()
            case .failed:
                state.fail()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard
            ready.wait(timeout: .now() + 2) == .success,
            state.didSucceed,
            listener.port != nil
        else {
            listener.cancel()
            throw ServerError.failedToStart
        }
    }

    var sourceURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/held-body")!
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func stop() {
        listener.cancel()
        let connections = lock.withLock {
            let values = heldConnections
            heldConnections.removeAll()
            return values
        }
        for connection in connections { connection.cancel() }
    }

    private func handle(_ connection: NWConnection) {
        lock.withLock {
            requests += 1
            heldConnections.append(connection)
        }
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] _, _, _, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let headers: String
            let bodyPrefix: String
            switch self.mode {
            case .declaredLarge:
                headers = "HTTP/1.1 200 OK\r\n"
                    + "Content-Length: 100000000\r\n"
                    + "Connection: keep-alive\r\n\r\n"
                bodyPrefix = String(repeating: "x", count: 64 * 1_024)
            case .chunked:
                headers = "HTTP/1.1 503 Service Unavailable\r\n"
                    + "Transfer-Encoding: chunked\r\n"
                    + "Connection: keep-alive\r\n\r\n"
                bodyPrefix = "10000\r\n"
                    + String(repeating: "x", count: 64 * 1_024)
                    + "\r\n"
            case .noResponse:
                return
            }
            connection.send(
                content: Data(headers.utf8),
                completion: .contentProcessed { _ in
                    connection.send(
                        content: Data(bodyPrefix.utf8),
                        completion: .contentProcessed { _ in
                            // Intentionally leave the body unfinished.
                        })
                })
        }
    }
}

private final class ListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false

    var didSucceed: Bool {
        lock.withLock { succeeded }
    }

    func succeed() {
        lock.withLock { succeeded = true }
    }

    func fail() {
        lock.withLock { succeeded = false }
    }
}

private final class RedirectDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var accepted: [URLRequest] = []

    func record(_ request: URLRequest?) {
        lock.withLock {
            calls += 1
            if let request { accepted.append(request) }
        }
    }

    var completionCount: Int {
        lock.withLock { calls }
    }

    var acceptedRequests: [URLRequest] {
        lock.withLock { accepted }
    }

    var acceptedBodies: [Data] {
        lock.withLock { accepted.compactMap(\.httpBody) }
    }
}
