import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Onboarding completion notification")
struct OnboardingCompletionNotificationTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func markingDonePostsCompletionNotification() async {
        let store = SettingsStore(defaults: Self.freshDefaults())
        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .quotaMonitorOnboardingCompleted,
            object: nil, queue: nil) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        store.markProviderOnboardingDone()
        #expect(received == true)
    }
}
