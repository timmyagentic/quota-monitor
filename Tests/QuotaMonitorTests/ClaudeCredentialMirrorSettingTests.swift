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
    func snapshotDefaultsToEnabledOnFreshInstall() {
        let d = Self.freshDefaults()
        let snapshot = SettingsStore.snapshot(defaults: d)
        #expect(snapshot.mirrorClaudeKeychainToFile == true)
    }

    @Test
    func storedFalseIsReadOnInit() {
        let d = Self.freshDefaults()
        d.set(false, forKey: "settings.mirrorClaudeKeychainToFile")
        let store = SettingsStore(defaults: d)
        #expect(store.mirrorClaudeKeychainToFile == false)
    }
}
