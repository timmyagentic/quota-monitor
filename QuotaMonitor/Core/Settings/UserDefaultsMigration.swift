import Foundation

/// One-shot copy of UserDefaults from the legacy `dev.tjzhou.CodexMonitor`
/// bundle id into the new `dev.tjzhou.QuotaMonitor` domain that the post-
/// rename binary writes to.
///
/// **Why this exists.** macOS scopes `UserDefaults.standard` per-bundle,
/// so changing the Bundle ID makes every previously-saved key invisible
/// to the new build. The user would lose their language choice, poll
/// interval, override paths, window frames, and the tiny `claude.lastUsage`
/// hydrator snapshot — even though all of that is still on disk in
/// `~/Library/Preferences/dev.tjzhou.CodexMonitor.plist`.
///
/// **Strategy.** On first launch under the new id, enumerate every key
/// under the legacy domain via `CFPreferencesCopyKeyList` and copy any
/// value the new domain doesn't already have. Then plant a one-shot
/// guard so we never run again. We deliberately enumerate-and-copy
/// rather than hard-code a key list so future settings keys we forget
/// to allow-list still get carried across.
///
/// **Safety.** Idempotent: if the guard key is set, no-op. If the new
/// domain already has a value for a key, we don't overwrite. The legacy
/// plist is left untouched (the user can `defaults delete dev.tjzhou.CodexMonitor`
/// at their leisure once they're sure the rename went well).
///
/// **Call site.** `QuotaMonitorApp.init()` calls `runIfNeeded()` BEFORE
/// any `@Observable` singleton (`LocalizationStore.shared`,
/// `SettingsStore.shared`) is constructed, since those read UserDefaults
/// in their initializers.
enum UserDefaultsMigration {
    private static let legacyBundleID = "dev.tjzhou.CodexMonitor"
    private static let guardKey = "migration.fromCodexMonitor.done"

    static func runIfNeeded() {
        if LocalQAEnvironment.isActive() { return }
        let defaults = LocalQAEnvironment.userDefaults() ?? .standard
        if defaults.bool(forKey: guardKey) { return }

        let legacy = legacyBundleID as CFString
        guard let keys = CFPreferencesCopyKeyList(
            legacy,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String], !keys.isEmpty else {
            // Either no legacy plist or empty — still flip the guard so
            // we don't probe on every launch.
            defaults.set(true, forKey: guardKey)
            return
        }

        var copied = 0
        for key in keys {
            // Don't ever copy our own guard key (defensive — shouldn't
            // exist in the legacy domain anyway).
            if key == guardKey { continue }
            // Don't clobber: if the user already wrote something to the
            // new domain (e.g. they launched and changed a setting
            // before we shipped this migration), respect that.
            if defaults.object(forKey: key) != nil { continue }
            if let value = CFPreferencesCopyAppValue(key as CFString, legacy) {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: guardKey)
        // No Logger import here — Log lives in Core/Log.swift and we
        // want this file to have minimal dependencies, but logging the
        // count is useful for the smoke test. Use os_log directly via
        // the existing subsystem.
        if copied > 0 {
            DeveloperLog.eventRecord(
                "settings.user_defaults_migration.finish",
                category: "settings",
                result: "success",
                fields: [
                    "copied": .int(copied),
                    "legacy_bundle_id": .string(legacyBundleID)
                ])
            // Print to stderr too so a `swift test` invocation surfaces
            // it without needing log show.
            FileHandle.standardError.write(Data(
                "[UserDefaultsMigration] copied \(copied) keys from \(legacyBundleID)\n".utf8
            ))
        }
    }
}
