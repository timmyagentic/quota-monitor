# Anonymous Version Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the maintainer an authenticated view of daily active QuotaMonitor/CodexMonitor version distribution without creating a stable installation identifier or collecting usage history.

**Architecture:** After explicit user consent, the app sends at most one best-effort check-in per UTC day and version using a fresh 16-byte random token that is reused only for same-day retries and replaced the next day. The Worker hashes the date-scoped token, upserts it into D1 for exact daily deduplication, aggregates closed days, deletes raw hashes, and renders only aggregate version counts on an authenticated maintainer page. The production service is deployed before the app reporter ships.

**Tech Stack:** Swift 6 strict concurrency, Foundation/CryptoKit/Security, Swift Testing, Cloudflare Workers/Static Assets, TypeScript/Vitest, D1/SQL migrations, Wrangler, AppKit consent alert.

## Global Constraints

- First complete, push, review, and merge PR #102 from `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-product-website`; preserve its six existing local commits.
- After #102 merges, create `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-anonymous-version-distribution` on `codex/anonymous-version-distribution` from fresh `origin/main`; never edit the primary checkout or `main`.
- Call the metric “daily active installations/check-ins,” never “users” or total installed base.
- No request may be sent before explicit consent. Consent values are `undecided`, `enabled`, and `disabled`; Local QA is always disabled.
- The app sends exactly `schema`, `day`, `token`, `version`, `brand`, and `channel`; never send account, IP-derived fields, device/hardware/OS identifiers, history, quota, token usage, paths, or file data.
- Generate a new cryptographic 16-byte token per UTC day. Do not retain a stable secret, installation ID, Keychain ID, or cross-day pseudonym.
- Same-day retries reuse the token; same-day upgrades upsert the version instead of double-counting.
- Raw date-scoped token hashes are deleted after closed-day aggregation; aggregate counts are retained for 400 days.
- The public ingest endpoint is best-effort and never blocks app launch, scanning, quota refresh, or shutdown.
- Maintainer counts are private and protected by a Worker secret using constant-time verification; never expose raw tokens or hashes.
- Disable request invocation logs for telemetry privacy and never log payload bodies, tokens, Authorization, or source IP.
- Follow current Cloudflare docs/types/config schema, use bindings instead of REST from the Worker, parameterize every SQL value, run `wrangler types`, and update both changelogs plus privacy copy.

---

## File Structure

**PR #102 prerequisite modifications:**

- `website/tests/site-content.test.ts`, `website/public/app.js` — respect browser language ordering.
- `.github/workflows/tests.yml` — add a gated Node 22 website check.

**New app files:**

- `QuotaMonitor/Core/Telemetry/DailyActivePayload.swift` — six-field wire model and UTC day/version/brand/channel validation.
- `QuotaMonitor/Core/Telemetry/DailyActiveTokenStore.swift` — cryptographic per-day token and success state.
- `QuotaMonitor/Core/Telemetry/DailyActiveReporter.swift` — best-effort request, retry, rollover, and cancellation.
- Focused `DailyActive*Tests.swift` files.

**New website files:**

- `website/src/daily-active.ts` — bounded request parsing, validation, hashing, and D1 upsert.
- `website/src/version-distribution.ts` — aggregation queries and server-rendered private dashboard.
- `website/src/admin-auth.ts` — constant-time Basic credential validation.
- `website/migrations/0001_daily_active.sql` — strict observation/aggregate schema.
- `website/tests/daily-active.test.ts`, `version-distribution.test.ts`, `admin-auth.test.ts`.

**Modified integration files:**

- `Branding.swift`, `SettingsStore.swift`, `GeneralSettingsTab.swift`, `L10n.swift`, `AppDelegate.swift` — stable slugs, consent/toggle, disclosure, reporter lifecycle.
- `website/src/worker.ts`, `website/wrangler.jsonc`, `website/worker-configuration.d.ts`, `website/public/index.html`, `website/public/app.js`, and `website/tests/site-content.test.ts` — routes, D1, cron, and privacy copy.
- Both changelogs and product/privacy design documentation.

## Wire Contract

```json
{
  "schema": 1,
  "day": "2026-07-16",
  "token": "22-character-base64url",
  "version": "0.2.41",
  "brand": "quota-monitor",
  "channel": "developer-id"
}
```

Allowed brands: `quota-monitor`, `codex-monitor`. Allowed channels: `developer-id`, `app-store`.

---

### Task 0: Finish and merge the website foundation

**Files:**

- Modify: `website/tests/site-content.test.ts`
- Modify: `website/public/app.js`
- Modify: `.github/workflows/tests.yml`

- [ ] **Step 1: Write the failing language-order test**

```ts
expect(resolveLanguage(null, ["en-US", "zh-CN"])).toBe("en");
expect(resolveLanguage(null, ["fr-FR", "zh-CN", "en-US"])).toBe("zh-Hans");
```

- [ ] **Step 2: Confirm RED**

Run `cd website && npm test -- --run tests/site-content.test.ts`.
Expected: English-first case returns `zh-Hans`.

- [ ] **Step 3: Implement first-supported-language resolution**

```js
for (const value of values) {
  if (typeof value !== "string") continue;
  const language = value.toLowerCase();
  if (language.startsWith("en")) return "en";
  if (language.startsWith("zh")) return "zh-Hans";
}
return "en";
```

- [ ] **Step 4: Add a website CI gate**

Extend change detection with `website/**`, run Node 22 plus `npm ci && npm run check` in `website/`, and make the required summary job fail when a requested website check is not successful.

- [ ] **Step 5: Verify, publish, and merge #102**

Run `npm run check` and `./qa/run-static.sh`; commit the fix/CI files, push all seven local commits, resolve review thread `PRRT_kwDOSWyflM6RD3J5`, wait for the new head checks, request final review, and merge PR #102 only when review threads and checks are clean.

### Task 1: Generate and persist a day-scoped anonymous token

**Files:**

- Create: `QuotaMonitor/Core/Telemetry/DailyActiveTokenStore.swift`
- Create: `Tests/QuotaMonitorTests/DailyActiveTokenStoreTests.swift`

- [ ] **Step 1: Write failing token-store tests**

Inject a deterministic 16-byte random source and UTC calendar. Assert same-day calls reuse one 22-character base64url token, the next UTC day replaces it, a random-source failure returns nil without persisting, `markSucceeded(day:version:)` records only the day/version, and `clear()` removes token/success state.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter DailyActiveTokenStoreTests`.
Expected: compile failure because the store does not exist.

- [ ] **Step 3: Implement minimal storage**

```swift
struct DailyActiveTokenRecord: Codable, Equatable, Sendable {
    let day: String
    let token: String
}
```

Use `SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)`, URL-safe unpadded Base64, one JSON `Data` key, and one successful `day|version` string. Never create any cross-day secret.

- [ ] **Step 4: Confirm GREEN and commit**

Run the suite and commit with `Generate unlinkable daily version tokens`.

### Task 2: Build the six-field payload and best-effort reporter

**Files:**

- Create: `QuotaMonitor/Core/Telemetry/DailyActivePayload.swift`
- Create: `QuotaMonitor/Core/Telemetry/DailyActiveReporter.swift`
- Create: `Tests/QuotaMonitorTests/DailyActivePayloadTests.swift`
- Create: `Tests/QuotaMonitorTests/DailyActiveReporterTests.swift`
- Modify: `QuotaMonitor/Core/Branding.swift`

- [ ] **Step 1: Write failing payload tests**

Assert encoded JSON has exactly six keys and stable slugs:

```swift
#expect(Set(json.keys) == ["schema", "day", "token", "version", "brand", "channel"])
#expect(payload.schema == 1)
#expect(payload.brand == "quota-monitor")
#expect(payload.channel == "developer-id")
```

Reject empty/non-semver versions, invalid days, unknown brand/channel, and malformed tokens.

- [ ] **Step 2: Write failing reporter tests**

With an injected transport/clock/sleeper, prove disabled/undecided/LocalQA states issue zero requests, one 204 marks success, same day/version does not resend, same-day version change resends with the same token, 4xx stops until next lifecycle trigger, 5xx/network errors retry with bounded backoff, UTC rollover sends a new token, and `stop()` cancels work.

- [ ] **Step 3: Confirm RED**

Run `swift test --disable-keychain --filter 'DailyActivePayloadTests|DailyActiveReporterTests'`.
Expected: missing types fail compilation.

- [ ] **Step 4: Implement payload and reporter**

POST to `https://quota-monitor.timmyagentic.com/api/v1/daily-active` with `Content-Type: application/json`, `Accept: application/json`, and a versioned app User-Agent. Treat only 204 as success. `start()` performs an initial jittered attempt and reevaluates every six hours so a long-running app crosses UTC days without a permanent timer.

- [ ] **Step 5: Confirm GREEN and commit**

Run both suites and commit with `Report anonymous daily app versions`.

### Task 3: Add explicit consent and app lifecycle wiring

**Files:**

- Modify: `QuotaMonitor/Core/Settings/SettingsStore.swift`
- Modify: `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
- Modify: `QuotaMonitor/App/AppDelegate.swift`
- Create: `Tests/QuotaMonitorTests/AnonymousVersionReportingConsentTests.swift`
- Modify: `Tests/QuotaMonitorTests/BrandingLocalizationTests.swift`
- Modify: `Tests/QuotaMonitorTests/AppDelegateLifecycleTests.swift`

- [ ] **Step 1: Write failing consent tests**

Add `AnonymousVersionReportingConsent: String` with `.undecided`, `.enabled`, `.disabled`. Fresh/upgrade defaults are undecided; setting enabled/disabled persists across a fresh store; disabling calls the token-store clear hook; Local QA never presents disclosure or starts a reporter.

- [ ] **Step 2: Confirm RED**

Run settings, localization, and app lifecycle suites. Expected: missing consent APIs and copy fail.

- [ ] **Step 3: Implement disclosure and toggle**

After onboarding is complete, present one AppKit disclosure with explicit `Share Anonymous Statistics` / `Don't Share` choices. Do not send before the enabled choice is persisted. General Settings exposes `Share anonymous version statistics` / `共享匿名版本统计` plus exact copy that lists the four dimensions and exclusions; toggling off stops the reporter and clears the current daily token.

- [ ] **Step 4: Wire reporter lifecycle**

AppDelegate owns the reporter, starts it only for enabled consent and non-QA execution, reacts to settings changes, and stops it at termination. Reporting failures never surface as app errors.

- [ ] **Step 5: Confirm GREEN and commit**

Run focused suites and commit with `Add consent for anonymous version statistics`.

### Task 4: Ingest and exactly deduplicate daily observations

**Files:**

- Create: `website/migrations/0001_daily_active.sql`
- Create: `website/src/daily-active.ts`
- Create: `website/tests/daily-active.test.ts`
- Modify: `website/src/worker.ts`
- Modify: `website/wrangler.jsonc`
- Regenerate: `website/worker-configuration.d.ts`

- [ ] **Step 1: Write failing request-validation tests**

Test POST-only, HTTPS, exact `application/json`, 2 KiB bounded body streaming, exact key set, schema/day/token/version/allowlist validation, current UTC day enforcement, and 204/no-store success. Invalid method/media/size/payload/day return 405/415/413/400/409 without touching D1.

- [ ] **Step 2: Write failing hash/upsert tests**

Assert the raw token never reaches SQL/log output, the SHA-256 input is `v1\0<day>\0<token>`, duplicate day/token updates version/brand/channel, and all values are prepared-statement bindings.

- [ ] **Step 3: Confirm RED**

Run `cd website && npm test -- --run tests/daily-active.test.ts`.
Expected: missing route/module failures.

- [ ] **Step 4: Add strict D1 schema**

```sql
CREATE TABLE daily_active_observations (
  day TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  version TEXT NOT NULL,
  brand TEXT NOT NULL,
  channel TEXT NOT NULL,
  PRIMARY KEY (day, token_hash)
) STRICT, WITHOUT ROWID;

CREATE TABLE daily_version_counts (
  day TEXT NOT NULL,
  version TEXT NOT NULL,
  brand TEXT NOT NULL,
  channel TEXT NOT NULL,
  active_count INTEGER NOT NULL CHECK(active_count >= 0),
  PRIMARY KEY (day, version, brand, channel)
) STRICT, WITHOUT ROWID;
```

- [ ] **Step 5: Implement bounded parsing and upsert**

Add `/api/v1/daily-active` to `run_worker_first`; stream/cancel after 2 KiB; hash with Web Crypto; use one prepared `INSERT ... ON CONFLICT(day, token_hash) DO UPDATE`. Return generic 503 on storage failure and never log request metadata.

- [ ] **Step 6: Confirm GREEN and commit**

Run tests, `npm run typegen`, and `npm run typecheck`; commit with `Ingest anonymous daily version check-ins`.

### Task 5: Aggregate closed days and render a private dashboard

**Files:**

- Create: `website/src/admin-auth.ts`
- Create: `website/src/version-distribution.ts`
- Create: `website/tests/admin-auth.test.ts`
- Create: `website/tests/version-distribution.test.ts`
- Modify: `website/src/worker.ts`
- Modify: `website/wrangler.jsonc`

- [ ] **Step 1: Write failing aggregation tests**

Prove a closed day is rebuilt idempotently from observations, then raw hashes are deleted; aggregate rows older than 400 days are deleted; D1 `batch()` contains all steps; today's provisional query groups observations while historical queries read only aggregates.

- [ ] **Step 2: Write failing authentication/dashboard tests**

Missing/bad Basic credentials return 401 with `WWW-Authenticate`; valid credentials use constant-time comparison and return `private, no-store`. HTML shows latest complete-day total, today's provisional total, latest-version adoption, 7/30/90-day trends, brand/channel filters, and a count/share table; no response contains `token`, `token_hash`, Authorization, or raw rows.

- [ ] **Step 3: Confirm RED**

Run the two new Vitest files. Expected: missing modules/routes fail.

- [ ] **Step 4: Implement cron aggregation**

Configure `15 * * * *`; the scheduled handler reevaluates UTC time and batches aggregate upsert, closed-day observation deletion, and 400-day retention cleanup. Do not destructure `ctx`; await/batch every promise.

- [ ] **Step 5: Implement maintainer view**

Protect `/maintainer/versions` with `VERSION_STATS_ADMIN_TOKEN`; render semantic server-side HTML and existing same-origin CSS without client analytics or public JSON. Query ranges are allowlisted to 7/30/90/400 days and filters to known brand/channel values.

- [ ] **Step 6: Confirm GREEN and commit**

Run website tests/typecheck/dry-run/startup checks and commit with `Add private version distribution dashboard`.

### Task 6: Align privacy copy, logging, and CI

**Files:**

- Modify: `website/public/index.html`
- Modify: `website/public/app.js`
- Modify: `website/tests/site-content.test.ts`
- Modify: `docs/superpowers/specs/2026-07-15-product-website-design.md`
- Modify: `.github/workflows/tests.yml`
- Modify: `website/wrangler.jsonc`
- Modify: `CHANGELOG.md`, `CHANGELOG.zh-Hans.md`

- [ ] **Step 1: Write failing privacy/content tests**

Require English/Chinese disclosure of once-per-UTC-day fields, no stable device identifier, Cloudflare transport/IP processing without database storage, raw hash deletion after aggregation, 400-day aggregate retention, opt-out, and no history/quota/token/path upload.

- [ ] **Step 2: Update copy and observability**

Remove the old “no telemetry required/in scope” contradiction. Disable invocation logs in Wrangler config while retaining safe aggregate error observability that never records request data.

- [ ] **Step 3: Add/confirm website CI**

Ensure every website/migration/Worker change runs Node 22 `npm ci && npm run check` and contributes to the required PR summary check.

- [ ] **Step 4: Add bilingual changelog entries**

English Summary: `You can now opt in to anonymous daily version statistics, helping updates reach active installations without sharing usage history or a persistent device identifier.`

Chinese Summary: `你现在可以选择共享匿名的每日版本统计，帮助更新覆盖活跃安装，同时不会上传使用历史或持久设备标识。`

- [ ] **Step 5: Commit**

Commit with `Document anonymous version statistics`.

### Task 7: Provision, deploy, and verify the service before the app ships

**Files:**

- Cloudflare D1 database and Worker secret/deployment state.

- [ ] **Step 1: Validate current Cloudflare tooling**

Run `npx wrangler whoami`, validate `wrangler.jsonc` against its installed schema, and retrieve latest Workers types/docs before deployment.

- [ ] **Step 2: Create and migrate production D1**

Create `quota-monitor-version-stats` in APAC if it does not already exist, add the returned binding to config, run the migration locally then remotely, and query `sqlite_master` to confirm both strict tables.

- [ ] **Step 3: Install maintainer secret safely**

Generate a cryptographic token without printing it, set `VERSION_STATS_ADMIN_TOKEN` with `wrangler secret put`, and save the same value in the local macOS Keychain service `quota-monitor-version-dashboard` for maintainer retrieval.

- [ ] **Step 4: Deploy and smoke-test production**

Deploy Worker first. Send a synthetic current-day token twice and a version update once; confirm 204, one provisional active installation, updated version classification, 401 for unauthenticated dashboard, authenticated aggregate view, existing `/api/release`, `/download` HEAD, and homepage behavior.

- [ ] **Step 5: Verify privacy cleanup path**

Run the scheduled handler against test/closed-day data, confirm aggregate counts remain and observation hashes are removed, then delete synthetic production rows so the dashboard starts with real app data only.

### Task 8: Complete app and end-to-end verification

- [ ] **Step 1: Run all local gates**

```bash
swift test --disable-keychain --filter 'DailyActiveTokenStoreTests|DailyActivePayloadTests|DailyActiveReporterTests'
./qa/run-static.sh
cd website && npm run check
```

- [ ] **Step 2: Run Computer QA**

Use fixture-smoke first to verify no external request occurs under Local QA. Then use real-data shadow QA to inspect disclosure, General Settings toggle/copy, opt-out cleanup, and all normal app surfaces. Check artifacts and clean up with the generated script.

- [ ] **Step 3: Publish and merge the feature PR**

Push, open a Ready PR with privacy/data-flow summary and verification evidence, request final review, resolve all threads, wait for CI, and merge when clean.

- [ ] **Step 4: Release through the hardened pipeline**

After the reminder and release-reliability PRs are also merged, prepare the next patch release through the repository's release PR/tag workflow, wait for both brand releases and the automatically opened Appcast PR, merge the Appcast PR, and verify a production check-in reaches the private dashboard only after explicit consent.
