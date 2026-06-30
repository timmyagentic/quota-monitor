# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

QuotaMonitor is a **macOS-only Swift 6 menu-bar app** (SwiftPM, no Xcode project) that tracks **Codex** and **Claude Code** usage: live quota meters, rolling spend, session/history drilldown, and burn-rate forecasts. It reads local CLI history (`~/.codex`, `~/.claude`) plus each vendor's live quota API. App sandbox is **off** — that local-file access is the reason. `README.md` covers user-facing behavior and provider data sources; `AGENTS.md` is the canonical contributor guide. This file is the architecture map for editing the code.

## Commands

The system Command Line Tools SwiftPM can be mismatched on newer macOS; `build.sh` and `qa/run-static.sh` source `~/.swiftly/env.sh` to prefer a Swiftly toolchain. Run `swift` commands through those scripts, or source that env first if invoking `swift` directly.

```bash
swift test --disable-keychain                 # full test suite (always pass --disable-keychain)
swift test --filter SuiteName                 # one suite/test while iterating
./qa/run-static.sh                            # THE PR gate — run before publishing any PR (see below)
./build.sh                                    # debug build → .build/QuotaMonitor.app (+ local/ad-hoc sign)
CONFIG=release ./build.sh                     # release-style build
open .build/QuotaMonitor.app                  # run it
./tools/make-dmg.sh                           # release + dist/<Brand>-<ver>.dmg
./tools/release.sh                            # full pipeline; Developer ID when configured, else ad-hoc
```

`--disable-keychain` is mandatory for `swift test` — it prevents test runs from stalling on / touching the real login keychain. `qa/run-static.sh` runs: bash QA tests (`qa/tests/common_tests.sh`), Python tool tests (`python3 -m unittest discover tools/tests`), release-note validation (`tools/validate-release-notes.py`), `git diff --check`, then `swift test --disable-keychain`. There is also `qa/run-all.sh`, which additionally drives the **GUI QA harness** — **not** the PR gate. That harness is opt-in via env vars read by `LocalQAConfiguration`/`LocalQAEnvironment` (`App/`): setting `QUOTAMONITOR_QA_MODE=1` (plus `QUOTAMONITOR_QA_HOME` / `_DEFAULTS_SUITE` / `_OUTPUT_DIR` / `_STEPS`) redirects HOME, the `UserDefaults` suite, and history roots to throwaway fixture dirs so the real app runs against fixtures instead of `~/.codex`/`~/.claude`, runs scripted `LocalQAStep`s, and writes a `LocalQAReport`. Use these same isolation hooks when a test must avoid real local data.

Tests use **Swift Testing** (`@Suite`/`@Test`, not XCTest); fixtures live in `Tests/QuotaMonitorTests/Fixtures/` and load via `Bundle.module`. Name tests by behavior.

## Architecture

Everything hangs off one hub: **`AppEnvironment.shared`** (`QuotaMonitor/App/AppEnvironment.swift`), a single `@Observable` object that owns the pollers, lazy services, and all UI-facing snapshots. `QuotaMonitorApp` (`@main`) runs `UserDefaultsMigration` then hands off to `AppDelegate.applicationDidFinishLaunching`, which starts polling and the first refresh. Feature views read state via `@Environment(AppEnvironment.self)` and call back into it (`refreshAll`, `runScan`, query facades). The controller files in `App/` (`ScanController`, `PricingController`, `QueryFacade`, `UninstallController`) are **extensions on `AppEnvironment`**, not separate objects.

Two independent data planes feed that hub:

1. **Local history → SQLite (GRDB).** `ScanController.runScan()` drives two importers under `Core/Importer/`. Codex (`ImportEngine` + `RolloutParser`) scans `~/.codex/sessions` + `archived_sessions` and **always re-parses whole files**; Claude (`ClaudeImportEngine`) scans `~/.claude/projects` and is **incremental via stored byte offsets**. Both upsert into `usage_events` / `sessions` / `rate_limit_samples`. The DB lives at `~/Library/Application Support/QuotaMonitor/quotamonitor.sqlite`; on first launch `DatabaseManager` auto-migrates the legacy `CodexMonitor/codexmonitor.sqlite` (DB + `-wal` + `-shm` moved in lockstep). Schema is an append-only GRDB migration list (`Core/Storage/Migrations.swift`).
2. **Live quota pollers** (own background tasks owned by `AppEnvironment`). Codex: `RateLimitPoller` → `AppServerClient` spawns `codex app-server` per poll and calls JSON-RPC method **`account/rateLimits/read`** (not `rateLimits/read`), ~300s cadence. Claude: `ClaudeUsagePoller` → `ClaudeUsageClient` GETs `/api/oauth/usage`, **~10-minute** cadence (`defaultInterval` = 600s) with a 429/auth-failure back-off ladder. Both persist samples into the same `rate_limit_samples` table and update observable snapshots on the main actor; `*Hydrator` types reload the latest persisted sample for instant cold-start UI.

**Analytics** (`Core/Analytics/`) is the read side: `Aggregator` is **stateless static methods** turning stored rows into DTOs (`DashboardSnapshot`, `SessionRow`, `DayDetail`, …). `QueryFacade` wraps them with the active `ProviderFilter` and logging; `AppEnvironment.refreshDashboard()` runs them in one `pool.read`. `BillingBlocks.swift` reconstructs Anthropic's 5-hour billing blocks (ported from ccusage). **Features** (`QuotaMonitor/Features/`) are pure SwiftUI render layers over those snapshots: `MenuBar`, `Dashboard`, `Sessions`, `History`, `Settings`, `Onboarding`.

## Things that will bite you

- **The menu-bar label is rendered natively** (`NSStatusItem.button.attributedTitle` in `StatusItemController`), not a hosted SwiftUI view — SwiftUI subviews break `variableLength` sizing. The four app windows are **AppKit-owned via `WindowManager`**, not SwiftUI `Window` scenes; the `Window` scene in `QuotaMonitorApp` is an inert placeholder.
- **Refresh has coalescing + throttles.** `refreshMenuBar()` reruns if a refresh is in flight; popover-open refreshes throttle (~30s rate limits / ~20s scans) while the explicit Refresh button bypasses throttle (still subject to the 429 cooldown). Don't add naive "refresh on every change" calls.
- **Pricing is recomputed, never read from the API.** Token counts → `value_usd` via `PricingService.backfillAllValues()` against `pricing_catalog`. Two traps baked into its provider-branched SQL: for **Codex**, cached tokens are *already inside* `input_tokens` so they're subtracted before pricing; **reasoning tokens are not added to output** (output already includes them — adding them double-bills). `price_source='local'` rows are user edits and are never overwritten by seed/LiteLLM refresh. Codex Fast-Mode reroutes events to synthetic `<model>-fast` catalog rows. Toggling Fast-Mode or editing a price re-runs `backfillAllValues()` over all history.
- **All date bucketing is client-side via `Calendar`/`startOfDay`**, not SQL date math — required for DST correctness. Keep new aggregations consistent with this.
- **QuotaMonitor refreshes the Claude OAuth token itself, into its own private store.** When the local token is stale, `ClaudeTokenRefresher` performs a direct OAuth refresh-token grant (the same endpoint the official `claude` CLI uses) and persists the rotated credentials to QuotaMonitor's own `ClaudeOAuthCache` — **never** back to `~/.claude/.credentials.json` or Claude Code's Keychain item, so the user's real `claude` login can't be corrupted. The old `ClaudeCLIRefreshTrigger` (spawn `claude --version`, then watch the Keychain) was removed as dead code; only `ClaudeBinaryLocator` remains, for version detection. Credentials are read file-first (`~/.claude/.credentials.json`), then keychain. Keychain reads are **non-interactive** (`/usr/bin/security`, ~2s timeout) — if macOS would need UI the source is treated as unavailable.

## Branding, versioning & distribution

- **`QuotaMonitor/Core/Branding.swift` is the single source of truth for user-facing names** (`appDisplayName`, `appCodeName`). Build scripts `grep`/`sed` these at build time and inject them into `Info.plist`, DMG filenames, and appcast titles — this is the dual-brand mechanism (one codebase ships Quota Monitor + CodexMonitor; see the `dual-brand-distribution` memory). Internal identifiers (bundle ID `dev.tjzhou.QuotaMonitor`, DB path, URL scheme) intentionally stay fixed for upgrade continuity.
- **`Resources/VERSION` is the single source of truth for the version.** Bump that one file to release. `build.sh` injects it into **both** `CFBundleShortVersionString` and `CFBundleVersion` (they must match exactly, or Sparkle's comparator shows a spurious "update available" every launch). The git SHA goes to a separate `BuildCommit` key. `Resources/Info.plist` ships obviously-wrong placeholders (`0.0.0`) so an un-injected build fails loudly.
- **`Sparkle.framework` is hand-embedded by `build.sh`** (copied from `.build/artifacts/.../Sparkle.xcframework`) — SwiftPM only links the dylib, so without this the auto-updater crashes. An rpath fixup (`install_name_tool`) runs *before* codesign for the same reason.
- **`QM_DISTRIBUTION`** (`developer-id` default | `app-store`) selects the entitlements file and strips Sparkle plist keys for App Store builds; `Core/DistributionChannel.swift` reads it back at runtime. Sparkle's Ed25519 appcast signature is independent of Apple Developer ID signing — public releases need **both**. CI signs the GitHub Release DMG and opens the appcast PR; do not rotate the Sparkle key/feed/bundle identity. CI workflows: `.github/workflows/{tests,release,verify-signing}.yml`.

## Localization

UI strings live in `Core/Localization/L10n.swift` (compile-time-checked static dispatch on `LocalizationStore.activeLanguage`, EN + zh-Hans, hot-swappable). Because `L10n.foo` is a plain static call, SwiftUI can't see it as a dependency — a view that shows translated text **must hold `@Environment(LocalizationStore.self)`** so it re-renders when the language changes.

## Contribution workflow

Changes go in via **PR only — never push to `main`** (enforced by a GitHub ruleset; see the `no-direct-push-to-main` memory). Per `AGENTS.md`: branch from latest `origin/main` in an isolated worktree on a `codex/` branch, don't edit the primary checkout or `main` directly. Non-appcast PRs must update **both** `CHANGELOG.md` and `CHANGELOG.zh-Hans.md`. Run `./qa/run-static.sh` before publishing. Keep Swift 6 strict concurrency clean, four-space indent, small domain-named types.

For runtime debugging: OSLog subsystem `dev.tjzhou.QuotaMonitor` (`log stream --predicate 'subsystem == "dev.tjzhou.QuotaMonitor"'`), or enable **Settings → Advanced → Developer Mode** for JSONL diagnostics at `~/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log`.
