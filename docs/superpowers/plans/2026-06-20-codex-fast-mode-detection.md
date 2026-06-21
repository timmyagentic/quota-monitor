# Codex Fast Mode Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect Codex Fast/Priority usage per turn, persist it on `usage_events`, price only confirmed/fallback Fast rows at Fast rates, and show Standard/Fast/Unknown splits without changing token delta totals.

**Architecture:** Read Codex request traces from `logs_2.sqlite` in read-only mode and build a `turn_id -> billing tier` map. `RolloutParser` keeps its existing token-delta algorithm, only adding the current turn id and tier classification to each `UsageDelta`; pricing then chooses the base or synthetic `*-fast` catalog row from the stored event tier.

**Tech Stack:** Swift 6, SwiftPM, GRDB, SQLite3 C API, Swift Testing, existing QuotaMonitor importer/pricing/aggregator layers.

---

## Non-Negotiable Billing Invariants

- Token counts must not change: for any fixture, `SUM(total_tokens)`, per-event deltas, input/cached/output/reasoning buckets must match the current parser unless Codex source data itself changed.
- Fast must only be assigned from an explicit trace value: `service_tier = fast` or `service_tier = priority`, including `preferred_service_tier`.
- Match Agent Signal Bar's priority-set semantics: with a readable trace DB, turns without a Fast/Priority request trace are Standard; only trace DB unavailability, missing turn id, or unsupported explicit tiers stay Unknown.
- Existing `codexFastModeBilling` remains as a compatibility fallback, but only for `unknown` Codex rows. It must not override rows explicitly classified as `standard`.
- Do not persist or display `feedback_log_body`. It can contain request details; parse it in memory and discard it.
- Any migration that can change historical dollar values must force a Codex reimport and then run value backfill.

## File Map

- Create `QuotaMonitor/Core/Importer/CodexBillingTier.swift`
  Defines `CodexBillingTier`, `CodexBillingTierSource`, and lookup helpers shared by parser/importer/pricing UI.
- Create `QuotaMonitor/Core/Importer/CodexServiceTierTraceStore.swift`
  Opens `logs_2.sqlite` read-only, queries a bounded time window, parses trace bodies into turn-tier metadata.
- Modify `QuotaMonitor/Core/Importer/RolloutEvent.swift`
  Decode `turn_id` / `turnId` from `turn_context`.
- Modify `QuotaMonitor/Core/Importer/RolloutParser.swift`
  Track `currentTurnId`; attach `turnId`, `billingTier`, and `billingTierSource` to `UsageDelta`.
- Modify `QuotaMonitor/Core/Importer/ImportEngine.swift`
  Load the trace lookup once per scan, pass it into the parser, and persist new usage-event columns.
- Modify `QuotaMonitor/Core/Storage/Migrations.swift`
  Add `turn_id`, `billing_tier`, `billing_tier_source`; force Codex reimport.
- Modify `QuotaMonitor/Core/Storage/Records.swift`
  Add stored fields to `UsageEventRecord`.
- Modify `QuotaMonitor/Core/Pricing/PricingService.swift`
  Route event-level Fast rows to `*-fast`; use the existing setting only for `unknown`.
- Modify `QuotaMonitor/Core/Analytics/Aggregator.swift`, `AggregatorReports.swift`, `AggregatorSessions.swift`, `AggregatorHistory.swift`
  Add tier split fields to `ModelShare` and event detail queries.
- Modify `QuotaMonitor/Features/Sessions/SessionDetailView.swift`, `QuotaMonitor/Features/History/HistoryView.swift`
  Surface Standard/Fast/Unknown split.
- Modify `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`, `QuotaMonitor/Core/Localization/L10n.swift`
  Reword the Fast setting as a fallback for unclassified events.
- Modify `QuotaMonitor/App/ScanController.swift`
  Export `turn_id`, `billing_tier`, and `billing_tier_source` in CSV.
- Create tests:
  - `Tests/QuotaMonitorTests/CodexServiceTierTraceStoreTests.swift`
  - Extend `Tests/QuotaMonitorTests/RolloutParserTests.swift`
  - Extend `Tests/QuotaMonitorTests/PricingValueBackfillTests.swift`
  - Extend `Tests/QuotaMonitorTests/AggregatorTests.swift`
  - Extend `Tests/QuotaMonitorTests/MigrationsTests.swift`

## Data Model

Use three stored tiers:

```swift
enum CodexBillingTier: String, Codable, Sendable {
    case standard
    case fast
    case unknown
}
```

Use source metadata to explain confidence:

```swift
enum CodexBillingTierSource: String, Codable, Sendable {
    case trace
    case missingTurnID = "missing_turn_id"
    case traceUnavailable = "trace_unavailable"
    case traceMissing = "trace_missing"
    case legacy
    case notCodex = "not_codex"
}
```

Classification rules:

| Condition | Stored tier | Source |
| --- | --- | --- |
| Request trace has `service_tier` or `preferred_service_tier` equal to `fast` or `priority` | `fast` | `trace` |
| Request trace exists for the turn and tier is anything else, such as `standard`, `auto`, or `flex` | `standard` | `trace` |
| Parser has no current turn id | `unknown` | `missing_turn_id` |
| Trace DB missing or unreadable | `unknown` | `trace_unavailable` |
| Trace DB read succeeds but no matching Fast/Priority request trace exists | `standard` | `trace` |
| Non-Codex rows | `unknown` | `not_codex` |
| Pre-migration rows before reimport | `unknown` | `legacy` |

## Task 1: Add Billing Tier Domain Types

**Files:**
- Create: `QuotaMonitor/Core/Importer/CodexBillingTier.swift`

- [ ] **Step 1: Add the domain file**

```swift
import Foundation

enum CodexBillingTier: String, Codable, Sendable {
    case standard
    case fast
    case unknown
}

enum CodexBillingTierSource: String, Codable, Sendable {
    case trace
    case missingTurnID = "missing_turn_id"
    case traceUnavailable = "trace_unavailable"
    case traceMissing = "trace_missing"
    case legacy
    case notCodex = "not_codex"
}

struct CodexTurnBillingTrace: Sendable, Equatable {
    let tier: CodexBillingTier
    let modelId: String?
    let timestamp: Date?
}

struct CodexTurnBillingLookup: Sendable {
    let available: Bool
    let tracesByTurnID: [String: CodexTurnBillingTrace]

    static let unavailable = CodexTurnBillingLookup(
        available: false,
        tracesByTurnID: [:])

    func classify(turnID: String?) -> (tier: CodexBillingTier, source: CodexBillingTierSource) {
        guard available else { return (.unknown, .traceUnavailable) }
        guard let turnID, !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.unknown, .missingTurnID) }
        guard let trace = tracesByTurnID[turnID] else { return (.unknown, .traceMissing) }
        return (trace.tier, .trace)
    }
}
```

- [ ] **Step 2: Run focused compile check**

Run:

```bash
swift test --disable-keychain --filter RolloutParserTests/deltaComputationFromCumulativeCounters
```

Expected: compile succeeds and the existing parser test still passes. This file should not change behavior yet.

## Task 2: Implement `logs_2.sqlite` Trace Reader

**Files:**
- Create: `QuotaMonitor/Core/Importer/CodexServiceTierTraceStore.swift`
- Test: `Tests/QuotaMonitorTests/CodexServiceTierTraceStoreTests.swift`

- [ ] **Step 1: Write the failing trace-store tests**

Create `Tests/QuotaMonitorTests/CodexServiceTierTraceStoreTests.swift` with tests covering:

```swift
@Test("service_tier priority and fast classify as Fast")
func priorityAndFastClassifyAsFast() throws {
    let db = try makeTraceDatabase(rows: [
        traceRow(turnID: "turn-priority", serviceTier: "priority"),
        traceRow(turnID: "turn-fast", serviceTier: "fast")
    ])

    let lookup = try CodexServiceTierTraceStore(databaseURL: db)
        .loadLookup(start: Date(timeIntervalSince1970: 1_781_755_000),
                    end: Date(timeIntervalSince1970: 1_781_756_000))

    #expect(lookup.available)
    #expect(lookup.tracesByTurnID["turn-priority"]?.tier == .fast)
    #expect(lookup.tracesByTurnID["turn-fast"]?.tier == .fast)
}

@Test("non-fast service tiers classify as Standard only when a trace exists")
func explicitNonFastTraceClassifiesAsStandard() throws {
    let db = try makeTraceDatabase(rows: [
        traceRow(turnID: "turn-standard", serviceTier: "standard"),
        traceRow(turnID: "turn-flex", serviceTier: "flex")
    ])

    let lookup = try CodexServiceTierTraceStore(databaseURL: db)
        .loadLookup(start: Date(timeIntervalSince1970: 1_781_755_000),
                    end: Date(timeIntervalSince1970: 1_781_756_000))

    #expect(lookup.tracesByTurnID["turn-standard"]?.tier == .standard)
    #expect(lookup.tracesByTurnID["turn-flex"]?.tier == .standard)
    #expect(lookup.classify(turnID: "missing").tier == .unknown)
    #expect(lookup.classify(turnID: "missing").tier == .standard)
}
```

The helper must create this schema, matching the real Codex DB:

```sql
CREATE TABLE logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    ts_nanos INTEGER NOT NULL,
    level TEXT NOT NULL,
    target TEXT NOT NULL,
    feedback_log_body TEXT,
    module_path TEXT,
    file TEXT,
    line INTEGER,
    thread_id TEXT,
    process_uuid TEXT,
    estimated_bytes INTEGER NOT NULL DEFAULT 0
);
```

Use trace bodies shaped like:

```text
session_loop:turn{turn.id=turn-fast model=gpt-5.5}:run_sampling_request websocket request:{"type":"response.create","service_tier":"fast","model":"gpt-5.5","turn_id":"turn-fast"}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --disable-keychain --filter CodexServiceTierTraceStoreTests
```

Expected: compile fails because `CodexServiceTierTraceStore` does not exist.

- [ ] **Step 3: Implement the store**

Implementation requirements:

```swift
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

struct CodexServiceTierTraceStore: Sendable {
    let databaseURL: URL

    static func defaultDatabaseURL(codexHome: URL) -> URL? {
        let primary = codexHome.appendingPathComponent("logs_2.sqlite")
        let fallback = codexHome
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite")
        let fm = FileManager.default
        if fm.fileExists(atPath: primary.path) { return primary }
        if fm.fileExists(atPath: fallback.path) { return fallback }
        return nil
    }

    func loadLookup(start: Date, end: Date) throws -> CodexTurnBillingLookup {
        #if canImport(SQLite3)
        // Open SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX.
        // Query only ts range and rows whose feedback_log_body contains service_tier.
        // Parse websocket request JSON and discard the body immediately.
        #else
        return .unavailable
        #endif
    }
}
```

SQL shape:

```sql
SELECT ts, ts_nanos, feedback_log_body
FROM logs
WHERE ts >= ? AND ts < ?
  AND feedback_log_body IS NOT NULL
  AND feedback_log_body LIKE '%service_tier%'
ORDER BY ts ASC, ts_nanos ASC, id ASC
```

Parsing rules:

```swift
private func tier(from value: String?) -> CodexBillingTier? {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "fast", "priority": return .fast
    case "standard", "auto", "flex": return .standard
    default: return nil
    }
}
```

Extract turn id from the prefix first (`turn.id=`, `turn_id=`, `turnId=`), then fallback to JSON keys `turn_id` and `turnId`.

- [ ] **Step 4: Run focused trace-store tests**

Run:

```bash
swift test --disable-keychain --filter CodexServiceTierTraceStoreTests
```

Expected: all trace-store tests pass.

## Task 3: Decode Turn IDs and Preserve Token Deltas

**Files:**
- Modify: `QuotaMonitor/Core/Importer/RolloutEvent.swift`
- Modify: `QuotaMonitor/Core/Importer/RolloutParser.swift`
- Test: `Tests/QuotaMonitorTests/RolloutParserTests.swift`

- [ ] **Step 1: Add failing parser tests**

Append tests that prove classification does not alter token math:

```swift
@Test("turn_id tags token deltas with Fast tier without changing token totals")
func turnIDTagsFastTierWithoutChangingTokenTotals() throws {
    let url = try writeRollout(#"""
    {"timestamp":"2026-06-18T08:00:00.000Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-06-18T08:00:00.000Z","cwd":"/tmp/project"}}
    {"timestamp":"2026-06-18T08:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5","turn_id":"turn-fast"}}
    {"timestamp":"2026-06-18T08:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100}}}}
    """# + "\n")
    let lookup = CodexTurnBillingLookup(available: true, tracesByTurnID: [
        "turn-fast": CodexTurnBillingTrace(tier: .fast, modelId: "gpt-5.5", timestamp: nil)
    ])

    let parsed = try #require(try RolloutParser.parse(
        fileURL: url,
        billingLookup: lookup))

    #expect(parsed.usageDeltas.map(\.totalTokens) == [1100])
    #expect(parsed.usageDeltas[0].turnId == "turn-fast")
    #expect(parsed.usageDeltas[0].billingTier == .fast)
    #expect(parsed.usageDeltas[0].billingTierSource == .trace)
}
```

Add a second test where lookup is available but no trace exists:

```swift
#expect(parsed.usageDeltas[0].billingTier == .unknown)
#expect(parsed.usageDeltas[0].billingTierSource == .traceMissing)
```

- [ ] **Step 2: Run parser tests to verify failure**

Run:

```bash
swift test --disable-keychain --filter RolloutParserTests/turnID
```

Expected: compile fails because parser signature and `UsageDelta` fields do not exist yet.

- [ ] **Step 3: Extend event and parser models**

Update `TurnContextPayload`:

```swift
struct TurnContextPayload: Decodable {
    let model: String?
    let turnId: String?

    enum CodingKeys: String, CodingKey {
        case model
        case turnId = "turn_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
            ?? c.decodeIfPresent(String.self, forKey: DynamicCodingKey("turnId"))
    }
}
```

If the existing decoder cannot use a dynamic key helper cleanly, add `turnIdCamel` to `CodingKeys` and map it.

Update `UsageDelta`:

```swift
let turnId: String?
let billingTier: CodexBillingTier
let billingTierSource: CodexBillingTierSource
```

Update parser signature:

```swift
static func parse(
    fileURL: URL,
    fallbackSessionId: String? = nil,
    billingLookup: CodexTurnBillingLookup = .unavailable
) throws -> ParsedSession?
```

Track `currentTurnId` on `.turnContext`, then classify right before appending each delta.

- [ ] **Step 4: Run parser tests**

Run:

```bash
swift test --disable-keychain --filter RolloutParserTests
```

Expected: parser tests pass and existing `usageDeltas.map(\.totalTokens)` expectations remain unchanged.

## Task 4: Add Schema Columns and Force Codex Reimport

**Files:**
- Modify: `QuotaMonitor/Core/Storage/Migrations.swift`
- Modify: `QuotaMonitor/Core/Storage/Records.swift`
- Test: `Tests/QuotaMonitorTests/MigrationsTests.swift`

- [ ] **Step 1: Add failing migration test**

Add a test that initializes a fresh DB and checks:

```sql
PRAGMA table_info(usage_events);
```

Expected columns:

```text
turn_id
billing_tier
billing_tier_source
```

Also insert a minimal legacy-shaped `usage_events` row without the new columns and assert defaults:

```swift
#expect(row["billing_tier"] as String == "unknown")
#expect(row["billing_tier_source"] as String == "legacy")
```

- [ ] **Step 2: Run migration test to verify failure**

Run:

```bash
swift test --disable-keychain --filter MigrationsTests
```

Expected: the new column test fails.

- [ ] **Step 3: Add migration**

Append a new migration after the current latest migration:

```swift
migrator.registerMigration("v12-codex-billing-tier") { db in
    try db.alter(table: "usage_events") { t in
        t.add(column: "turn_id", .text)
        t.add(column: "billing_tier", .text)
            .notNull().defaults(to: CodexBillingTier.unknown.rawValue)
        t.add(column: "billing_tier_source", .text)
            .notNull().defaults(to: CodexBillingTierSource.legacy.rawValue)
    }
    try db.create(
        indexOn: "usage_events",
        columns: ["provider", "billing_tier", "timestamp"])
    try db.execute(sql: """
        UPDATE import_state
        SET file_size = -1,
            file_mtime_ms = -1,
            byte_offset = 0
        WHERE session_id IN (
            SELECT session_id FROM sessions WHERE provider = 'codex'
        )
           OR source_path LIKE '%/.codex/sessions/%'
           OR source_path LIKE '%/.codex/archived_sessions/%'
        """)
}
```

Update `UsageEventRecord` with `turnId`, `billingTier`, and `billingTierSource` coding keys.

- [ ] **Step 4: Run migration tests**

Run:

```bash
swift test --disable-keychain --filter MigrationsTests
```

Expected: migration tests pass.

## Task 5: Wire ImportEngine to Trace Lookup and Persistence

**Files:**
- Modify: `QuotaMonitor/Core/Importer/ImportEngine.swift`
- Test: create or extend importer-focused tests in `Tests/QuotaMonitorTests/CodexServiceTierTraceStoreTests.swift`

- [ ] **Step 1: Add import integration test**

Create a temp `codexHome` with:

```text
.codex/
  logs_2.sqlite
  sessions/2026/06/18/rollout-test.jsonl
```

JSONL contains one Fast `turn_id` and one untraced turn. The SQLite trace contains only the Fast turn. Run `ImportEngine.performScan()` and assert:

```sql
SELECT turn_id, billing_tier, billing_tier_source, total_tokens
FROM usage_events
ORDER BY timestamp ASC, id ASC;
```

Expected rows:

```text
turn-fast | fast    | trace         | 1100
turn-miss | standard | trace | 550
```

- [ ] **Step 2: Run integration test to verify failure**

Run:

```bash
swift test --disable-keychain --filter CodexServiceTierTraceStoreTests/importEnginePersistsBillingTier
```

Expected: fails because `ImportEngine` does not load or persist tier fields.

- [ ] **Step 3: Load lookup once per scan**

In `performScan()`, after `changed` is computed, derive a bounded scan window from changed file paths and mtimes:

```swift
let traceLookup = loadCodexBillingLookup(for: changed)
```

Rules:

- If no changed files: use `.unavailable` and do no SQLite work.
- If no trace DB exists: use `.unavailable`.
- Start bound: earliest changed file mtime minus 24 hours.
- End bound: latest changed file mtime plus 24 hours.
- If the trace store throws: use `.unavailable` and continue import rather than failing the scan.

Pass lookup into parser:

```swift
try RolloutParser.parse(
    fileURL: file.url,
    fallbackSessionId: file.sessionIdHint,
    billingLookup: traceLookup)
```

Persist fields:

```swift
turnId: delta.turnId,
billingTier: delta.billingTier.rawValue,
billingTierSource: delta.billingTierSource.rawValue
```

- [ ] **Step 4: Run integration test**

Run:

```bash
swift test --disable-keychain --filter CodexServiceTierTraceStoreTests/importEnginePersistsBillingTier
```

Expected: pass.

## Task 6: Change Pricing Without Breaking Existing Fallback Semantics

**Files:**
- Modify: `QuotaMonitor/Core/Pricing/PricingService.swift`
- Test: `Tests/QuotaMonitorTests/PricingValueBackfillTests.swift`

- [ ] **Step 1: Add failing pricing tests**

Add four Codex tests:

```swift
@Test("event-level Fast prices as fast even when global fallback is off")
func eventLevelFastPricesAsFastWithFallbackOff() throws

@Test("explicit Standard remains standard even when global fallback is on")
func explicitStandardIgnoresGlobalFallback() throws

@Test("unknown uses standard when global fallback is off")
func unknownUsesStandardWhenFallbackOff() throws

@Test("unknown uses fast when global fallback is on")
func unknownUsesFastWhenFallbackOn() throws
```

Each test should seed `gpt-5.5` at `$35.00` per 1M input + 1M output and `gpt-5.5-fast` at `$87.50`, then assert exact values.

- [ ] **Step 2: Run pricing tests to verify failure**

Run:

```bash
swift test --disable-keychain --filter PricingValueBackfillTests/codex
```

Expected: event-level tests fail because SQL still only uses the global toggle.

- [ ] **Step 3: Update effective model SQL**

Change the CASE logic to:

```sql
CASE
  WHEN usage_events.provider = 'codex'
       AND usage_events.model_id IN (...)
       AND (
         usage_events.billing_tier = 'fast'
         OR (
           usage_events.billing_tier = 'unknown'
           AND <codexFastModeBilling is true>
         )
       )
  THEN usage_events.model_id || '-fast'
  ELSE usage_events.model_id
END
```

When `codexFastModeBilling` is false, omit the fallback branch but still honor `billing_tier = 'fast'`.

- [ ] **Step 4: Run pricing tests**

Run:

```bash
swift test --disable-keychain --filter PricingValueBackfillTests
```

Expected: all pricing tests pass, including Claude untouched and unlisted model tests.

## Task 7: Add Aggregation Splits

**Files:**
- Modify: `QuotaMonitor/Core/Analytics/Aggregator.swift`
- Modify: `QuotaMonitor/Core/Analytics/AggregatorReports.swift`
- Modify: `QuotaMonitor/Core/Analytics/AggregatorSessions.swift`
- Modify: `QuotaMonitor/Core/Analytics/AggregatorHistory.swift`
- Test: `Tests/QuotaMonitorTests/AggregatorTests.swift`

- [ ] **Step 1: Add failing aggregator test**

Seed one model with three rows:

```text
standard: $35.00, 100 tokens
fast:     $87.50, 200 tokens
unknown: $35.00, 300 tokens
```

Assert `fetchModelShares` returns:

```swift
#expect(share.valueUSD == 157.50)
#expect(share.tokens == 600)
#expect(share.standardValueUSD == 35.00)
#expect(share.fastValueUSD == 87.50)
#expect(share.unknownValueUSD == 35.00)
#expect(share.standardTokens == 100)
#expect(share.fastTokens == 200)
#expect(share.unknownTokens == 300)
```

- [ ] **Step 2: Run aggregator test to verify failure**

Run:

```bash
swift test --disable-keychain --filter AggregatorTests/modelSharesIncludeBillingTierBreakdown
```

Expected: compile fails because `ModelShare` lacks split fields.

- [ ] **Step 3: Extend `ModelShare`**

Add fields with defaults only at construction sites if needed:

```swift
let standardValueUSD: Double
let fastValueUSD: Double
let unknownValueUSD: Double
let standardTokens: Int64
let fastTokens: Int64
let unknownTokens: Int64
```

Update every model-share query with:

```sql
SUM(CASE WHEN ue.billing_tier = 'standard' THEN ue.value_usd ELSE 0 END) AS standard_value_usd,
SUM(CASE WHEN ue.billing_tier = 'fast' THEN ue.value_usd ELSE 0 END) AS fast_value_usd,
SUM(CASE WHEN ue.billing_tier = 'unknown' THEN ue.value_usd ELSE 0 END) AS unknown_value_usd,
SUM(CASE WHEN ue.billing_tier = 'standard' THEN ue.total_tokens ELSE 0 END) AS standard_tokens,
SUM(CASE WHEN ue.billing_tier = 'fast' THEN ue.total_tokens ELSE 0 END) AS fast_tokens,
SUM(CASE WHEN ue.billing_tier = 'unknown' THEN ue.total_tokens ELSE 0 END) AS unknown_tokens
```

- [ ] **Step 4: Include tier on event detail rows**

Add to `SessionDetail.Event`:

```swift
let turnId: String?
let billingTier: CodexBillingTier
let billingTierSource: CodexBillingTierSource
```

Decode from SQL with raw-value fallbacks:

```swift
CodexBillingTier(rawValue: row["billing_tier"] ?? "") ?? .unknown
CodexBillingTierSource(rawValue: row["billing_tier_source"] ?? "") ?? .legacy
```

- [ ] **Step 5: Run aggregator tests**

Run:

```bash
swift test --disable-keychain --filter AggregatorTests
```

Expected: pass.

## Task 8: Surface the Splits in UI and Settings Copy

**Files:**
- Modify: `QuotaMonitor/Features/Sessions/SessionDetailView.swift`
- Modify: `QuotaMonitor/Features/History/HistoryView.swift`
- Modify: `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`

- [ ] **Step 1: Update model breakdown text**

For each model row, add a secondary caption only when at least one split is non-zero:

```swift
Text(tierBreakdownText(share))
    .font(.caption2)
    .foregroundStyle(.secondary)
```

Formatting rule:

```text
Fast 200 tokens / $87.50 · Standard 100 tokens / $35.00 · Unknown 300 tokens / $35.00
```

Hide zero pieces.

- [ ] **Step 2: Add event-level badge**

In session event rows, show:

```swift
Fast
Standard
Unknown
```

Use `Fast` only for `billingTier == .fast`; use `Unknown` when unclassified.

- [ ] **Step 3: Reword setting**

Keep the storage key `settings.codexFastModeBilling`, but change label/help:

```swift
t(en: "Bill unclassified Codex as Fast Mode",
  zh: "未识别的 Codex 按 Fast Mode 计费")
```

Help copy:

```swift
t(en: "QuotaMonitor now detects Fast usage from local Codex traces when possible. This fallback only affects Codex events whose tier could not be identified.",
  zh: "QuotaMonitor 会尽量从本地 Codex trace 识别 Fast 用量。这个兜底开关只影响无法识别档位的 Codex 事件。")
```

- [ ] **Step 4: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

## Task 9: Export New Columns

**Files:**
- Modify: `QuotaMonitor/App/ScanController.swift`
- Test: extend an export or source-level test if one exists; otherwise verify with focused manual export.

- [ ] **Step 1: Add columns to CSV SQL and header**

Select:

```sql
ue.turn_id,
ue.billing_tier,
ue.billing_tier_source
```

Header:

```text
id,session_id,timestamp,model_id,turn_id,billing_tier,billing_tier_source,input,cached,output,reasoning,total,value_usd,title,agent
```

- [ ] **Step 2: Run build**

Run:

```bash
swift build
```

Expected: build succeeds.

## Task 10: Full Verification Gate

**Files:** none.

- [ ] **Step 1: Focused correctness tests**

Run:

```bash
swift test --disable-keychain --filter CodexServiceTierTraceStoreTests
swift test --disable-keychain --filter RolloutParserTests
swift test --disable-keychain --filter PricingValueBackfillTests
swift test --disable-keychain --filter AggregatorTests
swift test --disable-keychain --filter MigrationsTests
```

Expected: all pass.

- [ ] **Step 2: Full Swift test suite**

Run:

```bash
swift test --disable-keychain
```

Expected: all tests pass.

- [ ] **Step 3: Static QA gate**

Run:

```bash
./qa/run-static.sh
```

Expected: shell checks, Python checks, release-note checks, Swift build, and Swift tests pass.

- [ ] **Step 4: Real-data shadow check**

Use a QA home, not the production app database:

```bash
QM_QA_SOURCE_HOME="$HOME" ./qa/prepare-computer-use-real-data.sh
```

Then inspect the generated QA database path printed in the QA config. Run these against the QA database:

```sql
SELECT provider, billing_tier, COUNT(*) AS events, SUM(total_tokens) AS tokens, ROUND(SUM(value_usd), 6) AS usd
FROM usage_events
GROUP BY provider, billing_tier
ORDER BY provider, billing_tier;

SELECT COUNT(*) AS codex_events, SUM(total_tokens) AS codex_tokens
FROM usage_events
WHERE provider = 'codex';
```

Expected:

- Codex events include `fast` if local traces contain Fast/Priority turns.
- `unknown` may exist and is acceptable.
- `SUM(total_tokens)` for Codex should match the same QA import before the pricing/tier change when run against the same source JSONL.

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| False Standard classification when trace DB was unavailable during scan | Understates Fast cost and misleads UI | Trace DB unavailable stores `unknown`; with a readable DB, absence of a Fast/Priority request follows Agent Signal Bar and stores `standard` |
| `logs_2.sqlite` missing, moved, or unreadable | No Fast detection | Use `.unavailable`; keep fallback setting for unknown rows |
| SQLite scan too slow on large logs | Refresh feels slow | Query bounded timestamp window; load once per scan; do not scan when no changed Codex files |
| Historical values change unexpectedly | User loses trust in charts | Migration forces reimport; pricing tests pin standard/fast/unknown behavior; release notes must call out improved detection |
| Existing tests inserting usage rows break | Build/test failure | DB defaults keep raw SQL inserts working; update `UsageEventRecord` call sites |
| Fast pricing changes upstream | Incorrect dollars | Continue using pricing catalog and synthetic `*-fast` rows; future catalog refresh remains the source of truth |
| Privacy leak from trace logs | Sensitive local data exposed | Parse `feedback_log_body` in memory only; never persist body, prompt, or raw JSON |

## Self-Review Checklist

- [ ] Token delta algorithm remains untouched except for attaching metadata.
- [ ] Event-level Fast wins over global fallback.
- [ ] Explicit Standard wins over global fallback.
- [ ] Unknown + fallback off prices as Standard.
- [ ] Unknown + fallback on prices as Fast for listed models only.
- [ ] Claude rows are unaffected.
- [ ] Unlisted Codex models are unaffected.
- [ ] UI distinguishes Fast, Standard, and Unknown.
- [ ] CSV export includes tier metadata.
- [ ] Full QA gate passes before shipping.
