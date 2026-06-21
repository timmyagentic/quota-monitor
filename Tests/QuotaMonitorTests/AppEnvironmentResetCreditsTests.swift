import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("AppEnvironment Codex reset credits")
struct AppEnvironmentResetCreditsTests {
    actor MockResetCreditsClient: CodexResetCreditsFetching {
        private(set) var calls = 0
        let result: Result<CodexResetCreditsSnapshot, any Error>

        init(result: Result<CodexResetCreditsSnapshot, any Error>) {
            self.result = result
        }

        func fetchResetCredits() async throws -> CodexResetCreditsSnapshot {
            calls += 1
            return try result.get()
        }
    }

    @Test("refreshCodexResetCredits stores detailed snapshot")
    func refreshStoresDetailedSnapshot() async throws {
        let restore = preserveSettings(keys: [
            "settings.enabledProviders",
            "onboarding.providersDone",
        ])
        defer { restore() }

        UserDefaults.standard.set(["codex"], forKey: "settings.enabledProviders")
        UserDefaults.standard.set(true, forKey: "onboarding.providersDone")

        let expires = try #require(ISO8601.parse("2026-07-12T00:16:55.107346Z"))
        let snapshot = CodexResetCreditsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_781_000_000),
            availableCount: 1,
            credits: [CodexResetCredit(grantedAt: nil, expiresAt: expires)],
            detailStatus: .complete)
        let client = MockResetCreditsClient(result: .success(snapshot))
        let env = AppEnvironment(
            codexResetCreditsClient: client,
            startBackgroundTasks: false)

        env.refreshCodexResetCredits(trigger: "test")
        for _ in 0..<50
            where env.latestCodexResetCredits == nil || env.isRefreshingCodexResetCredits {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await client.calls == 1)
        #expect(env.latestCodexResetCredits == snapshot)
        #expect(env.lastCodexResetCreditsError == nil)
        #expect(env.isRefreshingCodexResetCredits == false)
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
}
