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

    var codexBinaryOverride: String {
        didSet { defaults.set(codexBinaryOverride, forKey: Keys.codexBinary) }
    }
    var codexHomeOverride: String {
        didSet { defaults.set(codexHomeOverride, forKey: Keys.codexHome) }
    }
    var claudeHomeOverride: String {
        didSet { defaults.set(claudeHomeOverride, forKey: Keys.claudeHome) }
    }
    var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollInterval) }
    }
    /// Controls whether `ClaudeUsageClient` is allowed to read the
    /// `Claude Code-credentials` keychain entry. First read may prompt
    /// the user; subsequent reads are silent unless the user clicked
    /// "Deny" (which sticks for the app's bundle ID). The file source
    /// (`~/.claude/.credentials.json`) is always tried first, so most
    /// users won't notice this knob.
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
    /// Which provider's quota fills the menu-bar icon (one row per
    /// window: 5h + 7d, "X% used"). Multi-select — the user can show
    /// one provider, both side-by-side, or neither (in which case the
    /// menu-bar label falls back to the static gauge SF Symbol).
    /// Hidden when no chosen provider is currently tracked or when no
    /// usage data is yet available.
    ///
    /// Default on fresh install: same set as `enabledProviders`. On
    /// upgrades from the legacy single-string key we migrate the old
    /// choice once. Reconcile behaviour: disabling a provider drops
    /// it from this set; we do NOT reseed an empty set because empty
    /// is a valid "show the gauge icon" choice.
    ///
    /// Constraint: must be a subset of `knownIconProviders` AND
    /// `enabledProviders`. UI should call
    /// `setMenuBarIconProviderEnabled(_:enabled:)` to enforce the
    /// "must be currently enabled" rule when adding.
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
        self.codexBinaryOverride = defaults.string(forKey: Keys.codexBinary) ?? ""
        self.codexHomeOverride   = defaults.string(forKey: Keys.codexHome) ?? ""
        self.claudeHomeOverride  = defaults.string(forKey: Keys.claudeHome) ?? ""
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
        // Menu-bar icon providers (multi-select). Defaults to whatever
        // is enabled. We also migrate the legacy single-string key
        // `settings.menuBarIconProvider` (one of "codex"/"claude") so
        // upgrading users keep their previous choice. Sanitise against
        // both knownIconProviders AND the resolved enabled set so we
        // never persist a row that points at a disabled provider.
        let storedIconArr = defaults.array(forKey: Keys.menuBarIconProviders) as? [String]
        let sanitisedIcons: Set<String> = storedIconArr.map {
            Set($0).intersection(Self.knownIconProviders).intersection(resolvedEnabled)
        } ?? []
        if !sanitisedIcons.isEmpty {
            self.menuBarIconProviders = sanitisedIcons
        } else if let legacy = defaults.string(forKey: Keys.legacyMenuBarIconProvider),
                  Self.knownIconProviders.contains(legacy),
                  resolvedEnabled.contains(legacy) {
            self.menuBarIconProviders = [legacy]
        } else {
            // Fresh install (or legacy value pointed at a now-disabled
            // provider). Show every enabled provider — that's the
            // least-surprising default and matches what the user just
            // saw in onboarding.
            self.menuBarIconProviders = resolvedEnabled
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
        reconcileMenuBarIconProviders()
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
        reconcileMenuBarIconProviders()
        return true
    }

    /// Drop any icon-provider entries that aren't currently enabled.
    /// Empty is a valid resting state (the menu-bar label falls back
    /// to the gauge SF Symbol) so we do NOT reseed when the
    /// intersection clears out — that would override the user's
    /// explicit "show neither" choice next time they toggle providers.
    private func reconcileMenuBarIconProviders() {
        let next = menuBarIconProviders.intersection(enabledProviders)
        if next != menuBarIconProviders {
            menuBarIconProviders = next
        }
    }

    /// Provider IDs the app currently knows about. Match the `provider`
    /// column values in SQLite + `ProviderFilter.rawValue`.
    /// `nonisolated` so `Snapshot` (called off the main actor by the
    /// pollers) can read it without hopping back.
    nonisolated static let knownProviders: Set<String> = ["codex", "claude"]

    /// Read-only snapshot for non-MainActor callers (poller actor, etc.).
    nonisolated static func snapshot() -> Snapshot {
        let d = UserDefaults.standard
        let storedProviders = d.array(forKey: Keys.enabledProviders) as? [String]
        let sanitised: Set<String> = storedProviders.map {
            Set($0).intersection(knownProviders)
        } ?? []
        let providers = sanitised.isEmpty ? knownProviders : sanitised
        return Snapshot(
            codexBinaryOverride: d.string(forKey: Keys.codexBinary) ?? "",
            codexHomeOverride: d.string(forKey: Keys.codexHome) ?? "",
            claudeHomeOverride: d.string(forKey: Keys.claudeHome) ?? "",
            pollIntervalSeconds: max(60, d.integer(forKey: Keys.pollInterval) > 0
                ? d.integer(forKey: Keys.pollInterval) : 300),
            keychainPolicy: (d.string(forKey: Keys.keychainPolicy)
                .flatMap(KeychainPolicy.init(rawValue:))) ?? .fallback,
            mirrorClaudeKeychainToFile: d.bool(forKey: Keys.mirrorClaudeKeychainToFile),
            enabledProviders: providers,
            // SettingsStore.init writes the resolved value to this key on
            // every launch (see `defaults.set(resolvedDone, …)` near the
            // tail of `init`), so a raw `bool(forKey:)` is correct here —
            // we don't need to re-run the heuristic.
            hasCompletedProviderOnboarding: d.bool(forKey: Keys.providerOnboardingDone)
        )
    }

    struct Snapshot: Sendable {
        let codexBinaryOverride: String
        let codexHomeOverride: String
        let claudeHomeOverride: String
        let pollIntervalSeconds: Int
        let keychainPolicy: KeychainPolicy
        let mirrorClaudeKeychainToFile: Bool
        let enabledProviders: Set<String>
        let hasCompletedProviderOnboarding: Bool
    }

    private enum Keys {
        static let codexBinary    = "settings.codexBinary"
        static let codexHome      = "settings.codexHome"
        static let claudeHome     = "settings.claudeHome"
        static let pollInterval   = "settings.pollIntervalSeconds"
        static let keychainPolicy = "settings.keychainPolicy"
        static let mirrorClaudeKeychainToFile = "settings.mirrorClaudeKeychainToFile"
        static let showDockIconForWindows = "settings.showDockIconForWindows"
        static let menuBarHeadlineWindow = "settings.menuBarHeadlineWindow"
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
