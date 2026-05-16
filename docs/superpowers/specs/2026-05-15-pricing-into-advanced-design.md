# Fold Pricing Tab Into Advanced

**Date:** 2026-05-15
**Status:** Approved (design)

## Goal

Collapse the Settings → Pricing tab into a small section inside
Settings → Advanced. Drop the read-only price catalog table. Keep the
two interactive buttons users actually click ("Sync from LiteLLM" and
"Restore Defaults") plus a one-line "last synced" hint.

## Why

The Pricing tab is heavy for what it gives users. ~80 lines of view
code render a 5-column read-only table (240pt min height) whose only
purpose is inspection — but the failure mode for "wrong price" is
always "everything is way off," not "this one model is off by $0.50,"
which the Sync + Restore buttons already cover. Users who genuinely
want to inspect specific models can read the sqlite database directly
from Advanced → Database → Reveal in Finder.

Three tabs also disproportionately weights pricing as a first-class
concern. Two tabs (General + Advanced) reads as "the normal stuff,
and the power-user stuff" — which is the truer mental model.

## Non-goals

- No change to the pricing data layer (`AppEnvironment.refreshPricingFromLiteLLM`,
  `restorePricingDefaults`, `loadPricingCatalog`). Only the UI is touched.
- No new L10n keys. Every string the new section needs already exists.
- No removal of the underlying `loadPricingCatalog` API — it stays on
  `AppEnvironment` and the new Advanced section still calls it to derive
  the "last synced" timestamp (same `rows.compactMap { $0.fetchedAt }.max()`
  reduction the old tab used).
- No data migration. The on-disk catalog is unchanged.
- No caption / hint text. The two buttons stand alone — confirmed by user
  during brainstorming. Power users in Advanced don't need the hand-holding.

## Affected files

- `QuotaMonitor/Features/Settings/SettingsView.swift` — remove the
  `PricingSettingsTab()` `.tabItem` and its `env` injection. Update
  the file-header comment from three tabs to two.
- `QuotaMonitor/Features/Settings/AdvancedSettingsTab.swift` — append
  a new `Section` at the bottom (after Export). Holds: a "Pricing"
  headline + last-synced subtitle, the Sync button, the Restore
  Defaults button, and a one-line status line for success/error
  messages.
- `QuotaMonitor/Features/Settings/PricingSettingsTab.swift` — **delete**.
  The catalog-loading / table-rendering / source-badge logic moves
  nowhere because we're dropping the table outright.
- `QuotaMonitor/Core/Localization/L10n.swift` — **no edits.** The
  existing keys cover everything the new section needs.

## Design

### Tab structure (after)

```swift
TabView {
    GeneralSettingsTab()      .tabItem { ... gearshape }
    AdvancedSettingsTab()     .tabItem { ... wrench }
}
```

The Advanced tab's `.environment(env)` injection becomes load-bearing
for the new pricing section's button actions; it's already there for
the existing CSV export, so no new wiring.

### New Advanced section

Sits at the bottom of Advanced, after the Export section. Pricing is
the lowest-traffic concern on the tab — most users will never touch
it — so putting it last keeps the more frequently used controls (CLI
toggles, Database, Export) above the fold.

```swift
Section(L10n.settingsTabPricing) {   // reuse the existing tab title — short and scannable
    Text(lastRefreshedLabel)         // see "Last-synced label" below
        .font(.caption)
        .foregroundStyle(.secondary)
    HStack {
        Button(L10n.pricingFetchLiteLLM) {
            Task { await refreshFromLiteLLM() }
        }
        .disabled(restoring || refreshing)
        if refreshing { ProgressView().controlSize(.small) }
        Spacer()
        Button(L10n.pricingRestoreDefaults) {
            Task { await restore() }
        }
        .disabled(restoring || refreshing)
    }
    if let statusMessage {
        Text(statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    } else if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
    }
}
```

### Last-synced label

Reuse exactly what the old tab did. On `.task` (and after every Sync /
Restore action), call `env.loadPricingCatalog()` and reduce
`rows.compactMap { $0.fetchedAt }.max()` into a `Date?`. The full row
set is small (~few dozen models) so loading the whole catalog just to
read the max timestamp is fine — that's already what the existing
Pricing tab does on every appearance.

If `nil` → render `L10n.neverRefreshed`. Otherwise render
`L10n.lastRefreshed(RelativeDateTimeFormatter().localizedString(
for: date, relativeTo: Date()))` exactly like today.

### Status / error state

- `@State private var refreshing = false` — disables both buttons,
  shows a spinner next to Sync.
- `@State private var restoring = false` — disables both buttons.
- `@State private var statusMessage: String?` — success messages
  (`litellmUpdated(n)`, `litellmNoMatch`, `restoredSeedPrices`).
- `@State private var errorMessage: String?` — `litellmRefreshFailed(err)`.

When either fires, the corresponding state is set; the other is cleared
so we never show two lines.

### Localization

All keys already exist:

- Section title: `L10n.settingsTabPricing` ("Pricing" / "计费")
- Last-synced (never): `L10n.neverRefreshed`
- Last-synced (with date): `L10n.lastRefreshed(_:)`
- Sync button: `L10n.pricingFetchLiteLLM`
- Restore button: `L10n.pricingRestoreDefaults`
- Success messages: `L10n.litellmUpdated(_:)`, `L10n.litellmNoMatch`,
  `L10n.restoredSeedPrices`
- Error message: `L10n.litellmRefreshFailed(_:)`

`L10n.livePricesViaLiteLLM` becomes unused after `PricingSettingsTab`
is deleted. Leave the key in place — removing dead L10n keys isn't
worth the noise, and it might come back if we ever surface the data
source elsewhere.

## Edge cases

| Scenario | Behavior |
|---|---|
| User on Pricing tab when this ships | Pricing tab is gone on next launch; their currently-selected tab index (`com_apple_SwiftUI_Settings_selectedTabIndex`) may point at index 2 which no longer exists. SwiftUI gracefully falls back to index 0 (General). Acceptable. |
| Last-synced query fails (e.g., row truncated) | Treat as "never refreshed." Don't surface a database error in the Advanced UI — the legitimate user action is still "click Sync." |
| Refresh fails | Same as today: `errorMessage` shows `L10n.litellmRefreshFailed(err)` for the next render until cleared. |
| Pricing data still loads correctly | Untouched. The catalog table is gone from the UI only; cost calculations elsewhere still read the same rows. |
| Test coverage | The Sync / Restore / catalog-load paths have no automated coverage — `Tests/QuotaMonitorTests/PricingValueBackfillTests.swift` covers a different code path (`PricingService.backfillAllValues`), and the three `AppEnvironment` pricing APIs are exercised only by manual QA. This refactor doesn't make that worse, but it also doesn't fix it. View-level disappearance doesn't need a new test; the buttons' env-layer wiring is unchanged from the deleted tab. |

## Resolved during brainstorming

1. **No new L10n key.** Power users in Advanced don't need a button-usage
   hint; the buttons stand alone.
2. **Section title is `L10n.settingsTabPricing`** ("Pricing" / "计费").
   Shorter / easier to scan than the live-prices phrasing.
3. **Section placement: after Export**, as the last section on the tab.
   Pricing is the lowest-traffic concern; keeping it last leaves the
   more-used controls above the fold.

## Testing

- Manual: open Settings → Advanced, scroll to the new section,
  click Sync (verify status line + last-synced timestamp updates),
  click Restore Defaults (verify status line). No automated UI test.
- Existing pricing tests at the env layer continue to pass.
- `swift build` + `swift test` for sanity.
