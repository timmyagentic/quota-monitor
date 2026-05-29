import Foundation
import Testing
@testable import QuotaMonitor

/// The menu-bar label style preference. Defaults to `.emphasis` (the app's
/// original rounded, mixed-weight look) and persists as a raw string.
@MainActor
@Suite("Menu-bar label style setting")
struct MenuBarLabelStyleSettingTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func defaultsToEmphasis() {
        let store = SettingsStore(defaults: Self.freshDefaults())
        #expect(store.menuBarLabelStyle == .emphasis)
    }

    @Test
    func persistsAndReloads() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.menuBarLabelStyle = .native
        #expect(d.string(forKey: "settings.menuBarLabelStyle") == "native")
        #expect(SettingsStore(defaults: d).menuBarLabelStyle == .native)
    }
}
