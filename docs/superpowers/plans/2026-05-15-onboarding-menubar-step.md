# Onboarding Menu-Bar Step Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third onboarding step that lets users who picked both Codex and Claude choose which provider(s) appear in the menu bar.

**Architecture:** Extend the existing `Step` enum in `OnboardingView` from two to three cases. Use a session-scoped `@State` flag (`providersCommitted`) to drive the step-2 → step-3 transition without introducing a new persistence key. Defer **all** settings writes to a shared `finishOnboarding(...)` helper invoked exactly once per onboarding completion. Reuse existing `SettingsStore.setMenuBarIconProviderEnabled` and existing L10n strings — no new APIs, no new L10n keys.

**Tech Stack:** SwiftUI (macOS 14+), Swift 6 strict concurrency, Swift Testing framework, SwiftPM. Single-file view edit + a single regression-lock test in `EnabledProvidersTests.swift`.

**Spec:** `docs/superpowers/specs/2026-05-15-onboarding-menubar-step-design.md`

---

## File Structure

Files modified by this plan:

- `QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift` — extend `Step` enum, add `providersCommitted` state, refactor commit path into shared `finishOnboarding(_:_:)`, add `menuBarStep` ViewBuilder, route step-2 Continue based on pick count.
- `Tests/QuotaMonitorTests/EnabledProvidersTests.swift` — add one regression test that exercises the exact `replaceEnabledProviders` + `setMenuBarIconProviderEnabled` sequence the onboarding will call.

No new files. No L10n additions.

---

## Task 1: Add regression test for the onboarding commit sequence

The new code calls `replaceEnabledProviders` followed by a loop of `setMenuBarIconProviderEnabled` calls. This test locks down the expected end state of that exact sequence so a future refactor of either API can't silently break onboarding's contract.

**Files:**
- Modify: `Tests/QuotaMonitorTests/EnabledProvidersTests.swift`

- [ ] **Step 1: Add the test at the bottom of the `EnabledProvidersTests` suite**

Open `Tests/QuotaMonitorTests/EnabledProvidersTests.swift`. Just before the closing `}` of the `EnabledProvidersTests` struct (currently line 197, after the `replaceEnabledProvidersRejectsEmpty` test), insert:

```swift
    @Test
    func onboardingCommitSequenceProducesExpectedEndState() {
        // Locks down the call sequence OnboardingView.finishOnboarding uses:
        //   1. replaceEnabledProviders(providers)  — internally reconciles
        //      menuBarIconProviders to a subset of the new enabled set
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
            // setMenuBarIconProviderEnabled returns true for a no-op
            // "remove a provider that's already absent" — claude was
            // dropped from menuBarIconProviders by the reconcile that
            // ran inside replaceEnabledProviders.
            #expect(store.setMenuBarIconProviderEnabled("claude", enabled: false))
            #expect(store.enabledProviders == ["codex"])
            #expect(store.menuBarIconProviders == ["codex"])
        }
    }
```

- [ ] **Step 2: Run the new test to verify it passes against the unchanged SettingsStore**

Run:

```bash
swift test --filter EnabledProvidersTests/onboardingCommitSequenceProducesExpectedEndState
```

Expected: 1 test passes. If it fails, **stop** — the SettingsStore API behaves differently than the design assumed, and `finishOnboarding` will be wrong. Investigate before continuing.

- [ ] **Step 3: Run the full test target to confirm nothing else regressed**

Run:

```bash
swift test
```

Expected: all tests pass (the existing tests plus the new one).

- [ ] **Step 4: Commit**

```bash
git add Tests/QuotaMonitorTests/EnabledProvidersTests.swift
git commit -m "Regression-test the SettingsStore sequence onboarding will call"
```

---

## Task 2: Extract `finishOnboarding` helper (pure refactor)

Pull the four-call commit block out of step 2's Continue button into a private method. This is a behavior-preserving refactor: step 2's Continue still calls the same four operations with the same arguments, just routed through the helper. Sets up the seam Task 4 will reuse from step 3.

**Files:**
- Modify: `QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift:165-175`

- [ ] **Step 1: Add the `finishOnboarding` helper method**

Open `QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift`. The current step-2 Continue button body at line 165–175 looks like:

```swift
            Button {
                var picked = Set<String>()
                if pickedCodex { picked.insert("codex") }
                if pickedClaude { picked.insert("claude") }
                settings.replaceEnabledProviders(picked)
                settings.markProviderOnboardingDone()
                env.applyEnabledProviders()
                // Both `needs*` flags are now false, so closing here
                // is the legitimate path; the `onDisappear` re-opener
                // sees the cleared flags and stays silent.
                dismissWindow(id: "onboarding")
            } label: {
```

Insert the helper method after the `providerStep` body's closing `}` and before the `private enum Step { ... }` declaration at the end of the struct. (Concretely: right after the closing brace of the `providerStep` ViewBuilder block; there's currently nothing between it and the `Step` enum.)

```swift
    /// Single commit path for the whole onboarding wizard. Called once
    /// per completion — either from step 2 (if the user picked only
    /// one provider, in which case `iconProviders == providers`) or
    /// from step 3 (if they picked both and chose the menu-bar subset
    /// explicitly). Writes are ordered so the reconcile inside
    /// `replaceEnabledProviders` can't fight the explicit menu-bar
    /// toggles: enable the providers first, then drive the icon set.
    private func finishOnboarding(providers: Set<String>,
                                  iconProviders: Set<String>) {
        settings.replaceEnabledProviders(providers)
        // Explicitly sync the menu-bar subset. Without this we'd inherit
        // the SettingsStore default (a copy of enabledProviders) and
        // over-show on a "user picked both but only wants Codex on the
        // menu bar" flow.
        for id in SettingsStore.knownIconProviders {
            _ = settings.setMenuBarIconProviderEnabled(
                id, enabled: iconProviders.contains(id))
        }
        settings.markProviderOnboardingDone()
        env.applyEnabledProviders()
        // Both `needs*` flags are now false, so closing here is the
        // legitimate path; the `onDisappear` re-opener sees the
        // cleared flags and stays silent.
        dismissWindow(id: "onboarding")
    }
```

- [ ] **Step 2: Replace step 2's Continue body with a call to the helper**

In `providerStep`, replace the existing Continue button's action (lines 165–175 in the original file) so the button now reads:

```swift
            Button {
                var picked = Set<String>()
                if pickedCodex { picked.insert("codex") }
                if pickedClaude { picked.insert("claude") }
                finishOnboarding(providers: picked, iconProviders: picked)
            } label: {
                Text(L10n.onboardingContinue)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!pickedCodex && !pickedClaude)
            .padding(.horizontal, 8)
```

`iconProviders: picked` preserves today's behavior: whichever providers the user picked also show up in the menu bar. The reconcile inside `replaceEnabledProviders` would have done this implicitly before; now we do it explicitly. End state is identical.

- [ ] **Step 3: Build to verify it compiles**

Run:

```bash
swift build
```

Expected: build succeeds with no errors. Warnings are fine if pre-existing.

- [ ] **Step 4: Run the full test suite to verify no regressions**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift
git commit -m "Extract finishOnboarding helper from step 2 Continue path"
```

---

## Task 3: Add `.menuBar` step case and `providersCommitted` state

Wire up the state machine for the new step without yet building its UI or routing into it. After this task the third step is reachable in principle but renders nothing visible and step 2 still goes directly to dismiss.

**Files:**
- Modify: `QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift`

- [ ] **Step 1: Extend the `Step` enum**

Find the line:

```swift
    private enum Step { case language, providers }
```

Replace with:

```swift
    private enum Step { case language, providers, menuBar }
```

- [ ] **Step 2: Add the `providersCommitted` state property**

Find the `step` computed property (currently lines 39–41):

```swift
    private var step: Step {
        loc.needsOnboarding ? .language : .providers
    }
```

Replace with:

```swift
    /// Flips to `true` when step 2's Continue is clicked with **both**
    /// providers selected, transitioning the wizard to the menu-bar
    /// step. Session-scoped on purpose — closing and re-opening the
    /// window resets it to `false`, which is what we want (re-do step 2).
    @State private var providersCommitted = false

    private var step: Step {
        if loc.needsOnboarding { return .language }
        if !providersCommitted   { return .providers }
        return .menuBar
    }
```

- [ ] **Step 3: Add a placeholder `menuBarStep` ViewBuilder and the switch case**

In the `body` `Group`, find:

```swift
        Group {
            switch step {
            case .language: languageStep
            case .providers: providerStep
            }
        }
```

Replace with:

```swift
        Group {
            switch step {
            case .language: languageStep
            case .providers: providerStep
            case .menuBar:  menuBarStep
            }
        }
```

Add an empty `menuBarStep` ViewBuilder immediately after the `finishOnboarding` helper added in Task 2 (still above the `Step` enum). Task 4 fills it in:

```swift
    // MARK: - menu-bar step (filled in next task)

    @State private var iconCodex = true
    @State private var iconClaude = false

    @ViewBuilder
    private var menuBarStep: some View {
        EmptyView()
    }
```

- [ ] **Step 4: Build to confirm the file compiles**

Run:

```bash
swift build
```

Expected: build succeeds. The new step is unreachable because nothing sets `providersCommitted = true` yet, so user-facing behavior is unchanged.

- [ ] **Step 5: Run tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift
git commit -m "Stub menuBar step in OnboardingView state machine"
```

---

## Task 4: Build the menu-bar step UI

Fill in `menuBarStep` with the real content: header, headline, subhead, two switches, Continue button. Continue calls `finishOnboarding` with both providers selected and the user's chosen icon subset.

**Files:**
- Modify: `QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift`

- [ ] **Step 1: Replace the placeholder `menuBarStep` body with the real UI**

Locate the placeholder added in Task 3:

```swift
    // MARK: - menu-bar step (filled in next task)

    @State private var iconCodex = true
    @State private var iconClaude = false

    @ViewBuilder
    private var menuBarStep: some View {
        EmptyView()
    }
```

Replace it with:

```swift
    // MARK: - menu-bar step

    /// Local working copy for step 3 — only consumed by `finishOnboarding`
    /// on Continue. Defaults: Codex on, Claude off. The user can flip
    /// both off; an empty icon set is legal and means "show the gauge
    /// SF Symbol" (see SettingsStore.menuBarIconProviders docs).
    @State private var iconCodex = true
    @State private var iconClaude = false

    @ViewBuilder
    private var menuBarStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "menubar.dock.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text(L10n.menuBarIconProviderLabel)
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 12)

            Text(L10n.menuBarIconProviderHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                Toggle(isOn: $iconCodex) {
                    Label(L10n.codex, systemImage: "terminal")
                }
                .toggleStyle(.switch)
                Toggle(isOn: $iconClaude) {
                    Label(L10n.claudeCode, systemImage: "sparkles")
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 8)

            // Unlike step 2's Continue, this one is always enabled —
            // an empty icon set is a legal resting state (gauge-icon
            // fallback) per SettingsStore.menuBarIconProviders semantics.
            Button {
                var icons = Set<String>()
                if iconCodex  { icons.insert("codex") }
                if iconClaude { icons.insert("claude") }
                finishOnboarding(providers: ["codex", "claude"],
                                 iconProviders: icons)
            } label: {
                Text(L10n.onboardingContinue)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 8)
        }
    }
```

- [ ] **Step 2: Build**

Run:

```bash
swift build
```

Expected: build succeeds. The step is wired but still not reachable from step 2.

- [ ] **Step 3: Run tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift
git commit -m "Build the menu-bar onboarding step UI"
```

---

## Task 5: Route step 2 Continue based on pick count

Make step 2's Continue branch on whether the user picked both providers or just one. One: call `finishOnboarding` (skip step 3, as today's flow does). Both: set `providersCommitted = true` so the body re-derives `step` to `.menuBar` on the next render.

**Files:**
- Modify: `QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift`

- [ ] **Step 1: Update step 2's Continue button action to route**

In `providerStep`, locate the Continue button (the version edited in Task 2 step 2):

```swift
            Button {
                var picked = Set<String>()
                if pickedCodex { picked.insert("codex") }
                if pickedClaude { picked.insert("claude") }
                finishOnboarding(providers: picked, iconProviders: picked)
            } label: {
```

Replace just the action body so it reads:

```swift
            Button {
                var picked = Set<String>()
                if pickedCodex { picked.insert("codex") }
                if pickedClaude { picked.insert("claude") }
                // Both picked → ask which to show in the menu bar.
                // Just one → the question is degenerate (the only
                // tracked provider is the only icon-eligible one),
                // so commit immediately with iconProviders == picked.
                if picked.count == 2 {
                    providersCommitted = true
                } else {
                    finishOnboarding(providers: picked,
                                     iconProviders: picked)
                }
            } label: {
```

Leave the `label`, `.controlSize`, `.buttonStyle`, `.disabled`, and `.padding` modifiers untouched.

- [ ] **Step 2: Build**

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

- [ ] **Step 4: Manual verification — fresh-install path picks both**

Quit any running instance, then:

```bash
# Reset onboarding state so we see the wizard from step 1.
defaults delete com.tjzhou.quotamonitor app.language 2>/dev/null
defaults delete com.tjzhou.quotamonitor onboarding.providersDone 2>/dev/null
defaults delete com.tjzhou.quotamonitor onboarding.lastVersion 2>/dev/null
defaults delete com.tjzhou.quotamonitor settings.enabledProviders 2>/dev/null
defaults delete com.tjzhou.quotamonitor settings.menuBarIconProviders 2>/dev/null

swift run
```

(The bundle ID may differ — check `Info.plist` or the app's `defaults` domain if those commands no-op. If you don't know the bundle ID, run the app, complete onboarding once, and inspect `~/Library/Preferences/` for files matching the app name.)

Walk through:
1. Step 1 appears. Pick a language.
2. Step 2 appears. Turn **both** toggles on, click Continue.
3. **Step 3 should appear**: header `menubar.dock.rectangle`, headline "Show in menu bar" / "菜单栏显示", two switches (Codex on, Claude off by default), Continue button.
4. Click Continue with the defaults. Window closes. Menu bar should show **only Codex** usage.

If step 3 doesn't appear when both are picked, or the wrong provider appears in the menu bar after Continue, debug before continuing.

- [ ] **Step 5: Manual verification — single-provider path skips step 3**

Reset onboarding state as in Step 4. Re-run. This time at step 2 leave only **one** provider on (e.g. Codex on, Claude off — the default), click Continue.

Expected: window closes immediately. Step 3 does **not** appear. Menu bar shows the picked provider.

- [ ] **Step 6: Manual verification — empty icon selection on step 3**

Reset onboarding state. Re-run. At step 2 pick both. At step 3 turn **both** toggles off. Continue remains enabled. Click it.

Expected: window closes. Menu bar shows the static gauge SF Symbol (no per-provider readout).

- [ ] **Step 7: Manual verification — close on step 3 re-opens at step 2**

Reset onboarding state. Re-run. At step 2 pick both → arrive at step 3. Click the red titlebar close button instead of Continue.

Expected: window reappears immediately, but at **step 2** (not step 3), with the language already chosen. Re-pick providers and verify the full path completes.

- [ ] **Step 8: Commit**

```bash
git add QuotaMonitor/Features/Onboarding/LanguageOnboardingView.swift
git commit -m "Route step 2 Continue through new menu-bar step when both providers picked"
```

---

## Self-review

**Spec coverage check** — every spec item maps to a task:

| Spec item | Implemented in |
|---|---|
| `Step` enum extension to three cases | Task 3 step 1 |
| `providersCommitted` `@State` flag | Task 3 step 2 |
| New `step` derivation logic | Task 3 step 2 |
| Shared `finishOnboarding(providers:iconProviders:)` helper | Task 2 step 1 |
| Atomic commit (replace → loop set menu bar → mark done → apply → dismiss) | Task 2 step 1 |
| Step 2 single-provider path: immediate commit, skip step 3 | Task 5 step 1 |
| Step 2 both-providers path: set `providersCommitted = true` only | Task 5 step 1 |
| Step 3 UI with `menubar.dock.rectangle` header, `.switch` toggles, always-enabled Continue | Task 4 step 1 |
| Default `iconCodex = true`, `iconClaude = false` | Task 4 step 1 |
| Reused L10n keys (`menuBarIconProviderLabel`, `menuBarIconProviderHelp`, `onboardingContinue`) | Task 4 step 1 |
| No new persistence flag | Task 3 step 2 (`providersCommitted` is `@State`, not persisted) |
| Close-on-step-3 re-opens at step 2 | Verified in Task 5 step 7 |
| Empty icon selection is legal | Task 4 step 1 (Continue not gated), Task 5 step 6 verifies |
| Upgrade users see standard defaults (no seed from current `menuBarIconProviders`) | Task 4 step 1 (`iconCodex/iconClaude` are unconditional `@State` initial values) |
| `EnabledProvidersTests` continues to pass | Task 1 step 3, Task 2 step 4, etc. |
| Manual verification scenarios | Task 5 steps 4–7 |
