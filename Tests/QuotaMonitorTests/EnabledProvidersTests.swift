import Foundation
import Testing
@testable import QuotaMonitor

/// Locks down the per-provider toggle's persistence + invariants:
///   - default = the full `knownProviders` set (so users upgrading
///     from a build without the toggle keep tracking everything),
///   - "at least one" rule: disabling the last enabled provider is a
///     no-op and `setProviderEnabled` returns `false`,
///   - sanitisation: an unknown token in stored UserDefaults is dropped
///     on read, and an empty stored array is treated as "never set"
///     (i.e. fall back to the default rather than honouring the empty),
///   - onboarding inference + version gate: a fresh UserDefaults
///     gets `needsProviderOnboarding == true`. A UserDefaults that
///     holds prior settings *and* a `lastOnboardedVersion >=
///     onboardingResetMinVersion` skips the step. Same user without
///     a `lastOnboardedVersion` (or with an older one) is dragged
///     back through it so release-specific changes land.
///   - version stamp: `markProviderOnboardingDone()` writes the
///     current `appVersion` to `lastOnboardedVersion` so the next
///     launch's reset gate sees the right value.
///   - Snapshot carries the field so the non-MainActor poller code can
///     read it without hopping back to the actor.
///
/// `SettingsStore` is `@MainActor`, so the suite is too. We isolate
/// each test by handing the store its own `UserDefaults(suiteName:)`,
/// then `removePersistentDomain` in the teardown helper to leave the
/// host's defaults untouched.
@MainActor
@Suite("Provider enabled toggle")
struct EnabledProvidersTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func defaultsIncludeBothProviders() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.enabledProviders == ["codex", "claude"])
    }

    @Test
    func snapshotCarriesEnabledProviders() {
        let d = Self.freshDefaults()
        d.set(["codex"], forKey: "settings.enabledProviders")
        // Exercise the nonisolated path that the poller actually uses.
        // `snapshot()` reads `UserDefaults.standard`, so write into
        // standard for this case and clean up.
        let key = "settings.enabledProviders"
        let priorStandard = UserDefaults.standard.array(forKey: key)
        UserDefaults.standard.set(["codex"], forKey: key)
        defer {
            if let priorStandard {
                UserDefaults.standard.set(priorStandard, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let snap = SettingsStore.snapshot()
        #expect(snap.enabledProviders == ["codex"])
    }

    @Test
    func cannotDisableLastProvider() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        // Disable claude — succeeds, set goes down to {codex}.
        #expect(store.setProviderEnabled("claude", enabled: false))
        #expect(store.enabledProviders == ["codex"])
        // Now try to disable the only remaining one — must refuse and
        // keep the set unchanged so the UI's binding can stay ON.
        #expect(store.setProviderEnabled("codex", enabled: false) == false)
        #expect(store.enabledProviders == ["codex"])
    }

    @Test
    func unknownStoredProvidersAreDropped() {
        let d = Self.freshDefaults()
        d.set(["codex", "gemini" /* not yet supported */], forKey: "settings.enabledProviders")
        let store = SettingsStore(defaults: d)
        #expect(store.enabledProviders == ["codex"])
    }

    @Test
    func emptyStoredFallsBackToDefaultSet() {
        let d = Self.freshDefaults()
        d.set([] as [String], forKey: "settings.enabledProviders")
        let store = SettingsStore(defaults: d)
        // Empty is treated as "garbled / never set", not as "user
        // wants nothing" — that would violate the at-least-one rule
        // before any UI ever runs.
        #expect(store.enabledProviders == ["codex", "claude"])
    }

    @Test
    func freshInstallNeedsProviderOnboarding() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.needsProviderOnboarding)
    }

    @Test
    func upgradingUserWithoutLastVersionGetsReprompted() {
        let d = Self.freshDefaults()
        // Simulate a v0.2.6 user: language + poll interval written by
        // prior versions, and `onboarding.providersDone` may already be
        // true from their earlier completion — but they have never seen
        // `onboarding.lastVersion` (it didn't exist pre-0.2.7).
        d.set("en", forKey: "app.language")
        d.set(180, forKey: "settings.pollIntervalSeconds")
        d.set(true, forKey: "onboarding.providersDone")
        let store = SettingsStore(defaults: d, appVersion: "0.2.7")
        // The version-gated reset drags them back through the provider
        // step. Their enabled set is unchanged so they don't lose data.
        #expect(store.needsProviderOnboarding)
        #expect(store.enabledProviders == ["codex", "claude"])
    }

    @Test
    func userWithCurrentLastVersionSkipsOnboarding() {
        let d = Self.freshDefaults()
        // User already on the reset-min version — last onboarded at
        // exactly 0.2.7. They should not be intercepted.
        d.set("en", forKey: "app.language")
        d.set(true, forKey: "onboarding.providersDone")
        d.set("0.2.7", forKey: "onboarding.lastVersion")
        let store = SettingsStore(defaults: d, appVersion: "0.2.7")
        #expect(store.needsProviderOnboarding == false)
    }

    @Test
    func userOnOlderLastVersionGetsReprompted() {
        let d = Self.freshDefaults()
        d.set("en", forKey: "app.language")
        d.set(true, forKey: "onboarding.providersDone")
        d.set("0.2.6", forKey: "onboarding.lastVersion")
        let store = SettingsStore(defaults: d, appVersion: "0.2.7")
        #expect(store.needsProviderOnboarding)
    }

    @Test
    func markProviderOnboardingDoneIsIdempotent() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d, appVersion: "0.2.7")
        store.markProviderOnboardingDone()
        #expect(store.needsProviderOnboarding == false)
        // Calling again is a no-op for the flag (no didSet thrash).
        store.markProviderOnboardingDone()
        #expect(store.needsProviderOnboarding == false)
    }

    @Test
    func markProviderOnboardingDoneStampsLastVersion() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d, appVersion: "0.2.7")
        store.markProviderOnboardingDone()
        #expect(d.string(forKey: "onboarding.lastVersion") == "0.2.7")
    }

    @Test
    func semverCompareIsComponentWiseNotLexicographic() {
        // The naive String.< on "0.10.0" vs "0.2.0" gets it backwards;
        // make sure our comparator doesn't.
        #expect(SettingsStore.compareSemver("0.10.0", "0.2.0") > 0)
        #expect(SettingsStore.compareSemver("0.2.6", "0.2.7") < 0)
        #expect(SettingsStore.compareSemver("0.2.7", "0.2.7") == 0)
        // Pre-release tag is ignored (we only ship release builds).
        #expect(SettingsStore.compareSemver("0.2.7-beta", "0.2.7") == 0)
    }

    @Test
    func shouldResetOnboardingMatchesMinVersion() {
        // Nil → always reset (first-launch path or pre-stamp user).
        #expect(SettingsStore.shouldResetOnboarding(lastOnboarded: nil))
        // Older than min → reset.
        #expect(SettingsStore.shouldResetOnboarding(lastOnboarded: "0.2.6"))
        // At or above min → no reset.
        #expect(SettingsStore.shouldResetOnboarding(
            lastOnboarded: SettingsStore.onboardingResetMinVersion) == false)
    }

    @Test
    func replaceEnabledProvidersRejectsEmpty() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.replaceEnabledProviders([]) == false)
        #expect(store.enabledProviders == ["codex", "claude"])
        // An all-unknown set is also empty after sanitisation → reject.
        #expect(store.replaceEnabledProviders(["gemini"]) == false)
        #expect(store.enabledProviders == ["codex", "claude"])
    }
}
