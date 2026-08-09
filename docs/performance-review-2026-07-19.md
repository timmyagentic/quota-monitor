# Performance review — 2026-07-19

Original audit baseline: `87b99f5`. This document anchors the performance-optimization work:
it records every finding from a full four-track audit (import/scan plane, storage/analytics
read side, background services, UI/main-actor), ranked by impact, each with file references,
cost analysis, and a fix direction. Follow-up fixes landed as independently reviewed PRs;
the status snapshot below links the merged work back to each original finding. The detailed
problem statements preserve the baseline failure modes, while the status table and refresh
notes are checked against the named current `main` commit. Baseline line numbers in the
detailed findings are historical and will drift.

The recurring theme: several hot paths do work proportional to **total history size** where
the work needed is proportional to **the delta since last time**. A months-old install pays
more for every scan, poll, and dashboard open than a fresh one, forever.

## Trigger cadences (context for everything below)

| Trigger | Cadence | Work started |
| --- | --- | --- |
| Claude file watcher (`~/.claude` writes) | ~every 5 s during an active Claude session | Claude-scoped `runScan()` |
| Popover open | throttled to 20 s (scan) / 30 s (rate limits) | full `runScan()` + refreshes |
| Manual Refresh button | unthrottled | full `runScan()` + refreshes |
| Codex live poller | ~300 s | `codex app-server` spawn + JSON-RPC |
| Claude usage poller | ~600 s | `/api/oauth/usage` GET |
| Dashboard open / price edit / Fast-Mode toggle / provider-filter change | on demand | `refreshDashboard()` → `Aggregator.loadDashboard` |

"Every scan" below therefore means *every ~5 seconds* while Claude Code is in use, and every
menu-bar open otherwise.

---

## Delivery status — refreshed 2026-08-09

Status was checked against `origin/main` at `797237d`. The original 20 findings
are **not all complete**: **6 are delivered, 5 are partially delivered, and 9
remain open**. “Delivered” means the referenced merge commit is an ancestor of
that exact main head. “Partial” means a material part shipped, but the original
cost described below still exists.

| Finding | Status | Current evidence |
| --- | --- | --- |
| P0.1 full-history repricing | Delivered | PR #135 scopes incremental pricing to changed events. |
| P0.2 repeated Dashboard scans | Partial | PR #144 removes the redundant 14-day daily scan by deriving it from the 365-day result. `loadDashboard` still performs independent overview, daily, two breakdown, monthly, three model-share, provider-share, and all-time activity reads. |
| P0.3 full Codex rollout reparsing | Delivered | PR #121 adds validated incremental checkpoints and tail parsing. |
| P0.4 broad session-tree and metadata walks | Partial | PR #133 skips the heavy tree refresh after no-op scans and gates reconciliation on imported sessions; metadata backfill and changed-scan reconciliation still traverse broad session state. |
| P1.1 synchronous login-shell discovery | Partial | PR #124 prefers the CLI bundled with ChatGPT before shell probing, but the remaining fallback path is still synchronous. |
| P1.2 per-file popover progress invalidation | Partial | PR #155 keeps routine scans on a compact activity indicator, so those renders no longer read per-file `scanProgress`. Launch/onboarding imports still publish every file on MainActor and invalidate the parent popover view. |
| P1.3 redundant status-item title renders | Delivered | PR #136 caches visible rows, style, and localization state before assigning the native title. |
| P1.4 per-line rollout decoder allocation | Delivered | PR #137 reuses rollout JSON decoders. |
| P1.5 repeated environment snapshots | Open | `LocalQAEnvironment` still defaults many calls to `ProcessInfo.processInfo.environment`. |
| P2.1 Keychain busy-wait | Open | The Claude credential fallback still polls `/usr/bin/security` with `Thread.sleep` from an actor method. |
| P2.2 Claude cross-day lookup batching | Open | `crossDaySnapshotResolution` still queries stored rows separately for each parsed event. |
| P2.3 bulk import transactions | Open | Both importers still commit one write transaction per changed file. |
| P2.4 unindexed import-state session lookup | Delivered | PR #138 adds and tests the `import_state(session_id)` index. |
| P2.5 catalog seeding on every Codex scan | Delivered | PR #121 removed scan-time seeding; catalog setup remains in database initialization and explicit pricing flows. |
| P2.6 unbounded Sessions aggregation before limit | Partial | PR #129 adds request-driven 50-row pagination and PR #134 debounces search; the aggregate query still groups matching events before applying `LIMIT`. |
| P2.7 heatmap model rebuild on hover | Open | PR #164 makes the year layout responsive, but `ActivityHeatmap.body` still constructs `HeatmapModel` from `daily` on every hover-driven body evaluation. |
| P2.8 repeated Trends series derivation | Open | `activeSeries` is still recomputed by chart, selection, and legend paths. |
| P2.9 per-render formatter allocation | Open | Menu-bar and Sessions rows still allocate relative/date formatters during rendering. |
| P2.10 model-share index coverage | Open | Current usage-event indexes still omit `model_id` from the timestamp-leading covering indexes. |
| P2.11 small read, network, and logging costs | Open | The two Dashboard/BillingBlocks reads, monthly session sets, separate reset-credit request, developer-log file churn, and other small items remain. |

### Delta since the 2026-07-25 refresh

- `main` advanced by 25 commits from `90b48a3` to `797237d`.
- PR #155 moves P1.2 from Open to Partial by removing detailed per-file progress from routine
  refresh and file-watcher presentation. It does not coalesce progress publication itself.
- PR #164 addresses heatmap width and scrolling. It does not cache `HeatmapModel`, so it does
  not change P2.7's delivery status.
- The other 19 findings keep their previous status after re-reading their current code paths.

---

## P0 — cost scales with total history, hit constantly

### P0.1 `backfillAllValues()` re-prices the entire `usage_events` table on every changed-file scan

- [x] Fixed by PR #135.
- **Where:** call `App/ScanController.swift:180-185`; SQL `Core/Pricing/PricingService.swift:544-603`.
- **Problem:** whenever `merged.changedFiles > 0`, one `UPDATE usage_events SET value_usd = (…)`
  runs with **no predicate scoping it to the rows imported this scan**. Every row in history
  evaluates the large `effectiveModelIdSQL()` CASE correlated subquery *twice* (SET + `WHERE
  EXISTS`). During active use `changedFiles > 0` is true on virtually every scan, so the full
  re-price fires on the ~5 s watcher cadence, holding the write lock for the duration; poller
  sample inserts queue behind it.
- **Impact:** at the documented ~300 k-event scale this is a full-table rewrite (seconds of
  write-lock + WAL churn) every few seconds, indefinitely, to price a handful of new rows.
  Single largest recurring cost in the app.
- **Fix direction:** scan path updates only events belonging to sessions touched this scan
  (`WHERE session_id IN (…)`). Keep the whole-table pass only for the genuinely global
  triggers: price edit, Fast-Mode toggle, LiteLLM refresh (`PricingService.swift:516-519`).

### P0.2 `loadDashboard` performs many independent full-window scans, including all-time reads

- [ ] Fixed
- **Current evidence:** `Core/Analytics/AggregatorReports.swift:9-71` sequentially runs an
  overview read, a 365-day daily read, two 365-day breakdown reads, a 12-month read, three
  model-share reads, a 30-day provider-share read, and `fetchActivity`. The 14-day series is
  now derived from the 365-day result (PR #144), but the remaining reads are independent.
  `Core/Analytics/AggregatorActivity.swift:48-105` still loads every matching event for the
  lifetime/activity calculation.
- **Problem:** the daily and breakdown passes repeatedly materialize and parse overlapping
  rows. The overview, lifetime model share, and activity paths also revisit all matching
  history; activity brings the full raw result into Swift to compute a scalar lifetime total,
  peak day, streaks, and the heatmap.
- **Impact:** work still grows with total history and the same 365-day window is decoded three
  times before monthly/share/activity work begins. The refresh is triggered on Dashboard open,
  price edits, provider-filter changes, and scan completion while the Dashboard is visible.
- **Fix direction:** treat this as a measured data-path project. Fetch the 365-day event window
  once and derive daily/breakdown/monthly views without changing local-calendar/DST semantics.
  Move only safe lifetime aggregates into SQL, fetch distinct active-day markers for streaks,
  and add large-history regression fixtures before combining queries.

### P0.3 Codex re-parses the whole rollout file for any grown file

- [x] Fixed by PR #121.
- **Where:** change detection `Core/Importer/ImportEngine.swift:118-131`; parse loop `:147-178`;
  `persist` delete-all + re-insert `:322-432`; `byte_offset` hard-coded to 0 at `:409-416`.
- **Problem:** the (size, mtime) skip correctly avoids unchanged files, but a changed file is
  re-read from byte 0, fully re-parsed, and its `usage_events` deleted and re-inserted. An
  in-progress session's rollout grows continuously, so it is "changed" on every scan.
- **Impact:** an active Codex session with a hundreds-of-MB rollout is fully re-read,
  re-decoded, and rewritten on every popover open and manual refresh. Headline Codex CPU/IO
  cost; also the reason the 5-minute scan timeout exists.
- **Fix direction:** adopt Claude-style incremental tail reads for Codex. Harder than Claude
  because token counts are cumulative — needs persisted parser state (last cumulative totals)
  or tail re-process from the last known offset+state. Biggest single win, biggest change.

### P0.4 metadata backfill walks all Codex sessions on every scan; changed scans reconcile the full tree

- [ ] Fixed
- **Current evidence:** `ImportEngine.performScan` still calls `CodexSessionMetadataStore.load`
  and `backfillCodexSessionMetadata` before it knows whether any rollout changed; the backfill
  reads every Codex session. PR #133 correctly gates `reconcileSessionTree()` on
  `importedSessions > 0`, but that function still reads and updates every Codex session when it
  does run (`ImportEngine.swift:947-975`).
- **Impact:** no-op scans avoid the full tree rewrite, but still pay metadata-store loading and
  an all-session comparison. A one-session changed scan can still turn into a full-tree update.
- **Fix direction:** cache/gate external metadata by file identity or mtime, select only missing
  metadata rows, and reconcile affected ancestors/descendants instead of every session.

## P1 — significant, bounded or less frequent

### P1.1 Launch: synchronous login-shell spawn on the main thread

- [ ] Fixed
- **Current evidence:** PR #124 makes `AppServerClient.resolveBinary` short-circuit for an
  explicit override or the ChatGPT-bundled Codex before evaluating the login-shell autoclosure.
  On fallback installations, `AppServerClient()` is still created synchronously by
  `AppEnvironment` and computes the login-shell PATH with a two-second bound. Claude version
  detection separately performs its own login-shell PATH and `command -v claude` probes when
  first requested.
- **Impact:** the common ChatGPT-app path no longer pays this launch cost. CLI-only and
  version-manager installations can still block initialization on shell startup, and the
  duplicated Claude probe remains avoidable background work.
- **Fix direction:** move fallback discovery off the main actor, check known executable paths
  before shell startup, and share one cached login-shell environment between Codex and Claude.

### P1.2 Scan progress re-renders the entire popover once per file

- [ ] Fixed
- **Current evidence:** each importer still calls the shared progress handler per file;
  `ScanController.swift:150-153` hops each update to MainActor and
  `handleScanProgressUpdate` logs and reassigns `scanProgress`. PR #155 changes routine scans
  to `.compactActivity`, so the routine popover path no longer reads `scanProgress`; only
  launch/onboarding imports show detailed file progress.
- **Impact:** routine refresh and watcher UI invalidation is materially reduced, but cold-start
  imports can still publish hundreds or thousands of parent-view updates and every scan still
  pays the MainActor/logging work.
- **Fix direction:** coalesce progress publication to about 10 Hz and move detailed progress
  into a child view with its own observation boundary. Preserve exact final counts.

### P1.3 Menu-bar label rebuilds with no equality short-circuit, and over-subscribes to `dashboardSnapshot`

- [x] Fixed by PR #136.
- **Where:** `App/StatusItemController.swift:92-132`. `renderLabel()` unconditionally rebuilds
  the `NSAttributedString` and assigns `button.attributedTitle` on every Observation change.
  It reads `env.dashboardSnapshot?.codexQuota` (`:110`) in the common path, registering a
  dependency on the whole snapshot even though `codexQuota` is only a fallback used when
  `latestRateLimits == nil` (`MenuBarLabelModel.swift:37-47`).
- **Impact:** every dashboard refresh, scan completion, and poll triggers an attributed-string
  rebuild + `variableLength` status-item re-measure, even when the rendered text is identical
  (8.2 % → 8.4 % both render "8%"). Redundant main-thread relayouts, constantly.
- **Fix direction:** `MenuBarLabelModel.Row` is already `Equatable` — cache the last rows (or
  built string) and early-return when unchanged; read `codexQuota` only inside the
  `latestRateLimits == nil` branch so the snapshot dependency disappears in the common case.

### P1.4 `JSONDecoder` allocated per line in the Codex parse hot loop

- [x] Fixed by PR #137.
- **Where:** `Core/Importer/RolloutEvent.swift:242` (allocated before the `switch`,
  unconditionally per line); `:343` allocates another for any escaped string literal.
- **Impact:** the dominant `response_item` lines never touch the decoder — pure per-line
  allocation waste, hundreds of thousands of times per large-rollout re-parse; multiplies P0.3.
- **Fix direction:** construct the decoder only in branches that decode a payload, or reuse one.

### P1.5 Logging/QA-config hot path copies the whole process environment per call

- [ ] Fixed
- **Where:** `DeveloperLog.eventRecord` guards on `SettingsStore.developerModeEnabledNonisolated`,
  which calls `LocalQAEnvironment.userDefaults()`. The default arguments throughout
  `App/LocalQAEnvironment.swift:25-175` still copy `ProcessInfo.processInfo.environment`, and
  `isQARequested` scans every key. `SettingsStore.snapshot()` and
  `allowsExternalDataSources()` use the same uncached defaults.
- **Impact:** modest per call but multiplied by log volume — every `eventRecord` on every hot
  path (including the per-file scan progress events) pays an env snapshot just to discard the
  record when dev mode is off.
- **Fix direction:** the QA configuration cannot change at runtime — resolve it once into a
  `static let`; gate `eventRecord` on a cached bool.

## P2 — bounded, spiky, or cheap-to-fix

- [ ] **P2.1 Keychain read busy-waits on the actor.**
  `ClaudeUsageClient.readKeychainCredsIfAllowed()` invokes the synchronous
  `readKeychainTokenOutcomeViaSecurityTool`, which polls `process.isRunning` with
  `Thread.sleep(0.05)` for up to two seconds. Because the caller is an actor method, this blocks
  a cooperative-pool thread and serializes other client work. Fix: run the bounded security-tool
  operation in detached blocking work or replace it with an async process/pipe bridge.
- [ ] **P2.2 Claude cross-day snapshot resolution issues one SELECT (with LIKE) per event.**
  `ClaudeImportEngine.swift:523-529,604-623` still calls `storedClaudeEvents` for each parsed
  message that can have persisted history. Bounded for normal tail reads; multiplied across all
  history on a forced full read. Fix: batch-fetch the base/delta message ids once per file or
  persist pass and resolve them from an in-memory map.
- [ ] **P2.3 One write transaction per changed file (both engines).**
  The Codex loop calls `persist` per candidate and the Claude loop calls `persist` or
  `persistEmpty` per plan; each helper opens `database.pool.write`. This is pathological on first
  import and forced-re-read migrations: thousands of tiny serialized transactions. Fix: batch a
  bounded number of files per transaction on bulk paths while keeping per-file checkpoints.
- [x] **P2.4 `import_state` prune by `session_id` is unindexed.** Fixed by PR #138.
  Migration v18 adds the partial `idx_import_state_session_id` index used by alias pruning.
- [x] **P2.5 `seedCatalog` write transaction at the top of every Codex scan.** Fixed by PR #121.
  Catalog setup remains in database initialization and explicit pricing-catalog flows, not the
  steady scan path.
- [ ] **P2.6 `fetchSessions` aggregates all matching events before the page limit.**
  `AggregatorSessions.swift:27-82` computes lifetime totals with a join and `GROUP BY` before
  applying `LIMIT`. PR #129 reduced the requested page to 50 (+1 sentinel) and PR #134 debounces
  search, but the database still aggregates every matching session. Fix: maintain/materialize
  per-session totals, or select candidate session ids before joining when the chosen sort allows.
- [ ] **P2.7 `ActivityHeatmap` rebuilds its model on every hover.**
  `ActivityHeatmap.swift:106-109,276-336` keeps `hoveredCell` in `@State` and constructs
  `HeatmapModel(daily:calendar:)` in `body`, including threshold sorting and a month
  `DateFormatter`. PR #164 made the year layout responsive but left this dataflow unchanged.
  Fix: cache the model by `daily`/language/calendar inputs and keep hover state in a child view.
- [ ] **P2.8 `TrendsSection.activeSeries` recomputed 2–3× per body eval, per scrub frame.**
  `TrendsSection.swift:95,359-366,384,403-404` reads the computed series from chart,
  selection, and legend paths; the legend alone evaluates it twice. `.chartXSelection` causes
  repeated body work while scrubbing. Fix: derive one immutable series per body evaluation or
  cache `collapsedModelSeries` by breakdown/range/stack mode.
- [ ] **P2.9 Per-render formatter allocations in rows.**
  `QuotaRow.swift:116-120` and `SessionRowMetadataView.swift:53-58` build a fresh
  `RelativeDateTimeFormatter`; `CodexResetCreditsRow.swift:56-69` uses computed static vars that
  allocate each access. Fix: cache formatters by active language or use value-style formatting.
- [ ] **P2.10 Windowed model-share queries `GROUP BY model_id` without index support.**
  `AggregatorReports.swift:308-385` groups both lifetime and windowed reads by `model_id`.
  Current timestamp-leading covering indexes omit `model_id`, so matching index rows still need
  table lookups. The 30-day windows are bounded; lifetime is not. Fix only after `EXPLAIN QUERY
  PLAN` and representative measurement: consider a covering index beginning with timestamp
  (and provider for filtered views) that includes `model_id`, value, and tokens.
- [ ] **P2.11 Small singles.** `refreshDashboard` opens two read transactions
  (`AppEnvironment.swift:1320-1334`; fold `BillingBlocks` into `loadDashboard` or return both from
  one pool read); `fetchMonthly` retains per-month `Set<String>` values for every session id in
  the 12-month window; `sessions.parent_session_id`/`provider` remain unindexed (small table,
  only act if it grows); Codex reset credits still use a separate GET from the account/rate-limit
  pollers; `DeveloperFileLogger.append` still stats and open/seek/closes per record (developer
  mode only); launch intentionally requests a menu snapshot before the scan tail requests
  another, relying on coalescing; Claude cross-day bucketing still calls shared
  `ISO8601DateFormatter` parsing repeatedly in message loops.

## Verified healthy (checked; do not "fix")

- `LineReader` (`RolloutParser.swift:462-529`): raw-pointer newline scanning, documented 300×
  speedup — already optimal.
- mtime/size change detection skips unchanged files in both engines; Claude byte-offset
  incremental tail reads are correct and cheap in steady state.
- v16 covering indexes make History range queries index-only; History pagination is
  cursor-based (no OFFSET); `usage_events(session_id,timestamp)` covers persist deletes.
- `rate_limit_samples` retention pruning is bounded and runs inside existing write
  transactions; hydrator MAX-per-group reads stay cheap.
- Read paths use raw GRDB `Row` (no per-row Codable decode). `parseTimestamp` already uses the
  fast `ISO8601FormatStyle` strategy — the volume (P0.2), not the call, is the problem.
- Poller cadences match docs (300 s / 600 s) with correct 429/`Retry-After` backoff ladders,
  single-flighted token refresh, staggered boot; no retry storms. `DailyActiveReporter` is
  jittered, bounded, and generation-guarded.
- FSEvents watcher coalesces 2 s + 5 s scan throttle; `isScanning` re-entrancy guard and
  popover throttles (20 s/30 s) work as designed.
- Scans/parses/DB work run off the main actor; snapshot assignment hops back correctly.
- Swift Observation is property-granular: the single large `AppEnvironment` does **not**
  broadcast to unrelated views; `isRefreshingPricing` is correctly `@ObservationIgnored`.
- Sessions/History lists are virtualized (`List` / `LazyVStack`); no idle repeating timers in
  the App layer; DB pool pragmas (WAL, `synchronous=NORMAL`, `busy_timeout`, 3 readers) are
  sensible.
- Sparkle owns appcast fetch/parse on its own 24 h schedule — the known 612 KB appcast issue
  is feed size (server side), not client parse frequency.

## Suggested fix order

1. **Finish the bounded scan-progress win** — complete P1.2 with publication coalescing and a
   child observation boundary. PR #155 already removed the routine-render risk, so the
   remaining change can stay narrow and measurable.
2. **Remove repeated UI derivation** — P2.7 heatmap-model caching, then P2.8 Trends-series
   reuse. These have small correctness surfaces and direct interaction-level measurements.
3. **Cheap allocation cleanups** — cache launch-time QA configuration (P1.5) and row formatters
   (P2.9), preserving runtime language changes in the cache key.
4. **Measure before consolidating Dashboard reads** — benchmark P0.2 with a large, DST-spanning
   fixture; then combine compatible 365-day passes and fold P2.11's BillingBlocks read into the
   same transaction without changing provider/model semantics.
5. **Narrow broad scan work** — scope P0.4 metadata/tree reconciliation and move P1.1 fallback
   shell discovery off the main actor.
6. **Batch only with importer invariants locked down** — P2.1–P2.3, P2.6, and P2.10 should
   follow targeted contention/query-plan measurements rather than their priority labels alone.

Each fix should land with a measurement note (Instruments trace, `os_signpost`, or timed log
delta) against a realistic fixture — several months of history, an active multi-hundred-MB
rollout — so the win is demonstrated, not assumed.

## Document verification — 2026-08-09

- Synced the PR branch with `origin/main` at `797237d063ee5a6f292d1631cca3501b0dc953f5`.
- Re-read the current implementation for all 20 original findings, including each P2.11
  sub-item, and inspected the 25 commits added since the previous `90b48a3` refresh.
- Confirmed PR #155 changes the presentation side of P1.2 but not progress publication, and
  confirmed PR #164 changes heatmap layout without caching `HeatmapModel`.
- Recounted the matrix from the individual rows: 6 Delivered, 5 Partial, 9 Open.
- This PR changes documentation and changelog text only. Product runtime E2E is
  therefore not applicable; the appropriate gate is Markdown review, status/commit freshness,
  repository validation, and GitHub CI.
