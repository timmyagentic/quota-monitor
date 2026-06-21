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
///     holds prior settings skips the step even if its
///     `lastOnboardedVersion` is missing or stale; the version stamp
///     is repaired in place so updates do not overwrite settings by
///     sending existing users through fresh-install defaults.
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
    func configuredExistingUserWithoutLastVersionSkipsOnboardingAndStampsCurrentVersion() {
        let d = Self.freshDefaults()
        // Simulate an installed user whose provider/menu-bar choices
        // survived but whose version stamp is missing. This happened for
        // some update paths; re-opening onboarding would submit its
        // fresh-install defaults and overwrite those choices.
        d.set("zh-Hans", forKey: "app.language")
        d.set(["claude"], forKey: "settings.enabledProviders")
        d.set(["claude"], forKey: "settings.menuBarIconProviders")
        d.set(true, forKey: "onboarding.providersDone")
        let store = SettingsStore(defaults: d, appVersion: "0.2.33")
        #expect(store.needsProviderOnboarding == false)
        #expect(store.enabledProviders == ["claude"])
        #expect(store.menuBarIconProviders == ["claude"])
        #expect(d.bool(forKey: "onboarding.providersDone"))
        #expect(d.string(forKey: "onboarding.lastVersion") == "0.2.33")
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
    func configuredExistingUserWithOlderLastVersionSkipsOnboardingAndStampsCurrentVersion() {
        let d = Self.freshDefaults()
        d.set("en", forKey: "app.language")
        d.set(["codex", "claude"], forKey: "settings.enabledProviders")
        d.set(["claude"], forKey: "settings.menuBarIconProviders")
        d.set(true, forKey: "onboarding.providersDone")
        d.set("0.2.6", forKey: "onboarding.lastVersion")
        let store = SettingsStore(defaults: d, appVersion: "0.2.33")
        #expect(store.needsProviderOnboarding == false)
        #expect(store.enabledProviders == ["codex", "claude"])
        #expect(store.menuBarIconProviders == ["claude"])
        #expect(d.string(forKey: "onboarding.lastVersion") == "0.2.33")
    }

    @Test
    func resetPendingConfiguredUserSkipsOnboardingAndRepairsDoneFlag() {
        let d = Self.freshDefaults()
        // A previous launch with a missing/stale version stamp used to
        // persist providersDone=false before the user could finish the
        // forced onboarding. If provider settings already exist, the next
        // launch must repair that state instead of opening onboarding
        // again and risking another overwrite.
        d.set("en", forKey: "app.language")
        d.set(["claude"], forKey: "settings.enabledProviders")
        d.set(["claude"], forKey: "settings.menuBarIconProviders")
        d.set(false, forKey: "onboarding.providersDone")
        let store = SettingsStore(defaults: d, appVersion: "0.2.33")
        #expect(store.needsProviderOnboarding == false)
        #expect(store.enabledProviders == ["claude"])
        #expect(store.menuBarIconProviders == ["claude"])
        #expect(d.bool(forKey: "onboarding.providersDone"))
        #expect(d.string(forKey: "onboarding.lastVersion") == "0.2.33")
    }

    @Test
    func languageOnlyExistingUserWithoutLastVersionSkipsOnboardingAndStampsCurrentVersion() {
        let d = Self.freshDefaults()
        // Builds before provider onboarding could have a valid language
        // selection without ever writing provider arrays. That is still
        // an existing user, not a fresh install.
        d.set("zh-Hans", forKey: "app.language")

        let store = SettingsStore(defaults: d, appVersion: "0.2.34")

        #expect(store.needsProviderOnboarding == false)
        #expect(store.enabledProviders == ["codex", "claude"])
        #expect(d.bool(forKey: "onboarding.providersDone"))
        #expect(d.string(forKey: "onboarding.lastVersion") == "0.2.34")
    }

    @Test
    func partialCurrentOnboardingStillNeedsProviderStep() {
        let d = Self.freshDefaults()
        // Current builds write an explicit false before the user finishes
        // the provider step. A language-only partial onboarding session is
        // not an existing configured user and should still resume setup.
        d.set("en", forKey: "app.language")
        d.set(false, forKey: "onboarding.providersDone")
        let store = SettingsStore(defaults: d, appVersion: "0.2.33")
        #expect(store.needsProviderOnboarding)
        #expect(d.string(forKey: "onboarding.lastVersion") == nil)
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

    @Test
    func onboardingCommitSequenceProducesExpectedEndState() {
        // Locks down the call sequence OnboardingView.finishOnboarding uses:
        //   1. replaceEnabledProviders(providers)  — does NOT touch
        //      menuBarIconProviders; that field stores user intent and
        //      the menu-bar render path intersects with enabledProviders
        //      at draw time.
        //   2. setMenuBarIconProviderEnabled(_:enabled:) for every known
        //      icon provider, driven by the user's step-3 picks
        // Three representative cases — pick-both/show-codex-only,
        // pick-both/show-neither, pick-one-and-step-3-skipped.

        // Case 1: both providers tracked, only Codex shown in menu bar.
        do {
            let d = Self.freshDefaults()
            let store = SettingsStore(defaults: d)
            #expect(store.replaceEnabledProviders(["codex", "claude"]))
            #expect(store.setMenuBarIconProviderEnabled("codex", enabled: true))
            #expect(store.setMenuBarIconProviderEnabled("claude", enabled: false))
            #expect(store.enabledProviders == ["codex", "claude"])
            #expect(store.menuBarIconProviders == ["codex"])
        }

        // Case 2: both providers tracked, neither shown in menu bar
        // (gauge-icon fallback). Empty is a valid resting state.
        do {
            let d = Self.freshDefaults()
            let store = SettingsStore(defaults: d)
            #expect(store.replaceEnabledProviders(["codex", "claude"]))
            #expect(store.setMenuBarIconProviderEnabled("codex", enabled: false))
            #expect(store.setMenuBarIconProviderEnabled("claude", enabled: false))
            #expect(store.enabledProviders == ["codex", "claude"])
            #expect(store.menuBarIconProviders == [])
        }

        // Case 3: only Codex tracked, only Codex shown. Mirrors the
        // "step 2 picks one provider, step 3 is skipped" branch where
        // finishOnboarding is called with iconProviders == providers.
        do {
            let d = Self.freshDefaults()
            let store = SettingsStore(defaults: d)
            #expect(store.replaceEnabledProviders(["codex"]))
            #expect(store.setMenuBarIconProviderEnabled("codex", enabled: true))
            // Claude is still in menuBarIconProviders here — fresh
            // init seeded it with the full default set and
            // replaceEnabledProviders no longer trims. The explicit
            // setMenuBarIconProviderEnabled call below is what removes
            // it, matching what step 3 of onboarding would do.
            #expect(store.setMenuBarIconProviderEnabled("claude", enabled: false))
            #expect(store.enabledProviders == ["codex"])
            #expect(store.menuBarIconProviders == ["codex"])
        }
    }

    /// Regression: disabling a provider then re-enabling it should
    /// restore its menu-bar icon automatically. Previously
    /// `setProviderEnabled(_, false)` invoked
    /// `reconcileMenuBarIconProviders` which trimmed the icon set;
    /// the symmetric re-enable path never reseeded, leaving the user
    /// in a "silently lost my icon" state.
    @Test
    func reenablingProviderRestoresMenuBarIcon() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        // Fresh install seeds both providers everywhere.
        #expect(store.enabledProviders == ["codex", "claude"])
        #expect(store.menuBarIconProviders == ["codex", "claude"])

        // Disable Codex tracking. Icon intent must NOT shrink.
        #expect(store.setProviderEnabled("codex", enabled: false))
        #expect(store.enabledProviders == ["claude"])
        #expect(store.menuBarIconProviders == ["codex", "claude"])

        // Re-enable Codex. Icon comes back without any extra call.
        #expect(store.setProviderEnabled("codex", enabled: true))
        #expect(store.enabledProviders == ["codex", "claude"])
        #expect(store.menuBarIconProviders == ["codex", "claude"])
    }

    /// User explicitly unchecks Codex's menu-bar icon while it's still
    /// tracked. Later they disable Codex tracking then re-enable it.
    /// The explicit "don't show in menu bar" choice must survive.
    @Test
    func explicitIconOffSurvivesProviderTrackingFlip() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        #expect(store.setMenuBarIconProviderEnabled("codex", enabled: false))
        #expect(store.menuBarIconProviders == ["claude"])

        #expect(store.setProviderEnabled("codex", enabled: false))
        #expect(store.setProviderEnabled("codex", enabled: true))
        // Intent for Codex was off → still off after the round trip.
        #expect(store.menuBarIconProviders == ["claude"])
    }

    /// Regression for an in-init bug discovered during self-audit:
    /// `SettingsStore.init` used to intersect the loaded icon set with
    /// the currently-enabled providers, so a "disable tracking →
    /// quit → relaunch → re-enable tracking" cycle silently dropped
    /// the icon. The disable/re-enable test above doesn't catch this
    /// because it stays inside a single SettingsStore instance.
    @Test
    func reenablingProviderRestoresMenuBarIconAcrossRelaunch() {
        let d = Self.freshDefaults()
        do {
            let store = SettingsStore(defaults: d)
            #expect(store.setProviderEnabled("codex", enabled: false))
            // Intent on disk is still [codex, claude] at this point.
            #expect(store.menuBarIconProviders == ["codex", "claude"])
        }
        // Simulate a relaunch — same UserDefaults, fresh store.
        let relaunched = SettingsStore(defaults: d)
        #expect(relaunched.enabledProviders == ["claude"])
        #expect(relaunched.menuBarIconProviders == ["codex", "claude"])

        #expect(relaunched.setProviderEnabled("codex", enabled: true))
        #expect(relaunched.menuBarIconProviders == ["codex", "claude"])
    }
}
