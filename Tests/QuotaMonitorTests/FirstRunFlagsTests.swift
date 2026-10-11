import Foundation
import Testing
@testable import QuotaMonitor

/// Locks down the two discoverability flags added for the menu-bar
/// clip-fallback feature. Both default OFF on a fresh install and
/// persist as plain Bools.
@MainActor
@Suite("First-run discoverability flags")
struct FirstRunFlagsTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = TestResources.userDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func firstRunPresentationDefaultsFalse() {
        let store = SettingsStore(defaults: Self.freshDefaults())
        #expect(store.hasShownFirstRunPresentation == false)
    }

    @Test
    func firstRunPresentationPersists() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.hasShownFirstRunPresentation = true
        #expect(d.bool(forKey: "discoverability.firstRunPresentationShown") == true)
        #expect(SettingsStore(defaults: d).hasShownFirstRunPresentation == true)
    }

    @Test
    func hintDismissedDefaultsFalse() {
        let store = SettingsStore(defaults: Self.freshDefaults())
        #expect(store.firstRunHintDismissed == false)
    }

    @Test
    func hintDismissedPersists() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.firstRunHintDismissed = true
        #expect(d.bool(forKey: "discoverability.firstRunHintDismissed") == true)
        #expect(SettingsStore(defaults: d).firstRunHintDismissed == true)
    }
}
