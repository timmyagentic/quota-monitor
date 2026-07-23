import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Account usage controller", .serialized)
struct AccountUsageControllerTests {
    actor DeferredAccountUsageClient: CodexAccountUsageFetching {
        private var nextRequestID = 0
        private var continuations: [
            Int: CheckedContinuation<CodexAccountUsageSnapshot, any Error>
        ] = [:]
        private var returnedRequestIDs: Set<Int> = []

        var callCount: Int { nextRequestID }

        func fetchAccountUsage() async throws -> CodexAccountUsageSnapshot {
            let requestID = nextRequestID
            nextRequestID += 1
            let snapshot = try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
            }
            returnedRequestIDs.insert(requestID)
            return snapshot
        }

        func hasReturned(requestID: Int) -> Bool {
            returnedRequestIDs.contains(requestID)
        }

        func resume(
            requestID: Int,
            returning snapshot: CodexAccountUsageSnapshot
        ) {
            continuations.removeValue(forKey: requestID)?.resume(returning: snapshot)
        }

        func resumeAll(returning snapshot: CodexAccountUsageSnapshot) {
            let pending = continuations.values
            continuations.removeAll()
            for continuation in pending {
                continuation.resume(returning: snapshot)
            }
        }
    }

    @Test("superseded request cannot clear a newer refresh flag")
    func supersededRequestKeepsNewerRefreshInFlight() async throws {
        let restore = preserveSettings(keys: [
            "settings.enabledProviders",
            "onboarding.providersDone",
        ])
        defer { restore() }

        UserDefaults.standard.set(["codex"], forKey: "settings.enabledProviders")
        UserDefaults.standard.set(true, forKey: "onboarding.providersDone")

        let client = DeferredAccountUsageClient()
        let env = AppEnvironment(
            codexAccountUsageClient: client,
            startBackgroundTasks: false)
        env.providerFilter = .codex
        env.activityDataScope = .account

        try await waitForCallCount(1, client: client)
        #expect(env.isRefreshingCodexAccountUsage)

        // Match stopCodexPoller's invalidation, then start the replacement
        // request before the superseded request has unwound.
        env.codexAccountUsageRefreshGeneration &+= 1
        env.codexAccountUsageState = .idle
        env.isRefreshingCodexAccountUsage = false
        env.lastCodexAccountUsageRefreshAttemptAt = nil
        env.refreshCodexAccountUsage(trigger: "replacement-test")

        try await waitForCallCount(2, client: client)
        let replacementGeneration = env.codexAccountUsageRefreshGeneration
        let oldSnapshot = makeSnapshot(lifetimeTokens: 1)
        await client.resume(requestID: 0, returning: oldSnapshot)
        try await waitForReturn(requestID: 0, client: client)
        try await Task.sleep(for: .milliseconds(20))

        #expect(env.codexAccountUsageRefreshGeneration == replacementGeneration)
        #expect(env.isRefreshingCodexAccountUsage)
        #expect(env.codexAccountUsageState == .loading)

        // While request 1 remains deferred, another refresh must still be
        // rejected by the single-flight guard.
        env.refreshCodexAccountUsage(trigger: "overlap-test")
        try await Task.sleep(for: .milliseconds(20))
        #expect(await client.callCount == 2)

        let replacementSnapshot = makeSnapshot(lifetimeTokens: 2)
        await client.resume(requestID: 1, returning: replacementSnapshot)
        try await waitForLoaded(replacementSnapshot, in: env)

        #expect(env.codexAccountUsageState == .loaded(replacementSnapshot))
        #expect(env.isRefreshingCodexAccountUsage == false)
        await client.resumeAll(returning: replacementSnapshot)
    }

    private func makeSnapshot(lifetimeTokens: Int64) -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: nil,
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil,
            daily: [],
            latestBucketDate: nil,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(lifetimeTokens)))
    }

    private func waitForCallCount(
        _ expected: Int,
        client: DeferredAccountUsageClient
    ) async throws {
        for _ in 0..<200 {
            if await client.callCount == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestTimeout()
    }

    private func waitForReturn(
        requestID: Int,
        client: DeferredAccountUsageClient
    ) async throws {
        for _ in 0..<200 {
            if await client.hasReturned(requestID: requestID) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestTimeout()
    }

    private func waitForLoaded(
        _ snapshot: CodexAccountUsageSnapshot,
        in env: AppEnvironment
    ) async throws {
        for _ in 0..<200 {
            if env.codexAccountUsageState == .loaded(snapshot),
               !env.isRefreshingCodexAccountUsage {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestTimeout()
    }

    private func preserveSettings(keys: [String]) -> () -> Void {
        let defaults = UserDefaults.standard
        let oldValues = keys.map { ($0, defaults.object(forKey: $0)) }
        return {
            for (key, value) in oldValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    private struct TestTimeout: Error {}
}
