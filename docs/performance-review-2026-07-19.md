# Performance review — 2026-07-19

Baseline commit: `87b99f5`. This document anchors the dedicated performance-optimization PR:
it records every finding from a full four-track audit (import/scan plane, storage/analytics
read side, background services, UI/main-actor), ranked by impact, each with file references,
cost analysis, and a fix direction. Code changes land in follow-up commits on this branch and
should check items off here. Line numbers are as of the baseline commit and will drift.

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

## P0 — cost scales with total history, hit constantly

### P0.1 `backfillAllValues()` re-prices the entire `usage_events` table on every changed-file scan

- [ ] Fixed
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

### P0.2 `loadDashboard` performs ~6 independent full-window scans, one of them unbounded

- [ ] Fixed
- **Where:** `Core/Analytics/AggregatorReports.swift:9-73`.
- **Problem:** one `pool.read` sequentially runs `fetchDaily(14)`, `fetchDaily(365)`,
  `fetchDailyBreakdown(.provider, 365)`, `fetchDailyBreakdown(.model, 365)`,
  `fetchMonthly(12)`, three `fetchModelShares` windows, and `fetchActivity` — which has **no
  timestamp bound at all** (`Core/Analytics/AggregatorActivity.swift:61-65`) and pulls the
  entire lifetime table into memory to compute a scalar lifetime sum, a peak day, and streaks.
  Each pass materializes GRDB `Row`s and buckets client-side with `parseTimestamp` +
  `Calendar.startOfDay` per row. `fetchDaily(14)` is a strict subset of `fetchDaily(365)`;
  the two breakdown calls scan the identical 365-day rows twice.
- **Impact:** ≈1.5 M date parses + 1.5 M `startOfDay` calls + 1.5 M row materializations per
  dashboard refresh at 300 k events — seconds of CPU, holding 1 of only 3 reader connections.
  `fetchActivity` grows without bound as history accumulates. Triggered on dashboard open,
  every price edit, provider-filter change, and scan completion while the dashboard is open.
- **Fix direction:** fetch the 365-day window **once**, bucket in a single pass, derive
  daily(14)/daily(365)/both breakdowns/monthly from it. Push `fetchActivity`'s lifetime sum
  and peak day into SQL aggregates; fetch only distinct active-day markers for streaks; feed
  the heatmap from the shared 365-day pass. (Client-side `Calendar` bucketing itself stays —
  it is the DST-correctness convention; the problem is doing it five times.)

### P0.3 Codex re-parses the whole rollout file for any grown file

- [ ] Fixed
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

### P0.4 `reconcileSessionTree` + metadata backfill walk **all** Codex sessions on every scan, even with zero changed files

- [ ] Fixed
- **Where:** `ImportEngine.swift:183` (unconditional call; impl `:443-473`) issues **one UPDATE
  per Codex session** regardless of whether anything changed; `backfillCodexSessionMetadata`
  (`:101`, impl `:225-268`) reads every Codex session row each scan;
  `CodexSessionMetadataStore.load` (`:97`, impl `CodexSessionMetadataStore.swift:18-33,215-231`)
  slurps `session_index.jsonl` line-by-line through `JSONSerialization` and opens Codex's
  `state_5.sqlite` each scan.
- **Impact:** thousands of sessions → thousands of UPDATEs inside a write transaction on every
  menu-bar open, plus a full external-file re-parse, when usually nothing changed.
- **Fix direction:** skip all three when `changed.isEmpty`; when files did change, reconcile
  only the affected parent chains and gate the metadata store on an mtime check.

## P1 — significant, bounded or less frequent

### P1.1 Launch: synchronous login-shell spawn on the main thread

- [ ] Fixed
- **Where:** `Core/AppServer/AppServerClient.swift:43-56` — `init` → `resolveBinary()` →
  `discoverViaLoginShell()` (`:98-117`) runs `$SHELL -ilc "command -v codex"` with
  `process.waitUntilExit()`. `AppEnvironment.shared` (and thus the default `AppServerClient()`)
  is first constructed on the main thread in `applicationDidFinishLaunching`.
- **Impact:** an interactive login shell sources the full rc chain (nvm/conda/oh-my-zsh):
  150–400 ms typical, 1–2 s on heavy dotfiles, as a hard main-thread stall before first frame.
  `discoverViaLoginShell()` is evaluated eagerly as a call argument, so it runs even when the
  `CODEX_BINARY` override would short-circuit. Separately, `loginShellPATH`
  (`:131-155`) and `ClaudeCodeVersionDetector` (`Core/Claude/ClaudeUsageClient.swift:1043-1109`)
  each spawn their own login shell — 3–4 spawns clustered at launch.
- **Fix direction:** resolve the binary lazily/async off-main; compute the login-shell PATH
  once and share it across AppServer + Claude detection; short-circuit before spawning when
  the override or a hardcoded candidate hits.

### P1.2 Scan progress re-renders the entire popover once per file

- [ ] Fixed
- **Where:** importer progress callback hops to the main actor per file
  (`App/ScanController.swift:144-147`) and reassigns `scanProgress`
  (`:366-384`); `Features/MenuBar/ScanStatusView.swift:9` reads it, and it is spliced directly
  into `MenuBarContentView.body` (`Features/MenuBar/MenuBarContentView.swift:86`) — making it
  a body-level dependency of the whole popover (all quota rows, formatters, buttons).
- **Impact:** dozens–hundreds of full-popover re-evals per scan; on cold-start imports,
  thousands. The popover's `NSHostingController` is retained for process lifetime
  (`App/StatusItemController.swift:56`); if AppKit keeps the hosted tree live while the popover
  is closed, these re-renders also run invisibly during background watcher scans (needs an
  Instruments confirmation pass — treat as plausible until measured).
- **Fix direction:** move scan status into its own child view that independently reads
  `env.scanProgress` so only it invalidates; coalesce progress publication to ~10 Hz.

### P1.3 Menu-bar label rebuilds with no equality short-circuit, and over-subscribes to `dashboardSnapshot`

- [ ] Fixed
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

- [ ] Fixed
- **Where:** `Core/Importer/RolloutEvent.swift:242` (allocated before the `switch`,
  unconditionally per line); `:343` allocates another for any escaped string literal.
- **Impact:** the dominant `response_item` lines never touch the decoder — pure per-line
  allocation waste, hundreds of thousands of times per large-rollout re-parse; multiplies P0.3.
- **Fix direction:** construct the decoder only in branches that decode a payload, or reuse one.

### P1.5 Logging/QA-config hot path copies the whole process environment per call

- [ ] Fixed
- **Where:** `DeveloperLog.eventRecord` guards on `SettingsStore.developerModeEnabledNonisolated`
  (`Core/DeveloperFileLogger.swift:351`, `Core/Settings/SettingsStore.swift:640-643`), which
  calls `LocalQAEnvironment.userDefaults()` — and `App/LocalQAEnvironment.swift:25-63,100-119,170-175`
  caches nothing: each access snapshots `ProcessInfo.processInfo.environment` (fresh dictionary)
  and `isQARequested` scans every env key. `SettingsStore.snapshot()` and
  `allowsExternalDataSources()` pay the same cost per poll.
- **Impact:** modest per call but multiplied by log volume — every `eventRecord` on every hot
  path (including the per-file scan progress events) pays an env snapshot just to discard the
  record when dev mode is off.
- **Fix direction:** the QA configuration cannot change at runtime — resolve it once into a
  `static let`; gate `eventRecord` on a cached bool.

## P2 — bounded, spiky, or cheap-to-fix

- [ ] **P2.1 Keychain read busy-waits on the actor.**
  `Core/Claude/ClaudeUsageClient.swift:781-826` polls `process.isRunning` with
  `Thread.sleep(0.05)` up to 2 s inside an actor method — blocks a cooperative-pool thread and
  serializes the client (a concurrent manual Refresh waits). Usually once per run; recurs per
  poll on file-less machines. Fix: async pipe read / `Task.detached` + continuation.
- [ ] **P2.2 Claude cross-day snapshot resolution issues one SELECT (with LIKE) per event.**
  `Core/Importer/ClaudeImportEngine.swift:502-598`. Bounded for normal tail reads; per-event
  across all history on forced full re-reads (migrations v6/v7/v8/v12). Fix: batch-fetch
  message ids once per pass.
- [ ] **P2.3 One write transaction per changed file (both engines).**
  `ImportEngine.swift:159`, `ClaudeImportEngine.swift:219`. Pathological on first import /
  forced-re-read migrations: thousands of tiny serialized transactions. Fix: batch N files per
  transaction on the bulk path.
- [ ] **P2.4 `import_state` prune by `session_id` is unindexed.**
  `ImportEngine.swift:423-426`; table has only the `source_path` PK
  (`Core/Storage/Migrations.swift:46-52`). Full `import_state` scan per changed Codex file.
  Fix: add index on `import_state(session_id)`.
- [ ] **P2.5 `seedCatalog` write transaction at the top of every Codex scan.**
  `ImportEngine.swift:64-68`, already seeded in `DatabaseManager` init. Small but an
  unnecessary write-lock acquisition per scan. Fix: seed once per launch.
- [ ] **P2.6 `fetchSessions` aggregates all events before `LIMIT 500`.**
  `Core/Analytics/AggregatorSessions.swift:19-66` — lifetime per-session totals force a full
  join+GROUP BY per Sessions-tab load/search keystroke (debounced 200 ms). Fix: materialize
  per-session totals at import time.
- [ ] **P2.7 `ActivityHeatmap` rebuilds its model on every hover.**
  `Features/Dashboard/Sections/ActivityHeatmap.swift:74,153-161` — `hoveredCell` is `@State`,
  so each pointer move re-runs body → rebuilds `HeatmapModel` (sort + `DateFormatter` alloc at
  `:254`) over ~365 days. Fix: derive the model once per `daily` change; hover in a child view.
- [ ] **P2.8 `TrendsSection.activeSeries` recomputed 2–3× per body eval, per scrub frame.**
  `Features/Dashboard/Sections/TrendsSection.swift:223-231,248,266,84`;
  `.chartXSelection` (`:127`) re-evals body per pointer move. Fix: bind it once per body /
  memoize `collapsedModelSeries` on (stackBy, range).
- [ ] **P2.9 Per-render formatter allocations in rows.**
  `Features/MenuBar/QuotaRow.swift:116-121` and
  `Features/Sessions/SessionRowMetadataView.swift:53-59` build a fresh
  `RelativeDateTimeFormatter` per row per render;
  `Features/MenuBar/CodexResetCreditsRow.swift:56-70` declares formatters as **computed**
  `static var` — every access allocates. Fix: `static let` caches keyed by active language.
- [ ] **P2.10 Windowed model-share queries `GROUP BY model_id` without index support.**
  `AggregatorReports.swift:297-376` — covering index lacks `model_id`, so each matching row
  bounces to the table. 30-day windows are bounded; lifetime variant is a full scan. Fix
  (optional): index `(timestamp, model_id, value_usd, total_tokens)`.
- [ ] **P2.11 Small singles.** `refreshDashboard` opens two read transactions
  (`App/AppEnvironment.swift:1266,1275-1277` — fold `BillingBlocks` into `loadDashboard`);
  `fetchMonthly` retains a `Set<String>` of all session ids across 12 months
  (`AggregatorReports.swift:272-282`); `sessions.parent_session_id`/`provider` unindexed
  (small table, only if it grows); Codex reset-credits GET wakes the network separately from
  the poller (`AppEnvironment.swift:346-348`); `DeveloperFileLogger.append` open/seek/close +
  stat per record (`DeveloperFileLogger.swift:224-246`, dev-mode only); launch refresh fan-out
  queues one redundant menu-bar refresh (absorbed by coalescing);
  `ISO8601DateFormatter.date(from:)` (two-attempt slow parse) in `ClaudeRolloutParser`
  day-bucketing loops (`ClaudeImportEngine.swift:931-1012`).

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

1. **Quick wins, big wins** — P0.1 (scope the backfill), P0.4 (guard the per-scan walks),
   P1.3 (label short-circuit), P1.4 (decoder hoist), P2.4/P2.5 (index + seed gate).
2. **Read-side consolidation** — P0.2 (single-pass dashboard + bounded activity), P2.11's
   read-transaction merge alongside it.
3. **Launch + UI responsiveness** — P1.1 (async binary resolution), P1.2 (progress
   throttle/isolation), P2.7–P2.9.
4. **The big one** — P0.3 (Codex incremental tail parsing), with P2.2/P2.3 batched into the
   same importer work.

Each fix should land with a measurement note (Instruments trace, `os_signpost`, or timed log
delta) against a realistic fixture — several months of history, an active multi-hundred-MB
rollout — so the win is demonstrated, not assumed.
