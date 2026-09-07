import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Dashboard first visible snapshot")
struct DashboardSnapshotPublicationTests {
    @Test("Import invalidation cannot discard the only available Trends snapshot")
    func invalidationStillPublishesLastGoodContent() async throws {
        let (environment, _, _, tokens) = try makeEnvironment()
        environment.refreshDashboard(trigger: "scan")
        // A scan/settings update arrives after this read's generation was
        // captured. The atomic payload is still useful while the next one loads.
        environment.markDashboardReadModelChanged()
        await waitForIdle(environment)
        let snapshot = try #require(environment.dashboardSnapshot)
        #expect(snapshot.trends.last7Days.daily.reduce(0) { $0 + $1.tokens } == tokens)

        environment.ensureDashboardVisible()
        #expect(environment.dashboardSnapshot == snapshot)
        #expect(environment.isLoadingDashboard, "The old generation must still revalidate")
        await waitForIdle(environment)
    }

    @Test("A three-day-old disk cache is visible synchronously during cold-open refresh")
    func oldDiskCacheRendersBeforeRefresh() async throws {
        let (first, database, store, tokens) = try makeEnvironment()
        first.refreshDashboard(trigger: "scan")
        await waitForIdle(first)
        for _ in 0..<200 where store.load() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(store.load())
        let old = DashboardSnapshotCacheEnvelope(
            key: original.key,
            generatedAt: Date().addingTimeInterval(-3 * 24 * 3600),
            snapshot: original.snapshot)
        try store.save(old)

        let reopened = AppEnvironment(startBackgroundTasks: false, database: database,
                                      dashboardSnapshotStore: store,
                                      dashboardSettings: first.dashboardSettings)
        reopened.restoreCachedDashboardSnapshot()
        let restoredAt = try #require(reopened.dashboardCachedSnapshotDate)
        #expect(abs(restoredAt.timeIntervalSince(old.generatedAt)) < 0.001)
        let restored = try #require(reopened.dashboardSnapshot)
        #expect(restored.trends.last7Days.daily.reduce(0) { $0 + $1.tokens } == tokens)
        reopened.ensureDashboardVisible()
        #expect(reopened.dashboardSnapshot == restored)
        #expect(reopened.isLoadingDashboard)
        await waitForIdle(reopened)
    }

    private func makeEnvironment() throws
        -> (AppEnvironment, DatabaseManager, DashboardSnapshotStore, Int64) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-publication-\(UUID().uuidString)")
        let database = try DatabaseManager(url: root.appendingPathComponent("history.sqlite"))
        let store = DashboardSnapshotStore(fileURL: root.appendingPathComponent("snapshot.json"))
        let suiteName = "dashboard-publication-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore.snapshot(defaults: defaults)
        let providers = settings.enabledProviders
        let stamp = ISO8601.fractional.string(from: Date().addingTimeInterval(-3600))
        try database.pool.write { db in
            for provider in providers {
                try db.execute(sql: """
                    INSERT INTO sessions
                    (session_id, root_session_id, started_at, updated_at, created_at, imported_at, provider)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [provider, provider, stamp, stamp, stamp, stamp, provider])
                try db.execute(sql: """
                    INSERT INTO usage_events
                    (session_id, timestamp, model_id, input_tokens, cached_input_tokens,
                     output_tokens, reasoning_output_tokens, total_tokens, value_usd,
                     provider, cache_creation_tokens, model_inferred)
                    VALUES (?, ?, 'gpt-5', 123, 0, 0, 0, 123, 1, ?, 0, 0)
                    """, arguments: [provider, stamp, provider])
            }
        }
        let environment = AppEnvironment(startBackgroundTasks: false, database: database,
                                         dashboardSnapshotStore: store,
                                         dashboardSettings: settings)
        return (environment, database, store, Int64(providers.count) * 123)
    }

    private func waitForIdle(_ environment: AppEnvironment) async {
        for _ in 0..<200 {
            if !environment.isLoadingDashboard && !environment.isLoadingDashboardActivity { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Dashboard refresh did not finish")
    }
}
