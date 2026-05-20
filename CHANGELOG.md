# Changelog

All notable changes to QuotaMonitor (formerly CodexMonitor) are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.16] — 2026-05-20

### Added
- **Developer Mode persistent diagnostics.** Settings → Advanced now
  includes a Developer Mode toggle that writes lifecycle, refresh,
  scan, pricing, query, settings, migration, and uninstall diagnostics
  to `~/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log`.
  Records are structured JSONL with operation IDs that thread parent /
  child calls together, automatic redaction of sensitive fields, and
  size-based rotation. The file logger is off by default, creates its
  parent directory on demand, escapes multiline messages, and exposes a
  "Reveal Log File" button for support / debug sessions.
- **Quota percentage display mode.** General settings now exposes a
  "Used vs Remaining" toggle that flips every quota percentage between
  the two framings. Applies to the menu-bar icon, the popover quota
  rows, and the Dashboard forecast rows; the choice persists across
  launches.

### Changed
- **Refresh fan-out is now centralized.** Cold launch, popover-open
  auto-refresh, and the explicit Refresh button all route through the
  same `refreshAll(throttle:)` path. Cold launch performs an immediate
  full refresh + local scan and warms the Dashboard cache; popover-open
  uses throttles; the button remains explicit user intent and bypasses
  those throttles.
- **Passive refresh feedback is less misleading.** The menu-bar
  Refresh button no longer changes to "Refreshing..." or disables just
  because a background scan started from opening the popover. Scan
  status now lives in the progress row, while the refresh actions keep
  their own re-entrancy guards.
- **Claude cache-creation billing now splits 5-minute and 1-hour
  writes.** A new schema migration adds `cache_creation_5m_tokens` /
  `cache_creation_1h_tokens` columns and re-reads existing Claude
  rollouts so historical rows pick up the split. The pricing backfill
  bills 1h cache writes at 2x base input while 5m writes keep the
  catalog `cache_creation` rate; seeded Claude prices were refreshed to
  the April-2026 list rates. See `docs/billing-logic.md` for the full
  pricing pipeline.
- **L10n copy.** "Indexing local history" → "Scanning local history"
  so the wording lines up with the rest of the scan-status UI.

### Fixed
- **Menu-bar auto-refresh now fires when the popover opens.**
  `scenePhase` is app-wide and does not change just because a
  `MenuBarExtra(.window)` popover is toggled, so the previous hook
  silently missed the common open-popover path. The refresh now hangs
  off `.onAppear`, which remounts on each popover open.
- **Main-window Reload works outside Dashboard.** The toolbar Reload
  button now remounts the active tab, so History and Sessions re-run
  their own list-loading tasks instead of only refreshing the Dashboard
  snapshot.
- **Popover no longer shows a "Loading…" placeholder during the
  cold-launch scan.** Launch now hydrates `menuBarSnapshot` from the
  database before the initial scan completes, so opening the popover
  during a first-run scan immediately surfaces the previous run's data
  instead of a generic spinner. The scan-tail refresh still overwrites
  it with fresh numbers once the scan finishes.

### Internal
- **Post-refactor dead-code sweep.** Removed the unused
  `account/read` JSONRPC method and `AccountReadResult` decoder,
  six `RateLimitsPayload` fields that were decoded but never read
  (`userId`, `accountId`, `email`, `credits`, `spendControl`,
  `rateLimitReachedType`) plus their `Credits` / `SpendControl`
  helper structs, two write-only `@Observable` properties
  (`lastPricingFetchedAt`, `lastPricingUpdateCount`), and six unused
  L10n keys. Marked `isRefreshingPricing` as `@ObservationIgnored`
  since no view observes it. Net –80 lines.

## [0.2.15] — 2026-05-20

### Fixed
- **First-run setup now starts and explains the initial scan.** After
  onboarding finishes, QuotaMonitor explicitly starts a local history
  scan instead of waiting for the menu-bar popover's foreground
  refresh hook. While the scan is running, the menu-bar status now
  shows "Indexing local history" / "正在建立索引", the current file,
  processed file count, and a linear progress bar so a large first
  import no longer looks like an endless spinner.
- **Codex rollout scans skip irrelevant payload decoding.** The
  importer now reads the JSONL envelope discriminator first and only
  decodes payloads for `session_meta`, `turn_context`, and
  `event_msg(type=token_count)`. Large `response_item` lines are
  skipped without building a full `JSONValue` tree and re-encoding it,
  cutting the hot parse path on large first scans while preserving
  parsed usage/rate-limit results in regression checks.
- **Codex JSONL rate-limit samples no longer require usage info.**
  Some Codex `token_count` rows carry `rate_limits` while `info` is
  `null`. The parser now retains those primary/secondary samples and
  `plan_type` instead of dropping the whole row just because it has no
  token delta.
- **In-app uninstall now removes stale installed app copies.** The
  uninstaller no longer only moves the currently-running bundle to
  Trash. It also scans trusted install locations
  (`/Applications` and `~/Applications`) for `QuotaMonitor.app` and
  legacy `CodexMonitor.app` copies, then removes only candidates whose
  `Contents/Info.plist` bundle id matches `dev.tjzhou.QuotaMonitor` or
  `dev.tjzhou.CodexMonitor`. This fixes the reinstall flow where a user
  ran a dev/DMG copy, clicked Uninstall, and Finder still prompted to
  replace an existing `/Applications/QuotaMonitor.app`.

## [0.2.14] — 2026-05-20

### Added
- **Pricing catalog viewer in Advanced.** Settings → Advanced →
  Pricing → "View Catalog" opens a sheet with the per-model rate
  table (input / cached / output / cache-creation $/M, plus a
  LIVE / LOCAL / SEED source badge per row). The top-level Pricing
  tab was folded into Advanced back in 0.2.8 and lost the inspection
  surface; this restores it as a read-only sheet without making
  pricing a first-class concern again. Sync from LiteLLM and Restore
  Defaults still live alongside the View Catalog button on the same
  row.
- **General-tab Codex Billing section.** A "Codex Fast-Mode billing"
  toggle for users on Fast Mode — the Codex CLI doesn't tag each
  request with its billing tier, so this is a global re-price that
  also backfills history. Placed at position 2 (after Appearance,
  before Language) so it's discoverable for the audience that needs
  it without distracting users who don't.

### Changed
- **Codex Fast-Mode help copy reworded.** Drops the multiplier
  internals (2.5× / 2× per model) that users shouldn't have to know
  about and prefixes the explanation with the upstream constraint
  ("Due to Codex limitations, the CLI doesn't tag each request with
  its billing tier"). Ends with a plain rule of thumb — turn it on
  if you regularly use Fast Mode.
- **Advanced settings hide untracked-provider sections.** The Codex
  CLI and Claude Code sections in Advanced are only shown when the
  matching provider is enabled in General → Tracked tools. Showing
  knobs whose poller is already off was just dead controls; same
  filter the menu-bar block / Dashboard already apply.

### Removed
- **Codex binary / `CODEX_HOME` / Claude home path overrides.**
  Settings → Advanced no longer asks the user to type in path
  overrides for the Codex executable, the Codex sessions directory,
  or the Claude home directory. Resolving these is the app's
  problem to solve — it now autoprobes environment variables
  (`$CODEX_BINARY`, `$CODEX_HOME`) and well-known install
  locations. If a path can't be found, that's a bug we need to fix,
  not a knob to expose. The corresponding L10n strings and
  `SettingsStore.codexBinaryOverride` / `codexHomeOverride` /
  `claudeHomeOverride` properties are gone with no migration shim;
  any previously-stored values in UserDefaults are silently ignored.

### Fixed
- **Re-enabling a tracked tool restores its menu-bar icon.**
  Toggling a provider off in General → Tracked tools used to also
  drop it from the menu-bar icon set, but re-enabling the provider
  never re-seeded the icon — the slot stayed empty until the user
  manually re-checked it in the menu-bar provider picker. The icon
  set is now stored as user intent (independent of which providers
  are currently tracked); the renderer filters by enabled providers
  at draw time. The fix also catches an adjacent bug where Swift's
  `didSet` doesn't fire on the initializer's first assignment, so
  on a fresh install the initial icon-providers seed was never
  persisted to UserDefaults — the next launch re-derived from
  `enabledProviders` and the user's earlier choice didn't survive.
  Three regression tests (in-process, cross-relaunch, explicit-off
  survives) added to `EnabledProvidersTests`.

## [0.2.13] — 2026-05-19

### Added
- **Dock icon visibility toggle.** Settings → General → Appearance
  now has a "Show Dock icon when windows are open" toggle, default
  OFF. By default QuotaMonitor stays a pure menu-bar agent — no
  Dock icon ever appears, even while the Dashboard or Settings
  window is open. The trade-off accepted in this default is that
  the app's windows do not appear in Cmd+Tab; users who want the
  classic Dock-icon-while-window-open behaviour can flip the
  toggle on and the change applies immediately.

## [0.2.12] — 2026-05-19

### Fixed
- **Menu-bar label no longer collapses to the gauge icon when the
  Codex CLI can't find `node`.** On nvm-managed setups, `node` lives
  under `~/.nvm/versions/node/<version>/bin` — a path the spawned-
  child PATH builder didn't know about, so the npm-installed `codex`
  shell script (which starts with `#!/usr/bin/env node`) failed at
  shebang resolution. The poller logged `env: node: No such file or
  directory` followed by `stream ended before id=init` on every
  attempt, `latestRateLimits` stayed nil forever, and the menu-bar
  label fell back to the static gauge SF Symbol — looking like the
  live-usage display had vanished. `AppServerClient` and
  `ClaudeCLIRefreshTrigger` now each cache the user's interactive
  login-shell PATH once per process (`$SHELL -ilc 'printf %s
  "$PATH"'`) and splice it into the spawned child's environment, so
  whatever the user's dotfiles add — nvm, asdf, rbenv, manual
  prependers — comes along for the ride.
- **Cold-launch menu bar warm-starts from the database.**
  `startClaudePoller` already hydrated `latestClaudeUsage` from the
  last persisted `rate_limit_samples` row before the first live poll
  fired, but `startCodexPoller` didn't. Any cold launch where the
  first Codex poll was slow or transiently failing left the menu-bar
  label on the gauge fallback icon. A new `RateLimitsHydrator`
  mirrors the Claude side, taking the max-per-(bucket, limit_name)
  across `live` and `jsonl` source rows so the freshest stored
  snapshot is rendered immediately on launch.

## [0.2.11] — 2026-05-18

### Added
- **In-app uninstaller.** Settings → Advanced now has an "Uninstall
  QuotaMonitor…" button that wipes everything the app owns under
  `~/Library/` (Application Support, Preferences, Caches, Saved
  Application State, HTTPStorages — for both the current
  `dev.tjzhou.QuotaMonitor` bundle id and the legacy
  `dev.tjzhou.CodexMonitor` id from before the rename), moves the
  `.app` to Trash, and terminates. macOS has no first-party
  uninstaller framework — Apple's "drag to Trash" only removes the
  bundle and leaves orphan data behind, which is noticeably untidy
  for a menu-bar app that writes a SQLite database. The button is
  destructive-styled and gated behind a confirmation alert. The
  Codex CLI's `~/.codex/` and Claude Code's `~/.claude/` directories
  are deliberately not touched — they're owned by the upstream
  tools, not by QuotaMonitor.

### Fixed
- **Onboarding is now a hard gate against premature Keychain
  prompts and JSONL scans.** Before this release, on a fresh install
  the menu-bar popover could trigger a refresh (which reads the
  Claude Code Keychain credential and rescans local JSONL files)
  before the user finished the onboarding wizard's "Tracked tools"
  step. That meant the macOS Keychain ACL prompt could fire — for
  data the user hadn't yet opted in to track — and a JSONL scan
  could run against providers the user intended to disable. The
  four entry points (`startBackgroundPolling`, `refreshRateLimits`,
  `refreshClaudeUsage`, `runScan`) now short-circuit while
  `hasCompletedProviderOnboarding` is false. The menu-bar popover
  itself swaps in a lock screen with an "Open setup" button so the
  user can't accidentally click Refresh either.

## [0.2.10] — 2026-05-18

### Added
- **Menu-bar popover auto-refreshes on open.** Opening the menu-bar
  card now re-pulls Codex `/rateLimits/read`, Claude `/usage`, and
  rescans the local JSONL files automatically — you no longer have
  to click Refresh to see current numbers. Implicit triggers carry
  per-action time gates (30 s on Codex, 20 s on the file scan) so
  reopening the popover three times in five seconds doesn't spawn
  three back-to-back refreshes; the Refresh button itself stays
  un-throttled because clicking it is explicit intent.
- **Claude 5-hour window idle placeholder.** When you have 7-day
  Claude data but no 5-hour activity, the menu-bar card now shows
  an explicit "idle" row instead of dropping the line entirely.

### Changed
- **Popover-triggered refresh skips the Dashboard's heavy aggregator
  query.** `runScan()` only fires from the popover (open + Refresh
  button) and the Dashboard refreshes itself when its window opens,
  so chaining the Dashboard's aggregator off every popover refresh
  was wasted work. The popover refresh now only updates the menu-bar
  snapshot, making the Refresh button feel noticeably snappier.

### Removed
- **Quota threshold notification feature.** Settings → General →
  Notifications and the per-reset desktop alert that fired the
  first time a Codex rate-limit window crossed the threshold have
  been removed. The feature only covered Codex (Claude 5h/7d windows
  have different semantics and were never wired in), and the
  menu-bar percentage is glanceable enough on its own. The stale
  `settings.notifyThreshold` key in UserDefaults from older installs
  is left alone — it's harmless dead bytes that the app no longer
  reads.

## [0.2.9] — 2026-05-17

### Fixed
- **Claude token refresh no longer wedges on a server-revoked file
  token.** 0.2.8's file-first ordering avoided the recurring Keychain
  ACL prompt but exposed an adjacent failure: a token whose local
  `expiresAtMs` is still in the future but which Anthropic has already
  revoked (split-brain refresh from another client, manual logout on
  web, etc.) kept getting handed back from the file shortcut. Every
  poll re-sent the same dead token, `/usage` 401'd, the CLI refresh
  trigger fired but didn't always produce a fresher Keychain item
  (CLI cooldown, mdat-watch timeout) — and the next call returned
  the exact same locally-fresh file token instead of consulting the
  Keychain where the CLI may have already written a successor.
  `ClaudeUsageClient` now tracks rejected tokens in a process-scoped
  set: a credential counts as usable only when it's both locally
  not-expired AND its access token hasn't been 401'd this run. The
  401 handler inserts the just-used token; the 200 handler clears
  the set. The file shortcut still skips the Keychain when the file
  is genuinely fresh, but stops looping on a revoked token.

## [0.2.8] — 2026-05-16

### Fixed
- **macOS Keychain prompt no longer fires on every launch when the
  credentials file is already fresh.** `loadAccessToken` was reading
  both `~/.claude/.credentials.json` and the `Claude Code-credentials`
  keychain item up front before checking expiry, so the keychain ACL
  prompt could fire on every cold launch even when the file token was
  perfectly valid. The function now matches what its own doc comment
  already claimed: read the file first; only consult the keychain
  when the file is missing or stale. Combined with the existing
  `mirrorClaudeKeychainToFile` opt-in (Settings → Advanced), the
  steady-state launch flow becomes one file read with zero keychain
  access. Particularly visible during development — ad-hoc rebuilds
  generate a different code signature each time, invalidating the
  keychain ACL the user just approved.

### Changed
- **Settings → Pricing has been folded into Settings → Advanced.**
  The standalone Pricing tab's only purpose was to render a read-only
  5-column catalog table; the two interactive controls users actually
  touched (Sync from LiteLLM, Restore Defaults) plus a "last synced"
  timestamp now live as a section at the bottom of Advanced. Two
  tabs (General + Advanced) reads as "the normal stuff and the
  power-user stuff," which is the truer mental model than weighting
  pricing as a first-class concern. Users who want to inspect
  specific catalog rows can read the sqlite database directly via
  Advanced → Database → Reveal in Finder.
- **Onboarding gains a menu-bar display step** when the user picks
  both Codex and Claude Code on step 2. Users tracking both CLIs can
  now decide up front which provider's quotas appear in the menu-bar
  readout, instead of inheriting the "show both" default and having
  to flip it off in Advanced after the fact. Picking only one
  provider on step 2 still skips this step — the question is
  degenerate. Upgrading users get re-prompted once via the
  `lastOnboardedVersion` reset gate added in 0.2.7.

### Performance
- **Menu-bar refresh and dashboard now share a single BillingBlocks
  snapshot.** Both surfaces previously ran independent aggregations
  on every poll, querying the same `usage_events` rows twice. They
  now consume a shared snapshot recomputed once per poll cycle.
- **GRDB reader pool capped at 3 connections** (down from the default
  5). Five concurrent readers was over-provisioning a desktop
  menu-bar app whose hottest path has at most two simultaneous
  queries (poller + dashboard view).

### Polish
- **Menu-bar live-quota readout uses a mixed-font rhythm.** Window
  labels ("5h" / "7d") render at 9pt medium next to 11pt heavy
  monospaced-digit percentages, joined by a U+2009 thin space.
  Between the two windows " · " at 9pt regular reads as a calm
  pause; between providers a triple space separates "CX …" from
  "CC …" without adding another glyph. Replaces the previous flat
  11pt semibold row with " | " separators.

## [0.2.7] — 2026-05-14

### Fixed
- **Manual Refresh now also pulls a fresh Claude `/usage` snapshot.**
  Previously the menu-bar Refresh button only re-scanned local JSONL
  files and re-pulled Codex `/rateLimits/read`; the Claude quota rows
  were refreshed solely by the 5-minute background poller, so a user
  who clicked Refresh right after their 5h reset would still see the
  pre-reset percentages until the next poller tick. The button now
  also calls `pollOnce()` on the Claude poller alongside the Codex
  refresh.
- **Claude poller's 429 cooldown is now wall-clock based** so manual
  Refresh clicks honor it. The previous `nextDelayOverride: Duration`
  was consumed by the scheduled-loop's `currentInterval()` immediately
  after a 429 was observed, leaving no state for a manual caller to
  gate against. Wiring Refresh to `pollOnce()` naively would have let
  a click ~60s into a 5-min cooldown immediately re-fire `/usage` and
  earn another 429 — the cooldown is now a `Date` that both the
  scheduled loop and `pollOnce()` consult.

### Added
- **"Rate limited, retry in X" banner** above the Claude quota rows
  while the poller is in 429 cooldown, so spam-clicking Refresh
  doesn't look like a silent no-op. The countdown ticks once per
  second via `TimelineView` and self-hides at expiry without needing
  the actor to broadcast a "cleared" event.

### Changed
- **Upgrading users are dragged back through the provider step of
  onboarding once on first launch of this release.** `SettingsStore`
  now persists `lastOnboardedVersion` and resets the provider step
  whenever that stamp is missing or older than
  `onboardingResetMinVersion` (currently "0.2.7"). Language pick is
  preserved — only the provider screen re-prompts. Bumping the
  `onboardingResetMinVersion` constant in a future release will
  re-trigger the same one-shot prompt for whatever step needs
  re-confirmation then.

## [0.2.6] — 2026-05-14

### Performance
- **Claude rollouts now read incrementally.** `ClaudeImportEngine`
  was re-parsing every rollout from byte 0 each time mtime/size
  moved, then re-inserting every `usage_event` for the touched
  session. On heavy-Claude installs that dominated each menu-bar
  refresh cost — multi-MB JSONL files re-parsed every 5 minutes
  just to discover one new assistant turn. Schema v5 adds
  `import_state.byte_offset` and a Claude-only
  `usage_events.provider_message_id` (with a partial unique index),
  so the second pass only sees appended bytes and `INSERT OR IGNORE`
  silently deduplicates any rows re-emitted across a boundary.
  `LineReader.lastLineHadNewline` lets the parser leave a mid-write
  tail for the next pass to re-read once the writer finishes. Codex
  is unchanged — its parser's cumulative→delta math needs separate
  design work before incremental scanning there is safe.

## [0.2.5] — 2026-05-13

### Changed
- **Onboarding moved to a standalone window.** First-launch language +
  provider picks used to render as a sheet attached to the menu-bar
  popover, which made the modal feel cramped if the user opened the
  status item before finishing it. The flow now lives in a centered
  Window scene of its own.

### Performance
- **BillingBlocks no longer scans every Claude usage_event** on each
  menu-bar refresh. The 5h-window aggregator now pushes a
  `WHERE timestamp >= now - (recentDays + 1) days` filter into SQL,
  so the Swift side only sees rows it might actually use.
- **Cached process-wide ISO8601 formatters.** Constructing
  `ISO8601DateFormatter()` allocates a CFLocale + CFCalendar +
  CFDateFormatter each time. We were doing this per usage event
  during scans, per row during CSV export, and per redraw for some
  list views; everything now goes through a shared
  `ISO8601.fractional` / `.plain` singleton.
- **Dropped a duplicate `PricingService.backfillAllValues`** at the
  tail of the Codex import pass. ScanController already runs it once
  per scan after both engines finish, and now skips it entirely when
  no files changed.

## [0.2.4] — 2026-05-14

### Added
- **Per-tool tracking toggles.** Settings → General → "Tracked tools"
  lets you turn off Codex or Claude Code if you only have one of the
  CLIs installed. Disabling a provider stops its background poller,
  hides its menu-bar block, and drops it from the Dashboard's
  Forecast / Composition / statline. The first-launch onboarding
  sheet has a matching second step so new users can pick what they
  actually use; Codex defaults on, Claude Code defaults off (Claude
  triggers a one-time macOS Keychain prompt and many users won't
  have it installed).
- **Live usage in the menu-bar icon.** Settings → General → "Show in
  menu bar" replaces the static gauge symbol with one or both of:
  `5h XX% · 7d XX%` for Codex and/or Claude Code. Picking both joins
  them on a single line with `CX` / `CC` prefixes; picking neither
  falls back to the gauge symbol.
- **Opt-in Claude credentials cache.** Settings → Advanced → Claude
  Code → "Cache Claude credentials to disk" mirrors the Keychain
  entry to `~/.claude/.credentials.json` so the macOS Keychain
  password prompt stops firing on every ad-hoc-signed launch. Off
  by default — moving credentials from Keychain to a plain file is
  a security trade-off and the help text spells it out.

## [0.2.3] — 2026-05-11

### Fixed
- **Refresh / scan can no longer freeze the menu bar.** If the Codex
  `app-server` child wedged (e.g. went unresponsive mid-RPC), the
  `AppServerClient` actor would block forever on `Process.waitUntilExit()`
  and every subsequent click on Refresh would queue behind it. The actor
  now `terminate()`s the child and escalates to `SIGKILL` after 2 s
  asynchronously, so the request returns instead of stranding the actor.
- **Spinner can no longer be stuck "on" forever.** `runScan` and
  `refreshRateLimits` were only flipping their `isScanning` /
  `isRefreshingRateLimits` flags back to false when the underlying work
  returned. A hung parser, wedged actor, or stuck GRDB write meant the
  spinner stayed on and Refresh stayed disabled until the app was
  quit. Both calls are now wrapped in a hard timeout (5 min for
  `runScan`, 30 s for `refreshRateLimits`); on timeout the work task is
  cancelled (best-effort), the error is surfaced, and the UI flag is
  reset.
- **Token counts no longer drop the first sample of every session.**
  `RolloutParser.computeDelta` was treating the first `token_count`
  event as a baseline and emitting no delta, which silently undercounted
  every session by its opening turn. It now mirrors codex-pacer's
  importer: the first sample IS the delta from t=0. Same fix applies on
  context-reset (post-reset cumulative is emitted as a fresh delta
  rather than dropped).
- **Rollout parsing for very large active sessions is ~300× faster.**
  The line reader's `firstIndex(of: 0x0A)` + `removeSubrange` per-line
  pattern was O(n²) on the growing buffer. On a 469 MB active rollout,
  just reading the lines took ~3 min (2.5 MB/s) — dangerously close to
  the 5-min `runScan` timeout above. The reader now keeps a cursor into
  the buffer and scans the unread region via a raw pointer. Same file:
  0.65 s (760 MB/s) for line iteration, 3.7 s for the full
  parse-and-decode pass.

[0.2.3]: https://github.com/systemoutprintlnnnn/quota-monitor/releases/tag/v0.2.3

## [0.2.2] — 2026-05-07

### Fixed
- **Simplified-Chinese localization gaps in the menu bar.** The pace
  verdict labels next to each quota row ("On pace" / "X% in deficit ·
  Runs out in 47m" / "X% in reserve") and the inline duration units
  (`d/h/m`) had no Chinese translation — Chinese users saw English
  chrome on every quota row. Now route through `L10n` and emit
  `节奏正常 / 超出节奏 N% · 预计 X后耗尽 / 慢于节奏 N%`, with duration
  units rendered as `天/小时/分`. Pinned by 9 new tests in
  `QuotaPaceLabelTests` (both languages, both deficit branches, the
  cold-start gate).
- **Pace percent rounding.** A `1.789` ratio rendered as `78%` due to
  `Int()` truncation; now uses `.rounded()` so the displayed integer
  matches the intuitive value (`79%`).

### Changed
- **Unified zh terminology.** Four small but visible inconsistencies
  resolved: `token` → `Token` in help text and the count chip, `服务商`
  → `Provider` (kept latin to match the rest of the file), `5h 窗口`
  → `5 小时窗口`. The "节余 N%" reserve label that read as a
  savings/accounting term was reworded to `慢于节奏 N%` so it pairs
  symmetrically with `超出节奏 N%`.

[0.2.2]: https://github.com/systemoutprintlnnnn/quota-monitor/releases/tag/v0.2.2

## [0.2.1] — 2026-05-07

### Changed
- **Renamed product from CodexMonitor → QuotaMonitor** (display: "Quota Monitor").
  Bundle ID is now `dev.tjzhou.QuotaMonitor`; OSLog subsystem follows. The
  app's first launch under the new bundle id auto-migrates the legacy
  SQLite database (`~/Library/Application Support/CodexMonitor/codexmonitor.sqlite`
  → `…/QuotaMonitor/quotamonitor.sqlite`, including `-wal` / `-shm` siblings)
  and copies every key from `defaults read dev.tjzhou.CodexMonitor` into
  the new domain (idempotent, guarded). The old `/Applications/CodexMonitor.app`
  install must be removed manually — the rename leaves it intact so the
  user can roll back if the migration misbehaves.

[0.2.1]: https://github.com/systemoutprintlnnnn/quota-monitor/releases/tag/v0.2.1

## [0.2.0] — 2026-05-06

Reliability release. Fixes silent regressions caused by upstream wire-format
drift in both the Codex CLI and the Claude Code CLI, plus a long-standing
GUI-launch path bug that left spawned `codex` unable to find `node`.

### Added
- **Delegated Claude OAuth refresh to the `claude` CLI.** When the cached
  access token is expired (file + Keychain both stale) — or when the
  server returns 401 — the app now spawns `claude --version` so the CLI
  performs the OAuth refresh against
  `platform.claude.com/v1/oauth/token` and writes the rotated credentials
  back to the Keychain. We then re-read the freshest token. We never
  refresh in-app: refresh tokens **rotate** server-side, so a split-brain
  refresh between CodexMonitor and the CLI would silently revoke the
  loser's token. Single in-flight task coalesces concurrent expiry
  detections; failed attempts back off 5 min → 1 h to avoid spawn storms.
- **Multi-item Keychain disambiguation.** `Claude Code-credentials` items
  are now queried with `kSecMatchLimitAll` and sorted by
  `kSecAttrModificationDate` desc — the freshest item wins. Fixes a case
  where dev machines accumulated stale duplicate items (from prior
  in-app refresh attempts) and the keychain returned the oldest one,
  producing perma-401s.

### Fixed
- **Codex live quota stuck on "Sign in via codex CLI"** even when fully
  signed in. codex CLI ≥ 0.128 silently flipped `account/rateLimits/read`
  from snake_case (`rate_limit`, `primary_window`, `limit_window_seconds`,
  `reset_at`, `additional_rate_limits: [...]`) to camelCase (`rateLimits`,
  `primary`, `windowDurationMins`, `resetsAt`, `rateLimitsByLimitId: {...}`).
  Decoder now accepts both shapes; the duplicate `codex` entry inside
  `rateLimitsByLimitId` is dropped to avoid double-counting against the
  headline `rateLimits` group. Pinned by new fixture under
  `Tests/.../Fixtures/RateLimits/`.
- **Claude "token rejected" infinite loop** after Claude Code CLI ≥ 2.1.x.
  Newer CLI versions only update the Keychain item `Claude Code-credentials`
  on token refresh and leave `~/.claude/.credentials.json` frozen at the last
  `claude login` value. `loadAccessToken` was reading the stale file, sending
  an expired token, getting 401, then re-reading the same file on the next
  poll. `readCredentialsFile` now parses `expiresAt` (60 s skew margin) and
  returns nil if past expiry, falling through to the live Keychain copy.
  `mirrorTokenToFile` was also relaxed to overwrite a file whose `expiresAt`
  is already in the past — the previous strict no-clobber rule was locking
  the app into perma-expired tokens.
- **Spawned `codex` exiting before `initialize` responds** ("stream ended
  before id=init") on machines where `node` lives only at
  `/opt/homebrew/bin/node`. GUI launches inherit launchd's near-empty PATH,
  so the npm-installed `codex` (a JS shebang script) couldn't find its own
  interpreter. `AppServerClient.runSession` now sets
  `process.environment = augmentedEnvironment()`, prepending
  `/opt/homebrew/bin:/usr/local/bin:~/.npm-global/bin:~/.local/bin:~/.cargo/bin:~/.bun/bin`
  to PATH for any spawned subprocess.
- **Silent codex spawn failures**: stderr from the codex subprocess was
  previously never read. A `Task.detached` now drains the stderr Pipe
  line-by-line into `Log.appServer.error("stderr: …")`, so future spawn
  / shebang / auth failures show up in `log show` instead of being swallowed.
- **Claude `/api/oauth/usage` 6000 % bug** (Day-25 → Day-26 regression):
  the `utilization` field is in **percent** (60.0 = 60 %), not a 0..1 ratio.
  Decoder now uses `<= 1.5 → ratio × 100, else → as-is` heuristic for
  backward compatibility with old CodexBar 0..1 captures, pinned by
  `Tests/.../Fixtures/ClaudeUsage/live_pro_2026-04-29.json`.

### Notes
- Build pipeline / DMG layout / signing strategy unchanged from 0.1.0.

### Test coverage
- 62 tests (was 37 in 0.1.0). New suites: `RateLimitsDecoderTests`
  (camelCase wire format), `ClaudeUsageDecoderTests` (utilization
  heuristic), `BillingBlocksTests`, `PricingValueBackfillTests`,
  `SalvageBodyFromErrorMessageTests`, `ClaudeOAuthRefreshTests`
  (URL-protocol-stubbed refresh + write-back + concurrency coalescing).

[0.2.0]: https://github.com/systemoutprintlnnnn/quota-monitor/releases/tag/v0.2.0

## [0.1.0] — 2026-04-30


First public release. macOS menu-bar app for tracking Codex CLI and Claude Code
usage.

### Added
- Menu-bar popover with provider blocks for **Codex** and **Claude Code**:
  rolling 30-day API-equivalent spend, sessions / tokens summary, live quota
  rows (5h, 7d, per-model 7d for Opus/Sonnet on Pro/Max).
- **Live Codex quota** via `account/rateLimits/read` against the local
  `codex app-server` binary; auto-discovery of the `codex` executable plus
  GUI-aware login-shell fallback.
- **Live Claude quota** via Anthropic's OAuth `/api/oauth/usage` endpoint,
  with hard 2-hour background polling cadence (Anthropic edge rate-limits
  this endpoint aggressively) and an exponential 429 back-off ladder.
- **Local importer** for `~/.codex/sessions/**/*.jsonl` and Claude Code
  rollouts, with cumulative→delta token reconciliation, embedded rate-limit
  sample extraction, subagent rollups, and inferred-model fallback for
  legacy sessions without `turn_context`.
- **Pricing catalog** seeded from LiteLLM with per-row local override + sync
  button. API-equivalent value backfilled per event.
- **Dashboard window** with Forecast (5h / 7d burn-rate projection),
  Trends (configurable 7-day or 30-day window), and Composition (top
  models + provider donut over the last 30 days).
- **Sessions** drilldown with title/agent/model search, recency / value /
  tokens sort, and an event-level timeline with token-class chips.
- **History** day rollups + per-day session inspection.
- **Settings** with Language picker (English / 简体中文), Codex CLI paths,
  Claude home + Keychain policy, polling interval, notification threshold,
  pricing editor, database location reveal, and CSV export.
- **i18n**: English (default) + Simplified Chinese, runtime hot-swap
  without restart, first-launch language picker.
- **Notifications** at the configurable threshold (default 85%), deduped
  per reset cycle.
- **DMG distribution** with custom installer-window background (drag-icon
  arrow + first-launch hint). Build pipeline at `tools/release.sh`:
  `swift test` → release build → ad-hoc codesign → DMG → SHA-256 →
  mount-and-verify self-check.

### Notes
- **Ad-hoc signed**, not notarized. macOS will refuse the first launch —
  right-click → Open, or `xattr -dr com.apple.quarantine` (see README).
- **No auto-update** in this release. Users will need to download new DMGs
  manually until a future Sparkle integration.

### Test coverage
- 37 tests across `RolloutParser`, `Aggregator`, `ClaudeUsageDecoder`,
  `ClaudeUsagePoller`, and `ClaudeUsageHydrator`.

[0.1.0]: https://github.com/systemoutprintlnnnn/quota-monitor/releases/tag/v0.1.0
