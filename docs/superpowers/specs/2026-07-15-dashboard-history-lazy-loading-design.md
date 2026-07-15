# Dashboard History Seven-Day Lazy Loading

**Date:** 2026-07-15
**Status:** Approved design; awaiting written-spec review

## Background

Opening Dashboard > History currently calls `fetchDaysList(limit: 365)`. The
query orders every matching `usage_events` row by timestamp, then parses and
buckets rows in Swift until it has found the requested number of active days.
When the database contains fewer than 365 active days, the cursor consumes the
entire matching event history on every visit to History.

The current real-data shadow contains 61,628 events across 101 active days. A
Release build spent 4,291 ms in `query.days.list`; the day-detail query took only
13 ms. End-to-end observation was approximately 4.5 seconds, with the Computer
Use action completing after 6.895 seconds including its observation wait. The
bottleneck is therefore the unbounded History list read and per-row date
parsing, not the detail pane or SwiftUI row construction.

On the same database, an indexed SQL aggregation restricted to the latest seven
local-calendar days covered 5,222 events and completed in approximately 6 ms in
the SQLite CLI. This is sufficient evidence to replace the all-history scan
with bounded calendar pages.

## Goals

- The first History load queries only today and the preceding six natural
  calendar days in the user's current calendar and time zone.
- Reaching the bottom through an actual user scroll loads the preceding seven
  natural calendar days.
- Each page uses indexed timestamp ranges and SQL aggregation; it never fetches
  raw event rows merely to construct the day list.
- Local day membership remains correct across 23-, 24-, and 25-hour days.
- Existing provider filtering, automatic selection, day detail, session
  expansion, and event-timeline lazy loading keep their current behavior.
- Initial History content is visible within 500 ms on the current real-data
  shadow, with each page query completing within 100 ms.

## Non-goals

- Do not add a materialized rollup table, schema migration, or persistent
  all-history cache.
- Do not preload the second page merely because the initial seven rows fit in
  the sidebar.
- Do not render blank rows for calendar dates with no usage.
- Do not change Dashboard charts, day-detail aggregation, session ordering, or
  event-timeline presentation.
- Do not retain a 365-active-day compatibility path that can fall back to the
  current unbounded row scan.

## Calendar-page semantics

A page represents seven consecutive natural calendar dates, not seven active
dates and not a rolling 168-hour interval.

For the initial request, let `todayStart` be
`calendar.startOfDay(for: now)`. The query window is:

```text
[calendar.date(byAdding: .day, value: -6, to: todayStart),
 calendar.date(byAdding: .day, value:  1, to: todayStart))
```

The lower boundary becomes the next page's exclusive upper cursor. A subsequent
page ending at cursor `C` is `[C - 7 calendar days, C)`. Calendar arithmetic,
not fixed-second subtraction, produces every boundary. Each boundary is then
encoded as a UTC ISO-8601 string for the database predicates, so a local DST
transition naturally yields a 23- or 25-hour interval.

Dates with no events consume their position in the seven-day window but do not
produce a `DaySummary` row. Returned summaries are newest first. The day key and
`date` continue to use the same injected calendar as the detail query, ensuring
that selecting a list row retrieves exactly the events included in its summary.

## Page result and cursor

Introduce a sendable, equatable page value alongside `DaySummary`:

```swift
struct HistoryPage: Sendable, Equatable {
    let days: [DaySummary]
    let nextCursor: Date
    let hasMore: Bool
}
```

`nextCursor` is the page's lower local-day boundary and is always strictly older
than the request cursor. `hasMore` means at least one matching event exists
before `nextCursor` for the current provider filter. The query facade exposes a
page-oriented operation, taking an optional exclusive upper cursor, page size
defaulting to seven, an injectable `now`, and the calendar used to form local
days. Production captures `Calendar.current` and `now` for the first request;
tests pass fixed values.

The first request captures one calendar and time-zone snapshot for the whole
paging session. Page ranges, day keys, and day-detail requests use that same
snapshot. A provider-filter, system-time-zone, or current-calendar change
cancels outstanding work and starts a new first-page session; it never continues
an existing cursor under different calendar rules. The view observes the
standard system time-zone and current-locale change notifications while it is
alive; recreating the view naturally captures a new snapshot.

The view owns the cursor and never uses SQL `OFFSET`. Appending a page deduplicates
by `DaySummary.id` as a defensive invariant, while cursor monotonicity is the
primary guarantee against overlaps or gaps. Changing/recreating the History tab
starts a fresh first-page request; cross-tab caching is outside this change.

## Bounded SQL aggregation

For each page, Swift first creates the seven explicit local-day ranges. One
database read aggregates the ranges with seven parameterized `UNION ALL`
branches. Each branch has the following shape:

```sql
SELECT
  ? AS day_key,
  ? AS ordinal,
  SUM(value_usd) AS value_usd,
  SUM(total_tokens) AS tokens,
  COUNT(*) AS events,
  COUNT(DISTINCT session_id) AS sessions
FROM usage_events
WHERE timestamp >= ? AND timestamp < ?
  -- optional provider predicate
```

An aggregate branch returns one row even for an empty range; Swift discards rows
whose event count is zero and sorts the remainder by ordinal. There is no SQL
`date(..., 'localtime')`, fixed-offset modifier, raw-row timestamp parsing, or
whole-table `GROUP BY`.

The all-provider path uses `idx_usage_events_timestamp`; filtered paths use the
existing `(provider, timestamp)` index. `EXPLAIN QUERY PLAN` tests must confirm
that every aggregation branch performs an indexed range search and that no
temporary B-tree for `ORDER BY` or unbounded `ORDER BY timestamp` scan returns.

After aggregation, an indexed existence query determines whether any matching
event is older than the page's lower bound. It selects at most one timestamp
with `timestamp < ?`, applies the same provider filter, and uses descending
timestamp order plus `LIMIT 1`. This result sets `hasMore` without scanning all
older events.

The initial request never follows that older timestamp: it returns only the
latest seven-date window, even when that window is empty. For pagination
requests, if an entire seven-day page is empty while older matching data exists,
the same page operation uses the indexed newest-older timestamp to skip invisible
empty windows. It converts the timestamp to its local day, builds one seven-day
window ending immediately after that local day, and aggregates that window. The
operation repeats only if a concurrent deletion makes the candidate window
empty; cursor movement must remain strictly older on every attempt. From the
user's perspective, one scroll still yields the next visible group of up to
seven consecutive dates without inventing blank rows or stalling at a gap.
The returned `nextCursor` is the lower boundary of this final jumped window, and
`hasMore` is recomputed strictly before that final boundary; neither value may
be reused from the originally requested empty window.

## History view state

`HistoryView` separates initial loading from pagination:

- `days`, `selection`, and `detail` retain their present roles;
- `nextCursor` and `hasMore` describe the next page;
- `isLoadingInitial` controls the full-sidebar progress state;
- `isLoadingNextPage` controls a footer progress state and enforces single
  flight;
- `initialError` replaces the empty first page;
- `paginationError` preserves loaded rows and offers an inline Retry action.

The initial `.task` requests exactly one page. It auto-selects the newest
returned active day exactly as today. Pagination appends without changing a
valid selection or reloading its detail. If the first page is empty but
`hasMore` is true, the sidebar shows localized “no usage in the latest seven
days” guidance and keeps the pagination footer available for a deliberate
scroll. Only an empty page with `hasMore == false` uses the existing all-history
empty state.

Every page-loading async path checks cancellation before applying results. A
request captures its provider filter and cursor; stale results from a cancelled
or superseded task are not appended. The next-page guard rejects calls when a
request is already running or `hasMore` is false. A failed next page leaves the
cursor unchanged so Retry requests the identical window.

## Genuine-scroll trigger on macOS 14

A plain footer `.onAppear` or `.task` is explicitly forbidden: the sidebar can
display roughly fourteen rows, so a seven-row first page makes its footer visible
immediately and would silently preload page two.

QuotaMonitor supports macOS 14, where the newer SwiftUI scroll-phase APIs are
unavailable. Add a narrow AppKit bridge attached to the History `List`. The
bridge locates that list's enclosing `NSScrollView` and observes its
will-start, did-scroll, and did-end live-scroll notifications. A live-scroll
generation belongs only to that exact scroll view; movement direction is
determined by comparing successive document-visible rectangles.

The bridge is hosted by the pagination footer so it can compare the footer's
actual frame in document coordinates with the scroll view's
`documentVisibleRect`. SwiftUI `.onAppear` is not treated as visibility evidence.

The bridge also installs a local `NSEvent` monitor for scroll-wheel events. It
accepts an event only when the event belongs to the History window and its
window-space point lies inside this exact sidebar scroll view. This supplies a
genuine user-gesture signal even when seven rows and the footer already fit, a
case where the clip-view origin does not change and AppKit may emit no live-scroll
notification. The monitor normalizes the event delta into downward document
movement, observes without consuming or modifying the event, and ignores upward
and horizontal-only input. The scroll-view notifications remain useful for
scrollbar drags and for reevaluating bottom geometry as the visible rectangle
moves.

Pagination fires only when both conditions have occurred for the current page:

1. the user generated a downward scroll gesture inside this sidebar after the
   page became current;
2. the footer frame intersects the document's visible rectangle.

Either ordering is valid: scrolling can arm the page before the footer appears,
or an initially visible footer can wait for a deliberate scroll gesture. The
gate is consumed before starting the async request.

The bridge assigns a generation to each physical gesture. Trackpad phase and
live-scroll start/end notifications delimit a generation; phase-less mouse-wheel
events share a generation until 250 ms has elapsed without another wheel event.
A generation can be consumed at most once. Trackpad momentum remains part of the
originating generation through its momentum-ended phase; a missing end phase
falls back to the same 250 ms idle boundary. Momentum and changed-phase events
from a consumed generation stay consumed even if a fast page append finishes
before the gesture ends. Notifications while `isLoadingNextPage` is true never
create a pending generation for the appended page. Loading another page
therefore requires a newly started gesture, and one long inertial scroll cannot
cascade through page two into page three.

The coordinator removes the local event monitor and every notification observer
when its view is dismantled, and rebinds them if SwiftUI replaces the enclosing
scroll view. The initial render creates no gesture generation and never performs
a second query.

When `hasMore` is false, the footer shows no spinner and the bridge does not arm
another request. The pagination error Retry button is an explicit user action
and does not require another scroll gesture.

## Logging and diagnostics

Replace the list operation's all-history semantics with
`query.days.page`. Each operation records:

- provider filter;
- page size;
- initial versus pagination trigger;
- UTC lower and upper query bounds;
- number of visible day rows;
- whether more data exists;
- elapsed duration through the existing operation logger.

Logs contain only bounds and counts, never event payloads, session titles, or
local database paths. The day-detail operation remains independently timed so a
future detail regression cannot be confused with list pagination.

## Errors and user-visible behavior

An initial query failure shows the existing error treatment in place of the
list. A pagination failure leaves all loaded days selectable, replaces the
footer spinner with a compact localized error and Retry button, and does not
clear the detail pane. A successful retry clears only the pagination error.

Any new visible strings, including Retry or pagination failure copy, must use
the existing localization system and include Simplified Chinese and English.
The header count continues to show the number of loaded active-day rows rather
than implying an all-history total.

## Test-first implementation

Write failing tests before production changes. Automated coverage must prove:

- the first page covers today plus the preceding six local dates;
- later pages use the previous lower boundary and have no overlap or gap;
- spring-forward and fall-back events land in the correct 23- and 25-hour local
  days;
- empty dates consume window positions without producing blank summaries;
- an empty initial window does not aggregate older data and accurately reports
  whether older data exists;
- a fully empty pagination window jumps to older indexed data or reports
  exhaustion;
- all, Codex, and Claude provider filters return and continue independently;
- sums, token counts, event counts, and distinct session counts match the
  existing day-detail summary for every returned date;
- query tracing and `EXPLAIN QUERY PLAN` reject the former unbounded raw-row
  scan, full table scans, and a temporary B-tree used for `ORDER BY`, while
  confirming timestamp-range index use; a bounded temporary structure used by
  `COUNT(DISTINCT session_id)` is permitted;
- the view pagination reducer/state helper enforces single flight, monotonic
  cursor advancement, deduplication, cancellation/stale-result rejection, and
  retry with an unchanged cursor;
- the AppKit bridge tests or a focused seam prove footer-frame visibility,
  in-scroll-view event filtering, downward-direction filtering, one load per
  gesture generation, momentum suppression, and phase-less wheel debouncing;
- source/static UI checks reject a footer-only initial `.onAppear` trigger and
  pin the user-gesture-plus-footer-geometry gate;
- switching provider or recreating History performs one fresh initial-page
  request.

Run targeted suites while iterating, then the repository gates:

```sh
swift test --disable-keychain --filter AggregatorDSTTests
swift test --disable-keychain --filter HistoryPaginationTests
swift test --disable-keychain
./qa/run-static.sh
```

## Real-data performance and UI verification

Use `quota-monitor-computer-qa` with the read-only shadow workflow and a Release
build. The source database must be fingerprinted before and after and remain
unchanged. Verification must demonstrate:

- the shadow still contains 61,628 events and the first natural seven-day page
  still represents 5,222 events, unless live imports legitimately changed the
  source before the final run;
- clicking History issues one `query.days.page` operation and no second page
  query before an actual scroll;
- the first page query is under 100 ms and visible History content appears
  within 500 ms on this machine;
- scrolling to the footer issues exactly one next-page query, under 100 ms, and
  appends older rows without changing the selected day;
- another page requires another genuine downward scroll;
- an empty-gap fixture continues to older history instead of leaving the list
  permanently armed or stalled;
- selection, provider filtering, detail loading, and session expansion remain
  functional;
- screenshots capture the initial seven-day state and the appended state for
  the pull request.

If the live source changes, report the final event/day counts and page cardinality
alongside the timings rather than comparing against stale values. The acceptance
thresholds remain 100 ms for the database page and 500 ms to visible initial
content.

## Expected files and delivery

Implementation is expected to touch:

- `QuotaMonitor/Core/Analytics/AggregatorHistory.swift` for page ranges and
  bounded aggregation;
- `QuotaMonitor/Core/Analytics/Aggregator.swift` for the page value;
- `QuotaMonitor/App/QueryFacade.swift` for the logged async page operation;
- `QuotaMonitor/Features/History/HistoryView.swift` and a narrowly scoped helper
  for pagination state and the AppKit scroll observer;
- focused suites under `Tests/QuotaMonitorTests/` plus static QA coverage if
  needed;
- both `CHANGELOG.md` and `CHANGELOG.zh-Hans.md` under Unreleased.

After deterministic and real-data verification, commit the implementation,
push `codex/dashboard-history-performance`, and open a Ready pull request with
the baseline/after timings, verification commands, source-unchanged evidence,
and UI screenshots.
