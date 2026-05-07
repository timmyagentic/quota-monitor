# Changelog

All notable changes to QuotaMonitor (formerly CodexMonitor) are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
