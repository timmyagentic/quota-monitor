import Foundation
import Observation

// Cross-feature settings backed by UserDefaults.
//
// Convention:
//   - Empty string means "not set" / use auto-discovery.
//   - Hot-reloadable settings (poll interval) are applied via
//     AppEnvironment.applySettings() right after the user edits them.
//   - Path-changing settings (codex binary, codex home, claude home) currently
//     take effect on next launch — we surface that in the UI so users aren't
//     surprised.

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollInterval) }
    }
    /// Controls whether `ClaudeUsageClient` is allowed to read the
    /// `Claude Code-credentials` keychain entry. Reads are
    /// non-interactive: if macOS would need to show an authorization
    /// prompt, the read is treated as unavailable instead of blocking a
    /// background poller. The file source (`~/.claude/.credentials.json`)
    /// is always tried first, so most users won't notice this knob.
    var keychainPolicy: KeychainPolicy {
        didSet { defaults.set(keychainPolicy.rawValue, forKey: Keys.keychainPolicy) }
    }
    /// **OFF by default — security policy.** When ON, after a successful
    /// Keychain read of the Claude OAuth credentials we mirror the same
    /// JSON blob to `~/.claude/.credentials.json`. This stops the
    /// recurring "QuotaMonitor wants to use…" Keychain prompt that
    /// appears after every ad-hoc rebuild (the macOS ACL is bound to
    /// the binary's signature, which changes with each `./build.sh`).
    ///
    /// **Why opt-in.** Moving credentials from a more-protected store
    /// (Keychain, per-app ACL'd) to a less-protected one (a plain
    /// 0600 file readable by any process running as your user) is a
    /// security downgrade. We will not flip this for the user
    /// silently — they have to enable it in Settings → Advanced.
    /// Help text on the toggle spells out the trade-off.
    ///
    /// File written 0600 + atomic replace so we never expose the
    /// token mid-write or leave a half-written file behind.
    var mirrorClaudeKeychainToFile: Bool {
        didSet { defaults.set(mirrorClaudeKeychainToFile,
                              forKey: Keys.mirrorClaudeKeychainToFile) }
    }
    /// Whether to promote the menu-bar app to `.regular` activation
    /// policy while a Dashboard / Settings / Onboarding window is on
    /// screen. **Default false** — by default QuotaMonitor stays a
    /// pure menu-bar agent (no Dock icon, not in Cmd+Tab). Users who
    /// want the more conventional Dock-icon-while-window-open
    /// behaviour can flip this in Settings → General → Appearance.
    ///
    /// Live-applied: the General tab's toggle calls
    /// `AppEnvironment.applyDockIconPolicy()` after mutating, so a
    /// flip takes effect on the next render even with a window
    /// already open.
    var showDockIconForWindows: Bool {
        didSet { defaults.set(showDockIconForWindows,
                              forKey: Keys.showDockIconForWindows) }
    }
    /// Which rolling window the menu bar uses for the headline
    /// `$X.XX · Yk tokens` line and the session-count chip. Default
    /// 7 days because most users want a "what did I do this week"
    /// signal — 30 days drowns out short-term spikes. The picker lives in
    /// Settings → General → Menu bar.
    var menuBarHeadlineWindow: HeadlineWindow {
        didSet { defaults.set(menuBarHeadlineWindow.rawValue,
                              forKey: Keys.menuBarHeadlineWindow) }
    }
    /// How quota percentages are presented in compact UI. The source data
    /// remains `usedPercent`; this only changes the displayed number and
    /// progress fill:
    ///   - `.used`      → 37% means 37% consumed, bar is 37% full
    ///   - `.remaining` → 63% means 63% left, bar is 63% full
    ///
    /// Default `.used` preserves the app's existing behavior.
    var quotaDisplayMode: QuotaDisplayMode {
        didSet { defaults.set(quotaDisplayMode.rawValue,
                              forKey: Keys.quotaDisplayMode) }
    }
    /// Which language to render compact token suffixes in (`5.1B Token`
    /// vs `51亿 Token`). The picker is hidden in English mode — there
    /// is only one sensible answer (B/M/K) so the switch would be
    /// confusing clutter. Chinese users see it in General → Appearance.
    /// Default `.followLanguage`: zh renders 亿/万 to match the rest of
    /// the UI, en stays on B/M/K. `.english` overrides zh back to B/M/K
    /// for users who prefer the engineering convention.
    var tokenUnitLanguage: TokenUnitLanguage {
        didSet { defaults.set(tokenUnitLanguage.rawValue,
                              forKey: Keys.tokenUnitLanguage) }
    }
    /// Global override for Codex CLI billing tier. Codex's JSONL output
    /// does not record whether a given turn used Fast Mode, so we can't
    /// auto-detect per call. When ON, the value-backfill SQL routes
    /// every event for the models listed in `CodexFastMode.multipliers`
    /// (currently GPT-5.5 → 2.5×, GPT-5.4 → 2.0×) to a synthetic
    /// `<model>-fast` catalog row so the dollar figure reflects the
    /// Fast-tier rate. Toggling re-runs `backfillAllValues` so history
    /// is recomputed end-to-end — a flip changes every prior chart and
    /// the menu-bar headline immediately.
    ///
    /// Default OFF: most Codex users are on Standard, and we don't want
    /// to silently inflate the $ for someone who never enabled Fast
    /// Mode on the OpenAI side.
    var codexFastModeBilling: Bool {
        didSet { defaults.set(codexFastModeBilling,
                              forKey: Keys.codexFastModeBilling) }
    }
    /// Developer diagnostics mode. When enabled, app lifecycle,
    /// refresh, scan, pricing, query, and settings actions are mirrored
    /// to a local plain-text file under Application Support so a dev can
    /// inspect a run after the app exits. Default OFF: normal users
    /// should not accumulate debug files silently.
    var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled,
                              forKey: Keys.developerModeEnabled) }
    }
    /// Which provider's quota fills the menu-bar icon (one row per
    /// window: 5h + 7d, "X% used"). Multi-select — the user can show
    /// one provider, both side-by-side, or neither (in which case the
    /// menu-bar label falls back to the static gauge SF Symbol).
    /// Hidden when no chosen provider is currently tracked or when no
    /// usage data is yet available.
    ///
    /// Default on fresh install: same set as `enabledProviders`. On
    /// upgrades from the legacy single-string key we migrate the old
    /// choice once.
    ///
    /// **Stored as user intent, not as the currently-displayed set.**
    /// Toggling a provider OFF in Tracked tools does NOT trim it from
    /// here — the menu-bar render path (`MenuBarLabelView.pickRows`)
    /// already intersects with `enabledProviders` at draw time, so a
    /// disabled provider is invisible regardless. Keeping the intent
    /// intact means re-enabling tracking restores the icon
    /// automatically, instead of stranding the user in "icon
    /// silently disappeared" state.
    ///
    /// Constraint: must be a subset of `knownIconProviders`. UI should
    /// call `setMenuBarIconProviderEnabled(_:enabled:)` for explicit
    /// user changes.
    private(set) var menuBarIconProviders: Set<String> {
        didSet {
            defaults.set(Array(menuBarIconProviders).sorted(),
                         forKey: Keys.menuBarIconProviders)
        }
    }
    /// Which providers QuotaMonitor actively tracks. Persisted as a
    /// string array under `Keys.enabledProviders`. Disabling a provider
    /// stops its background poller, hides its menu-bar block, drops it
    /// from the Dashboard's Forecast / Composition / statline, and
    /// removes it from the toolbar provider filter.
    ///
    /// Constraint: must contain at least one entry. Mutating directly is
    /// allowed (set logic clamps to the previous value if the input is
    /// empty), but UI should prefer `setProviderEnabled(_:enabled:)`
    /// which returns false when the constraint blocked the change so
    /// the caller can keep the toggle in its current visual state.
    private(set) var enabledProviders: Set<String> {
        didSet {
            defaults.set(Array(enabledProviders).sorted(),
                         forKey: Keys.enabledProviders)
        }
    }
    /// Set once the user has completed the provider step of onboarding.
    /// Existing-installation upgrades infer `true` in `init` (see the
    /// `looksLikeExistingUser` heuristic) EXCEPT when the stored
    /// `lastOnboardedVersion` is older than `onboardingResetMinVersion`
    /// — in that case we drag them back through the provider step so
    /// they see any release-specific copy or new options. Language is
    /// never reset (`app.language` is left untouched), only the
    /// provider step is re-prompted.
    private(set) var hasCompletedProviderOnboarding: Bool {
        didSet { defaults.set(hasCompletedProviderOnboarding,
                              forKey: Keys.providerOnboardingDone) }
    }
    var needsProviderOnboarding: Bool { !hasCompletedProviderOnboarding }

    /// The bundle version (`CFBundleShortVersionString`) this instance
    /// was constructed with. Stamped into `lastOnboardedVersion` when
    /// the user finishes the provider step so a future release can
    /// detect "did this user finish onboarding at a version ≥ X".
    /// Tests inject an explicit value; production reads `Bundle.main`.
    private let appVersion: String?

    /// Bump this when a release introduces an onboarding step (or
    /// changes copy) you want existing users to see. On launch, any
    /// user whose `lastOnboardedVersion` is missing or strictly less
    /// than this string is dragged back through the provider step,
    /// even if they previously completed onboarding. Language pick is
    /// preserved.
    nonisolated static let onboardingResetMinVersion = "0.2.7"

    enum TokenUnitLanguage: String, CaseIterable, Sendable, Identifiable {
        /// Use the same locale the rest of the UI is rendered in.
        /// zh → 亿/万, en → B/M/K. Default.
        case followLanguage
        /// Force English-style compact suffixes (B/M/K) regardless of
        /// the app language. For Chinese users who prefer the
        /// engineering convention.
        case english
        var id: String { rawValue }
    }

    enum QuotaDisplayMode: String, CaseIterable, Sendable, Identifiable {
        case used
        case remaining
        var id: String { rawValue }

        func displayPercent(forUsedPercent usedPercent: Double) -> Double {
            let used = Self.clampPercent(usedPercent)
            switch self {
            case .used: return used
            case .remaining: return 100 - used
            }
        }

        func progressValue(forUsedPercent usedPercent: Double) -> Double {
            displayPercent(forUsedPercent: usedPercent) / 100
        }

        private static func clampPercent(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return max(0, min(100, value))
        }
    }

    /// Locale to feed `.number.notation(.compactName).locale(...)` so all
    /// token counts pick up the user's choice. Reading this in a view
    /// body also subscribes that view to `tokenUnitLanguage` changes via
    /// `@Observable`, so flipping the setting re-renders the affected
    /// rows without a manual refresh.
    var tokenFormatLocale: Locale {
        switch tokenUnitLanguage {
        case .english: return Locale(identifier: "en_US")
        case .followLanguage: return LocalizationStore.shared.locale
        }
    }

    /// Nonisolated read of `tokenFormatLocale` for code paths that can't
    /// hop to MainActor (e.g. static `L10n` helpers). Pulls the stored
    /// preference straight from UserDefaults and combines it with
    /// `LocalizationStore.activeLanguage` (also nonisolated).
    nonisolated static var tokenFormatLocaleNonisolated: Locale {
        let stored = UserDefaults.standard.string(forKey: Keys.tokenUnitLanguage)
            .flatMap(TokenUnitLanguage.init(rawValue:)) ?? .followLanguage
        switch stored {
        case .english: return Locale(identifier: "en_US")
        case .followLanguage: return LocalizationStore.activeLanguage.locale
        }
    }

    enum KeychainPolicy: String, CaseIterable, Sendable, Identifiable {
        /// Try keychain only when the on-disk credentials file is missing
        /// or stale. Default — covers Claude CLI users without prompts.
        case fallback
        /// Skip the keychain entirely. Use this if the user has rejected
        /// the prompt and doesn't want to be asked again.
        case never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fallback: return L10n.keychainPolicyFallback
            case .never:    return L10n.keychainPolicyNever
            }
        }
    }

    /// Provider IDs eligible to appear in the menu-bar label. Same
    /// shape as `enabledProviders` (raw provider strings), and a
    /// subset of `knownProviders`. Kept as a free-form Set instead of
    /// an enum so the storage shape mirrors `enabledProviders` and we
    /// can do simple Set operations when reconciling.
    nonisolated static let knownIconProviders: Set<String> = ["codex", "claude"]

    init(defaults: UserDefaults = .standard,
         appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) {
        self.defaults = defaults
        self.appVersion = appVersion
        let storedInterval = defaults.integer(forKey: Keys.pollInterval)
        self.pollIntervalSeconds = storedInterval > 0 ? storedInterval : 300
        self.keychainPolicy = (defaults.string(forKey: Keys.keychainPolicy)
            .flatMap(KeychainPolicy.init(rawValue:))) ?? .fallback
        // Default false. We never default-on a security downgrade —
        // see `mirrorClaudeKeychainToFile` doc comment.
        self.mirrorClaudeKeychainToFile =
            defaults.bool(forKey: Keys.mirrorClaudeKeychainToFile)
        // Default false. A missing key reads as false via
        // `defaults.bool(forKey:)`, which is exactly the resolved
        // default we want for both fresh installs and existing users
        // upgrading to this release (per the user-confirmed spec).
        self.showDockIconForWindows =
            defaults.bool(forKey: Keys.showDockIconForWindows)
        self.menuBarHeadlineWindow = (defaults.string(forKey: Keys.menuBarHeadlineWindow)
            .flatMap(HeadlineWindow.init(rawValue:))) ?? .last7d
        self.quotaDisplayMode = (defaults.string(forKey: Keys.quotaDisplayMode)
            .flatMap(QuotaDisplayMode.init(rawValue:))) ?? .used
        self.tokenUnitLanguage = (defaults.string(forKey: Keys.tokenUnitLanguage)
            .flatMap(TokenUnitLanguage.init(rawValue:))) ?? .followLanguage
        // Default false. A missing key reads as false via
        // `defaults.bool(forKey:)`, which is exactly what we want for
        // fresh installs and existing users (we don't enable Fast
        // billing for anyone who hasn't asked for it).
        self.codexFastModeBilling = defaults.bool(forKey: Keys.codexFastModeBilling)
        self.developerModeEnabled = defaults.bool(forKey: Keys.developerModeEnabled)
        // Enabled providers — defaults to the full set so an old build
        // upgrading to this binary keeps tracking both. We sanitise to
        // drop unknown tokens (future renames / deletions) and refuse
        // an empty stored value (treat as "never set" → full default).
        let storedProviders = defaults.array(forKey: Keys.enabledProviders) as? [String]
        let sanitised: Set<String> = storedProviders.map {
            Set($0).intersection(Self.knownProviders)
        } ?? []
        let resolvedEnabled: Set<String> = sanitised.isEmpty
            ? Self.knownProviders
            : sanitised
        self.enabledProviders = resolvedEnabled
        // Menu-bar icon providers (multi-select). Stored as user
        // *intent* — we sanitise only against `knownIconProviders` to
        // drop unknown tokens, and deliberately do NOT intersect with
        // `resolvedEnabled`. Intersecting on load would re-trim the
        // intent the moment a user disabled tracking, defeating the
        // "icon comes back when tracking comes back" guarantee
        // documented on `menuBarIconProviders`. The render path
        // (`MenuBarLabelView.pickRows`) does the per-draw filter
        // against `enabledProviders`, so disabled providers stay
        // invisible regardless of what intent is stored here.
        //
        // Legacy single-string key `settings.menuBarIconProvider`
        // ("codex" / "claude") is migrated once for upgrading users.
        let storedIconArr = defaults.array(forKey: Keys.menuBarIconProviders) as? [String]
        let seededIcons: Set<String>
        if let storedIconArr {
            // User has explicit stored intent (an empty array is a
            // valid "show neither" choice and must be preserved).
            seededIcons = Set(storedIconArr).intersection(Self.knownIconProviders)
        } else if let legacy = defaults.string(forKey: Keys.legacyMenuBarIconProvider),
                  Self.knownIconProviders.contains(legacy) {
            seededIcons = [legacy]
        } else {
            // Fresh install — seed with every enabled provider so the
            // menu bar shows what the user just confirmed in
            // onboarding rather than a blank gauge icon.
            seededIcons = resolvedEnabled
        }
        self.menuBarIconProviders = seededIcons
        // First-seed persistence. Swift suppresses `didSet` on the
        // initializer's first assignment, so a fresh install that
        // never explicitly touches the icon checkboxes would have
        // nothing written to UserDefaults. That left a hole where
        // disabling a tracked provider before quitting would, on
        // relaunch, re-seed the icon set from the now-smaller
        // `resolvedEnabled` — silently dropping the icon. Stamping
        // the resolved value here once turns the seed into durable
        // intent.
        if storedIconArr == nil {
            defaults.set(Array(seededIcons).sorted(),
                         forKey: Keys.menuBarIconProviders)
        }
        // Onboarding-done flag. Resolution has two layers:
        //
        //  1. Base value. If `providerOnboardingDone` is stored, use it.
        //     Otherwise infer from "looks like an existing user" — i.e.
        //     any of language / providers / poll interval already set on
        //     this UserDefaults. Fresh installs alone get `false` here
        //     and see the full onboarding.
        //
        //  2. Version-gated reset. If `lastOnboardedVersion` is missing
        //     or strictly less than `onboardingResetMinVersion`, force
        //     the flag back to `false` regardless of (1). This is what
        //     drags upgrading users back through the provider step
        //     when a release ships changes worth re-confirming.
        //
        // Result is persisted so a partial-quit-mid-onboarding doesn't
        // re-trigger the reset on every launch — the false sticks
        // until the user finishes via `markProviderOnboardingDone()`,
        // which also stamps `lastOnboardedVersion`.
        let storedDone = defaults.object(forKey: Keys.providerOnboardingDone) as? Bool
        let baseDone: Bool
        if let done = storedDone {
            baseDone = done
        } else {
            baseDone =
                defaults.string(forKey: "app.language") != nil
                || storedProviders != nil
                || storedInterval > 0
        }
        let lastOnboarded = defaults.string(forKey: Keys.lastOnboardedVersion)
        let resetGate = Self.shouldResetOnboarding(lastOnboarded: lastOnboarded)
        let resolvedDone = baseDone && !resetGate
        self.hasCompletedProviderOnboarding = resolvedDone
        defaults.set(resolvedDone, forKey: Keys.providerOnboardingDone)
    }

    /// True iff `lastOnboarded` is missing or strictly less than
    /// `onboardingResetMinVersion`. Comparison is component-wise numeric
    /// to avoid the lexicographic "0.10.0" < "0.2.0" trap.
    nonisolated static func shouldResetOnboarding(lastOnboarded: String?) -> Bool {
        guard let lastOnboarded else { return true }
        return compareSemver(lastOnboarded, onboardingResetMinVersion) < 0
    }

    /// Component-wise numeric semver compare. Trailing pre-release tags
    /// (everything after `-`) are stripped — release builds don't ship
    /// them and the onboarding gate doesn't need their resolution.
    /// Returns negative / 0 / positive like `strcmp`.
    nonisolated static func compareSemver(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Update one provider's enabled state, honouring the "at least one
    /// must stay enabled" constraint. Returns `false` (and leaves the
    /// store untouched) when the change would empty the set so the UI
    /// can keep the toggle visibly ON without going through a no-op
    /// write that would still fire the didSet.
    @discardableResult
    func setProviderEnabled(_ provider: String, enabled: Bool) -> Bool {
        var next = enabledProviders
        if enabled {
            guard Self.knownProviders.contains(provider) else { return false }
            next.insert(provider)
        } else {
            next.remove(provider)
        }
        guard !next.isEmpty else { return false }
        guard next != enabledProviders else { return true }
        enabledProviders = next
        // Intentionally NOT trimming `menuBarIconProviders` here.
        // It stores user intent; the render path intersects with
        // `enabledProviders` at draw time. Keeping intent intact lets
        // a flipped-off-then-on tracked tool restore its menu-bar icon
        // automatically instead of silently vanishing.
        return true
    }

    /// Toggle one provider on/off in the menu-bar icon set. Empty
    /// is a valid state (the label falls back to the gauge SF Symbol).
    /// Returns false (and leaves storage untouched) only when the
    /// caller asks to enable a provider that isn't a known icon
    /// provider or isn't currently enabled in `enabledProviders`.
    @discardableResult
    func setMenuBarIconProviderEnabled(_ provider: String, enabled: Bool) -> Bool {
        var next = menuBarIconProviders
        if enabled {
            guard Self.knownIconProviders.contains(provider),
                  enabledProviders.contains(provider) else { return false }
            next.insert(provider)
        } else {
            next.remove(provider)
        }
        guard next != menuBarIconProviders else { return true }
        menuBarIconProviders = next
        return true
    }

    /// Mark the provider step of onboarding as done. Idempotent for the
    /// flag itself (the didSet won't fire if already true), but always
    /// stamps `lastOnboardedVersion` so a user who re-runs onboarding
    /// after a `onboardingResetMinVersion` bump records the new version
    /// even if the flag survived the reset gate (it shouldn't, but be
    /// safe).
    func markProviderOnboardingDone() {
        if !hasCompletedProviderOnboarding {
            hasCompletedProviderOnboarding = true
        }
        if let appVersion {
            defaults.set(appVersion, forKey: Keys.lastOnboardedVersion)
        }
    }

    /// Replace the enabled set wholesale (e.g. from the onboarding
    /// sheet). Empty input is rejected (returns false).
    @discardableResult
    func replaceEnabledProviders(_ providers: Set<String>) -> Bool {
        let cleaned = providers.intersection(Self.knownProviders)
        guard !cleaned.isEmpty else { return false }
        enabledProviders = cleaned
        return true
    }

    /// Provider IDs the app currently knows about. Match the `provider`
    /// column values in SQLite + `ProviderFilter.rawValue`.
    /// `nonisolated` so `Snapshot` (called off the main actor by the
    /// pollers) can read it without hopping back.
    nonisolated static let knownProviders: Set<String> = ["codex", "claude"]

    /// Read-only snapshot for non-MainActor callers (poller actor, etc.).
    nonisolated static func snapshot() -> Snapshot {
        snapshot(defaults: .standard)
    }

    nonisolated static func snapshot(defaults d: UserDefaults) -> Snapshot {
        let storedProviders = d.array(forKey: Keys.enabledProviders) as? [String]
        let sanitised: Set<String> = storedProviders.map {
            Set($0).intersection(knownProviders)
        } ?? []
        let providers = sanitised.isEmpty ? knownProviders : sanitised
        return Snapshot(
            pollIntervalSeconds: max(60, d.integer(forKey: Keys.pollInterval) > 0
                ? d.integer(forKey: Keys.pollInterval) : 300),
            keychainPolicy: (d.string(forKey: Keys.keychainPolicy)
                .flatMap(KeychainPolicy.init(rawValue:))) ?? .fallback,
            mirrorClaudeKeychainToFile: d.bool(forKey: Keys.mirrorClaudeKeychainToFile),
            enabledProviders: providers,
            codexFastModeBilling: d.bool(forKey: Keys.codexFastModeBilling),
            developerModeEnabled: d.bool(forKey: Keys.developerModeEnabled),
            // SettingsStore.init writes the resolved value to this key on
            // every launch (see `defaults.set(resolvedDone, …)` near the
            // tail of `init`), so a raw `bool(forKey:)` is correct here —
            // we don't need to re-run the heuristic.
            hasCompletedProviderOnboarding: d.bool(forKey: Keys.providerOnboardingDone)
        )
    }

    nonisolated static var developerModeEnabledNonisolated: Bool {
        UserDefaults.standard.bool(forKey: Keys.developerModeEnabled)
    }

    struct Snapshot: Sendable {
        let pollIntervalSeconds: Int
        let keychainPolicy: KeychainPolicy
        let mirrorClaudeKeychainToFile: Bool
        let enabledProviders: Set<String>
        let codexFastModeBilling: Bool
        let developerModeEnabled: Bool
        let hasCompletedProviderOnboarding: Bool
    }

    private enum Keys {
        static let pollInterval   = "settings.pollIntervalSeconds"
        static let keychainPolicy = "settings.keychainPolicy"
        static let mirrorClaudeKeychainToFile = "settings.mirrorClaudeKeychainToFile"
        static let showDockIconForWindows = "settings.showDockIconForWindows"
        static let menuBarHeadlineWindow = "settings.menuBarHeadlineWindow"
        static let quotaDisplayMode = "settings.quotaDisplayMode"
        static let tokenUnitLanguage = "settings.tokenUnitLanguage"
        static let codexFastModeBilling = "settings.codexFastModeBilling"
        static let developerModeEnabled = "settings.developerModeEnabled"
        // Multi-select store (current). Persisted as `[String]`.
        static let menuBarIconProviders = "settings.menuBarIconProviders"
        // Legacy single-string key (pre-multi-select). Read-only — we
        // migrate it on first launch and never write to it again.
        static let legacyMenuBarIconProvider = "settings.menuBarIconProvider"
        static let enabledProviders = "settings.enabledProviders"
        static let providerOnboardingDone = "onboarding.providersDone"
        static let lastOnboardedVersion = "onboarding.lastVersion"
    }
}
