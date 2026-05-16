# Fold Pricing Tab Into Advanced — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse Settings → Pricing tab into a small "Pricing" section at the bottom of Settings → Advanced. Drop the read-only price catalog table; keep the Sync from LiteLLM + Restore Defaults buttons plus a last-synced timestamp.

**Architecture:** Pure view-layer refactor. The pricing data layer (`AppEnvironment.refreshPricingFromLiteLLM`, `restorePricingDefaults`, `loadPricingCatalog`) is untouched — the new section calls exactly the same APIs the deleted tab did. The `lastRefreshedLabel` reduces `loadPricingCatalog()` row timestamps to a `Date?`, same reduction as today.

**Tech Stack:** SwiftUI (macOS 14), Swift 6 strict concurrency, SwiftPM, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-05-15-pricing-into-advanced-design.md`

---

### Task 1: Add Pricing section to AdvancedSettingsTab

**Files:**
- Modify: `QuotaMonitor/Features/Settings/AdvancedSettingsTab.swift`

Mirror the existing `PricingSettingsTab` state shape and helper methods, drop the `Table`, keep everything else. Section sits at the bottom of `Form` after the existing Export section.

- [ ] **Step 1: Add the new `@State` properties next to the existing `exportStatus` / `exporting`**

In `AdvancedSettingsTab.swift`, find the existing state block at the top of the struct:

```swift
@Environment(SettingsStore.self) private var settings
@Environment(AppEnvironment.self) private var env
@State private var exportStatus: String?
@State private var exporting = false
```

Add the pricing state after `exporting`:

```swift
@State private var pricingRows: [PricingCatalogRow] = []
@State private var pricingLoaded = false
@State private var refreshingPricing = false
@State private var restoringPricing = false
@State private var pricingStatusMessage: String?
@State private var pricingErrorMessage: String?
```

**Why prefixed names** (`pricingRows`, `refreshingPricing`, …): the file already has `exporting` and `exportStatus`. Generic `rows` / `refreshing` / `errorMessage` would clash if the export logic ever grows similar state, and reading `refreshing` in a 170-line file with two unrelated async actions is confusing without the prefix. The old `PricingSettingsTab` could use bare names because pricing was the only concern in that file.

- [ ] **Step 2: Append the Pricing Section to the `Form` after the Export section**

The current `Form` ends with the Export section:

```swift
Section(L10n.sectionExport) {
    Button(L10n.exportUsageEventsCsv) {
        Task { await exportCSV() }
    }
    .disabled(exporting)
    if let exportStatus {
        Text(exportStatus).font(.caption).foregroundStyle(.secondary)
    }
}
```

Append directly below it, still inside the `Form` braces:

```swift
Section(L10n.settingsTabPricing) {
    Text(lastPricingRefreshedLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    HStack {
        Button(L10n.pricingFetchLiteLLM) {
            Task { await refreshPricingFromLiteLLM() }
        }
        .disabled(restoringPricing || refreshingPricing)
        if refreshingPricing { ProgressView().controlSize(.small) }
        Spacer()
        Button(L10n.pricingRestoreDefaults) {
            Task { await restorePricingDefaults() }
        }
        .disabled(restoringPricing || refreshingPricing)
    }
    if let pricingStatusMessage {
        Text(pricingStatusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    } else if let pricingErrorMessage {
        Text(pricingErrorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
    }
}
```

The two buttons mirror the old tab's button states: `disabled(restoringPricing || refreshingPricing)` on both, and the spinner sits next to Sync (not Restore — Restore is fast enough to skip the spinner, same as today). The error / status branches are mutually exclusive — each helper clears the opposite slot, so the `else if` will never accidentally double up.

- [ ] **Step 3: Add the `.task` trigger after the existing `.padding(20)`**

After `.formStyle(.grouped).padding(20)`, attach:

```swift
.task {
    if !pricingLoaded {
        pricingLoaded = true
        await reloadPricing()
    }
}
```

`pricingLoaded` is the same idempotence latch the old `PricingSettingsTab` used. Without it, switching tabs and switching back re-loads the catalog every visit, which is fine but wasteful.

- [ ] **Step 4: Add the helper methods at the bottom of the struct (after `exportCSV`)**

```swift
private var lastPricingRefreshedLabel: String {
    let latest = pricingRows.compactMap { $0.fetchedAt }.max()
    guard let latest, let date = ISO8601.parse(latest) else {
        return L10n.neverRefreshed
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = LocalizationStore.activeLanguage.locale
    formatter.unitsStyle = .short
    return L10n.lastRefreshed(formatter.localizedString(for: date, relativeTo: Date()))
}

private func reloadPricing() async {
    do {
        pricingRows = try await env.loadPricingCatalog()
    } catch {
        pricingErrorMessage = String(describing: error)
    }
}

private func restorePricingDefaults() async {
    restoringPricing = true
    defer { restoringPricing = false }
    do {
        try await env.restorePricingDefaults()
        await reloadPricing()
        pricingErrorMessage = nil
        pricingStatusMessage = L10n.restoredSeedPrices
    } catch {
        pricingErrorMessage = String(describing: error)
    }
}

private func refreshPricingFromLiteLLM() async {
    refreshingPricing = true
    defer { refreshingPricing = false }
    do {
        let updated = try await env.refreshPricingFromLiteLLM()
        await reloadPricing()
        pricingErrorMessage = nil
        pricingStatusMessage = updated == 0
            ? L10n.litellmNoMatch
            : L10n.litellmUpdated(updated)
    } catch {
        pricingErrorMessage = L10n.litellmRefreshFailed(error.localizedDescription)
    }
}
```

These are line-for-line copies of `PricingSettingsTab`'s `reload`, `restore`, `refreshFromLiteLLM`, and `lastRefreshedLabel`, with the state names prefixed. **Do not invent new behavior** — match the old tab exactly so the diff is a pure move.

`restorePricingDefaults()` shadows `env.restorePricingDefaults()` — that's intentional and matches today's `restore()` / `env.restorePricingDefaults()` pairing in `PricingSettingsTab`. The call site `env.restorePricingDefaults()` resolves through `env`, so the shadowing is unambiguous to the compiler.

- [ ] **Step 5: Update the struct doc-comment to mention the new Pricing section**

Find the existing `/// Sections:` list:

```swift
///   - Codex CLI: binary path + CODEX_HOME override
///   - Claude Code: home path override + Keychain access policy
///   - Database: location + reveal in Finder
///   - Export: usage_events.csv dump
```

Add Pricing as the last entry:

```swift
///   - Codex CLI: binary path + CODEX_HOME override
///   - Claude Code: home path override + Keychain access policy
///   - Database: location + reveal in Finder
///   - Export: usage_events.csv dump
///   - Pricing: LiteLLM sync + Restore Defaults (folded in from the
///     deleted Pricing tab — power-user controls, not a top-level tab)
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: Build succeeds. No warnings.

If the build fails: most likely a typo in a state name or a missing comma in the section. Re-read the diff and fix.

- [ ] **Step 7: Commit**

```bash
git add QuotaMonitor/Features/Settings/AdvancedSettingsTab.swift
git commit -m "Add Pricing section to AdvancedSettingsTab

Mirrors the buttons + last-synced label from PricingSettingsTab,
without the read-only price table. Old tab still exists; next
commit removes it."
```

---

### Task 2: Remove old Pricing tab

**Files:**
- Modify: `QuotaMonitor/Features/Settings/SettingsView.swift`
- Delete: `QuotaMonitor/Features/Settings/PricingSettingsTab.swift`

- [ ] **Step 1: Remove the Pricing `.tabItem` from `SettingsView`**

In `SettingsView.swift`, find the `TabView` body and delete these three lines:

```swift
            PricingSettingsTab()
                .environment(env)
                .tabItem { Label(L10n.settingsTabPricing, systemImage: "dollarsign.circle") }
```

The `TabView` should now contain exactly two `.tabItem` blocks: General and Advanced.

- [ ] **Step 2: Update the `SettingsView` file-header comment from three tabs to two**

Replace the existing top-of-file block comment:

```swift
// Top-level Settings window. Tab content lives in:
//   - GeneralSettingsTab.swift   (Language, menu bar window, polling, notify)
//   - PricingSettingsTab.swift   (LiteLLM sync + read-only catalog)
//   - AdvancedSettingsTab.swift  (paths, keychain, database, CSV export)
//
// **Why three tabs not two:** General stays short on purpose so first-
// time users don't bounce off a wall of knobs. Pricing has its own tab
// because the catalog table needs the full window width. Advanced
// collects every "I know what I'm doing" toggle in one place.
```

With:

```swift
// Top-level Settings window. Tab content lives in:
//   - GeneralSettingsTab.swift   (Language, menu bar window, polling, notify)
//   - AdvancedSettingsTab.swift  (CLI paths, keychain, database, CSV export,
//                                  pricing sync + restore)
//
// **Why two tabs:** General stays short on purpose so first-time users
// don't bounce off a wall of knobs. Advanced collects every "I know
// what I'm doing" toggle in one place — including the LiteLLM pricing
// sync, which used to live on its own tab around a read-only catalog
// table. Dropping the table left two buttons that fit naturally in
// Advanced.
```

`env` is still injected on `AdvancedSettingsTab` (line 29), so the new Pricing section's button actions have what they need.

- [ ] **Step 3: Delete `PricingSettingsTab.swift`**

```bash
git rm QuotaMonitor/Features/Settings/PricingSettingsTab.swift
```

- [ ] **Step 4: Verify nothing else references the deleted symbols**

Search the codebase for stale references:

```bash
grep -rn "PricingSettingsTab" QuotaMonitor/ Tests/ build.sh
```

Expected: no matches.

If matches exist outside the deleted file: investigate. Likely culprits are a Xcode project file (irrelevant — we're SwiftPM) or a stray `import` somewhere. Fix any references before the build step.

- [ ] **Step 5: Build + test**

```bash
swift build && swift test
```

Expected: Both pass. The existing pricing tests live at the env layer (`AppEnvironment.refreshPricingFromLiteLLM`, `loadPricingCatalog`) and are unaffected by the view change.

If `swift build` fails complaining about `PricingSettingsTab` being missing: there's a stale reference Step 4's grep missed. Search again.

If `swift test` fails: that's a regression — investigate before continuing. Pricing tests should be untouched.

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Features/Settings/SettingsView.swift
git commit -m "Remove Pricing tab, fold callers into Advanced

The new Pricing section in AdvancedSettingsTab now hosts the Sync /
Restore buttons. The read-only price catalog table is dropped —
its only purpose was inspection, which the underlying sqlite file
covers via Advanced → Database → Reveal in Finder."
```

---

### Task 3: Manual sanity check + L10n leftover decision

**Files:** none modified — verification only.

- [ ] **Step 1: Build the app bundle and launch**

```bash
./build.sh && open ./QuotaMonitor.app
```

Expected: App launches, menu bar icon appears.

- [ ] **Step 2: Open Settings → Advanced, scroll to the bottom**

Expected:
- Only two tabs in the picker: General, Advanced. No Pricing tab.
- Advanced tab shows sections in this order: Codex CLI, Claude Code, Database, Export, **Pricing**.
- Pricing section shows: last-synced caption (likely "上次同步 N 分钟前" or "Last refreshed N min ago" depending on language), Sync button on the left, Restore Defaults button on the right.

- [ ] **Step 3: Click "Sync from LiteLLM"**

Expected:
- Spinner appears next to Sync button briefly.
- Both buttons disable during the sync.
- Status line appears below ("Updated N prices" / "已更新 N 项价格") on success, or red error text on network failure.
- Last-synced caption updates to "几秒前 / a few seconds ago" after success.

- [ ] **Step 4: Click "Restore Defaults"**

Expected:
- Both buttons disable briefly.
- Status line shows "Restored seed prices" / "已恢复内置价格" on success.

- [ ] **Step 5: Check `L10n.livePricesViaLiteLLM`**

```bash
grep -rn "livePricesViaLiteLLM" QuotaMonitor/ Tests/
```

Expected: matches only inside `L10n.swift` itself (the key definition). No call sites remain.

Decision: per spec, **leave the key in place**. Not worth a separate commit to remove; if a future surface (e.g. an About panel mentioning "powered by LiteLLM") wants it, it's there.

- [ ] **Step 6: Quit the app**

No commit for this task — it's pure verification. The previous two commits already constitute the shippable change.

---

## Notes for the implementer

- **No new tests.** The spec is explicit: behavior-level pricing tests live at `AppEnvironment` and are unaffected. The view-level disappearance doesn't need new coverage.
- **No new L10n keys.** Every string the new section uses already exists. If you find yourself reaching for `t(en:…, zh:…)`, stop — check `L10n.swift` first.
- **No data-layer edits.** The three pricing APIs on `AppEnvironment` (`refreshPricingFromLiteLLM`, `restorePricingDefaults`, `loadPricingCatalog`) are called exactly as the old tab called them. Don't refactor them.
- **Watch for the `restorePricingDefaults()` name collision** between the new instance method on `AdvancedSettingsTab` and `env.restorePricingDefaults()`. Both names are intentional; Swift's name resolution makes `env.restorePricingDefaults()` unambiguous at the call site. If the build complains, you've likely shadowed it in the wrong scope.
