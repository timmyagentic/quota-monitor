import Foundation
import Testing
@testable import QuotaMonitor

@Suite("User defaults migration", .serialized)
struct UserDefaultsMigrationTests {
    private static let quotaFeed =
        "https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml"
    private static let legacyQuotaFeed =
        "https://raw.githubusercontent.com/systemoutprintlnnnn/quota-monitor/main/appcast.xml"
    private static let codexFeed =
        "https://raw.githubusercontent.com/systemoutprintlnnnn/codex-monitor/main/appcast.xml"
    private static let customFeed = "https://updates.example.test/custom.xml"
    private static let customFeedUnderLegacyOwner =
        "https://raw.githubusercontent.com/systemoutprintlnnnn/custom-updater/main/appcast.xml"

    private let feedKey = "SUFeedURL"
    private let guardKey = "app.updaterFeedMigrationV2Done"

    @Test("QuotaMonitor repairs a legacy stored feed to the current bundled feed")
    func quotaMonitorRepairsLegacyStoredFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.legacyQuotaFeed,
            bundled: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id") == Self.quotaFeed)
    }

    @Test("QuotaMonitor repairs a missing override when the bundle still has the legacy feed")
    func quotaMonitorRepairsLegacyBundledFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: nil,
            bundled: Self.legacyQuotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id") == Self.quotaFeed)
    }

    @Test("QuotaMonitor leaves its current feed unchanged")
    func quotaMonitorPreservesCurrentFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.quotaFeed,
            bundled: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id") == Self.quotaFeed)
    }

    @Test("QuotaMonitor preserves a custom feed")
    func quotaMonitorPreservesCustomFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.customFeed,
            bundled: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id") == nil)
    }

    @Test("QuotaMonitor preserves a same-owner URL outside the exact allowlist")
    func quotaMonitorPreservesSameOwnerCustomFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.customFeedUnderLegacyOwner,
            bundled: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id") == nil)
    }

    @Test("CodexMonitor preserves its installed-client feed")
    func codexMonitorPreservesCurrentFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.codexFeed,
            bundled: Self.codexFeed,
            appCodeName: "CodexMonitor",
            distributionChannel: "developer-id") == Self.codexFeed)
    }

    @Test("CodexMonitor repairs an accidentally stored QuotaMonitor feed")
    func codexMonitorRepairsQuotaMonitorFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.quotaFeed,
            bundled: Self.codexFeed,
            appCodeName: "CodexMonitor",
            distributionChannel: "developer-id") == Self.codexFeed)
    }

    @Test("CodexMonitor preserves a custom feed")
    func codexMonitorPreservesCustomFeed() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.customFeed,
            bundled: Self.codexFeed,
            appCodeName: "CodexMonitor",
            distributionChannel: "developer-id") == nil)
    }

    @Test("App Store distributions never resolve a feed override")
    func appStoreDoesNotResolveFeedOverride() {
        #expect(SparkleFeedMigration.resolvedURL(
            existing: Self.legacyQuotaFeed,
            bundled: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "app-store") == nil)
    }

    @Test("App Store migration records completion without writing SUFeedURL")
    func appStoreMigrationDoesNotWriteFeedURL() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        UserDefaultsMigration.migrateSparkleFeedURL(
            defaults: defaults,
            bundledFeed: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "app-store")

        #expect(defaults.object(forKey: feedKey) == nil)
        #expect(defaults.bool(forKey: guardKey))
    }

    @Test("Feed migration uses the v2 guard exactly once")
    func feedMigrationRunsExactlyOnce() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Self.legacyQuotaFeed, forKey: feedKey)

        UserDefaultsMigration.migrateSparkleFeedURL(
            defaults: defaults,
            bundledFeed: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id")

        #expect(defaults.string(forKey: feedKey) == Self.quotaFeed)
        #expect(defaults.bool(forKey: guardKey))

        defaults.set(Self.legacyQuotaFeed, forKey: feedKey)
        UserDefaultsMigration.migrateSparkleFeedURL(
            defaults: defaults,
            bundledFeed: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id")

        #expect(defaults.string(forKey: feedKey) == Self.legacyQuotaFeed)
    }

    @Test("Injectable feed migration only mutates the supplied defaults suite")
    func feedMigrationDoesNotTouchStandardDefaults() throws {
        let standardFeedBefore = UserDefaults.standard.string(forKey: feedKey)
        let standardGuardBefore = UserDefaults.standard.object(forKey: guardKey) as? Bool
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Self.legacyQuotaFeed, forKey: feedKey)

        UserDefaultsMigration.migrateSparkleFeedURL(
            defaults: defaults,
            bundledFeed: Self.quotaFeed,
            appCodeName: "QuotaMonitor",
            distributionChannel: "developer-id")

        #expect(defaults.string(forKey: feedKey) == Self.quotaFeed)
        #expect(UserDefaults.standard.string(forKey: feedKey) == standardFeedBefore)
        #expect((UserDefaults.standard.object(forKey: guardKey) as? Bool) == standardGuardBefore)
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "UserDefaultsMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
