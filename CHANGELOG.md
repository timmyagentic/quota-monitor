# Changelog

All notable changes to QuotaMonitor (formerly CodexMonitor) are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
