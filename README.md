# QuotaMonitor

> **Renamed from CodexMonitor → QuotaMonitor on 2026-05-07.** Bundle ID is now
> `dev.tjzhou.QuotaMonitor`; first launch under the new binary auto-migrates
> the legacy SQLite database and UserDefaults. The old
> `/Applications/CodexMonitor.app` can be removed manually.

A macOS-only Swift menu-bar app for tracking **Codex CLI** and **Claude Code**
usage — live quota meters, rolling spend, session-level drilldown, and
forecast/burn-rate projections, all sourced from local rollouts plus the
respective official APIs.

> Heritage: started as a Swift rewrite of [codex-pacer](https://github.com/RyanZhangNTU/codex-pacer);
> Claude Code support, the dashboard redesign, the burn-rate forecast, and
> the i18n surface are new.

## Install

1. Download the latest `QuotaMonitor-<version>.dmg` from the
   **Releases page** (link will be updated after the first GitHub release is
   tagged).
2. Open the DMG, drag **QuotaMonitor.app** onto the **Applications** alias
   shown in the installer window.
3. **First launch only** — macOS will refuse to open the app directly. Pick
   one:
   - **Right-click** `QuotaMonitor.app` → **Open** → click **Open** again in
     the Gatekeeper dialog. (You only need to do this once.)
   - Or, in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/QuotaMonitor.app
     open /Applications/QuotaMonitor.app
     ```

> QuotaMonitor is **ad-hoc signed** (no Apple Developer ID), so macOS asks
> for confirmation the first time. Subsequent launches are silent.

Optional integrity check after download:

```bash
cd ~/Downloads
shasum -c QuotaMonitor-<version>.dmg.sha256
```

## What it does

- **Menu bar popover** — one column per provider (Codex / Claude), each with
  a rolling 30-day API-equivalent spend, sessions / tokens summary, and live
  quota rows (5h, 7d, per-model 7d for Opus / Sonnet on Pro/Max plans).
- **Dashboard** — Forecast (5h / 7d burn rate + projected exhaustion),
  Trends (7d or 30d window with prior-period delta), and Composition
  (top models + provider donut over the last 30 days).
- **Sessions** — searchable list with sort by recency / value / tokens,
  drilldown to event-level token breakdown.
- **History** — per-day rollups + per-session inspection on each day.
- **Settings** — two tabs:
  - **General** — language, Dock-icon visibility, Codex Fast-Mode billing,
    menu-bar display window, tracked tools toggle.
  - **Advanced** — Codex poll interval, Claude Keychain policy + optional
    credentials mirror, database location, CSV export, pricing catalog
    (Sync from LiteLLM / Restore Defaults / View Catalog), in-app
    uninstaller.

Languages: English (default) and 简体中文, hot-swappable.

See `CHANGELOG.md` for the v0.1.0 feature list, `docs/parity.md` for the
detailed comparison with codex-pacer, and `docs/findings.md` for the
Codex CLI / Anthropic API quirks discovered along the way.

## Tech stack

| Concern | Choice |
| --- | --- |
| Language | Swift 6 (strict concurrency) |
| Min OS | macOS 14 (Sonoma) |
| UI | SwiftUI + `MenuBarExtra(.window)` + `Window` + `Settings` scenes |
| Charts | Swift Charts (no third-party) |
| SQLite | GRDB.swift |
| Subprocess | `Foundation.Process` + `Pipe` |
| Logging | OSLog (subsystem `dev.tjzhou.QuotaMonitor`) |
| Sandbox | **off** — required for `~/.codex` and `~/.claude` access |
| Distribution | ad-hoc signed `.app`, packaged into DMG (no notarization yet) |

## Build & run (developers)

No Xcode project needed.

```bash
./build.sh                  # debug build, assembles .build/QuotaMonitor.app + ad-hoc sign
open .build/QuotaMonitor.app

CONFIG=release ./build.sh   # release build

./tools/make-dmg.sh         # release + dist/QuotaMonitor-<ver>.dmg with installer-window layout
./tools/release.sh          # full pipeline: tests + release + DMG + sha256 + self-check
```

Version is sourced from `Resources/VERSION` — bump that single file to
release a new version; both `Info.plist` (via PlistBuddy injection at
build time) and the DMG filename pick it up automatically.

After launch the menu bar shows a live `5h XX% · 7d XX%` readout (or the
gauge icon fallback if no data is available yet). Click it → "Refresh" to
pull live Codex rate limits **and** rescan local jsonl in one go,
"Open Dashboard" (⌘D) for the main window, "Settings…" (⌘,) for the
General / Advanced preferences.

## Layout

```
QuotaMonitor/
├── App/
│   ├── QuotaMonitorApp.swift       // @main + scenes
│   ├── AppEnvironment.swift        // @Observable shared state + lifecycle
│   ├── PricingController.swift     // LiteLLM refresh + per-row edits
│   ├── ScanController.swift        // file scan + CSV export
│   └── QueryFacade.swift           // sessions / history / day queries
├── Core/
│   ├── AppServer/                  // codex app-server JSON-RPC client
│   ├── Analytics/
│   │   ├── Aggregator.swift        // DTO types + ProviderFilter / SessionSort
│   │   ├── AggregatorReports.swift // dashboard / overview / shares
│   │   ├── AggregatorSessions.swift
│   │   ├── AggregatorHistory.swift
│   │   ├── AggregatorRateLimits.swift
│   │   └── BillingBlocks.swift     // 5h block algorithm (ported from ccusage)
│   ├── Claude/                     // OAuth client + poller + decoder + hydrator + CLI refresh trigger
│   ├── Importer/                   // jsonl scan + parse + persist
│   ├── Storage/                    // GRDB schema + DatabaseManager (auto-migrates legacy CodexMonitor DB)
│   ├── Pricing/                    // seed catalog + LiteLLM source + value backfill
│   ├── RateLimits/                 // background poller + UN notifier
│   ├── Settings/                   // SettingsStore + UserDefaultsMigration
│   ├── Localization/               // L10n.swift + LocalizationStore
│   ├── Models/                     // domain types
│   └── Log.swift                   // OSLog categories
├── Features/
│   ├── Dashboard/                  // Forecast + Trends + Composition
│   ├── Sessions/                   // master/detail with timeline
│   ├── History/                    // day rollups + per-day events
│   ├── MainWindow/                 // tab container
│   ├── Onboarding/                 // first-launch language picker
│   ├── Settings/                   // General + Advanced tabs + PricingCatalogSheet
│   └── MenuBar/                    // popover + provider blocks + atoms
├── Resources/
│   ├── Info.plist                  // LSUIElement, bundle id (version injected at build)
│   ├── VERSION                     // single source of truth for the release
│   ├── AppIcon.icns
│   ├── dmg-background.png          // installer window background
│   └── QuotaMonitor.entitlements
└── tools/
    ├── release.sh                  // one-command release pipeline
    ├── make-dmg.sh                 // staged UDRW → AppleScript layout → UDZO
    ├── make-dmg-bg.swift           // regenerate the installer-window PNG
    ├── make-icon.sh                // app icon generator
    └── notarize.sh                 // unused — kept for future Developer ID flow
```

## Reference projects

Reference code lives in the workspace's `../references/` folder (see
`../references/README.md`). Two projects in particular informed this rewrite:

### `../references/codex-pacer/` — the original Tauri/Rust + React app

Kept for reference. Useful files when porting:

- `src-tauri/src/database.rs` — SQLite schema (mirrored in `Core/Storage/Migrations.swift`)
- `src-tauri/src/importer.rs` — jsonl → events parser (~1500 LOC of reverse-engineered taxonomy)
- `src-tauri/src/pricing.rs` — token pricing seed
- `src-tauri/src/rate_limits.rs` — **outdated** RPC names; see `docs/findings.md`

### `../references/ccusage/` — third-party Claude/Codex usage analyzer

Source of the 5-hour billing-block algorithm (`Core/Analytics/BillingBlocks.swift`,
ported from `apps/ccusage/src/_session-blocks.ts`) and the litellm-based pricing
catalog idea.

## Known CLI quirks

See `docs/findings.md`. Most important:

- Current Codex CLI requires `account/rateLimits/read`, not `rateLimits/read`.
- For accounts on `plan_type: "prolite"`, the CLI returns an error with the
  intact JSON body embedded after `body=`. `AppServerClient.readRateLimits()`
  salvages this transparently.
- Anthropic's `/api/oauth/usage` is edge-rate-limited; QuotaMonitor polls it
  on a hard 2-hour cadence with a 429 back-off ladder.
- Claude OAuth tokens rotate on every refresh. QuotaMonitor never refreshes
  them itself — when the local token is stale it spawns `claude --version`
  and lets the CLI write the new credentials to its Keychain item. See
  `docs/progress.md` Day-26 for the postmortem.

## Inspecting logs

```bash
log stream --predicate 'subsystem == "dev.tjzhou.QuotaMonitor"' --level info
```

Categories: `appserver`, `importer`, `poller`, `pricing`, `storage`, `ui`.

## Limitations of v0.1.0

- **Not notarized.** Distribute only to people willing to trust an ad-hoc
  signature (the Install section above explains the one-time bypass).
- **No auto-update.** New releases require downloading the DMG again.
- **macOS 14+ only.** No Linux / Windows / older macOS support planned.

## License

[MIT](LICENSE) © 2026 tjzhou.
