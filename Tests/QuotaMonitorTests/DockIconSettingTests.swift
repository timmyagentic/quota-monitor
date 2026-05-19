import Foundation
import Testing
@testable import QuotaMonitor

/// Locks down the `showDockIconForWindows` user preference. The
/// default is OFF — when the user has never touched the setting,
/// QuotaMonitor stays in `.accessory` activation policy permanently
/// so no Dock icon ever appears. The persistence path is a plain
/// `Bool` under `settings.showDockIconForWindows`.
@MainActor
@Suite("Show Dock icon for windows setting")
struct DockIconSettingTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func defaultsToFalseOnFreshInstall() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.showDockIconForWindows == false)
    }

    @Test
    func mutatingWritesToUserDefaults() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.showDockIconForWindows = true
        #expect(d.bool(forKey: "settings.showDockIconForWindows") == true)
    }

    @Test
    func storedTrueIsReadOnInit() {
        let d = Self.freshDefaults()
        d.set(true, forKey: "settings.showDockIconForWindows")
        let store = SettingsStore(defaults: d)
        #expect(store.showDockIconForWindows == true)
    }

    @Test
    func storedFalseIsReadOnInit() {
        let d = Self.freshDefaults()
        d.set(false, forKey: "settings.showDockIconForWindows")
        let store = SettingsStore(defaults: d)
        #expect(store.showDockIconForWindows == false)
    }
}
