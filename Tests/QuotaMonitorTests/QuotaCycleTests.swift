import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Quota cycle evidence")
struct QuotaCycleTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(
        at: Double = 100, reset: Double = 18_000, used: Double = 30,
        scope: String? = "account-a", plan: String? = "pro", duration: Double = 18_000
    ) -> QuotaCycle.Observation {
        .init(provider: "codex", bucket: "primary", scope: scope, plan: plan,
              capturedAt: origin.addingTimeInterval(at),
              resetAt: origin.addingTimeInterval(reset), duration: duration, usedPercent: used)
    }

    @Test func firstReadOnlyEstimatesStart() {
        let cycle = QuotaCycle.resolve(observation(), previous: nil)
        #expect(cycle.basis == .estimated)
        #expect(cycle.start == origin)
    }

    @Test func crossingKnownDeadlineObservesRollover() {
        let previous = QuotaCycle.resolve(observation(at: 17_900, used: 90), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 18_100, reset: 36_000, used: 1), previous: previous)
        #expect(cycle.basis == .observedRollover)
        #expect(cycle.start == origin.addingTimeInterval(18_000))
    }

    @Test func idleGapDoesNotPretendOldDeadlineIsNewStart() {
        let previous = QuotaCycle.resolve(observation(), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 30_100, reset: 48_000, used: 1), previous: previous)
        #expect(cycle.basis == .estimated)
        #expect(cycle.start == origin.addingTimeInterval(30_000))
    }

    @Test func earlyDeadlineChangeHasBoundedObservationInsteadOfInventedExactReset() {
        let previous = QuotaCycle.resolve(observation(at: 1_000, used: 80), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 1_300, reset: 19_200, used: 1), previous: previous)
        #expect(cycle.basis == .observedChange)
        #expect(cycle.start == origin.addingTimeInterval(1_300))
        #expect(cycle.possibleStart == origin.addingTimeInterval(1_000))
        let next = QuotaCycle.resolve(observation(at: 1_600, reset: 19_200, used: 2), previous: cycle)
        #expect(next.start == cycle.start)
        #expect(next.possibleStart == cycle.possibleStart)
    }

    @Test func percentageDropAloneCannotProveReset() {
        let previous = QuotaCycle.resolve(observation(used: 80), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 400, used: 10), previous: previous)
        #expect(cycle.basis == .unresolved)
        #expect(!cycle.allowsPaceEstimate)
        #expect(cycle.start == nil)
        let next = QuotaCycle.resolve(observation(at: 700, used: 11), previous: cycle)
        #expect(next.basis == .unresolved)
    }

    @Test func accountCredentialOrPlanChangeBreaksContinuity() {
        let previous = QuotaCycle.resolve(observation(used: 80), previous: nil)
        for current in [observation(at: 400, used: 10, scope: "account-b"),
                        observation(at: 400, used: 10, scope: nil),
                        observation(at: 400, used: 10, plan: "plus")] {
            #expect(QuotaCycle.resolve(current, previous: previous).basis == .estimated)
        }
    }

    @Test func lateResponseCannotRollStateBack() {
        let previous = QuotaCycle.resolve(observation(at: 1_000), previous: nil)
        #expect(QuotaCycle.resolve(observation(at: 500), previous: previous) == previous)
    }

    @Test func invalidFutureStartIsNotClampedIntoFakeReset() {
        #expect(QuotaCycle.resolve(observation(reset: 40_000), previous: nil).start == nil)
        #expect(QuotaCycle.resolve(observation(duration: 0), previous: nil).start == nil)
    }

    @Test func tinyTimerJitterDoesNotStartAnotherCycle() {
        let previous = QuotaCycle.resolve(observation(), previous: nil)
        let cycle = QuotaCycle.resolve(observation(at: 400, reset: 18_001, used: 31), previous: previous)
        #expect(cycle.start == previous.start)
        #expect(cycle.basis == previous.basis)
    }
    @Test func smallPercentageDropStillDoesNotProveReset() {
        let previous = QuotaCycle.resolve(observation(used: 0.7), previous: nil)
        #expect(QuotaCycle.resolve(observation(at: 400, used: 0), previous: previous).basis == .unresolved)
    }

    @Test func responseAccountIdentityIsOptionalAndNeverStoredRaw() throws {
        let body = #"{"accountId":"fixture-account-id","rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1800018000}}}"#
        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(body.utf8))
        let snapshot = RateLimitSnapshot(from: payload, capturedAt: origin.addingTimeInterval(100))
        #expect(snapshot.observationScope == QuotaCycle.scope(provider: "codex", value: "fixture-account-id"))
        #expect(snapshot.observationScope?.contains("fixture-account-id") == false)
        let malformed = body.replacingOccurrences(of: #""accountId":"fixture-account-id""#, with: #""accountId":42"#)
        let legacy = try JSONDecoder().decode(RateLimitsPayload.self, from: Data(malformed.utf8))
        #expect(legacy.accountId == nil)
        #expect(legacy.rateLimit?.primaryWindow?.usedPercent == 20)
    }

    @Test func simultaneousAccountSwitchDoesNotReuseAnotherAccountsCycle() {
        let previous = QuotaCycle.resolve(observation(at: 17_900, used: 90), previous: nil)
        let observed = QuotaCycle.resolve(observation(at: 18_100, reset: 36_000, used: 1), previous: previous)
        let switched = QuotaCycle.resolve(observation(at: 18_100, reset: 36_000, used: 1, scope: "account-b"), previous: observed)
        #expect(switched.basis == .estimated)
        #expect(switched.observation.scope == "account-b")
    }

}
