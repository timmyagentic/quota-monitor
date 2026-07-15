# Dashboard History Lazy Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dashboard > History open from one indexed seven-calendar-day query and load one older seven-day page only after each genuine downward scroll gesture.

**Architecture:** Replace the raw all-history cursor with a GRDB page query built from seven explicit DST-correct UTC ranges and an exclusive time cursor. Keep paging behavior in a pure value-state reducer, translate macOS 14 AppKit scroll input through a narrow footer bridge and testable gesture gate, then let `HistoryView` drive page requests through cancellable SwiftUI tasks. Reuse one captured calendar snapshot for list, detail, and expanded events until the view is reset.

**Tech Stack:** Swift 6 with strict concurrency, SwiftUI, AppKit, Swift Testing, GRDB/SQLite, SwiftPM, bilingual `L10n`, shell QA, Computer Use, GitHub CLI.

## Global Constraints

- Work only in `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-dashboard-history-performance` on `codex/dashboard-history-performance`; never edit the primary checkout or `main`.
- Support macOS 14 and do not depend on newer SwiftUI scroll-phase APIs.
- The initial page is exactly the current local date plus the preceding six natural calendar dates; it must not jump to older history when empty.
- Every subsequent page represents seven consecutive natural calendar dates ending at the preceding page's exclusive lower cursor; dates with no events consume positions but render no blank rows.
- Generate local-day boundaries with one captured `Calendar`; never subtract fixed 24-hour seconds or group with SQL `localtime`/a fixed UTC offset.
- Aggregate in SQL through indexed timestamp ranges; do not fetch raw event rows to build the list and do not retain the existing 365-active-day compatibility path.
- Use the existing `idx_usage_events_timestamp` and `(provider, timestamp)` indexes; add no schema migration, materialized rollup, persistent cache, or new dependency.
- A visible footer alone must not load page two. Require downward input inside the exact History sidebar plus actual footer/document-visible-rect intersection.
- One gesture generation loads at most one page; momentum cannot cascade, and phase-less wheel events use a 250 ms idle boundary.
- Keep provider filtering, automatic initial selection, detail/session behavior, and session-event lazy rendering; pagination must not change a valid selection.
- Initial errors replace only the initial list; pagination errors preserve loaded days and expose localized Retry; detail errors must not replace the sidebar.
- Add English and Simplified Chinese copy together, update both changelogs, and keep every Chinese changelog bullet on one physical line.
- Use test-first RED/GREEN cycles. Final acceptance is `<100 ms` per real-data page query and `<500 ms` from History click to visible initial content on this Mac.
- Real-data QA must use the read-only shadow workflow, report current counts if imports changed, prove `source_unchanged=true`, and clean up the QA app.

### Execution amendment from real-data validation

The original existing-index/no-migration constraint above is superseded by a
measured implementation follow-up. The bounded query was correct, but the live
shadow showed that table lookups and concurrent timestamp parsing still delayed
publication:

- Migration v16 replaces the two legacy History indexes with covering indexes
  ordered as `(timestamp, id, value_usd, total_tokens, session_id)` and
  `(provider, timestamp, id, value_usd, total_tokens, session_id)`. Keeping `id`
  immediately after the range key preserves billing `ORDER BY timestamp, id`.
- The shared analytics timestamp parser uses the value-type ISO-8601 parse
  strategy with the SQLite timestamp fallback retained.
- `query.days.page.database.finish` is the exact reader-boundary metric for the
  `<100 ms` database gate. The existing `query.days.page.finish` remains an
  honest facade/data-ready metric that can include MainActor scheduling. The
  independent click-to-visible gate remains `<500 ms`.

---

## File Structure

**New:**

- `QuotaMonitor/Features/History/HistoryPaginationState.swift` — pure request identity, cursor, append, retry, and stale-result state.
- `QuotaMonitor/Features/History/HistoryPaginationScrollBridge.swift` — testable gesture gate plus the narrow `NSViewRepresentable` footer probe.
- `Tests/QuotaMonitorTests/HistoryPaginationTests.swift` — calendar-page aggregation, gaps, providers, and SQLite query-plan coverage.
- `Tests/QuotaMonitorTests/HistoryPaginationStateTests.swift` — single-flight, cursor, deduplication, retry, and cancellation semantics.
- `Tests/QuotaMonitorTests/HistoryPaginationScrollBridgeTests.swift` — input generation, geometry, momentum, and bridge source-contract coverage.
- `Tests/QuotaMonitorTests/HistoryViewWiringTests.swift` — view/query-facade wiring and the prohibition on footer-only auto-loading.
- `docs/superpowers/plans/2026-07-15-dashboard-history-lazy-loading.md` — this execution plan.

**Modified:**

- `QuotaMonitor/Core/Analytics/Aggregator.swift` — `HistoryPage`, typed page trigger, and fast stored-timestamp parsing.
- `QuotaMonitor/Core/Analytics/AggregatorHistory.swift` — bounded page aggregation, older-event lookup, and gap jump; final removal of `fetchDays`.
- `QuotaMonitor/Core/Storage/Migrations.swift` — v16 covering History indexes that retain billing-order compatibility.
- `QuotaMonitor/App/QueryFacade.swift` — logged async page API plus calendar propagation into detail/event queries.
- `QuotaMonitor/Features/History/HistoryView.swift` — page-driven sidebar, cancellable tasks, footer states, captured calendar, and detail/event propagation.
- `QuotaMonitor/Core/Localization/L10n.swift` — recent-empty, loading-older, load-failure, and Retry copy.
- `Tests/QuotaMonitorTests/AggregatorDSTTests.swift` — remove the obsolete `fetchDays` raw-scan expectations while retaining detail/event DST coverage.
- `Tests/QuotaMonitorTests/BrandingLocalizationTests.swift` — exact bilingual History strings.
- `docs/superpowers/specs/2026-07-15-dashboard-history-lazy-loading-design.md` — mark the user-approved spec ready for implementation.
- `CHANGELOG.md` and `CHANGELOG.zh-Hans.md` — user-visible Unreleased notes.

## Interfaces

```swift
enum HistoryPageLoadTrigger: String, Sendable, Equatable {
    case initial
    case scroll
    case retry
}

struct HistoryPage: Sendable, Equatable {
    let days: [DaySummary]
    let nextCursor: Date
    let hasMore: Bool
}

extension Aggregator {
    static func fetchHistoryPage(
        db: Database,
        before cursor: Date? = nil,
        pageSize: Int = 7,
        provider: ProviderFilter = .all,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> HistoryPage
}

extension AppEnvironment {
    func fetchHistoryPage(
        before cursor: Date?,
        pageSize: Int = 7,
        now: Date,
        calendar: Calendar,
        trigger: HistoryPageLoadTrigger
    ) async throws -> HistoryPage

    func fetchDayDetail(day: String, calendar: Calendar) async throws -> DayDetail?

    func fetchSessionEventsOnDay(
        sessionId: String,
        day: String,
        calendar: Calendar
    ) async throws -> [SessionDetail.Event]
}
```

`HistoryPaginationState.Request` is the only value that starts a page task. It carries an ID, trigger, and optional exclusive cursor; `HistoryView` passes those values unchanged to the query facade. The scroll bridge has no database knowledge and only invokes a synchronous `onLoadMore` callback after its gesture gate consumes an eligible generation.

---

### Task 1: Add bounded seven-day aggregation

**Files:**

- Create: `Tests/QuotaMonitorTests/HistoryPaginationTests.swift`
- Modify: `QuotaMonitor/Core/Analytics/Aggregator.swift:449`
- Modify: `QuotaMonitor/Core/Analytics/AggregatorHistory.swift:18-59`

**Interfaces:**

- Consumes: `ProviderFilter.clause(table:)`, `ISO8601.fractional`, existing timestamp indexes, and the current `DaySummary` fields.
- Produces: `HistoryPageLoadTrigger`, `HistoryPage`, and `Aggregator.fetchHistoryPage(db:before:pageSize:provider:now:calendar:)` for all later tasks.

- [ ] **Step 1: Write failing first-page, cursor, aggregation, provider, and DST tests**

Create the suite with these deterministic helpers. Seed only UTC `T…Z` timestamps, matching the storage invariant and current real database. Pin UTC for ordinary boundaries and `America/New_York` for DST:

```swift
import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("History pagination")
struct HistoryPaginationTests {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func makeDatabase() throws -> DatabaseManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-monitor-history-page-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return try DatabaseManager(url: directory.appendingPathComponent(
            "history-\(UUID().uuidString).sqlite"))
    }

    private func seed(
        in database: DatabaseManager,
        sessionId: String,
        timestamp: String,
        provider: String = "codex",
        tokens: Int64 = 10,
        valueUSD: Double = 1
    ) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL,
                        'gpt-5', NULL, 0, ?, ?, ?)
                """, arguments: [
                    sessionId, sessionId, timestamp, timestamp,
                    timestamp, timestamp, provider
                ])
            try db.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred)
                VALUES (?, ?, 'gpt-5', ?, 0, 0, 0, ?, ?, ?, 0, 0)
                """, arguments: [
                    sessionId, timestamp, tokens, tokens, valueUSD, provider
                ])
        }
    }

    @Test("initial page is today plus the previous six natural dates")
    func initialPageBounds() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "today", timestamp: "2026-07-15T10:00:00Z")
        try seed(in: db, sessionId: "lower", timestamp: "2026-07-09T00:00:00Z")
        try seed(in: db, sessionId: "older", timestamp: "2026-07-08T23:59:59Z")

        let page = try db.pool.read {
            try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
        }

        #expect(page.days.map(\.day) == ["2026-07-15", "2026-07-09"])
        #expect(page.nextCursor == try #require(ISO8601.parse("2026-07-09T00:00:00Z")))
        #expect(page.hasMore)
    }

    @Test("next page uses the preceding cursor as an exclusive upper bound")
    func cursorHasNoOverlapOrGap() throws {
        let calendar = utcCalendar()
        let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
        let db = try makeDatabase()
        try seed(in: db, sessionId: "boundary", timestamp: "2026-07-09T00:00:00Z")
        try seed(in: db, sessionId: "older", timestamp: "2026-07-08T23:59:59Z")
        let first = try db.pool.read {
            try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
        }
        let second = try db.pool.read {
            try Aggregator.fetchHistoryPage(
                db: $0, before: first.nextCursor, now: now, calendar: calendar)
        }

        #expect(first.days.map(\.day) == ["2026-07-09"])
        #expect(second.days.map(\.day) == ["2026-07-08"])
        #expect(Set(first.days.map(\.id)).isDisjoint(with: second.days.map(\.id)))
        #expect(second.nextCursor == try #require(ISO8601.parse("2026-07-02T00:00:00Z")))
    }
}
```

Add assertions that two events from the same session plus one from a second session produce the exact `valueUSD`, tokens, event count, and distinct-session count returned by `fetchDayDetail`. Add `.codex`/`.claude` control rows on the same day. For DST, assert that the New York 2025-03-09 page contains events through `2025-03-10T03:59:59Z` but not `04:00:00Z`, and the 2025-11-02 page contains events through `2025-11-03T04:59:59Z` but not `05:00:00Z`.

- [ ] **Step 2: Run the focused suite and confirm RED**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationTests
```

Expected: compile failure because `HistoryPage`, `HistoryPageLoadTrigger`, and `Aggregator.fetchHistoryPage` do not exist.

- [ ] **Step 3: Add the page values and explicit local-day ranges**

Place these values immediately after `DaySummary` in `Aggregator.swift`:

```swift
enum HistoryPageLoadTrigger: String, Sendable, Equatable {
    case initial
    case scroll
    case retry
}

struct HistoryPage: Sendable, Equatable {
    let days: [DaySummary]
    let nextCursor: Date
    let hasMore: Bool
}
```

In `AggregatorHistory.swift`, add an internal range value and build newest-first ranges with calendar arithmetic:

```swift
private struct HistoryDayRange {
    let dayKey: String
    let ordinal: Int
    let start: Date
    let end: Date

    var lowerISO: String { ISO8601.fractional.string(from: start) }
    var upperISO: String { ISO8601.fractional.string(from: end) }
}

private static func historyDayRanges(
    endingAt upperBound: Date,
    pageSize: Int,
    calendar: Calendar
) -> [HistoryDayRange] {
    let formatter = dayKeyFormatter(calendar)
    return (0..<pageSize).map { ordinal in
        let end = calendar.date(byAdding: .day, value: -ordinal, to: upperBound)!
        let start = calendar.date(byAdding: .day, value: -1, to: end)!
        return HistoryDayRange(
            dayKey: formatter.string(from: start),
            ordinal: ordinal,
            start: start,
            end: end)
    }
}
```

- [ ] **Step 4: Implement one parameterized `UNION ALL` aggregate and indexed older lookup**

Use one branch per range and map `ordinal` back to the already-computed local start; do not parse each event timestamp:

```swift
static func fetchHistoryPage(
    db: Database,
    before cursor: Date? = nil,
    pageSize: Int = 7,
    provider: ProviderFilter = .all,
    now: Date = Date(),
    calendar: Calendar = .current
) throws -> HistoryPage {
    precondition(pageSize > 0)
    let today = calendar.startOfDay(for: now)
    let upper = cursor.map { calendar.startOfDay(for: $0) }
        ?? calendar.date(byAdding: .day, value: 1, to: today)!
    return try fetchHistoryWindow(
        db: db,
        upperBound: upper,
        pageSize: pageSize,
        provider: provider,
        calendar: calendar)
}

private static func fetchHistoryWindow(
    db: Database,
    upperBound: Date,
    pageSize: Int,
    provider: ProviderFilter,
    calendar: Calendar
) throws -> HistoryPage {
    let ranges = historyDayRanges(
        endingAt: upperBound, pageSize: pageSize, calendar: calendar)
    let branch = """
        SELECT ? AS day_key, ? AS ordinal,
               SUM(value_usd) AS value_usd,
               SUM(total_tokens) AS tokens,
               COUNT(*) AS events,
               COUNT(DISTINCT session_id) AS sessions
        FROM usage_events
        WHERE timestamp >= ? AND timestamp < ?
        \(provider.clause(table: "usage_events"))
        """
    let sql = Array(repeating: branch, count: ranges.count)
        .joined(separator: "\nUNION ALL\n")
    var arguments: [(any DatabaseValueConvertible)?] = []
    for range in ranges {
        arguments.append(contentsOf: [
            range.dayKey, range.ordinal, range.lowerISO, range.upperISO
        ])
    }
    let rows = try Row.fetchAll(
        db, sql: sql, arguments: StatementArguments(arguments))
    let byOrdinal = Dictionary(uniqueKeysWithValues: ranges.map { ($0.ordinal, $0) })
    let days = rows.compactMap { row -> DaySummary? in
        let events: Int = row["events"] ?? 0
        let ordinal: Int = row["ordinal"] ?? -1
        guard events > 0, let range = byOrdinal[ordinal] else { return nil }
        return DaySummary(
            day: range.dayKey,
            date: range.start,
            valueUSD: row["value_usd"] ?? 0,
            tokens: row["tokens"] ?? 0,
            eventCount: events,
            sessionCount: row["sessions"] ?? 0)
    }.sorted { $0.date > $1.date }
    let lower = ranges.last!.start
    let older = try String.fetchOne(db, sql: """
        SELECT timestamp
        FROM usage_events
        WHERE timestamp < ?
        \(provider.clause(table: "usage_events"))
        ORDER BY timestamp DESC
        LIMIT 1
        """, arguments: [ISO8601.fractional.string(from: lower)])
    return HistoryPage(days: days, nextCursor: lower, hasMore: older != nil)
}
```

- [ ] **Step 5: Add production-SQL trace and query-plan assertions**

Trace `statement.expandedSQL`, select the statement containing `UNION ALL`, then run its exact SQL through SQLite's planner:

```swift
let details = try db.pool.read { conn in
    var aggregateSQL: String?
    conn.trace { event in
        guard case .statement(let statement) = event,
              statement.sql.contains("UNION ALL") else { return }
        aggregateSQL = statement.expandedSQL
    }
    _ = try Aggregator.fetchHistoryPage(
        db: conn, provider: .all, now: now, calendar: calendar)
    conn.trace(options: [])
    let sql = try #require(aggregateSQL)
    return try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN \(sql)")
        .map { $0["detail"] as String }
}

#expect(details.filter { $0.contains("SEARCH usage_events") }.count == 7)
#expect(!details.contains { $0.contains("SCAN usage_events") })
#expect(!details.contains { $0.contains("TEMP B-TREE FOR ORDER BY") })
```

Repeat with `.codex` and assert the plan mentions `index_usage_events_on_provider_timestamp`. Allow the bounded `USE TEMP B-TREE FOR count(DISTINCT)` detail. Trace the older lookup and assert it is a covering-index search. Assert no executed History statement contains the former raw projection `SELECT timestamp, value_usd, total_tokens, session_id`.

- [ ] **Step 6: Confirm GREEN and commit Task 1**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationTests
swift test --disable-keychain --filter AggregatorDSTTests
```

Expected: both suites pass; the new suite proves seven indexed range searches and permits only the bounded distinct-count temporary structure.

Commit:

```sh
git add QuotaMonitor/Core/Analytics/Aggregator.swift \
  QuotaMonitor/Core/Analytics/AggregatorHistory.swift \
  Tests/QuotaMonitorTests/HistoryPaginationTests.swift
git commit -m "Query History in seven-day pages"
```

---

### Task 2: Skip empty pagination windows without violating the initial page

**Files:**

- Modify: `QuotaMonitor/Core/Analytics/AggregatorHistory.swift`
- Test: `Tests/QuotaMonitorTests/HistoryPaginationTests.swift`

**Interfaces:**

- Consumes: Task 1's bounded window aggregate, newest-older timestamp query, cursor, and captured calendar.
- Produces: initial-page no-jump behavior plus indexed pagination gap continuation with final-window cursor semantics.

- [ ] **Step 1: Write failing initial-empty and pagination-gap tests**

Use a fixed `now` of 2026-07-15 and seed events in June:

```swift
@Test("empty initial week does not jump to older history")
func emptyInitialPageStaysRecent() throws {
    let calendar = utcCalendar()
    let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
    let db = try makeDatabase()
    try seed(in: db, sessionId: "old", timestamp: "2026-06-20T12:00:00Z")

    let page = try db.pool.read {
        try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
    }

    #expect(page.days.isEmpty)
    #expect(page.hasMore)
    #expect(page.nextCursor == try #require(ISO8601.parse("2026-07-09T00:00:00Z")))
}

@Test("empty pagination window jumps to the newest older populated week")
func emptyPaginationWindowJumps() throws {
    let calendar = utcCalendar()
    let now = try #require(ISO8601.parse("2026-07-15T12:00:00Z"))
    let db = try makeDatabase()
    try seed(in: db, sessionId: "june20", timestamp: "2026-06-20T12:00:00Z")
    try seed(in: db, sessionId: "may", timestamp: "2026-05-01T12:00:00Z")
    let first = try db.pool.read {
        try Aggregator.fetchHistoryPage(db: $0, now: now, calendar: calendar)
    }
    let next = try db.pool.read {
        try Aggregator.fetchHistoryPage(
            db: $0, before: first.nextCursor, now: now, calendar: calendar)
    }

    #expect(next.days.map(\.day) == ["2026-06-20"])
    #expect(next.nextCursor == try #require(ISO8601.parse("2026-06-14T00:00:00Z")))
    #expect(next.hasMore)
}
```

Add a provider-filter control where the newest older Claude row must not move a Codex page; the Codex cursor jumps to the newest older Codex row.

- [ ] **Step 2: Run the gap test and confirm RED**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationTests
```

Expected: the second page is empty because Task 1 aggregates only the requested empty window.

- [ ] **Step 3: Add pagination-only gap jumping**

Pass `allowGapJump: cursor != nil` from `fetchHistoryPage`. In one database read snapshot, repeat only when the requested pagination window is empty and the indexed older lookup returned a parseable event:

```swift
private static func newestOlderTimestamp(
    db: Database,
    before boundary: Date,
    provider: ProviderFilter,
) throws -> String? {
    try String.fetchOne(db, sql: """
        SELECT timestamp
        FROM usage_events
        WHERE timestamp < ?
        \(provider.clause(table: "usage_events"))
        ORDER BY timestamp DESC
        LIMIT 1
        """, arguments: [ISO8601.fractional.string(from: boundary)])
}

let today = calendar.startOfDay(for: now)
let requestedUpper = cursor.map { calendar.startOfDay(for: $0) }
    ?? calendar.date(byAdding: .day, value: 1, to: today)!
let allowGapJump = cursor != nil
var upper = requestedUpper
while true {
    let page = try fetchHistoryWindow(
        db: db,
        upperBound: upper,
        pageSize: pageSize,
        provider: provider,
        calendar: calendar)
    if !page.days.isEmpty || !allowGapJump || !page.hasMore {
        return page
    }
    guard let timestamp = try newestOlderTimestamp(
              db: db, before: page.nextCursor, provider: provider),
          let olderDate = parseTimestamp(timestamp),
          let jumpedUpper = calendar.date(
              byAdding: .day,
              value: 1,
              to: calendar.startOfDay(for: olderDate)),
          jumpedUpper < upper
    else {
        return HistoryPage(days: [], nextCursor: page.nextCursor, hasMore: false)
    }
    upper = jumpedUpper
}
```

Refactor Task 1's inline older lookup to call `newestOlderTimestamp`; `fetchHistoryWindow` still computes `hasMore` before returning. Because the loop returns only the page produced for its final `upper`, `nextCursor` and `hasMore` are never reused from the empty requested window.

- [ ] **Step 4: Confirm GREEN and commit Task 2**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationTests
```

Expected: the initial-empty page stays on July 9–15, the pagination request jumps to June 14–20, provider filtering remains independent, and all query-plan assertions pass.

Commit:

```sh
git add QuotaMonitor/Core/Analytics/AggregatorHistory.swift \
  Tests/QuotaMonitorTests/HistoryPaginationTests.swift
git commit -m "Continue History pagination across gaps"
```

---

### Task 3: Add a cancellable single-flight pagination state reducer

**Files:**

- Create: `QuotaMonitor/Features/History/HistoryPaginationState.swift`
- Create: `Tests/QuotaMonitorTests/HistoryPaginationStateTests.swift`

**Interfaces:**

- Consumes: `HistoryPage`, `HistoryPageLoadTrigger`, and `DaySummary.id` from Task 1.
- Produces: `HistoryPaginationState`, its nested `Request`, and its failure enum for `HistoryView`.

- [ ] **Step 1: Write failing state-transition tests**

Use deterministic UUIDs and fixed cursors. Cover initial replacement, single flight, older append, duplicate IDs, stale result rejection, non-advancing cursor rejection, cancellation, pagination error preservation, and retry with the same cursor:

```swift
@Suite("History pagination state")
struct HistoryPaginationStateTests {
    private func day(_ key: String) -> DaySummary {
        DaySummary(
            day: key,
            date: ISO8601.parse("\(key)T00:00:00Z")!,
            valueUSD: 1,
            tokens: 10,
            eventCount: 1,
            sessionCount: 1)
    }

    @Test("one next-page request is in flight and retry keeps the cursor")
    func singleFlightAndRetry() throws {
        var state = HistoryPaginationState()
        let initialID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let nextID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let blockedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let retryID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let initial = state.reset(requestID: initialID)
        let cursor = Date(timeIntervalSince1970: 1_000)
        #expect(state.complete(
            HistoryPage(days: [day("2026-07-15")], nextCursor: cursor, hasMore: true),
            for: initial))

        let next = try #require(state.beginNextPage(
            trigger: .scroll, requestID: nextID))
        #expect(state.beginNextPage(trigger: .scroll, requestID: blockedID) == nil)
        #expect(state.fail("database busy", for: next))
        #expect(state.days.map(\.day) == ["2026-07-15"])
        #expect(state.nextCursor == cursor)

        let retry = try #require(state.beginNextPage(
            trigger: .retry, requestID: retryID))
        #expect(retry.cursor == cursor)
        #expect(retry.trigger == .retry)
    }
}
```

For stale work, call `reset`, then deliver the former request and expect `complete == false`. For deduplication, return one existing and one older `DaySummary`; only the older row appends. For monotonicity, return `page.nextCursor >= request.cursor`; expect no append and `.nonAdvancingCursor` pagination failure.

- [ ] **Step 2: Run the state suite and confirm RED**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationStateTests
```

Expected: compile failure because `HistoryPaginationState` does not exist.

- [ ] **Step 3: Implement the pure reducer**

Use the following exact public-to-target interface; keep all mutation inside methods so the view cannot accidentally bypass request identity:

```swift
struct HistoryPaginationState {
    enum Failure: Equatable {
        case query(String)
        case nonAdvancingCursor
    }

    struct Request: Sendable, Equatable, Identifiable {
        let id: UUID
        let trigger: HistoryPageLoadTrigger
        let cursor: Date?
    }

    private(set) var days: [DaySummary] = []
    private(set) var nextCursor: Date?
    private(set) var hasMore = false
    private(set) var initialFailure: Failure?
    private(set) var paginationFailure: Failure?
    private(set) var inFlightRequest: Request?

    var isLoadingInitial: Bool { inFlightRequest?.trigger == .initial }
    var isLoadingNextPage: Bool {
        guard let trigger = inFlightRequest?.trigger else { return false }
        return trigger == .scroll || trigger == .retry
    }

    @discardableResult
    mutating func reset(requestID: UUID = UUID()) -> Request {
        let request = Request(id: requestID, trigger: .initial, cursor: nil)
        days = []
        nextCursor = nil
        hasMore = false
        initialFailure = nil
        paginationFailure = nil
        inFlightRequest = request
        return request
    }

    mutating func beginNextPage(
        trigger: HistoryPageLoadTrigger,
        requestID: UUID = UUID()
    ) -> Request? {
        guard trigger != .initial,
              inFlightRequest == nil,
              hasMore,
              let nextCursor else { return nil }
        paginationFailure = nil
        let request = Request(id: requestID, trigger: trigger, cursor: nextCursor)
        inFlightRequest = request
        return request
    }

    @discardableResult
    mutating func complete(_ page: HistoryPage, for request: Request) -> Bool {
        guard inFlightRequest == request else { return false }
        if let requestedCursor = request.cursor,
           page.nextCursor >= requestedCursor {
            inFlightRequest = nil
            paginationFailure = .nonAdvancingCursor
            return false
        }
        if request.trigger == .initial {
            days = page.days
            initialFailure = nil
        } else {
            var seen = Set(days.map(\.id))
            days.append(contentsOf: page.days.filter { seen.insert($0.id).inserted })
            paginationFailure = nil
        }
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        inFlightRequest = nil
        return true
    }

    @discardableResult
    mutating func fail(_ message: String, for request: Request) -> Bool {
        guard inFlightRequest == request else { return false }
        inFlightRequest = nil
        if request.trigger == .initial {
            initialFailure = .query(message)
        } else {
            paginationFailure = .query(message)
        }
        return true
    }

    mutating func cancel(_ request: Request) {
        guard inFlightRequest == request else { return }
        inFlightRequest = nil
    }
}
```

`complete(_:for:)` first matches the exact in-flight request. For pagination it requires `page.nextCursor < requestedCursor`, appends only IDs not already present, then updates cursor/`hasMore`; for initial it replaces the list. `fail(_:for:)` stores `.query(message)` in the correct failure slot without changing loaded rows or the cursor. `cancel(_:)` clears only the matching request. Every stale call returns `false` without mutation.

- [ ] **Step 4: Confirm GREEN and commit Task 3**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationStateTests
```

Expected: all reducer transitions pass without launching SwiftUI or a database.

Commit:

```sh
git add QuotaMonitor/Features/History/HistoryPaginationState.swift \
  Tests/QuotaMonitorTests/HistoryPaginationStateTests.swift
git commit -m "Model History pagination state"
```

---

### Task 4: Gate pagination on one genuine macOS scroll gesture

**Files:**

- Create: `QuotaMonitor/Features/History/HistoryPaginationScrollBridge.swift`
- Create: `Tests/QuotaMonitorTests/HistoryPaginationScrollBridgeTests.swift`

**Interfaces:**

- Consumes: macOS 14 AppKit `NSScrollView`/`NSEvent` notifications and a synchronous load callback.
- Produces: `HistoryScrollLoadGate` and `HistoryPaginationScrollBridge(isEnabled:isLoading:onLoadMore:)` for the History footer.

- [ ] **Step 1: Write failing pure gesture and geometry tests**

Drive the gate without posting real GUI events:

```swift
@Suite("History pagination scroll bridge")
struct HistoryPaginationScrollBridgeTests {
    @Test("visible footer alone never loads")
    func visibleFooterNeedsGesture() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        #expect(!gate.consumeIfEligible())
    }

    @Test("one downward gesture generation loads once across momentum")
    func oneLoadPerGesture() {
        var gate = HistoryScrollLoadGate()
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.updateFooterVisibility(true)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .began,
            momentumPhase: .none,
            timestamp: 10)
        #expect(gate.consumeIfEligible())
        gate.updateAvailability(isEnabled: true, isLoading: false)
        gate.registerWheel(
            isInsideScrollView: true,
            downwardIntent: true,
            phase: .changed,
            momentumPhase: .changed,
            timestamp: 10.1)
        #expect(!gate.consumeIfEligible())
    }
}
```

Add cases for gesture-before-geometry, upward input, horizontal-dominant input, outside-scroll-view input, loading-time input, a new phased gesture, phase-less events at 100 ms versus 251 ms, scrollbar live-scroll movement, and `HistoryScrollGeometry.footerIsVisible(footerFrame:visibleRect:)` intersection.

- [ ] **Step 2: Run the bridge suite and confirm RED**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationScrollBridgeTests
```

Expected: compile failure because the gate, phase adapter, geometry helper, and bridge do not exist.

- [ ] **Step 3: Implement the platform-neutral gate and helpers**

Define an internal phase enum so tests do not synthesize `NSEvent` objects:

```swift
enum HistoryScrollPhase: Equatable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

struct HistoryScrollGeometry {
    static func footerIsVisible(footerFrame: CGRect, visibleRect: CGRect) -> Bool {
        !footerFrame.isEmpty && footerFrame.intersects(visibleRect)
    }

    static func eventIsInsideScrollView(
        windowMatches: Bool,
        location: CGPoint,
        scrollViewBounds: CGRect
    ) -> Bool {
        windowMatches && scrollViewBounds.contains(location)
    }

    static func hasDownwardIntent(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        let downward = -deltaY
        return downward > 0 && downward > abs(deltaX)
    }
}

struct HistoryScrollLoadGate {
    static let phaseLessIdleInterval: TimeInterval = 0.250

    private var generation = 0
    private var activeGeneration: Int?
    private var consumedGeneration: Int?
    private var lastPhaseLessWheelAt: TimeInterval?
    private var footerVisible = false
    private var isEnabled = false
    private var isLoading = false
    private var hasDownwardIntent = false

    mutating func updateAvailability(isEnabled: Bool, isLoading: Bool) {
        self.isEnabled = isEnabled
        self.isLoading = isLoading
    }

    mutating func updateFooterVisibility(_ visible: Bool) {
        footerVisible = visible
    }

    mutating func registerWheel(
        isInsideScrollView: Bool,
        downwardIntent: Bool,
        phase: HistoryScrollPhase,
        momentumPhase: HistoryScrollPhase,
        timestamp: TimeInterval
    ) {
        guard isEnabled, !isLoading, isInsideScrollView, downwardIntent else {
            return
        }
        if momentumPhase != .none {
            if activeGeneration == nil, generation > 0 {
                activeGeneration = generation
            }
            hasDownwardIntent = true
            return
        }
        let isPhaseLess = phase == .none && momentumPhase == .none
        if isPhaseLess {
            if lastPhaseLessWheelAt.map({
                timestamp - $0 > Self.phaseLessIdleInterval
            }) ?? true {
                startGeneration()
            } else if activeGeneration == nil, generation > 0 {
                activeGeneration = generation
            }
            lastPhaseLessWheelAt = timestamp
        } else if phase == .began {
            startGeneration()
        } else if activeGeneration == nil {
            if generation == 0 {
                startGeneration()
            } else {
                activeGeneration = generation
            }
        }
        hasDownwardIntent = true
    }

    mutating func beginLiveScroll() {
        guard isEnabled, !isLoading else { return }
        if activeGeneration == nil {
            startGeneration()
        }
    }

    mutating func registerLiveMovement(isDownward: Bool) {
        guard isEnabled, !isLoading, isDownward else { return }
        if activeGeneration == nil {
            startGeneration()
        }
        hasDownwardIntent = true
    }

    mutating func endLiveScroll() {
        activeGeneration = nil
        hasDownwardIntent = false
    }

    mutating func consumeIfEligible() -> Bool {
        guard isEnabled, !isLoading, footerVisible, hasDownwardIntent,
              let activeGeneration,
              consumedGeneration != activeGeneration else { return false }
        consumedGeneration = activeGeneration
        return true
    }

    private mutating func startGeneration() {
        generation &+= 1
        activeGeneration = generation
        hasDownwardIntent = false
    }
}
```

`registerWheel` ignores outside/upward/loading input; starts a generation on a phased begin or a phase-less event more than 250 ms after the previous one; keeps changed and momentum phases in the same generation; and never clears `consumedGeneration` merely because loading finishes. `beginLiveScroll` creates a generation only when no wheel generation is active, `registerLiveMovement` arms only after the document-visible rectangle moves downward, and `endLiveScroll` ends that live generation. The next phased begin or post-idle phase-less event creates the only new consumable generation.

- [ ] **Step 4: Add the narrow footer `NSViewRepresentable`**

Expose only current availability and the synchronous callback:

```swift
@MainActor
final class FooterProbeView: NSView {
    var hierarchyDidChange: (() -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hierarchyDidChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hierarchyDidChange?()
    }
}

struct HistoryPaginationScrollBridge: NSViewRepresentable {
    let isEnabled: Bool
    let isLoading: Bool
    let onLoadMore: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadMore: onLoadMore)
    }

    func makeNSView(context: Context) -> FooterProbeView {
        let view = FooterProbeView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: FooterProbeView, context: Context) {
        context.coordinator.update(
            probe: view,
            isEnabled: isEnabled,
            isLoading: isLoading,
            onLoadMore: onLoadMore)
    }

    static func dismantleNSView(_ view: FooterProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

extension HistoryPaginationScrollBridge {
    @MainActor
    final class Coordinator {
        private weak var probe: FooterProbeView?
        private weak var scrollView: NSScrollView?
        private var eventMonitor: Any?
        private var notificationTokens: [NSObjectProtocol] = []
        private var gate = HistoryScrollLoadGate()
        private var lastVisibleRect = CGRect.zero
        private var onLoadMore: @MainActor () -> Void

        init(onLoadMore: @escaping @MainActor () -> Void) {
            self.onLoadMore = onLoadMore
        }

        func attach(to probe: FooterProbeView) {
            self.probe = probe
            probe.hierarchyDidChange = { [weak self, weak probe] in
                guard let probe else { return }
                self?.probe = probe
                self?.rebindIfNeeded()
            }
            installEventMonitorIfNeeded()
            rebindIfNeeded()
        }

        func update(
            probe: FooterProbeView,
            isEnabled: Bool,
            isLoading: Bool,
            onLoadMore: @escaping @MainActor () -> Void
        ) {
            self.probe = probe
            self.onLoadMore = onLoadMore
            gate.updateAvailability(isEnabled: isEnabled, isLoading: isLoading)
            installEventMonitorIfNeeded()
            rebindIfNeeded()
            refreshFooterVisibility()
            evaluate()
        }

        func detach() {
            probe?.hierarchyDidChange = nil
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            removeScrollObservers()
            probe = nil
            scrollView = nil
        }

        private func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.observeWheel(event)
                return event
            }
        }

        private func rebindIfNeeded() {
            guard let probe else { return }
            var ancestor: NSView? = probe
            var candidate: NSScrollView?
            while let view = ancestor {
                if let found = view as? NSScrollView {
                    candidate = found
                    break
                }
                ancestor = view.superview
            }
            guard let candidate, scrollView !== candidate else { return }
            removeScrollObservers()
            scrollView = candidate
            lastVisibleRect = candidate.documentVisibleRect
            let center = NotificationCenter.default
            notificationTokens = [
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: candidate,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.beginLiveScroll() }
                    },
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: candidate,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.observeLiveScroll() }
                    },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: candidate,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.endLiveScroll() }
                    },
            ]
        }

        private func removeScrollObservers() {
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
        }

        private func observeWheel(_ event: NSEvent) {
            guard let scrollView else { return }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            let inside = HistoryScrollGeometry.eventIsInsideScrollView(
                windowMatches: event.window === scrollView.window,
                location: point,
                scrollViewBounds: scrollView.bounds)
            gate.registerWheel(
                isInsideScrollView: inside,
                downwardIntent: HistoryScrollGeometry.hasDownwardIntent(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY),
                phase: Self.phase(event.phase),
                momentumPhase: Self.phase(event.momentumPhase),
                timestamp: event.timestamp)
            refreshFooterVisibility()
            evaluate()
        }

        private func beginLiveScroll() {
            lastVisibleRect = scrollView?.documentVisibleRect ?? .zero
            gate.beginLiveScroll()
        }

        private func observeLiveScroll() {
            guard let scrollView else { return }
            let current = scrollView.documentVisibleRect
            gate.registerLiveMovement(isDownward: current.maxY > lastVisibleRect.maxY)
            lastVisibleRect = current
            refreshFooterVisibility()
            evaluate()
        }

        private func endLiveScroll() {
            gate.endLiveScroll()
        }

        private func refreshFooterVisibility() {
            guard let probe,
                  let scrollView,
                  let documentView = scrollView.documentView else {
                gate.updateFooterVisibility(false)
                return
            }
            gate.updateFooterVisibility(HistoryScrollGeometry.footerIsVisible(
                footerFrame: probe.convert(probe.bounds, to: documentView),
                visibleRect: scrollView.documentVisibleRect))
        }

        private func evaluate() {
            if gate.consumeIfEligible() {
                onLoadMore()
            }
        }

        private static func phase(_ phase: NSEvent.Phase) -> HistoryScrollPhase {
            if phase.contains(.began) { return .began }
            if phase.contains(.changed) || phase.contains(.stationary) {
                return .changed
            }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.cancelled) { return .cancelled }
            return .none
        }
    }
}
```

The coordinator always returns the original local-monitor event. It filters by the exact window and converted sidebar bounds, uses AppKit's already preference-adjusted `scrollingDeltaY`, and normalizes `-scrollingDeltaY` as downward document intent. It rebinds when the probe's ancestor scroll view changes; `detach()` removes the local event monitor and every notification token.

- [ ] **Step 5: Pin lifecycle wiring in a source-contract test**

Read the bridge source from a repo-root helper and assert that it contains all three exact-scroll-view notifications, both local-monitor add/remove calls, notification removal, document-visible geometry, and `MainActor.assumeIsolated`. Assert it does not use a global unscoped scroll notification.

- [ ] **Step 6: Confirm GREEN and commit Task 4**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationScrollBridgeTests
```

Expected: pure gate tests pass, the source contract proves cleanup, and no UI process launches.

Commit:

```sh
git add QuotaMonitor/Features/History/HistoryPaginationScrollBridge.swift \
  Tests/QuotaMonitorTests/HistoryPaginationScrollBridgeTests.swift
git commit -m "Gate History pages on scroll gestures"
```

---

### Task 5: Wire page queries, captured calendars, errors, and localized History UI

**Files:**

- Modify: `QuotaMonitor/App/QueryFacade.swift:65-130`
- Modify: `QuotaMonitor/Features/History/HistoryView.swift:7-112,147-243,330-344`
- Modify: `QuotaMonitor/Core/Analytics/AggregatorHistory.swift:18-59`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift:654-667`
- Modify: `Tests/QuotaMonitorTests/AggregatorDSTTests.swift:129-180`
- Modify: `Tests/QuotaMonitorTests/BrandingLocalizationTests.swift`
- Create: `Tests/QuotaMonitorTests/HistoryViewWiringTests.swift`

**Interfaces:**

- Consumes: Tasks 1–4 page query, state reducer, and scroll bridge.
- Produces: one-page initial load, one-page-per-gesture pagination, retry, calendar-consistent detail/event queries, and `query.days.page` diagnostics.

- [ ] **Step 1: Write failing localization and source-wiring tests**

Add exact bilingual assertions:

```swift
@Test("History pagination copy is bilingual")
func historyPaginationCopy() {
    let en = LocalizationTestSupport.withLanguage(.english) {
        (L10n.historyNoUsageLatestSevenDays,
         L10n.historyLoadingOlder,
         L10n.historyLoadOlderFailed,
         L10n.retry)
    }
    let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
        (L10n.historyNoUsageLatestSevenDays,
         L10n.historyLoadingOlder,
         L10n.historyLoadOlderFailed,
         L10n.retry)
    }
    #expect(en.0 == "No usage in the latest 7 days")
    #expect(en.1 == "Loading older history")
    #expect(en.2 == "Couldn't load older history.")
    #expect(en.3 == "Retry")
    #expect(zh.0 == "最近 7 天暂无使用记录")
    #expect(zh.1 == "正在加载更早的历史记录")
    #expect(zh.2 == "加载更早的历史记录失败。")
    #expect(zh.3 == "重试")
}
```

In `HistoryViewWiringTests`, read `HistoryView.swift` and `QueryFacade.swift`. Assert the view contains `HistoryPaginationState`, `HistoryPaginationScrollBridge`, `.task(id: pagination.inFlightRequest?.id)`, the two system calendar notifications, and calendar propagation into detail/event calls. Assert the footer slice contains neither `.onAppear` nor its own `.task`. Assert the facade contains `query.days.page` and no `query.days.list`.

- [ ] **Step 2: Run wiring/localization tests and confirm RED**

Run:

```sh
swift test --disable-keychain --filter HistoryViewWiringTests
swift test --disable-keychain --filter BrandingLocalizationTests
```

Expected: failures because the new keys and page wiring are absent.

- [ ] **Step 3: Replace `fetchDaysList` with the logged page facade**

Snapshot the provider before entering the GRDB read and log the final window derived from the returned cursor:

```swift
func fetchHistoryPage(
    before cursor: Date? = nil,
    pageSize: Int = 7,
    now: Date = Date(),
    calendar: Calendar,
    trigger: HistoryPageLoadTrigger
) async throws -> HistoryPage {
    let filter = providerFilter
    let op = DeveloperLog.startOperation(
        "query.days.page",
        category: "query",
        trigger: trigger.rawValue,
        fields: [
            "page_size": .int(pageSize),
            "filter": .string(filter.rawValue),
            "cursor": .string(cursor.map {
                ISO8601.fractional.string(from: $0)
            } ?? "")
        ])
    do {
        let (db, _) = try ensureServices()
        let page = try await db.pool.read { conn in
            try Aggregator.fetchHistoryPage(
                db: conn,
                before: cursor,
                pageSize: pageSize,
                provider: filter,
                now: now,
                calendar: calendar)
        }
        let upper = calendar.date(
            byAdding: .day, value: pageSize, to: page.nextCursor)!
        DeveloperLog.finishOperation(op, fields: [
            "rows": .int(page.days.count),
            "has_more": .bool(page.hasMore),
            "lower_bound": .string(ISO8601.fractional.string(from: page.nextCursor)),
            "upper_bound": .string(ISO8601.fractional.string(from: upper)),
            "filter": .string(filter.rawValue)
        ])
        return page
    } catch {
        DeveloperLog.failOperation(op, error: error, fields: [
            "filter": .string(filter.rawValue)
        ])
        throw error
    }
}
```

Add non-default `calendar` parameters to `fetchDayDetail` and `fetchSessionEventsOnDay` and pass them to the existing Aggregator functions. Keep their existing operation names.

- [ ] **Step 4: Add localized strings and page-driven sidebar states**

Add these keys in the History section of `L10n.swift`:

```swift
static var historyNoUsageLatestSevenDays: String {
    t(en: "No usage in the latest 7 days", zh: "最近 7 天暂无使用记录")
}
static var historyLoadingOlder: String {
    t(en: "Loading older history", zh: "正在加载更早的历史记录")
}
static var historyLoadOlderFailed: String {
    t(en: "Couldn't load older history.", zh: "加载更早的历史记录失败。")
}
static var retry: String { t(en: "Retry", zh: "重试") }
```

Replace list state with:

```swift
@State private var pagination = HistoryPaginationState()
@State private var selection: DaySummary.ID?
@State private var detail: DayDetail?
@State private var loadingDetail = false
@State private var detailErrorMessage: String?
@State private var historyCalendar = Calendar.current
@State private var calendarRevision = 0
```

Render a `List(selection:)` whenever rows exist or `pagination.hasMore` is true. Put the recent-empty guidance inside that List, followed by `ForEach(pagination.days)` and the pagination footer. The footer shows a spinner while loading, the localized failure plus Retry after a page error, or a one-point clear probe when idle. Attach `HistoryPaginationScrollBridge` as its background with `isEnabled: pagination.hasMore && pagination.paginationFailure == nil`; its callback only calls `pagination.beginNextPage(trigger: .scroll)`.

Use these explicit failure mappings so detail and pagination errors cannot replace the sidebar incorrectly:

```swift
private var initialErrorMessage: String? {
    guard let failure = pagination.initialFailure,
          case .query(let message) = failure else { return nil }
    return message
}

private var paginationErrorMessage: String? {
    guard pagination.paginationFailure != nil else { return nil }
    return L10n.historyLoadOlderFailed
}
```

The sidebar branch order is initial spinner, initial error, true all-history empty state (`days.isEmpty && !hasMore`), then the List. The List's idle footer remains present whenever `hasMore` is true, including an empty initial seven-day window.

- [ ] **Step 5: Drive requests with cancellable `.task(id:)` work**

Add `import Combine` beside `import SwiftUI`. Use one reset task and one request task; do not create an unstructured task from the footer:

```swift
.task(id: calendarRevision) {
    historyCalendar = Calendar.current
    selection = nil
    detail = nil
    detailErrorMessage = nil
    pagination.reset()
}
.task(id: pagination.inFlightRequest?.id) {
    guard let request = pagination.inFlightRequest else { return }
    do {
        let page = try await env.fetchHistoryPage(
            before: request.cursor,
            now: Date(),
            calendar: historyCalendar,
            trigger: request.trigger)
        try Task.checkCancellation()
        guard pagination.complete(page, for: request) else { return }
        if request.trigger == .initial {
            let selectedStillExists = selection.map { selectedID in
                pagination.days.contains { $0.id == selectedID }
            } ?? false
            if !selectedStillExists {
                selection = pagination.days.first?.id
            }
        }
    } catch is CancellationError {
        pagination.cancel(request)
    } catch {
        pagination.fail(String(describing: error), for: request)
    }
}
.task(id: selection) {
    await loadDetail(for: selection, calendar: historyCalendar)
}
.onReceive(NotificationCenter.default.publisher(
    for: Notification.Name.NSSystemTimeZoneDidChange)) { _ in
        calendarRevision &+= 1
}
.onReceive(NotificationCenter.default.publisher(
    for: NSLocale.currentLocaleDidChangeNotification)) { _ in
        calendarRevision &+= 1
}
```

The parent `MainWindowView` already remounts content on provider changes through `.id("\(env.providerFilter.rawValue)-\(reloadToken)")`; keep that behavior. Map `.nonAdvancingCursor` and query failures to `L10n.historyLoadOlderFailed` in the footer, while the explicit Retry calls `beginNextPage(trigger: .retry)` with the unchanged cursor.

- [ ] **Step 6: Propagate the calendar through detail and expanded events**

Pass `historyCalendar` into `DayDetailView`, then into every `ExpandableSessionRow`, and finally into:

```swift
events = try await env.fetchSessionEventsOnDay(
    sessionId: session.sessionId,
    day: day,
    calendar: calendar)
```

The detail task calls `env.fetchDayDetail(day: id, calendar: calendar)`. Show detail errors in the detail pane and never route them into initial/pagination sidebar failures.

```swift
private func loadDetail(for id: DaySummary.ID?, calendar: Calendar) async {
    guard let id else {
        detail = nil
        detailErrorMessage = nil
        return
    }
    loadingDetail = true
    defer { loadingDetail = false }
    do {
        let loaded = try await env.fetchDayDetail(day: id, calendar: calendar)
        try Task.checkCancellation()
        detail = loaded
        detailErrorMessage = nil
    } catch is CancellationError {
        return
    } catch {
        detail = nil
        detailErrorMessage = String(describing: error)
    }
}
```

- [ ] **Step 7: Remove the unbounded API and obsolete tests**

Delete `Aggregator.fetchDays`, `AppEnvironment.fetchDaysList`, and the two `fetchDays` tests in `AggregatorDSTTests` that assert raw timestamp-descending scanning. Keep the existing `fetchDayDetail` and `fetchEventsForSessionOnDay` DST tests. Verify no compatibility path remains:

```sh
rg -n "fetchDays\(|fetchDaysList|query\.days\.list" QuotaMonitor Tests
```

Expected: no matches.

- [ ] **Step 8: Confirm GREEN and commit Task 5**

Run:

```sh
swift test --disable-keychain --filter HistoryPaginationTests
swift test --disable-keychain --filter HistoryPaginationStateTests
swift test --disable-keychain --filter HistoryPaginationScrollBridgeTests
swift test --disable-keychain --filter HistoryViewWiringTests
swift test --disable-keychain --filter AggregatorDSTTests
swift test --disable-keychain --filter BrandingLocalizationTests
```

Expected: all focused suites pass, the old raw scan is absent, and Swift 6 strict-concurrency compilation accepts the AppKit observer isolation.

Commit:

```sh
git add QuotaMonitor/App/QueryFacade.swift \
  QuotaMonitor/Core/Analytics/AggregatorHistory.swift \
  QuotaMonitor/Core/Localization/L10n.swift \
  QuotaMonitor/Features/History/HistoryView.swift \
  Tests/QuotaMonitorTests/AggregatorDSTTests.swift \
  Tests/QuotaMonitorTests/BrandingLocalizationTests.swift \
  Tests/QuotaMonitorTests/HistoryViewWiringTests.swift
git commit -m "Lazy-load older History pages"
```

---

### Task 6: Add release notes and pass deterministic repository gates

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`

**Interfaces:**

- Consumes: the complete implementation from Tasks 1–5.
- Produces: bilingual user-facing release notes and a deterministic green branch ready for GUI QA.

- [ ] **Step 1: Add exact Unreleased entries**

Insert below each `## [Unreleased]` heading.

English:

```markdown
#### Summary

- History now opens quickly with the latest week and loads older weeks only when you scroll down.

### Fixed

- **Faster History loading.** History now queries seven calendar days at a time and loads the previous week only after a downward scroll, avoiding a full-history scan whenever the page opens.
```

Simplified Chinese, keeping each bullet on one physical line:

```markdown
#### Summary

- 历史页面现在会先快速显示最近一周，并在继续向下滚动时再加载更早记录。

### 修复

- **历史记录按周懒加载。** 历史页面现在每次只查询连续 7 个自然日，并在用户向下滚动后再加载前一周，避免每次打开都扫描全部历史记录。
```

- [ ] **Step 2: Validate changelog policy**

Run:

```sh
python3 tools/validate-release-notes.py Unreleased CHANGELOG.md CHANGELOG.zh-Hans.md
```

Expected: the command passes and reports matching English/Chinese Unreleased structure.

- [ ] **Step 3: Run all deterministic and Release gates**

Run:

```sh
swift test --disable-keychain
./qa/run-static.sh
swift build -c release --disable-keychain
git diff --check origin/main...HEAD
git status --short --branch
```

Expected: the full Swift suite and static QA pass, Release builds, diff check is silent, and only the intended changelog files remain uncommitted.

- [ ] **Step 4: Commit Task 6**

```sh
git add CHANGELOG.md CHANGELOG.zh-Hans.md
git commit -m "Document faster History loading"
```

- [ ] **Step 5: Validate committed PR changelog coverage**

Run:

```sh
python3 tools/validate-pr-changelog.py --base origin/main --head HEAD
```

Expected: the committed branch satisfies the non-appcast bilingual changelog policy.

---

### Task 7: Verify Release behavior with fixture and current real data

**Files:**

- Local-only artifacts: `.build/qa-artifacts/$RUN_ID-computer-use-fixture-smoke/`
- Local-only artifacts: `.build/qa-artifacts/$RUN_ID-computer-use-real-data/`

**Interfaces:**

- Consumes: the committed implementation and the repository `quota-monitor-computer-qa` workflow.
- Produces: privacy-safe screenshots, current real-data counts/timings, one-page-per-gesture evidence, artifact-contract evidence, and clean QA teardown.

- [ ] **Step 1: Run deterministic fixture UI QA first**

Run:

```sh
CONFIG=release ./qa/prepare-computer-use-fixture-smoke.sh
FIXTURE_ARTIFACT_DIR="$(find "$PWD/.build/qa-artifacts" -maxdepth 1 -type d \
  -name '*-computer-use-fixture-smoke' | sort | tail -n 1)"
```

Open `$FIXTURE_ARTIFACT_DIR/computer-use-qa.md` and target its exact `Computer Use app target`. The existing fixture's recent week is empty and older events are in 2026-06-19 through 2026-06-21. Verify the initial page shows the localized recent-empty guidance without jumping; one deliberate downward gesture loads the older populated window; waiting and momentum do not load another page. Capture window-only screenshots before and after the gesture, then run:

```sh
./qa/check-artifacts.sh "$FIXTURE_ARTIFACT_DIR"
"$FIXTURE_ARTIFACT_DIR/cleanup-computer-use.sh"
```

Expected: artifact contract passes and the QA app closes without stopping the installed app.

- [ ] **Step 2: Start Release real-data shadow QA and unified-log capture**

Run:

```sh
CONFIG=release ./qa/prepare-computer-use-real-data.sh
ARTIFACT_DIR="$(find "$PWD/.build/qa-artifacts" -maxdepth 1 -type d \
  -name '*-computer-use-real-data' | sort | tail -n 1)"
QA_PID="$(plutil -extract pid raw -o - "$ARTIFACT_DIR/app-state.json")"
/usr/bin/log stream --info --style compact \
  --predicate "processIdentifier == $QA_PID AND subsystem == \"dev.tjzhou.QuotaMonitor\" AND category == \"query\" AND composedMessage CONTAINS \"event=query.days.page\"" \
  >"$ARTIFACT_DIR/history-page-unified.log" 2>&1 &
LOG_STREAM_PID=$!
```

Open `$ARTIFACT_DIR/computer-use-qa.md` and use its exact app target for the next step. The unified logger captures query operations without changing the user's Developer Mode preference.

- [ ] **Step 3: Measure initial and next-page behavior on the exact QA app**

With Computer Use, activate the exact QA app, start a timestamped observation, and click History. Record click-to-visible duration and confirm only one facade `query.days.page.start/finish` pair plus its `query.days.page.database.start/finish` pair with trigger `initial`. Wait without scrolling and confirm no second pair. Scroll downward once inside the sidebar and confirm exactly one new pair of each layer with trigger `scroll`, older rows append, and selection/detail stay unchanged. Let momentum finish and confirm no third pair; use a new downward gesture and confirm the third page then loads.

Repeat a first-page check for All, Codex, and Claude using the toolbar filter; each remount must issue exactly one initial operation. Open a day, expand a session, and verify detail/session-event rendering still works. Then stop the log stream:

```sh
kill "$LOG_STREAM_PID"
wait "$LOG_STREAM_PID" 2>/dev/null || true
rg "event=query.days.page" "$ARTIFACT_DIR/history-page-unified.log"
```

Acceptance:

```text
initial query.days.page.database.finish duration_ms < 100
next query.days.page.database.finish duration_ms < 100
query.days.page.finish retained as facade/data-ready diagnostic
History click to visible initial rows < 500 ms
one physical gesture generation == at most one appended page
```

- [ ] **Step 4: Record current counts and source-protection evidence**

Run:

```sh
SHADOW_DB="$(plutil -extract databasePath raw -o - "$ARTIFACT_DIR/app-state.json")"
sqlite3 "$SHADOW_DB" <<'SQL'
.headers on
.mode column
SELECT COUNT(*) AS events,
       COUNT(DISTINCT date(timestamp, 'localtime')) AS active_days,
       SUM(CASE
             WHEN date(timestamp, 'localtime') >= date('now', 'localtime', '-6 days')
             THEN 1 ELSE 0
           END) AS initial_window_events,
       MIN(timestamp) AS first_event,
       MAX(timestamp) AS last_event
FROM usage_events;
SQL
grep -q '^source_unchanged=true$' "$ARTIFACT_DIR/real-data-protection.txt"
grep -q '^copied_user_defaults=true$' "$ARTIFACT_DIR/user-defaults-shadow.txt"
grep -q '^safety_overrides=none$' "$ARTIFACT_DIR/user-defaults-shadow.txt"
./qa/check-artifacts.sh "$ARTIFACT_DIR"
```

Expected: all protection checks pass. Compare the fresh counts/timings with the baseline of 61,628 events, 101 active days, 5,222 events in the initial natural seven-day window, and 4,291 ms for the old list query; report fresh values if live imports changed them.

- [ ] **Step 5: Clean up and verify installed-app restoration**

Run:

```sh
"$ARTIFACT_DIR/cleanup-computer-use.sh"
pgrep -alf QuotaMonitor || true
```

Expected: no QA-configured process remains; if `/Applications/QuotaMonitor.app` was running before QA, only that installed app is restored.

---

### Task 8: Final review, push, and open a Ready pull request

**Files:**

- No repository file changes expected unless review finds a concrete defect.
- Temporary PR body: `/tmp/quota-monitor-history-pr.md`.

**Interfaces:**

- Consumes: green commits, deterministic/real-data evidence, privacy-safe fixture screenshots, and current `origin/main`.
- Produces: a pushed `codex/dashboard-history-performance` branch and Ready pull request.

- [ ] **Step 1: Run completion review and final repository checks**

Use `superpowers:requesting-code-review` for an independent code/spec review, address every actionable finding with a focused RED/GREEN commit, then use `superpowers:verification-before-completion`. Run:

```sh
git fetch --prune origin
git status --short --branch
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
swift test --disable-keychain
./qa/run-static.sh
swift build -c release --disable-keychain
python3 tools/validate-pr-changelog.py --base origin/main --head HEAD
```

Expected: clean worktree, intended commits only, all commands pass, and no unbounded History API remains.

- [ ] **Step 2: Prepare the complete PR body from recorded evidence**

Create `/tmp/quota-monitor-history-pr.md` with `apply_patch`. Use these exact sections and insert the concrete counts and timings recorded in Task 7 directly into the Performance bullets:

```markdown
## Summary
- Load History in indexed seven-calendar-day pages.
- Require a genuine downward sidebar gesture before loading each older page.
- Preserve DST-correct day boundaries, provider filters, selection, and lazy session events.

## Root cause
`fetchDays(limit: 365)` parsed and bucketed every matching event when the database had fewer than 365 active days. The 61,628-event baseline spent 4,291 ms in `query.days.list`.

## Verification
- Focused History query/state/scroll/UI suites
- `swift test --disable-keychain`
- `./qa/run-static.sh`
- `swift build -c release --disable-keychain`
- Release fixture Computer Use QA
- Release real-data shadow Computer Use QA with `source_unchanged=true`

## Performance
- Current event, active-day, and initial-page counts from the Task 7 SQLite report
- Initial and next page `duration_ms` values from `history-page-unified.log`
- History click-to-visible duration from the Task 7 Computer Use observation
- One gesture loaded at most one page; a new gesture was required for the next page

## Screenshots
- Initial seven-day fixture state
- State after one downward gesture
```

Attach only the privacy-safe fixture screenshots. Keep real session titles, values, and real-data screenshots local.

- [ ] **Step 3: Push and create the Ready PR**

Run:

```sh
git push -u origin codex/dashboard-history-performance
gh pr create \
  --base main \
  --head codex/dashboard-history-performance \
  --title "Load History in seven-day pages" \
  --body-file /tmp/quota-monitor-history-pr.md
gh pr view --json url,isDraft,state,baseRefName,headRefName,mergeStateStatus,statusCheckRollup
gh pr checks --watch
```

Expected: `isDraft` is `false`, base is `main`, head is `codex/dashboard-history-performance`, checks finish successfully, and the PR contains both screenshots plus baseline/final measurements.
