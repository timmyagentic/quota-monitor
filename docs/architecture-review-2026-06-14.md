# Architecture review — 2026-06-14

Findings from a multi-dimension, read-only review of QuotaMonitor across four
lenses: concurrency & resource lifecycle, data layer & performance, correctness
& error handling, and architecture & maintainability.

This is a **backlog to triage and fix incrementally** — nothing here is fixed by
this document. Each item lists where it lives, what's wrong, why it matters, a
fix direction, and a severity.

**Baseline.** `main` @ `2ac8fb9` (PR #49, "Fix time-window analytics queries
dropping today's rows"). Line references are approximate and anchored to that
commit; the analytics files shift slightly under the in-flight PRs noted below,
so prefer the function name over the exact line when navigating.

**Scope / exclusions.** These are already fixed or have an open PR and are
intentionally **not** relisted here:

| Area | Status |
|------|--------|
| Time-window queries dropping today's rows (`datetime()` → `strftime()`) | Fixed in #49 (merged) |
| `rate_limit_samples` unbounded growth | Retention prune — PR #52 (open) |
| Daily / monthly / History day bucketing across DST | PR #54 (open) |

**Legend.** Severity = **High** / **Med** / **Low**.
⊗ = independently flagged by more than one review lens (higher confidence).

---

## P0 — Correctness & billing (user-visible "wrong numbers")

### P0-1 ⊗ Claude incremental import misses data when a file is rewritten but stays ≥ the stored offset

- **Where:** `Core/Importer/ClaudeImportEngine.swift:117-135`.
- **What:** Incremental tail reads resume from the stored `byte_offset`. A full
  reset only happens when `fileSize < prior.byteOffset`. If a rollout file is
  rewritten/edited in place but its new size is still **≥** the stored offset
  (e.g. offset `500`, old size `10 KB`, new size `800 B`), the import reads only
  the tail past the offset and the bytes in `0..offset` are never re-imported.
- **Why it matters:** Atomic-save editors, partial corruption that shrinks but
  not below the offset, or a rebuilt rollout all silently drop or desync usage,
  so totals under- or over-count with no error surfaced.
- **Fix direction:** Detect rewrites by inode/generation or a small content
  fingerprint (header hash), and treat *any* size decrease (not just
  `< byteOffset`) as a reset to `fromOffset = 0, resetSession = true`.
- **Severity:** High.

### P0-2 ⊗ Claude events without `message.id` are re-inserted on every scan (double counting)

- **Where:** `Core/Importer/ClaudeImportEngine.swift:419-461`; parser at
  `Core/Importer/ClaudeRolloutParser.swift:623-651`; partial unique index in
  `Core/Storage/Migrations.swift:178-182`.
- **What:** The dedup guard is a partial unique index on
  `(session_id, provider_message_id) WHERE provider_message_id IS NOT NULL`
  combined with `INSERT OR IGNORE`. When `messageId == nil`, the index does not
  apply, so each incremental tail scan re-`INSERT`s the same rows.
- **Why it matters:** Older Claude Code rollouts (or any row missing
  `message.id`) accumulate duplicates across scans → token counts and cost
  **double** (and grow each scan).
- **Related:** This is the *opposite face* of the design documented in
  `docs/database-architecture-limitations.md` (which covers over-dedup when
  multiple events *share* a non-null `message.id`). Both stem from the same
  partial-index choice.
- **Fix direction:** Synthesize a dedup key for null-id rows
  (`session_id + timestamp + model_id + token fingerprint`), or force null-id
  files to always full-reset rather than tail-append.
- **Severity:** High.

### P0-3 ⊗ Unknown `model_id` is silently priced at $0

- **Where:** `Core/Pricing/PricingService.swift:441-484`; insert paths
  `Core/Importer/ImportEngine.swift:198`, `Core/Importer/ClaudeImportEngine.swift:434,594`.
- **What:** Imported rows start with `value_usd = 0`. `backfillAllValues` updates
  only rows that match `WHERE EXISTS (pricing_catalog …)`, so a model with no
  catalog entry stays at `$0` forever. Claude rows with a missing model fall back
  to the literal `"unknown"`, which is not seeded.
- **Why it matters:** When a new model ships before the catalog/LiteLLM knows it,
  the Dashboard and menu bar render its spend as `$0` — it looks *free* rather
  than *unpriced*. Unlike `model_inferred` → `gpt-5`, there is no approximate
  price and no UI warning.
- **Fix direction:** Add a fallback price + an "inferred/unpriced" flag, or mark
  `value_usd = 0 AND total_tokens > 0` rows visibly as "not priced"; optionally
  auto-add a catalog row from LiteLLM.
- **Severity:** High (billing visibility).

---

## P1 — Performance & scalability (degrades as `usage_events` grows)

Rough scale assumption: **500k `usage_events`**. DB reads run on a background
pool thread (not the main thread directly), but a single full-table fetch is a
~50–120 MB allocation plus ~500k `parseTimestamp` + `Calendar` calls, and large
result sets still spike memory when handed to `@MainActor` SwiftUI updates.

### P1-4 ⊗ Analytics does full-table fetches + in-memory aggregation, and one refresh scans `usage_events` several times

- **Where:** `Core/Analytics/AggregatorActivity.swift:56` (`fetchActivity`),
  `Core/Analytics/AggregatorHistory.swift:22` (`fetchDays`),
  `Core/Analytics/AggregatorReports.swift:9-49` (`loadDashboard`).
- **What:** `fetchActivity` and `fetchDays` have **no time window** (the
  `limit: 365` on `fetchDays` is applied client-side after fetching every row).
  `loadDashboard` runs ~14–16 query groups in one read transaction, several of
  them full-table or overlapping — `fetchOverview` (full), `fetchDaily(14)` and
  `fetchDaily(60)` (the 14-day window is a subset of the 60-day one — read
  twice), lifetime `fetchModelShares` (full), and `fetchActivity` (full).
- **Why it matters:** At 500k rows a single Dashboard refresh can make 5+
  full-table passes, hold the read transaction for seconds, and lengthen write-
  lock waits for the importer/pollers. `fetchActivity` runs on **every**
  Dashboard refresh.
- **Fix direction:** Maintain a **day-granularity rollup table** updated
  incrementally at import time (one change fixes `fetchActivity`, `fetchDays`,
  and the repeated daily/monthly/overview passes); slice `fetchDaily(14)` from
  the `fetchDaily(60)` result; cap the heatmap to the last 365 days in SQL.
- **Severity:** High.

### P1-5 Missing a standalone `usage_events(timestamp)` index

- **Where:** indexes in `Core/Storage/Migrations.swift` —
  `usage_events(session_id, timestamp)` and `usage_events(provider, timestamp)`.
- **What:** Pure time-range queries with `provider = .all` (no provider
  predicate) — `fetchDaily`/`fetchMonthly` lower bounds, `fetchDayDetail`,
  `BillingBlocks.fetchEntries`, the CSV export's `ORDER BY timestamp` — cannot
  use a `(provider, timestamp)` index effectively and there is no standalone
  `timestamp` index, so they tend to degrade to table scan + filter/sort.
- **Why it matters:** Lowest-cost, highest-ROI item here: one index immediately
  improves the 60-day / 12-month / billing-block / export paths at scale.
- **Fix direction:** `CREATE INDEX … ON usage_events(timestamp)` (or
  `(timestamp, provider)`); verify with `EXPLAIN QUERY PLAN`.
- **Severity:** Med (High ROI for the cost).

### P1-6 (data) Repeated/overlapping aggregation across the menu bar and Dashboard

- **Where:** `Core/Analytics/AggregatorReports.swift:271-335`
  (`fetchPerProviderStats`), called from `App/AppEnvironment.swift` `refreshMenuBar`.
- **What:** The menu-bar path recomputes lifetime / 7d / 30d rollups that
  largely duplicate the Dashboard's overview and model-share queries, and
  `refreshMenuBar` runs again right after a Dashboard refresh.
- **Fix direction:** Share one `Sendable` snapshot between menu bar and
  Dashboard, or compute the windows with conditional aggregation in a single SQL
  pass. Subsumed by the rollup table in P1-4.
- **Severity:** Med.

### P1-7 (data) Heavy write paths hold the write lock

- **Where:** `Core/Pricing/PricingService.swift:441-484` (`backfillAllValues`,
  full-table correlated UPDATE, no row cap — triggered after scans *and* on
  pricing/Fast-Mode toggles with no `changedFiles` gate); Codex import
  `Core/Importer/ImportEngine.swift:184-204` (per-session DELETE-all + row-by-row
  INSERT, while Claude already upserts); `reconcileSessionTree`
  `Core/Importer/ImportEngine.swift:284-291` (one UPDATE per session).
- **Why it matters:** At scale these are multi-second write transactions that
  queue other writes (imports, rate-limit persists) behind them. WAL keeps reads
  mostly alive, but Dashboard refreshes can hit `busy_timeout`.
- **Fix direction:** Backfill only `value_usd = 0` / changed-pricing rows; price
  inline at import; batch INSERT/UPDATE with prepared statements; Codex
  incremental upsert instead of delete-all.
- **Severity:** Med.

---

## P1 — Concurrency & stability

### P1-8 ⊗ Scan timeout doesn't stop the old scan, scans can overlap, and the Claude scan is unstructured

- **Where:** `App/ScanController.swift:103-137`,
  `App/AppEnvironment.swift:983-991`, `Core/Importer/ImportEngine.swift` (the
  per-file loop has no `Task.checkCancellation()`).
- **What:** `runScan` wraps work in a 300s `withTimeout` whose timeout path only
  `cancel()`s the task and is documented to "let abandoned work keep running".
  The Codex import loop never checks cancellation, and the Claude side runs in an
  **unstructured** `Task { … }` not guaranteed to be cancelled with its parent.
  `defer` flips `isScanning = false` after the timeout, so the UI unlocks while
  the old scan may still be writing.
- **Why it matters:** After a timeout the user can press Refresh again → **two
  scans writing the same SQLite** (contending on `busy_timeout`); the abandoned
  scan can still complete writes that contradict the surfaced timeout error.
- **Fix direction:** Structured concurrency (`async let` / `withTaskGroup`) for
  Codex + Claude, cancellation checks inside the import loops, and a `ScanRunID`
  so late completions from a superseded run are ignored.
- **Severity:** High.

### P1-9 `ClaudeCLIRefreshTrigger.runClaudeCLI` has no hard timeout on process exit

- **Where:** `Core/Claude/ClaudeCLIRefreshTrigger.swift:251-258` (and the
  in-flight task at `:140-142`, awaited at `:76-77`).
- **What:** A comment promises a "hard cap", but the wait is a bare
  `process.waitUntilExit()` inside `withCheckedContinuation`. The 8s
  `attemptTimeout` only bounds the post-spawn Keychain poll, not the CLI itself.
- **Why it matters:** A hung `claude` process means the `CheckedContinuation`
  **never resumes** (not a double-resume — a never-resume); the shared in-flight
  task never finishes and every later refresh queues behind it.
- **Fix direction:** Race `waitUntilExit` against the same wall-clock budget
  (terminate + resume on timeout); share one budget across spawn + mdat wait.
- **Severity:** High.

### P1-10 First `ensureServices()` runs DB migrations + catalog seed synchronously on the main actor

- **Where:** `App/AppEnvironment.swift:137-155` (`@MainActor`),
  `Core/Storage/DatabaseManager.swift` init runs `migrator.migrate` + `seedCatalog`.
- **What:** Startup (`applicationDidFinishLaunching` → `startBackgroundPolling`
  → `ensureServices`) constructs `DatabaseManager` synchronously on the main
  actor, which migrates and writes on first launch.
- **Why it matters:** Perceptible main-thread hitch on first launch / heavier
  migrations (delayed popover and status-item render).
- **Fix direction:** Initialize the DB off the main actor and assign it back when
  ready.
- **Severity:** High (startup path).

---

## P2 — Architecture & maintainability

### P2-11 `AppEnvironment` is a god object

- **Where:** `App/AppEnvironment.swift` (~1027 lines; with the controller
  cluster `PricingController`/`ScanController`/`QueryFacade`/`UninstallController`
  it's ~1984 lines for one type).
- **What:** A single `@MainActor @Observable` singleton holds 10+
  responsibilities: UI state store (20+ mutable properties), service locator,
  poller lifecycle, settings application, refresh orchestration + throttling,
  Codex/Claude refresh, snapshot loading (calls `Aggregator`/`BillingBlocks`
  directly), AppKit window policy, and cross-cutting `withTimeout`. The
  orchestration layer is effectively un-injectable for tests (`init` injects only
  `AppServerClient`; DB path, pricing source, and `SettingsStore` are hard-wired).
- **Fix direction:** Extract incrementally without changing the SwiftUI API —
  start with a `ServiceContainer` (constructs/holds DB + engines + pollers) and a
  `SnapshotLoader` (the `refreshMenuBar`/`refreshDashboard` reads), then split a
  read-only `AppState` from the coordinators. `AppEnvironment` becomes a
  composition root.
- **Severity:** High (maintainability/testability).

### P2-12 Duplicated boilerplate

- **Where / what:**
  - Two semantically different `withTimeout` implementations —
    `App/AppEnvironment.swift:992-1014` (TaskGroup, abandons work) vs
    `Core/RateLimits/RateLimitPoller.swift:299-331` (timeout-race actor,
    double-resume-safe). Easy to fix one and miss the other.
  - Two highly parallel pollers — `RateLimitPoller` and `ClaudeUsagePoller`
    ("Mirror" per the header comment) share `minimumGap`/cooldown/scheduling and
    test hooks.
  - `App/QueryFacade.swift` repeats the same "start op → `ensureServices` →
    `pool.read` → finish op" wrapper across ~5 methods.
  - Minor: duplicate `fetched_at` SQL (`PricingController.swift:39-44` & `109-115`),
    a `sqliteFormatter` defined in both `Aggregator.swift` and `BillingBlocks.swift`,
    and `DeveloperFileLogger` building a fresh `ISO8601DateFormatter` per log line
    instead of the shared `ISO8601` enum.
- **Fix direction:** One shared bounded-work helper; a generic
  `QuotaPoller<Fetcher, Snapshot>` or shared throttle; a `loggedRead` helper;
  fold the formatters into `ISO8601Formatters.swift`.
- **Severity:** Med.

### P2-13 Some window queries still compare timestamps as SQL strings

- **Where:** `Core/Analytics/AggregatorReports.swift` `fetchModelShares(sinceDays:)`
  and `fetchProviderShares30d`; `Core/Analytics/AggregatorRateLimits.swift`.
- **What:** These still use `strftime(...)` bounds and lexical `timestamp >= …`
  comparison. Correct today because stored values are ISO8601 `T/Z`, but
  `parseTimestamp` also accepts `yyyy-MM-dd HH:mm:ss` (space-separated), which
  would sort differently and silently drop/include rows if such values ever land
  in the table. (PR #54 moved `fetchDaily`/`fetchMonthly`/History to client-side
  `parseTimestamp`; these queries were not in its scope.)
- **Fix direction:** Use the same wide ISO lower bound + client-side
  `parseTimestamp` filtering, or normalize all writes to `ISO8601.fractional`.
- **Severity:** Med (latent / format-fragility).

### P2-14 Presentation logic embedded in views

- **Where:** `Features/MainWindow/ProviderBlock.swift:23-67,94-98` — a view body
  branches across live snapshot → dashboard fallback → QA → empty for Codex, and
  Claude OAuth vs billing-blocks fallback.
- **Fix direction:** Precompute a `CodexQuotaPresentation` / `ClaudeQuotaPresentation`
  in the environment and let the view render a single resolved value. (Most other
  views go through `@Environment(AppEnvironment)` cleanly — no view reaches into
  storage directly.)
- **Severity:** Med.

---

## P3 — Lower priority

- **Cross-file scans aren't atomic** — each file commits its own `pool.write`; a
  crash mid-scan can leave some sessions updated and `reconcileSessionTree`/
  backfill un-run (`ImportEngine.swift:76-106`). Add a scan generation marker /
  "scan incomplete" surfacing. (Med-leaning.)
- **Silent error swallowing** — Codex `LineReader` treats a read error as EOF
  (`RolloutParser.swift:393-395`); Claude skips unparseable JSON lines silently
  (`ClaudeRolloutParser.swift:571-573`); per-file scan errors still report
  success (`ImportEngine.swift:89-90`, `ScanController.swift:142-152`). Count /
  surface these.
- **`above_200k_*` prices stored but unused** — long-context sessions are
  systematically under-priced (`PricingService.swift:444-476`; see
  `docs/billing-logic.md`).
- **Fast-Mode with no `-fast` catalog row** keeps Codex spend at $0
  (`PricingService.swift:480-517`).
- **`updated_at` / session ordering relies on ISO string ordering**
  (`ClaudeImportEngine.swift:357-363`, `AggregatorSessions.swift:193`) — fragile
  if timestamp formats are mixed.
- **Legacy DB migration is not all-or-nothing** — moving `.sqlite`/`-wal`/`-shm`
  can partially fail and only logs (`DatabaseManager.swift:92-114`).
- **Claude `unknown` model never flags `model_inferred`** (asymmetric with Codex)
  — `ClaudeImportEngine.swift:437`.
- **History session expand is an interaction-time N+1** — one `pool.read` per
  expanded session against `maximumReaderCount = 3`
  (`AggregatorHistory.swift:148-177`, `DatabaseManager.swift`).
- **CSV export does a full-table `ORDER BY timestamp`** without a timestamp index
  (`ScanController.swift:198-206`) — improved for free by P1-5.
- **Background pollers don't pause on window close / app deactivation**
  (`RateLimitPoller.swift`, `ClaudeUsagePoller.swift`) — by design for a
  menu-bar app, listed only as a possible power optimization.

---

## Suggested order (by ROI)

1. **P0-1 / P0-2 / P0-3** — correctness & billing accuracy; each is testable with
   a focused regression.
2. **P1-5** — add `usage_events(timestamp)` index (one line of migration, broad
   speedup).
3. **P1-4** — day-granularity rollup table (collapses the full-table-scan family
   and the repeated daily/monthly/overview passes).
4. **P1-8 / P1-9 / P1-10** — scan-overlap structured concurrency, Claude CLI
   timeout, off-main-actor DB init.
5. **P2-11** — begin the `AppEnvironment` split (`ServiceContainer` +
   `SnapshotLoader`) to unlock testing of the orchestration layer.

## References

- `docs/database-architecture-limitations.md` — the non-null `message.id`
  over-dedup case (counterpart to P0-2).
- `docs/billing-logic.md` — pricing model, including the `above_200k` tier.
- `docs/project-survey-2026-04-30.md` — prior structural survey.
- Reviewed under PRs #49 (merged), #52 / #54 (open) — see Scope table above.
