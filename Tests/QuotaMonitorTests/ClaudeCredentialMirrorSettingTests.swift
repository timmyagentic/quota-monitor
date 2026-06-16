import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Claude credential disk cache setting")
struct ClaudeCredentialMirrorSettingTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func defaultsToEnabledOnFreshInstall() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.mirrorClaudeKeychainToFile == true)
    }

    @Test
    func freshInstallPersistsEnabledDefault() {
        let d = Self.freshDefaults()
        _ = SettingsStore(defaults: d)
        #expect(d.object(forKey: "settings.mirrorClaudeKeychainToFile") as? Bool == true)
    }

    @Test
    func snapshotDefaultsToEnabledOnFreshInstall() {
        let d = Self.freshDefaults()
        let snapshot = SettingsStore.snapshot(defaults: d)
        #expect(snapshot.mirrorClaudeKeychainToFile == true)
    }

    @Test
    func existingUserWithoutSavedPreferenceGetsEnabledOnInit() {
        let d = Self.freshDefaults()
        d.set(["claude"], forKey: "settings.enabledProviders")
        let store = SettingsStore(defaults: d)
        #expect(store.mirrorClaudeKeychainToFile == true)
    }

    @Test
    func existingUserWithoutSavedPreferenceGetsEnabledInSnapshot() {
        let d = Self.freshDefaults()
        d.set(["claude"], forKey: "settings.enabledProviders")
        let snapshot = SettingsStore.snapshot(defaults: d)
        #expect(snapshot.mirrorClaudeKeychainToFile == true)
    }

    @Test
    func existingUserWithoutSavedPreferencePersistsEnabledDefault() {
        let d = Self.freshDefaults()
        d.set(["claude"], forKey: "settings.enabledProviders")
        _ = SettingsStore(defaults: d)
        #expect(d.object(forKey: "settings.mirrorClaudeKeychainToFile") as? Bool == true)
    }

    @Test
    func storedFalseIsReadOnInit() {
        let d = Self.freshDefaults()
        d.set(false, forKey: "settings.mirrorClaudeKeychainToFile")
        let store = SettingsStore(defaults: d)
        #expect(store.mirrorClaudeKeychainToFile == false)
        #expect(d.object(forKey: "settings.mirrorClaudeKeychainToFile") as? Bool == false)
    }
}
