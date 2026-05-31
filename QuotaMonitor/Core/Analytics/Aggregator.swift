import Foundation
import GRDB

// Read-side query API for the Dashboard.
//
// Method definitions are split across topic-focused files for readability:
//   - AggregatorReports.swift     — loadDashboard, overview, daily/monthly,
//                                    per-model + per-provider shares
//   - AggregatorSessions.swift    — sessions list / detail / subagents
//   - AggregatorHistory.swift     — day rollups + per-day detail
//   - AggregatorRateLimits.swift  — Codex quota snapshot + burn rates +
//                                    raw history series
//
// All queries take a GRDB `Database` so they can compose inside one read transaction.

// MARK: - Types

struct OverviewStats: Sendable, Equatable {
    let totalValueUSD: Double
    let totalTokens: Int64
    let totalSessions: Int
    let totalEvents: Int
    let firstEventAt: String?
    let lastEventAt: String?
}

struct DailyPoint: Sendable, Identifiable, Equatable {
    let date: Date
    var id: Date { date }
    let valueUSD: Double
    let tokens: Int64
}

/// Monthly bucket for the Dashboard's "Monthly trend" section. `month` is
/// the first instant of the local-calendar month (so chart axes align).
/// Mirrors ccusage's `monthly` report (`monthly.ts`) and pacer's
/// `subscription_month` window — but our scope is just visualization,
/// no subscription anchoring.
struct MonthlyPoint: Sendable, Identifiable, Equatable {
    let month: Date
    var id: Date { month }
    let valueUSD: Double
    let tokens: Int64
    let sessionCount: Int
}

struct ModelShare: Sendable, Identifiable, Equatable {
    let modelId: String
    let displayName: String
    var id: String { modelId }
    let valueUSD: Double
    let tokens: Int64
    let eventCount: Int
}

struct DashboardSnapshot: Sendable, Equatable {
    let overview: OverviewStats
    let daily: [DailyPoint]          // last 14 days, oldest first
    /// Last 60 days, oldest first. Used by the Dashboard's Trends section
    /// to compute the rolling-30d total and the Δ vs the prior 30 days.
    /// We pull 60 days in one shot rather than two queries because the
    /// shape is identical to `daily` and the cost is negligible.
    let dailyExtended: [DailyPoint]
    /// Last 12 calendar months, oldest first. Zero-filled.
    let monthly: [MonthlyPoint]
    let modelShares: [ModelShare]    // sorted desc by valueUSD (lifetime)
    /// Per-model spend over the last 30 days. Powers the Composition
    /// section's bar list + insight line. Sorted desc by valueUSD.
    let modelShares30d: [ModelShare]
    /// Per-model spend over the prior 30-day window (days 30…60). Used to
    /// compute the per-model delta surfaced in the Composition section's
    /// auto-insight sentence ("Opus 4 = 67% of spend, +12pp vs prior 30d").
    let modelSharesPrior30d: [ModelShare]
    /// Per-provider spend over the last 30 days, used by the Composition
    /// donut. Keys are the canonical `provider` strings ("codex" /
    /// "claude").
    let providerShares30d: [ProviderShare]
    let recentRateLimits: [RateLimitHistoryPoint]
    /// Codex 5h / weekly quota snapshot. Nil when filter is Claude-only or
    /// when no rate-limit samples have ever been recorded. Mirrors pacer's
    /// quota5h / quota7d cards (`MenuBarPopup.tsx:247`).
    let codexQuota: CodexQuotaSnapshot?
    /// Lifetime / engagement profile (lifetime tokens, peak day, longest
    /// task, active-day streaks) plus the trailing ~1-year daily series
    /// behind the ActivitySection heatmap. Provider-aware via
    /// `loadDashboard`. See `AggregatorActivity.swift`.
    let activity: ActivitySnapshot
}

/// Compact provider-level slice, currently scoped to "last 30 days" for
/// the Composition donut. Keeping it as its own type rather than reusing
/// `ProviderStats` because we only need two scalars here and `ProviderStats`
/// carries a lot of menu-bar-specific fields.
struct ProviderShare: Sendable, Identifiable, Equatable {
    let provider: String  // "codex" | "claude"
    var id: String { provider }
    let valueUSD: Double
}

/// Most-recent rate-limit sample per bucket. Pacer separates `primary` (5h)
/// and `secondary` (weekly) windows; we follow the same convention. The
/// primary bucket includes a `live` source (app-server REST) and a `jsonl`
/// source (parsed from token_count.rate_limits) — we always prefer the
/// freshest sample regardless of source so live updates win when available.
struct CodexQuotaSnapshot: Sendable, Equatable {
    let primary: CodexQuotaWindow?
    let secondary: CodexQuotaWindow?
    /// Burn rate per bucket derived from the last hour of samples, if we
    /// have at least two distinct timestamps. Used to project exhaustion
    /// time on the quota card. Empty when there's not enough history.
    let burn: [String: CodexBurnRate]
}

/// Linear extrapolation of `used_percent` over the recent sample series.
/// Mirrors what ccusage's `BurnRateCalculator.projectExhaustionTime` does
/// for Anthropic, applied to OpenAI's quota counters instead.
struct CodexBurnRate: Sendable, Equatable {
    /// Percentage points consumed per minute (>0 means usage rising).
    let percentPerMinute: Double
    /// Sample count fed into the regression — UI shows "n samples" caption.
    let sampleCount: Int

    /// Minutes until usedPercent hits 100, or nil when we're at/past 100,
    /// when burn is non-positive (idle), or when the projection lands
    /// after the natural window reset.
    func minutesUntilExhaustion(currentPercent: Double) -> Double? {
        guard percentPerMinute > 0.001, currentPercent < 100 else { return nil }
        return (100 - currentPercent) / percentPerMinute
    }
}

struct CodexQuotaWindow: Sendable, Equatable {
    let bucket: String              // "primary" | "secondary"
    let sourceKind: String          // "live" | "jsonl"
    let planType: String?
    let sampleAt: Date
    let windowStart: Date?
    let resetsAt: Date
    let usedPercent: Double
    let remainingPercent: Double

    /// Seconds remaining until window resets (clamped >= 0). Nil if reset
    /// time is unparseable; UI should hide the countdown in that case.
    func secondsUntilReset(now: Date = Date()) -> TimeInterval {
        max(0, resetsAt.timeIntervalSince(now))
    }

    /// Time-axis percent: how much of the window is still ahead of us.
    /// Mirror of pacer's `computeRemainingTimePercent` (`MenuBarPopup.tsx:24`).
    /// Nil when window_start is missing (jsonl samples sometimes are).
    func remainingTimePercent(now: Date = Date()) -> Double? {
        guard let start = windowStart else { return nil }
        let total = resetsAt.timeIntervalSince(start)
        guard total > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return max(0, min(100, remaining / total * 100))
    }
}

/// Per-provider rollup powering the menu bar's "always show both" KPI rows.
/// Decoupled from `ProviderFilter` so the menu bar never goes blank just
/// because the Dashboard is currently filtered to the other provider.
struct ProviderStats: Sendable, Equatable {
    let provider: String      // "codex" | "claude"
    let totalValueUSD: Double
    let totalTokens: Int64
    let eventCount: Int
    let sessionCount: Int
    let lastActivityAt: String?
    /// Cost over the last 7 calendar days. Used by the menu bar's Claude
    /// section as a stand-in for the 7-day quota OpenAI exposes (Anthropic
    /// has no equivalent live counter — see `claude7DayValueUSD` below).
    var last7dValueUSD: Double = 0
    var last7dTokens: Int64 = 0
    /// Distinct sessions touched in the last 7 calendar days. Mirrors
    /// `last30dSessionCount` so the menu bar can swap windows without
    /// losing the session-count chip in the top-right.
    var last7dSessionCount: Int = 0
    /// API-equivalent cost over a rolling 30-day window. Surfaced as the
    /// menu bar's KPI headline because lifetime totals grow without bound
    /// and stop being useful for "how much am I using lately" decisions.
    var last30dValueUSD: Double = 0
    /// Tokens consumed in the same rolling 30-day window. Pairs with
    /// `last30dSessionCount` in the menu bar's secondary KPI line so all
    /// numbers in the provider block share one time horizon.
    var last30dTokens: Int64 = 0
    var last30dSessionCount: Int = 0
    var hasData: Bool { eventCount > 0 }
}

/// Which rolling window powers the menu bar's headline `$X.XX · Yk
/// tokens` line and the session-count chip. Persisted in
/// `SettingsStore.menuBarHeadlineWindow`.
/// Renderers (`ProviderBlock`, `DashboardView`) pick the right field
/// off `ProviderStats` based on this enum so the data layer stays
/// window-agnostic.
enum HeadlineWindow: String, CaseIterable, Sendable, Identifiable {
    case last7d
    case last30d
    var id: String { rawValue }
}

/// What the menu bar renders. Always includes both providers + Anthropic 5h
/// block; never gated by `providerFilter`.
struct MenuBarSnapshot: Sendable, Equatable {
    let codex: ProviderStats
    let claude: ProviderStats
    let anthropicBlocks: BillingBlocks.Snapshot

    static func empty(_ provider: String) -> ProviderStats {
        ProviderStats(
            provider: provider, totalValueUSD: 0, totalTokens: 0,
            eventCount: 0, sessionCount: 0, lastActivityAt: nil)
    }
}

struct RateLimitHistoryPoint: Sendable, Identifiable, Equatable {
    let id: Int64
    let sampleAt: Date
    let bucket: String          // "primary" | "secondary"
    let series: String          // "primary (live)" / "secondary (jsonl)" etc.
    let usedPercent: Double
}

struct SessionRow: Sendable, Identifiable, Equatable {
    let sessionId: String
    var id: String { sessionId }
    let title: String?
    let agentNickname: String?
    let lastModelId: String?
    let startedAt: String?
    let updatedAt: String?
    let totalValueUSD: Double
    let totalTokens: Int64
    let eventCount: Int
    /// True if this session has at least one descendant subagent. Set by the
    /// importer's reconciliation pass; defaults to false for Claude rows.
    let containsSubagents: Bool
    /// Number of direct child subagent sessions, or nil when not requested
    /// (most list queries skip this — it's only filled in for session detail).
    let subagentCount: Int?
    /// True iff at least one event in this session had its model inferred via
    /// the legacy fallback (gpt-5). Surfaces an asterisk in the row so users
    /// know the cost is approximate.
    let hasInferredModel: Bool
}

/// Top-level provider filter applied to every dashboard / list query.
/// `.all` is the union view; `.codex` and `.claude` restrict to one source.
enum ProviderFilter: String, CaseIterable, Identifiable, Sendable, Hashable {
    case all
    case codex
    case claude
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:    return L10n.providerAll
        case .codex:  return L10n.providerCodex
        case .claude: return L10n.providerClaude
        }
    }

    /// SQL fragment that must be combined with `AND` (or used as the only
    /// predicate). Includes leading space; empty for `.all`.
    func clause(table: String) -> String {
        switch self {
        case .all:    return ""
        case .codex:  return " AND \(table).provider = 'codex'"
        case .claude: return " AND \(table).provider = 'claude'"
        }
    }
    func whereClause(table: String) -> String {
        switch self {
        case .all:    return ""
        case .codex:  return " WHERE \(table).provider = 'codex'"
        case .claude: return " WHERE \(table).provider = 'claude'"
        }
    }
}

enum SessionSort: String, CaseIterable, Identifiable, Sendable {
    case recent       // updated_at DESC
    case value        // total_value DESC
    case tokens       // total_tokens DESC
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return L10n.sortRecent
        case .value:  return L10n.sortValue
        case .tokens: return L10n.sortTokens
        }
    }

    var orderClause: String {
        switch self {
        case .recent: return "COALESCE(s.updated_at, s.started_at) DESC"
        case .value:  return "total_value DESC"
        case .tokens: return "total_tokens DESC"
        }
    }
}

struct SessionDetail: Sendable, Equatable {
    let header: SessionRow
    let events: [Event]   // ordered by timestamp ASC
    let modelBreakdown: [ModelShare]
    /// Direct-child subagent sessions, ordered most-recently-active first.
    /// Empty when the session has no subagents.
    let subagents: [SessionRow]

    struct Event: Sendable, Identifiable, Equatable {
        let id: Int64
        let timestamp: String
        /// "codex" | "claude". The two providers store `input_tokens`
        /// with different semantics — Claude reports the uncached
        /// remainder (so `input + cacheRead + cacheCreate + output =
        /// total`), Codex inherits OpenAI's `prompt_tokens` which is
        /// the FULL prompt including the cached portion (so
        /// `input + output = total`, with `cached_input_tokens` being
        /// a subset of `input_tokens`). The EventRow popover uses
        /// this flag to compute "uncached input" consistently across
        /// providers without changing what's stored in the DB.
        let provider: String
        let modelId: String
        let inputTokens: Int64
        /// Tokens served back from cache on this request. Both Codex
        /// and Claude expose this; equivalent to "cache read" in the
        /// Anthropic billing UI.
        let cachedInputTokens: Int64
        /// Claude-only: prompt tokens written into the per-conversation
        /// cache on this turn. Codex's cache is server-managed and not
        /// separately metered, so for Codex rows this is always 0.
        /// Split across the 5-minute and 1-hour cache TTLs in the
        /// schema (migration v6); the UI sums them because users care
        /// about "how much did this turn pay for cache writes" more
        /// than the TTL split.
        let cacheCreation5mTokens: Int64
        let cacheCreation1hTokens: Int64
        let outputTokens: Int64
        let reasoningOutputTokens: Int64
        let totalTokens: Int64
        let valueUSD: Double
        /// True iff the parser inferred the model from the legacy fallback
        /// (no turn_context / payload model anywhere in the session). UI
        /// asterisks the cost so users know it's approximate.
        let modelInferred: Bool
    }
}

// MARK: - History (day-bucketed)

struct DaySummary: Sendable, Identifiable, Equatable {
    let day: String           // "yyyy-MM-dd" in local calendar
    let date: Date            // start-of-day in local TZ
    var id: String { day }
    let valueUSD: Double
    let tokens: Int64
    let eventCount: Int
    let sessionCount: Int
}

struct DayDetail: Sendable, Equatable {
    let summary: DaySummary
    let modelBreakdown: [ModelShare]
    let sessions: [SessionRow]      // sessions with at least one event on this day,
                                    // values restricted to events on that day
}

/// Namespace for read-side queries. Method definitions live in
/// `AggregatorReports.swift`, `AggregatorSessions.swift`,
/// `AggregatorHistory.swift`, and `AggregatorRateLimits.swift`.
enum Aggregator {

    /// Accept the three timestamp shapes Codex / SQLite / our parser emit.
    /// Used by the rate-limit query family.
    static func parseTimestamp(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = ISO8601.fractional.date(from: s) { return d }
        if let d = ISO8601.plain.date(from: s) { return d }
        return Self.sqliteFormatter.date(from: s)
    }

    private static let sqliteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
