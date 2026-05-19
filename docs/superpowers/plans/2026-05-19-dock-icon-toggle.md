# Dock Icon Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings → General → Appearance toggle "Show Dock icon when windows are open" (default OFF) that gates QuotaMonitor's promotion to `.regular` activation policy when a Dashboard / Settings / Onboarding window opens. With the default, the app remains a pure menu-bar agent: no Dock icon ever, no Cmd+Tab visibility.

**Architecture:** New `showDockIconForWindows: Bool` property on `SettingsStore` (default false). `AppEnvironment.activateForWindow()` and `demoteToAccessory()` each branch on that flag — when the setting is OFF, skip `NSApp.setActivationPolicy(.regular/.accessory)` and only call `NSApp.activate(ignoringOtherApps:)`. A new `applyDockIconPolicy()` method on `AppEnvironment` is invoked from the toggle's binding so a flip takes effect immediately even when a window is already open.

**Tech Stack:** SwiftUI (macOS 14), Swift 6 strict concurrency, SwiftPM, Swift Testing, AppKit (`NSApp.setActivationPolicy`).

**Spec:** `docs/superpowers/specs/2026-05-19-dock-icon-toggle-design.md`

---

### Task 1: Add `showDockIconForWindows` to `SettingsStore` with persistence tests

**Files:**
- Modify: `QuotaMonitor/Core/Settings/SettingsStore.swift`
- Create: `Tests/QuotaMonitorTests/DockIconSettingTests.swift`

TDD the new property: write the test suite first against the not-yet-existing API, run it to confirm the compile failure, then add the property + key.

- [ ] **Step 1: Write the failing test suite**

Create `Tests/QuotaMonitorTests/DockIconSettingTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test suite — expect compile failure**

Run:

```bash
swift test --filter DockIconSettingTests
```

Expected: build fails with something like `value of type 'SettingsStore' has no member 'showDockIconForWindows'` on the first `#expect` line of `defaultsToFalseOnFreshInstall`. That's the failing-test signal — the type doesn't yet expose the property.

- [ ] **Step 3: Add the new key to `SettingsStore.Keys`**

Open `QuotaMonitor/Core/Settings/SettingsStore.swift`. Find the `private enum Keys` block at the bottom of the file (around line 398). It currently looks like:

```swift
private enum Keys {
    static let codexBinary    = "settings.codexBinary"
    static let codexHome      = "settings.codexHome"
    static let claudeHome     = "settings.claudeHome"
    static let pollInterval   = "settings.pollIntervalSeconds"
    static let keychainPolicy = "settings.keychainPolicy"
    static let mirrorClaudeKeychainToFile = "settings.mirrorClaudeKeychainToFile"
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
```

Add the new key after `mirrorClaudeKeychainToFile` (keep the UI-preference cluster together):

```swift
static let mirrorClaudeKeychainToFile = "settings.mirrorClaudeKeychainToFile"
static let showDockIconForWindows = "settings.showDockIconForWindows"
static let menuBarHeadlineWindow = "settings.menuBarHeadlineWindow"
```

- [ ] **Step 4: Add the `showDockIconForWindows` stored property**

In the same file, find the `mirrorClaudeKeychainToFile` property declaration (around line 58):

```swift
var mirrorClaudeKeychainToFile: Bool {
    didSet { defaults.set(mirrorClaudeKeychainToFile,
                          forKey: Keys.mirrorClaudeKeychainToFile) }
}
```

Add the new property immediately after the closing brace of `mirrorClaudeKeychainToFile`:

```swift
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
```

- [ ] **Step 5: Initialise the property in `init`**

Find the `init` method (around line 163). The `mirrorClaudeKeychainToFile` initialisation looks like:

```swift
// Default false. We never default-on a security downgrade —
// see `mirrorClaudeKeychainToFile` doc comment.
self.mirrorClaudeKeychainToFile =
    defaults.bool(forKey: Keys.mirrorClaudeKeychainToFile)
```

Immediately after that statement, add:

```swift
// Default false. A missing key reads as false via
// `defaults.bool(forKey:)`, which is exactly the resolved
// default we want for both fresh installs and existing users
// upgrading to this release (per the user-confirmed spec).
self.showDockIconForWindows =
    defaults.bool(forKey: Keys.showDockIconForWindows)
```

- [ ] **Step 6: Run the test suite — expect pass**

Run:

```bash
swift test --filter DockIconSettingTests
```

Expected: all four tests pass.

- [ ] **Step 7: Run the full suite to make sure nothing else broke**

Run:

```bash
swift test
```

Expected: all tests pass (the existing `EnabledProvidersTests` exercises the same `init` path; making sure the new line didn't reorder anything).

- [ ] **Step 8: Commit**

```bash
git add QuotaMonitor/Core/Settings/SettingsStore.swift \
        Tests/QuotaMonitorTests/DockIconSettingTests.swift
git commit -m "$(cat <<'EOF'
Add showDockIconForWindows preference (default off)

New Bool on SettingsStore, persisted under
settings.showDockIconForWindows. Default false. Will gate the
.regular activation-policy promotion in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add three L10n keys for the Appearance section

**Files:**
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`

Pure additive change to the localization table. Three new keys: `sectionAppearance`, `showDockIconLabel`, `showDockIconHelp`. All three are EN + zh-CN.

- [ ] **Step 1: Add `sectionAppearance` near the other section headers**

Open `QuotaMonitor/Core/Localization/L10n.swift`. Find the existing `sectionLanguage` declaration (around line 467):

```swift
static var sectionLanguage: String { t(en: "Language", zh: "语言") }
```

Add `sectionAppearance` immediately above it (`Appearance` sorts before `Language` alphabetically, and the section will appear above Language in the form):

```swift
static var sectionAppearance: String { t(en: "Appearance", zh: "外观") }
static var sectionLanguage: String { t(en: "Language", zh: "语言") }
```

- [ ] **Step 2: Add the toggle label + help strings**

Find a spot in `L10n.swift` near other General-tab settings strings. The `sectionMenuBar` header (around line 104) and its associated `menuBarHeadlineWindowLabel` / `menuBarHeadlineWindowHelp` strings are a good neighbourhood. Search for `menuBarHeadlineWindowHelp`:

```bash
grep -n menuBarHeadlineWindowHelp QuotaMonitor/Core/Localization/L10n.swift
```

Right after the `menuBarHeadlineWindowHelp` declaration, add:

```swift
static var showDockIconLabel: String {
    t(en: "Show Dock icon when windows are open",
      zh: "窗口打开时显示程序坞图标")
}
/// Caption under the toggle. Spells out the Cmd+Tab side effect
/// of the default-OFF behaviour so users don't think their
/// windows are broken when they can't ⌘Tab back into them.
static var showDockIconHelp: String {
    t(en: "When off, QuotaMonitor stays in the menu bar only. The Dashboard and Settings windows will not appear in Cmd+Tab.",
      zh: "关闭后 QuotaMonitor 完全只占菜单栏，但 Cmd+Tab 将切换不到 Dashboard 与设置窗口。")
}
```

- [ ] **Step 3: Build the package to confirm the L10n table still compiles**

Run:

```bash
swift build
```

Expected: build succeeds. No new symbols are referenced yet — Tasks 5 and 6 wire them up.

- [ ] **Step 4: Commit**

```bash
git add QuotaMonitor/Core/Localization/L10n.swift
git commit -m "$(cat <<'EOF'
Add L10n keys for Appearance section + Dock-icon toggle

Three new keys: sectionAppearance, showDockIconLabel,
showDockIconHelp. EN + zh-CN. Not yet referenced from any view.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Gate `activateForWindow()` and `demoteToAccessory()` on the setting

**Files:**
- Modify: `QuotaMonitor/App/AppEnvironment.swift:399-409`

Branch both helpers on `SettingsStore.shared.showDockIconForWindows`. When the setting is OFF, skip the activation-policy switch entirely — just bring the window forward with `NSApp.activate(ignoringOtherApps:)` in `activateForWindow`, and make `demoteToAccessory` a no-op (we never promoted).

- [ ] **Step 1: Replace both helper methods**

Open `QuotaMonitor/App/AppEnvironment.swift`. Find the existing block at lines 399-409:

```swift
/// Promote the menu-bar app to a regular Dock-visible app so the
/// dashboard window can take key focus.
func activateForWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
}

/// Demote back to a menu-bar-only app once the last window closes.
func demoteToAccessory() {
    NSApp.setActivationPolicy(.accessory)
}
```

Replace with:

```swift
/// Bring a just-opened window (Dashboard / Settings / Onboarding)
/// forward over the menu-bar popover. When the user has
/// `showDockIconForWindows` ON, also promote to `.regular` so the
/// Dock icon appears and the app shows in Cmd+Tab. When OFF
/// (default), stay in `.accessory` — windows still get key focus
/// from `activate(ignoringOtherApps:)` alone.
func activateForWindow() {
    if SettingsStore.shared.showDockIconForWindows {
        NSApp.setActivationPolicy(.regular)
    }
    NSApp.activate(ignoringOtherApps: true)
}

/// Demote back to a menu-bar-only app once the last window closes.
/// No-op when `showDockIconForWindows` is OFF — we never promoted
/// past `.accessory` in the first place.
func demoteToAccessory() {
    guard SettingsStore.shared.showDockIconForWindows else { return }
    NSApp.setActivationPolicy(.accessory)
}
```

- [ ] **Step 2: Build the package**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass. No new behavioural test is added here — `NSApp.setActivationPolicy` is an AppKit side-effect we don't unit-test (per spec's Non-goals). Manual verification happens in Task 6.

- [ ] **Step 4: Commit**

```bash
git add QuotaMonitor/App/AppEnvironment.swift
git commit -m "$(cat <<'EOF'
Gate Dock-icon promotion on showDockIconForWindows

activateForWindow() now only flips to .regular when the user has
opted into the Dock icon. demoteToAccessory() becomes a no-op
when the setting is OFF. Window key focus still works via
NSApp.activate(ignoringOtherApps:) in either mode.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add `applyDockIconPolicy()` for live toggling

**Files:**
- Modify: `QuotaMonitor/App/AppEnvironment.swift`

Add a new method that the Settings toggle calls after the user flips the preference. It inspects open windows and applies the new policy immediately, so the user sees the Dock icon appear/disappear without having to close and reopen the window.

- [ ] **Step 1: Add `applyDockIconPolicy()` next to the existing window helpers**

In `QuotaMonitor/App/AppEnvironment.swift`, find the modified `demoteToAccessory()` from Task 3. Immediately after its closing brace, add:

```swift
/// Re-apply the activation policy based on the current setting.
/// Called from the Settings toggle's binding so a flip takes
/// effect without requiring the user to close and reopen a
/// window. Looks at `NSApp.windows` to decide whether any
/// app-owned window is currently on screen; if so and the
/// setting just turned ON, promotes to `.regular`; if so and
/// the setting just turned OFF, demotes to `.accessory`. If no
/// app-owned window is visible, leaves the policy alone — the
/// next `activateForWindow()` call will pick up the value.
func applyDockIconPolicy() {
    let anyWindowOpen = NSApp.windows.contains { win in
        // Skip the menu-bar popover host (NSStatusBarWindow and
        // friends are private classes; matching the class-name
        // prefix avoids depending on a specific symbol). The
        // popover is a transient panel, not the kind of window
        // we're tracking here.
        guard win.isVisible else { return false }
        let cls = NSStringFromClass(type(of: win))
        if cls.contains("StatusBar") || cls.contains("Popover") {
            return false
        }
        return true
    }
    guard anyWindowOpen else { return }
    if SettingsStore.shared.showDockIconForWindows {
        NSApp.setActivationPolicy(.regular)
    } else {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 2: Build the package**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add QuotaMonitor/App/AppEnvironment.swift
git commit -m "$(cat <<'EOF'
Add applyDockIconPolicy for live toggle of Dock visibility

New helper inspects NSApp.windows for any visible app-owned
window and flips activation policy immediately. Called from the
Settings toggle binding (next commit) so the user sees the Dock
icon appear/disappear without reopening a window.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add the Appearance section + toggle to General Settings tab

**Files:**
- Modify: `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`

Insert a new `Section(L10n.sectionAppearance)` at the top of the `Form` (before `sectionLanguage`). One `Toggle` bound to `$settings.showDockIconForWindows`, caption below from `L10n.showDockIconHelp`. The binding's setter (via Toggle's `isOn` Binding) writes through `settings.showDockIconForWindows`, then calls `env.applyDockIconPolicy()` so a live window picks up the change.

- [ ] **Step 1: Replace the `Form` opener**

Open `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`. Find the start of `body` (around line 17):

```swift
var body: some View {
    @Bindable var settings = settings
    Form {
        // Top of the General tab — language is the first thing the
        // user is likely to look for after first launch since the
        // onboarding sheet promised "you can change it later in
        // Settings". Keep it before any technical sections.
        Section(L10n.sectionLanguage) {
```

Insert a new section above `sectionLanguage`. Replace the snippet above with:

```swift
var body: some View {
    @Bindable var settings = settings
    Form {
        // Appearance section. Single knob — whether the Dock icon
        // is shown while a Dashboard / Settings / Onboarding
        // window is open. Default OFF: pure menu-bar agent. The
        // toggle's binding applies the change live via
        // `env.applyDockIconPolicy()` so users don't have to
        // close and reopen a window to see the effect.
        Section(L10n.sectionAppearance) {
            Toggle(L10n.showDockIconLabel, isOn: Binding(
                get: { settings.showDockIconForWindows },
                set: { newValue in
                    settings.showDockIconForWindows = newValue
                    env.applyDockIconPolicy()
                }
            ))
            Text(L10n.showDockIconHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Language section was originally the first thing in the
        // form (it's what the user is likely to look for after
        // the onboarding sheet promised "you can change it later
        // in Settings"). It's now second — Appearance edges it
        // out because the Dock-icon toggle is the only place
        // users can recover the "show in Cmd+Tab" behaviour, and
        // that's a high-discoverability concern.
        Section(L10n.sectionLanguage) {
```

The `Text(L10n.showDockIconHelp)` uses `.fixedSize(horizontal: false, vertical: true)` so the multi-line caption (the zh-CN version wraps onto two lines on a standard Settings window width) doesn't get truncated to one line — same pattern the existing `setupNotCompleteBody` text uses in `MenuBarContentView.swift:177-178`.

Why a manual `Binding(get:set:)` instead of `$settings.showDockIconForWindows`? The setter needs a side effect (`env.applyDockIconPolicy()`) that the `@Bindable` projection wouldn't expose. Using the explicit Binding makes the call site obvious.

- [ ] **Step 2: Build and run**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add QuotaMonitor/Features/Settings/GeneralSettingsTab.swift
git commit -m "$(cat <<'EOF'
Add Appearance → Show Dock icon toggle to General Settings

Toggle sits above Language, captioned with the Cmd+Tab side-
effect note. Binding setter calls env.applyDockIconPolicy() so
flipping while a window is open updates the Dock icon
immediately.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Manual verification

**Files:** None (smoke test against the built `.app`).

Verify the four behavioural claims from the spec's manual test plan against an actual build. No automated tests cover `NSApp.setActivationPolicy` — this is the only confirmation it works end-to-end.

- [ ] **Step 1: Build a debug `.app` and launch it**

Run:

```bash
./build.sh
open .build/QuotaMonitor.app
```

Expected: the build script completes (`✓ Built …`) and the menu-bar gauge icon appears in the system menu bar.

- [ ] **Step 2: Verify default (toggle OFF) hides the Dock icon when a window is open**

1. Click the menu-bar gauge → click "Open Dashboard".
2. Look at the Dock: **no QuotaMonitor icon should appear**.
3. Hold Cmd, tap Tab: **QuotaMonitor should not be in the application switcher**.
4. Close the Dashboard window.

- [ ] **Step 3: Verify the live ON-flip immediately shows the Dock icon**

1. Click the menu-bar gauge → click "Settings…" (the Settings window opens).
2. In Settings → General → Appearance, **toggle "Show Dock icon when windows are open" ON**.
3. **The QuotaMonitor icon should appear in the Dock immediately** (no need to reopen the Settings window).
4. Cmd+Tab → QuotaMonitor should now appear in the switcher.

- [ ] **Step 4: Verify the live OFF-flip immediately hides the Dock icon**

1. With the Settings window still open, toggle the same setting back to **OFF**.
2. **The Dock icon should disappear immediately**.
3. Cmd+Tab → QuotaMonitor should no longer be in the switcher.
4. Close the Settings window.

- [ ] **Step 5: Verify persistence across relaunch**

1. Toggle the setting back to ON, close the Settings window.
2. Quit QuotaMonitor (menu bar → Quit, or `⌘Q` from a window).
3. Relaunch: `open .build/QuotaMonitor.app`.
4. Click menu bar → Open Dashboard.
5. **The Dock icon should appear** (the ON state persisted).
6. Open Settings → General → Appearance, toggle back to OFF, quit.
7. Relaunch, open Dashboard. **No Dock icon** — the OFF state also persisted.

- [ ] **Step 6: Update CHANGELOG**

Open `CHANGELOG.md`. Under `## [Unreleased]`, add an `### Added` subsection (or extend the existing one) with:

```markdown
- **Dock icon visibility toggle.** Settings → General → Appearance
  now has a "Show Dock icon when windows are open" toggle, default
  OFF. By default QuotaMonitor stays a pure menu-bar agent — no
  Dock icon ever appears, even while the Dashboard or Settings
  window is open. The trade-off accepted in this default is that
  the app's windows do not appear in Cmd+Tab; users who want the
  classic Dock-icon-while-window-open behaviour can flip the
  toggle on and the change applies immediately.
```

- [ ] **Step 7: Commit the changelog entry**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
Note Dock-icon visibility toggle in changelog

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```
