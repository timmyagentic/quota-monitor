import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Quota display mode setting")
struct QuotaDisplayModeTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = TestResources.userDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func defaultsToUsedOnFreshInstall() {
        let store = SettingsStore(defaults: Self.freshDefaults())
        #expect(store.quotaDisplayMode == .used)
    }

    @Test
    func mutatingPersistsAndRelaunchReadsStoredValue() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)

        store.quotaDisplayMode = .remaining

        #expect(d.string(forKey: "settings.quotaDisplayMode") == "remaining")
        #expect(SettingsStore(defaults: d).quotaDisplayMode == .remaining)
    }

    @Test
    func unknownStoredValueFallsBackToUsed() {
        let d = Self.freshDefaults()
        d.set("left", forKey: "settings.quotaDisplayMode")

        let store = SettingsStore(defaults: d)

        #expect(store.quotaDisplayMode == .used)
    }

    @Test
    func displayPercentFollowsSelectedMode() {
        #expect(SettingsStore.QuotaDisplayMode.used
            .displayPercent(forUsedPercent: 37.5) == 37.5)
        #expect(SettingsStore.QuotaDisplayMode.used
            .progressValue(forUsedPercent: 37.5) == 0.375)

        #expect(SettingsStore.QuotaDisplayMode.remaining
            .displayPercent(forUsedPercent: 37.5) == 62.5)
        #expect(SettingsStore.QuotaDisplayMode.remaining
            .progressValue(forUsedPercent: 37.5) == 0.625)
    }

    @Test
    func displayPercentClampsBeforeInverting() {
        #expect(SettingsStore.QuotaDisplayMode.used
            .displayPercent(forUsedPercent: 133) == 100)
        #expect(SettingsStore.QuotaDisplayMode.used
            .displayPercent(forUsedPercent: -20) == 0)

        #expect(SettingsStore.QuotaDisplayMode.remaining
            .displayPercent(forUsedPercent: 133) == 0)
        #expect(SettingsStore.QuotaDisplayMode.remaining
            .displayPercent(forUsedPercent: -20) == 100)
    }
}
