# QuotaMonitor Probe Findings

This document started as a Codex CLI v0.115 probe and now also records the
small local integration facts that keep live quota polling working across
desktop-app-only installs.

Original Codex capture: `codex app-server` on macOS 15.5 / arm64, CLI version
`0.115.0`, user plan type `prolite` (upstream) / `plus` (per `account/read`).

## Methods that work

### `initialize`
Request:
```json
{"jsonrpc":"2.0","id":"init","method":"initialize",
 "params":{"clientInfo":{"name":"probe","version":"0"},
           "protocolVersion":"0.1.0","capabilities":{}}}
```
Response:
```json
{"id":"init","result":{
  "userAgent":"probe/0.115.0 (Mac OS 15.5.0; arm64) iTerm.app/3.6.10 (probe; 0)",
  "platformFamily":"unix","platformOs":"macos"}}
```
Required before any other call.

### `account/read`
Returns:
```json
{"id":"acc","result":{"account":{"type":"chatgpt","email":"...","planType":"plus"},
                       "requiresOpenaiAuth":true}}
```

## Method with a known bug on this CLI

### `account/rateLimits/read`
Upstream call to `https://chatgpt.com/backend-api/wham/usage` SUCCEEDS, but the CLI's
strict deserializer rejects `plan_type: "prolite"`. The complete usage JSON appears
in the error message (after `body=`).

Real response body extracted from the error:
```json
{
  "user_id": "...",
  "account_id": "...",
  "email": "...",
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 7,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 331,
      "reset_at": 1777284167
    },
    "secondary_window": {
      "used_percent": 75,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 155153,
      "reset_at": 1777438990
    }
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "metered_feature": "codex_bengalfox",
      "rate_limit": { "allowed": true, "limit_reached": false,
                      "primary_window": {...}, "secondary_window": {...} }
    }
  ],
  "credits": { "has_credits": false, "unlimited": false,
               "overage_limit_reached": false, "balance": "0",
               "approx_local_messages": [0,0], "approx_cloud_messages": [0,0] },
  "spend_control": { "reached": false },
  "rate_limit_reached_type": null,
  "promo": null,
  "referral_beacon": null
}
```

**Implications for our client:**
1. Treat `plan_type` as a free-form `String`, never enumerate.
2. When `account/rateLimits/read` returns `error`, attempt to extract the `body=`
   suffix from `error.message` and decode it as the same shape we'd accept from
   `result`.
3. Two windows we care about: `primary_window` (5h, 18000s) and
   `secondary_window` (7d, 604800s).

## Difference from original codex-pacer

The original Rust code in `src-tauri/src/rate_limits.rs` calls `rateLimits/read`.
That method **does not exist** in CLI 0.115. The current method is
`account/rateLimits/read`. The original also expected a different response shape
(camelCase `usedPercent`, `windowDurationMins`); the live shape is snake_case.

## 2026-05-23 desktop app-only probes

### Codex.app bundles a working app-server binary

On this machine, `/Applications/Codex.app/Contents/Resources/codex` reports
`codex-cli 0.133.0-alpha.1` and successfully serves `codex app-server` over
stdio. A direct `account/rateLimits/read` probe returned the current
camelCase result shape:

```json
{
  "rateLimits": { "planType": "pro", "primary": { "usedPercent": 16 },
                  "secondary": { "usedPercent": 52 } },
  "rateLimitsByLimitId": { "...": "..." }
}
```

Implication: QuotaMonitor should not require a separate `codex` package-manager
install when the user already has the first-party desktop app. The resolver now
checks:

1. `CODEX_BINARY`
2. first-party unified ChatGPT desktop bundles
3. the first executable `codex` in the captured login-shell `PATH`
4. common user install dirs (`~/.npm-global`, `~/.local`, `~/.cargo`, `~/.bun`)
5. legacy Codex desktop bundles
6. Homebrew / `/usr/local` fallbacks

The ordering matters because an executable Homebrew shim can still be broken if
its vendored package was removed.

### Claude Desktop may bundle Claude Code, but Desktop auth is separate

Claude Desktop stores its own UI auth in
`~/Library/Application Support/Claude/config.json` under `oauth:tokenCache`.
That value is Electron safeStorage-encrypted and backed by the `"Claude Safe
Storage"` Keychain item. QuotaMonitor does **not** decrypt or reuse this cache.

Claude Desktop can also download a native Claude Code helper under:

```text
~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude
```

On this machine the newest helper is `2.1.149 (Claude Code)` and `claude auth
status` reports a first-party Claude Code login. QuotaMonitor may use this
helper for delegated OAuth refresh when no standalone `claude` binary is on
PATH, but live Claude quotas still depend on Claude Code credentials
(`~/.claude/.credentials.json` or `Claude Code-credentials`). A pure Claude
Desktop web-session login is not enough.

### Keychain reads must not block the poller

Direct `SecItemCopyMatching` data reads for `Claude Code-credentials` can hang a
background poller if macOS wants interaction. The production path now shells
through `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`
with a short timeout and treats "interaction required" as unavailable. The older
Security.framework helper remains only as a testable query-construction path.

## 2026-07-19 unified ChatGPT app probe

The first-party desktop merge moved the bundled Codex binary to
`/Applications/ChatGPT.app/Contents/Resources/codex`. The local bundle reports
`codex-cli 0.145.0-alpha.18`; direct `app-server` initialization and
`account/rateLimits/read` both succeeded with the existing decoder. The current
provider response was weekly-only, so omitting a 5-hour row is valid behavior.

QuotaMonitor now checks both user-level and system-level `ChatGPT.app` bundles,
prefers them over the corresponding legacy `Codex.app` fallback, and resolves a
desktop bundle before starting a login shell. App-bundled native binaries also
skip login-shell PATH augmentation at launch. Standalone CLI installs retain a
two-second shell execution deadline plus bounded process-tree cleanup, so an
inaccessible mount or slow shell plugin cannot block quota polling indefinitely.

## Rollout JSONL shape

Each line is independently parseable JSON:
```json
{"timestamp": "<ISO8601>", "type": "<discriminator>", "payload": { ... }}
```

Confirmed `type` values so far:
- `session_meta` — `payload` includes `id`, `timestamp`, `cwd`, `originator`,
  `cli_version`, `instructions`, `source`, `model_provider`, `git`.
- `response_item` — `payload.type` is one of `message`, `function_call`,
  `function_call_output`, etc., with role/content arrays.

Token-usage events arrive as their own discriminator: `event_msg` outer
records whose inner `payload.type` is `token_count`. The parser at
`Core/Importer/RolloutEvent.swift:210` extracts the cumulative usage block
from `payload.info.total_token_usage` and lets `Importer` reconcile it into
deltas (with reset detection when totals decrease).

## Other available app-server methods (from rejection error list)

Worth investigating later:
- `thread/list`, `thread/read`, `thread/loaded/list` — server-side session index
- `model/list` — official model catalog
- `getAuthStatus`, `getConversationSummary`
- `config/read` — possibly replaces our `~/.codex/config.toml` parsing

## Risk register (next-likely-to-break code paths)

A short list of places where a silent regression would be hardest to
notice — kept here so the next agent / future me knows where to look
first when "the menu bar number is wrong."

### 1. `ClaudeUsageDecoder` — Anthropic /api/oauth/usage shape drift
- **Why risky**: Anthropic ships A/B-test keys (`iguana_necktie`,
  `omelette_promotional`, …) and silently flipped utilization from
  0..1 ratio to 0..100 percent once already (Day 25 → Day 26 6000% bug).
- **Coverage today**: 11 tests in `ClaudeUsageDecoderTests` pinned
  against real captured fixtures (`Tests/.../Fixtures/ClaudeUsage/*.json`).
- **What to do if it drifts again**: capture the new response into
  `Fixtures/ClaudeUsage/`, add a fixture-driven test, **do not** widen
  the `<=1.5 → ratio*100, else → as-is` heuristic blindly.

### 2. `ClaudeUsagePoller` — 2-hour cadence + 429 backoff ladder
- **Why risky**: Anthropic edge rate-limits the `/usage` endpoint
  aggressively. Wiring `pollOnce()` to too many UI sites will silently be
  throttled by `minimumGap = 60s`, or earn HTTP 429s that compound the
  back-off.
- **Coverage today**: 12 state-machine tests in `ClaudeUsagePollerTests`.
- **Don't**: don't shorten `minimumGap`, don't share the Codex poll
  interval setting, don't add extra trigger sites.

### 3. `BillingBlocks` — 5-hour billing-block math (ported from ccusage)
- **Why risky**: full of edge cases (gap > 5h splits, hour-flooring of
  block start in UTC, active-vs-closed determination at "now"). A bug
  here directly mislabels "Pace ~$X.XX/hr" + "Active 5h block."
- **Coverage today**: 6 DB-driven tests in `BillingBlocksTests`
  (added 2026-04-30; was 0 prior).
- **Watch**: any change to `identifyBlocks` or `floorToHour`.

### 4. `AppServerClient.salvageBodyFromErrorMessage` — `prolite` plan-type salvage
- **Why risky**: when `plan_type: "prolite"`, the CLI's deserializer
  rejects the response but embeds the intact JSON body after `body=`
  in the error. Without the brace-balance walker, prolite users see
  "no quota data" forever.
- **Coverage today**: 6 tests in `SalvageBodyFromErrorMessageTests`
  (added 2026-04-30).
- **Watch**: changes to the CLI error format. If the marker shifts
  from `body=` to something else, the tests + this code both die
  silently — regression must be caught by an end-to-end integration
  test someday, not just the unit tests.

### 4b. Binary resolution for GUI-launched apps and app-only installs
- **Why risky**: launchd gives GUI apps a minimal PATH, package-manager shims
  can be stale, and first-party desktop apps may bundle the only working
  binary. Picking the wrong executable makes the menu bar look frozen even
  though the user's terminal works.
- **Coverage today**: 16 tests in `AppServerClientResolverTests`, plus separate
  Claude binary-locator coverage and real-machine smoke probes against the
  unified `/Applications/ChatGPT.app/Contents/Resources/codex`, legacy
  `Codex.app`, and Claude Desktop bundled Claude Code helper paths.
- **Watch**: any new binary candidate must preserve the preference order:
  explicit override, unified ChatGPT bundle, login shell, user-local installs,
  legacy Codex bundle, then package-manager fallbacks.

### 5. `PricingService.backfillAllValues` — single SQL UPDATE that prices everything
- **Why risky**: a typo in the JOIN, a wrong column name, or an `OR`
  that misses a row would silently corrupt every dollar amount in the
  menu bar.
- **Coverage today**: 5 tests in `PricingValueBackfillTests` (added
  2026-04-30) pin: codex formula subtracts cached from input, claude
  formula is additive across input/cached/cache_creation, unknown
  model_id leaves rows alone, idempotent on re-run, price edit
  reprices only matching rows.
- **Watch**: any new token category (e.g. a future `vision_tokens`
  column) needs to be added to the SQL **and** a test.

### 6. `RolloutParser` token reconciliation
- **Why risky**: the cumulative→delta logic with reset detection is
  load-bearing for every Codex import. If we miss a reset we double-
  count tokens; if we false-positive a reset we lose them.
- **Coverage today**: handful of tests in `RolloutParserTests` plus
  `Aggregator` integration.
- **Watch**: changes to Codex CLI's `total_token_usage` schema —
  CLI 0.40 already truncated headers in older rollouts (see
  `scanErrorsExplain` in L10n.swift).

### 7. `LocalizationStore` runtime locale switch + `RelativeDateTimeFormatter`
- **Why risky**: `RelativeDateTimeFormatter()` defaults to the process's
  initial locale, NOT the runtime-switched one. Every site that
  creates one must do `f.locale = LocalizationStore.activeLanguage.locale`.
  3 such sites today (MenuBar QuotaRow, Sessions, Settings Pricing).
- **Coverage today**: none — these are UI-side and hard to unit-test.
- **Watch**: any new "X minutes ago" / "Y days from now" display.

### 8. Build pipeline version drift
- **Why risky**: `Resources/VERSION` is the single source of truth.
  `Info.plist` ships placeholder `0.0.0` so an un-injected build is
  obviously wrong, and `release.sh` cross-checks the injected version
  against `VERSION` post-build. But anything that bypasses `build.sh`
  (e.g. running `swift build` directly + opening
  `.build/.../QuotaMonitor`) will produce an unversioned bundle.
- **Coverage today**: `release.sh` step 4 fails loud if the version
  inside the built `.app` doesn't match `VERSION`.
- **Watch**: any new build entry point that skips `build.sh`.

### 9. Developer Mode persistent log volume / privacy
- **Why risky**: Developer Mode writes a local plain-text timeline under
  `~/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log`.
  It is intentionally broad enough to capture support evidence after the
  app exits, so new call sites must avoid logging secrets, access tokens,
  full request bodies, or unbounded user content.
- **Coverage today**: `DeveloperModeTests` pins opt-in behavior, parent
  directory creation, append format, and newline escaping. It does not
  audit every future log message for sensitivity.
- **Watch**: any new `DeveloperLog.*` call around OAuth credentials,
  JSONL payload text, filesystem paths beyond expected app/session paths,
  or large collections. Keep entries short, structured, and supportable.

### 9b. Claude Keychain read policy
- **Why risky**: Keychain UI from a background poller looks like a frozen
  progress bar and can leave worker threads parked in Security.framework.
  It is also easy to accidentally log or mirror credential blobs while
  debugging this path.
- **Coverage today**: `ClaudeUsageClientKeychainTests` pins non-interactive
  query construction and JSON password decoding from the `security` tool path.
- **Watch**: do not switch production back to unbounded `SecItemCopyMatching`
  data reads, and do not implement in-app OAuth refresh unless the refresh
  token ownership model is redesigned.

### 10. Refresh fan-out entry points
- **Why risky**: cold launch, menu-bar popover open, explicit Refresh,
  and Dashboard/History/Sessions reload are easy to drift apart. A user
  normally judges "fresh" by the downstream UI, not by whether a single
  poller actor accepted a request.
- **Coverage today**: the implementation routes menu-bar refresh through
  `AppEnvironment.refreshAll(throttle:)`, with separate throttling for
  popover-open versus explicit/cold-launch intent. There is no end-to-end
  UI automation test for the menu-bar popover lifecycle.
- **Watch**: adding a new refresh trigger should usually call
  `refreshAll(throttle:)` or explain why it deliberately refreshes only
  one provider/surface.
