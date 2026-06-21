import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Regression tests for the Aggregator query layer — the code path that
/// turns raw `usage_events` rows into the menu-bar `$XXX.XX` headline and
/// the Dashboard's per-window totals.
///
/// Pre-2026-04-30 this had zero coverage. The first time it broke (Day-30
/// 30d-window timezone bug) the user noticed because the menu bar was off
/// by 4 hours. These tests pin:
///
///   - `fetchPerProviderStats` returns separate codex / claude rollups,
///     zero-fills missing providers, and computes the 7d + 30d windows
///     from the SAME timestamp horizon.
///   - The 30d window is exclusive on the trailing edge: an event at
///     "now − 31 days" must NOT count, an event at "now − 1 day" must.
///   - DISTINCT session_id counting (not COUNT(*)) — without this the menu
///     bar's "149 ses" line over-counts events.
@Suite("Aggregator queries")
struct AggregatorTests {

    // MARK: - in-memory DB harness

    /// Build a fresh on-disk SQLite at a temp path so the GRDB pool can
    /// open it (DatabasePool refuses :memory:). Migrations run as part of
    /// init.
    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "agg-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert one session + one usage_event at `daysAgo` (negative ints
    /// mean past). `valueUSD` is what the Dashboard ultimately surfaces;
    /// the event's `timestamp` is what windowing predicates filter by.
    private func seedEvent(
        in db: DatabaseManager,
        provider: String,
        sessionId: String,
        daysAgo: Double,
        valueUSD: Double,
        tokens: Int64 = 1000,
        turnId: String? = nil,
        billingTier: CodexBillingTier = .unknown,
        billingTierSource: CodexBillingTierSource = .legacy
    ) throws {
        try seedEvent(
            in: db, provider: provider, sessionId: sessionId,
            at: Date().addingTimeInterval(-daysAgo * 86400),
            valueUSD: valueUSD, tokens: tokens, turnId: turnId,
            billingTier: billingTier, billingTierSource: billingTierSource)
    }

    /// Same as the `daysAgo:` overload but pins an absolute timestamp — used by
    /// time-zone boundary tests where the exact wall-clock instant matters.
    private func seedEvent(
        in db: DatabaseManager,
        provider: String,
        sessionId: String,
        at when: Date,
        valueUSD: Double,
        tokens: Int64 = 1000,
        turnId: String? = nil,
        billingTier: CodexBillingTier = .unknown,
        billingTierSource: CodexBillingTierSource = .legacy
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: when)

        try db.pool.write { conn in
            // INSERT OR IGNORE — reusing a session_id across calls is
            // intentional (so we can test DISTINCT counting).
            try conn.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL,
                        'gpt-5', NULL, 0, ?, ?, ?)
                """, arguments: [
                    sessionId, sessionId, stamp, stamp, stamp, stamp, provider
                ])
            try conn.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens, model_inferred,
                 turn_id, billing_tier, billing_tier_source)
                VALUES (?, ?, 'gpt-5', ?, 0, 0, 0, ?, ?, ?, 0, 0, ?, ?, ?)
                """, arguments: [
                    sessionId, stamp, tokens, tokens, valueUSD, provider,
                    turnId, billingTier.rawValue, billingTierSource.rawValue
                ])
        }
    }

    private func seedRateLimitSample(
        in db: DatabaseManager,
        sourceKind: String,
        sampleAt: String,
        bucket: String = "primary",
        usedPercent: Double,
        resetAt: String = "2026-06-03T15:00:00Z"
    ) throws {
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO rate_limit_samples
                  (source_kind, source_session_id, bucket, sample_timestamp,
                   plan_type, limit_name, window_start, resets_at,
                   used_percent, remaining_percent)
                VALUES (?, NULL, ?, ?, NULL, NULL, NULL, ?, ?, ?)
                """, arguments: [
                    sourceKind, bucket, sampleAt, resetAt,
                    usedPercent, max(0, 100 - usedPercent)
                ])
        }
    }

    private func expectModelShareSplits(
        _ share: ModelShare,
        standardValueUSD: Double,
        fastValueUSD: Double,
        unknownValueUSD: Double,
        standardTokens: Int64,
        fastTokens: Int64,
        unknownTokens: Int64
    ) {
        let totalValueUSD = standardValueUSD + fastValueUSD + unknownValueUSD
        let totalTokens = standardTokens + fastTokens + unknownTokens

        #expect(abs(share.valueUSD - totalValueUSD) < 0.0001)
        #expect(share.tokens == totalTokens)
        #expect(abs(share.standardValueUSD - standardValueUSD) < 0.0001)
        #expect(abs(share.fastValueUSD - fastValueUSD) < 0.0001)
        #expect(abs(share.unknownValueUSD - unknownValueUSD) < 0.0001)
        #expect(share.standardTokens == standardTokens)
        #expect(share.fastTokens == fastTokens)
        #expect(share.unknownTokens == unknownTokens)
    }

    // MARK: - per-provider rollups

    @Test("fetchPerProviderStats: separate codex + claude rollups, missing provider zero-filled")
    func perProviderStats_zeroFillsAndSplitsByProvider() throws {
        let db = try makeDatabase()
        // codex: 2 events in 2 sessions, both within the last 7 days
        try seedEvent(in: db, provider: "codex", sessionId: "c-1", daysAgo: 1, valueUSD: 4.50)
        try seedEvent(in: db, provider: "codex", sessionId: "c-2", daysAgo: 5, valueUSD: 3.00)
        // claude: NOTHING — must still return a row with all zeros so the
        // menu bar can render "no data yet" rather than crashing on a nil.

        let stats = try db.pool.read { conn in
            try Aggregator.fetchPerProviderStats(db: conn)
        }
        let codex = try #require(stats["codex"])
        let claude = try #require(stats["claude"])

        #expect(abs(codex.totalValueUSD - 7.50) < 0.0001)
        #expect(codex.eventCount == 2)
        #expect(codex.sessionCount == 2)
        #expect(codex.last7dValueUSD > 0, "both seeded events sit inside the 7d window")
        #expect(codex.hasData == true)

        #expect(claude.totalValueUSD == 0)
        #expect(claude.eventCount == 0)
        #expect(claude.hasData == false,
                "missing provider must zero-fill, not vanish from the dictionary")
    }

    @Test("30d window is exclusive on the trailing edge")
    func thirtyDayWindow_excludesEventAtBoundary() throws {
        let db = try makeDatabase()
        // One event JUST inside (29.5 days ago) and one JUST outside
        // (30.5 days ago). Only the inside one should land in last30d.
        try seedEvent(in: db, provider: "codex", sessionId: "inside",
                      daysAgo: 29.5, valueUSD: 1.00)
        try seedEvent(in: db, provider: "codex", sessionId: "outside",
                      daysAgo: 30.5, valueUSD: 2.00)

        let stats = try db.pool.read { conn in
            try Aggregator.fetchPerProviderStats(db: conn)
        }
        let codex = try #require(stats["codex"])

        #expect(abs(codex.last30dValueUSD - 1.00) < 0.0001,
                "30.5d-old event must NOT contribute to last30dValueUSD")
        #expect(abs(codex.totalValueUSD - 3.00) < 0.0001,
                "lifetime totals always include both")
        #expect(codex.last30dSessionCount == 1)
    }

    @Test("DISTINCT session_id counting (one session, many events → 1, not N)")
    func sessionCountDistinct_notEventCount() throws {
        let db = try makeDatabase()
        // Same session_id used three times.
        try seedEvent(in: db, provider: "codex", sessionId: "shared",
                      daysAgo: 1, valueUSD: 1.00)
        try seedEvent(in: db, provider: "codex", sessionId: "shared",
                      daysAgo: 2, valueUSD: 1.00)
        try seedEvent(in: db, provider: "codex", sessionId: "shared",
                      daysAgo: 3, valueUSD: 1.00)

        let stats = try db.pool.read { conn in
            try Aggregator.fetchPerProviderStats(db: conn)
        }
        let codex = try #require(stats["codex"])

        #expect(codex.eventCount == 3, "raw event count = 3")
        #expect(codex.sessionCount == 1, "lifetime distinct sessions = 1")
        #expect(codex.last30dSessionCount == 1,
                "30d distinct sessions = 1 — without DISTINCT this would be 3")
    }

    // MARK: - daily / monthly bucketing

    @Test("fetchDaily: zero-fills missing days, oldest first")
    func fetchDaily_zeroFillsMissingDays() throws {
        let db = try makeDatabase()
        try seedEvent(in: db, provider: "codex", sessionId: "today",
                      daysAgo: 0.1, valueUSD: 5.00)
        try seedEvent(in: db, provider: "codex", sessionId: "old",
                      daysAgo: 6.0, valueUSD: 2.00)

        let daily = try db.pool.read { conn in
            try Aggregator.fetchDaily(db: conn, days: 7)
        }
        #expect(daily.count == 7, "must always return exactly `days` buckets")
        #expect(daily.first?.date ?? .distantFuture < daily.last?.date ?? .distantPast,
                "must be ordered oldest → newest")

        let totalFromBuckets = daily.reduce(0) { $0 + $1.valueUSD }
        #expect(abs(totalFromBuckets - 7.00) < 0.0001)
    }

    // MARK: - 30d composition share

    @Test("fetchProviderShares30d: always emits both providers, zero-fills missing")
    func providerShares30d_alwaysEmitsBoth() throws {
        let db = try makeDatabase()
        // Codex-only data — claude should still appear with $0.
        try seedEvent(in: db, provider: "codex", sessionId: "x",
                      daysAgo: 5, valueUSD: 12.34)

        let shares = try db.pool.read { conn in
            try Aggregator.fetchProviderShares30d(db: conn)
        }
        #expect(shares.count == 2)
        let codex = try #require(shares.first { $0.provider == "codex" })
        let claude = try #require(shares.first { $0.provider == "claude" })
        #expect(abs(codex.valueUSD - 12.34) < 0.0001)
        #expect(claude.valueUSD == 0,
                "missing provider must zero-fill so the donut layout stays stable")
    }

    // MARK: - filter clause

    @Test("ProviderFilter clause: codex predicate restricts overview")
    func providerFilter_restrictsOverview() throws {
        let db = try makeDatabase()
        try seedEvent(in: db, provider: "codex", sessionId: "c", daysAgo: 1, valueUSD: 1.00)
        try seedEvent(in: db, provider: "claude", sessionId: "k", daysAgo: 1, valueUSD: 2.00)

        let codexOnly = try db.pool.read { conn in
            try Aggregator.fetchOverview(db: conn, provider: .codex)
        }
        let claudeOnly = try db.pool.read { conn in
            try Aggregator.fetchOverview(db: conn, provider: .claude)
        }
        let union = try db.pool.read { conn in
            try Aggregator.fetchOverview(db: conn, provider: .all)
        }

        #expect(abs(codexOnly.totalValueUSD - 1.00) < 0.0001)
        #expect(abs(claudeOnly.totalValueUSD - 2.00) < 0.0001)
        #expect(abs(union.totalValueUSD - 3.00) < 0.0001)
    }

    // MARK: - Codex quota source isolation

    @Test("fetchCodexQuota ignores Claude OAuth samples that share rate_limit_samples")
    func codexQuota_ignoresClaudeOAuthSamples() throws {
        let db = try makeDatabase()
        try seedRateLimitSample(
            in: db,
            sourceKind: "live",
            sampleAt: "2026-06-03T10:00:00Z",
            usedPercent: 12)
        try seedRateLimitSample(
            in: db,
            sourceKind: "claude_oauth",
            sampleAt: "2026-06-03T11:00:00Z",
            usedPercent: 88)

        let quota = try db.pool.read { conn in
            try Aggregator.fetchCodexQuota(db: conn)
        }

        #expect(abs((quota?.primary?.usedPercent ?? -1) - 12) < 0.0001,
                "newer Claude OAuth rows must not override Codex quota rows")
    }

    @Test("fetchRateLimitHistory excludes Claude OAuth samples")
    func codexRateLimitHistory_ignoresClaudeOAuthSamples() throws {
        let db = try makeDatabase()
        let now = ISO8601.fractional.string(from: Date())
        try seedRateLimitSample(
            in: db,
            sourceKind: "live",
            sampleAt: now,
            usedPercent: 12)
        try seedRateLimitSample(
            in: db,
            sourceKind: "claude_oauth",
            sampleAt: now,
            bucket: "secondary",
            usedPercent: 88)

        let history = try db.pool.read { conn in
            try Aggregator.fetchRateLimitHistory(db: conn, hours: 24)
        }

        #expect(history.count == 1)
        #expect(history.first?.series == "primary (live)")
    }

    // MARK: - sliding-window timestamp format (datetime() vs strftime regression)

    @Test("fetchModelShares [now-30d, now) keeps events from earlier today")
    func modelShares30dWindow_includesTodayEvents() throws {
        let db = try makeDatabase()
        // Earlier today. The old `datetime('now')` upper bound rendered a
        // space-separated "YYYY-MM-DD HH:MM:SS" string, so the stored ISO8601
        // 'T' timestamp sorted lexically ABOVE it — today's spend silently
        // dropped out of the Composition section.
        try seedEvent(in: db, provider: "codex", sessionId: "today",
                      daysAgo: 0.1, valueUSD: 5.00)
        try seedEvent(in: db, provider: "codex", sessionId: "midwindow",
                      daysAgo: 10, valueUSD: 2.00)
        // 40 days old — outside the 30d window, must be excluded.
        try seedEvent(in: db, provider: "codex", sessionId: "ancient",
                      daysAgo: 40, valueUSD: 99.00)

        let shares = try db.pool.read { conn in
            try Aggregator.fetchModelShares(
                db: conn, provider: .all, sinceDays: 30, untilDaysAgo: 0)
        }
        let total = shares.reduce(0) { $0 + $1.valueUSD }
        #expect(abs(total - 7.00) < 0.0001,
                "today's $5 + 10d-old $2 are inside [now-30d, now); 40d-old $99 is not")
    }

    @Test("fetchModelShares returns billing-tier value and token splits")
    func modelShares_includeBillingTierSplits() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "codex", sessionId: "standard",
            daysAgo: 1, valueUSD: 35.00, tokens: 100,
            billingTier: .standard, billingTierSource: .trace)
        try seedEvent(
            in: db, provider: "codex", sessionId: "fast",
            daysAgo: 1, valueUSD: 87.50, tokens: 200,
            billingTier: .fast, billingTierSource: .trace)
        try seedEvent(
            in: db, provider: "codex", sessionId: "unknown",
            daysAgo: 1, valueUSD: 35.00, tokens: 300,
            billingTier: .unknown, billingTierSource: .traceMissing)

        let shares = try db.pool.read { conn in
            try Aggregator.fetchModelShares(db: conn, provider: .codex)
        }

        let share = try #require(shares.first { $0.modelId == "gpt-5" })
        expectModelShareSplits(
            share,
            standardValueUSD: 35.00,
            fastValueUSD: 87.50,
            unknownValueUSD: 35.00,
            standardTokens: 100,
            fastTokens: 200,
            unknownTokens: 300)
    }

    @Test("fetchModelShares keeps non-Codex totals but zeroes billing-tier splits")
    func modelShares_zeroBillingTierSplitsForNonCodex() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "claude", sessionId: "claude-unknown",
            daysAgo: 1, valueUSD: 12.50, tokens: 123,
            billingTier: .unknown, billingTierSource: .notCodex)

        let shares = try db.pool.read { conn in
            try Aggregator.fetchModelShares(db: conn, provider: .claude)
        }

        let share = try #require(shares.first { $0.modelId == "gpt-5" })
        #expect(abs(share.valueUSD - 12.50) < 0.0001)
        #expect(share.tokens == 123)
        #expect(abs(share.standardValueUSD) < 0.0001)
        #expect(abs(share.fastValueUSD) < 0.0001)
        #expect(abs(share.unknownValueUSD) < 0.0001)
        #expect(share.standardTokens == 0)
        #expect(share.fastTokens == 0)
        #expect(share.unknownTokens == 0)
    }

    @Test("windowed fetchModelShares returns billing-tier value and token splits")
    func windowedModelShares_includeBillingTierSplits() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "codex", sessionId: "window-standard",
            daysAgo: 1, valueUSD: 35.00, tokens: 100,
            billingTier: .standard, billingTierSource: .trace)
        try seedEvent(
            in: db, provider: "codex", sessionId: "window-fast",
            daysAgo: 2, valueUSD: 87.50, tokens: 200,
            billingTier: .fast, billingTierSource: .trace)
        try seedEvent(
            in: db, provider: "codex", sessionId: "window-unknown",
            daysAgo: 3, valueUSD: 35.00, tokens: 300,
            billingTier: .unknown, billingTierSource: .traceMissing)
        try seedEvent(
            in: db, provider: "codex", sessionId: "window-outside",
            daysAgo: 45, valueUSD: 999.00, tokens: 900,
            billingTier: .fast, billingTierSource: .trace)

        let shares = try db.pool.read { conn in
            try Aggregator.fetchModelShares(
                db: conn, provider: .codex, sinceDays: 30, untilDaysAgo: 0)
        }

        let share = try #require(shares.first { $0.modelId == "gpt-5" })
        expectModelShareSplits(
            share,
            standardValueUSD: 35.00,
            fastValueUSD: 87.50,
            unknownValueUSD: 35.00,
            standardTokens: 100,
            fastTokens: 200,
            unknownTokens: 300)
    }

    @Test("fetchSessionDetail model breakdown returns billing-tier value and token splits")
    func sessionDetailModelBreakdown_includesBillingTierSplits() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "codex", sessionId: "session-splits",
            daysAgo: 1, valueUSD: 35.00, tokens: 100,
            billingTier: .standard, billingTierSource: .trace)
        try seedEvent(
            in: db, provider: "codex", sessionId: "session-splits",
            daysAgo: 1, valueUSD: 87.50, tokens: 200,
            billingTier: .fast, billingTierSource: .trace)
        try seedEvent(
            in: db, provider: "codex", sessionId: "session-splits",
            daysAgo: 1, valueUSD: 35.00, tokens: 300,
            billingTier: .unknown, billingTierSource: .traceMissing)

        let detail = try db.pool.read { conn in
            try Aggregator.fetchSessionDetail(db: conn, sessionId: "session-splits")
        }

        let share = try #require(detail?.modelBreakdown.first { $0.modelId == "gpt-5" })
        expectModelShareSplits(
            share,
            standardValueUSD: 35.00,
            fastValueUSD: 87.50,
            unknownValueUSD: 35.00,
            standardTokens: 100,
            fastTokens: 200,
            unknownTokens: 300)
    }

    @Test("fetchSessionDetail keeps non-Codex totals but zeroes billing-tier splits")
    func sessionDetailModelBreakdown_zeroBillingTierSplitsForNonCodex() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "claude", sessionId: "claude-session-splits",
            daysAgo: 1, valueUSD: 12.50, tokens: 123,
            billingTier: .unknown, billingTierSource: .notCodex)

        let detail = try db.pool.read { conn in
            try Aggregator.fetchSessionDetail(db: conn, sessionId: "claude-session-splits")
        }

        let share = try #require(detail?.modelBreakdown.first { $0.modelId == "gpt-5" })
        #expect(abs(share.valueUSD - 12.50) < 0.0001)
        #expect(share.tokens == 123)
        #expect(abs(share.standardValueUSD) < 0.0001)
        #expect(abs(share.fastValueUSD) < 0.0001)
        #expect(abs(share.unknownValueUSD) < 0.0001)
        #expect(share.standardTokens == 0)
        #expect(share.fastTokens == 0)
        #expect(share.unknownTokens == 0)
    }

    @Test("fetchDayDetail keeps non-Codex totals but zeroes billing-tier splits")
    func dayDetailModelBreakdown_zeroBillingTierSplitsForNonCodex() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "claude", sessionId: "claude-day-splits",
            daysAgo: 1, valueUSD: 12.50, tokens: 123,
            billingTier: .unknown, billingTierSource: .notCodex)

        let detail = try db.pool.read { conn in
            let day = try #require(Aggregator.fetchDays(db: conn, provider: .claude).first)
            return try Aggregator.fetchDayDetail(db: conn, day: day.day, provider: .claude)
        }

        let share = try #require(detail?.modelBreakdown.first { $0.modelId == "gpt-5" })
        #expect(abs(share.valueUSD - 12.50) < 0.0001)
        #expect(share.tokens == 123)
        #expect(abs(share.standardValueUSD) < 0.0001)
        #expect(abs(share.fastValueUSD) < 0.0001)
        #expect(abs(share.unknownValueUSD) < 0.0001)
        #expect(share.standardTokens == 0)
        #expect(share.fastTokens == 0)
        #expect(share.unknownTokens == 0)
    }

    @Test("fetchSessionDetail returns event billing metadata")
    func sessionDetailEvents_includeBillingMetadata() throws {
        let db = try makeDatabase()
        try seedEvent(
            in: db, provider: "codex", sessionId: "session-meta",
            daysAgo: 1, valueUSD: 1.25, turnId: "turn-fast",
            billingTier: .fast, billingTierSource: .trace)

        let detail = try db.pool.read { conn in
            try Aggregator.fetchSessionDetail(db: conn, sessionId: "session-meta")
        }

        let event = try #require(detail?.events.first)
        #expect(event.turnId == "turn-fast")
        #expect(event.billingTier == .fast)
        #expect(event.billingTierSource == .trace)
    }

    @Test("fetchModelShares prior window [now-60d, now-30d) excludes the recent 30d")
    func modelSharesPriorWindow_excludesRecent() throws {
        let db = try makeDatabase()
        try seedEvent(in: db, provider: "codex", sessionId: "recent",
                      daysAgo: 10, valueUSD: 5.00)   // inside last 30d -> excluded
        try seedEvent(in: db, provider: "codex", sessionId: "prior",
                      daysAgo: 45, valueUSD: 3.00)   // inside [60,30) -> included
        try seedEvent(in: db, provider: "codex", sessionId: "old",
                      daysAgo: 70, valueUSD: 9.00)   // older than 60d -> excluded

        let shares = try db.pool.read { conn in
            try Aggregator.fetchModelShares(
                db: conn, provider: .all, sinceDays: 60, untilDaysAgo: 30)
        }
        let total = shares.reduce(0) { $0 + $1.valueUSD }
        #expect(abs(total - 3.00) < 0.0001,
                "only the 45d-old event sits inside the prior [60d, 30d) window")
    }

    @Test("fetchBurnRates derives a positive slope from rising in-window samples")
    func burnRate_positiveSlopeWithinWindow() throws {
        let db = try makeDatabase()
        let now = Date()
        func stamp(minutesAgo: Double) -> String {
            ISO8601.fractional.string(from: now.addingTimeInterval(-minutesAgo * 60))
        }
        // Three live primary samples inside the 60-minute window, usage rising.
        // The old `datetime('now', '-60 minutes')` lower bound widened this to
        // "since 00:00 today"; strftime keeps it a true rolling 60 minutes.
        try seedRateLimitSample(in: db, sourceKind: "live",
                                sampleAt: stamp(minutesAgo: 50), usedPercent: 10)
        try seedRateLimitSample(in: db, sourceKind: "live",
                                sampleAt: stamp(minutesAgo: 25), usedPercent: 16)
        try seedRateLimitSample(in: db, sourceKind: "live",
                                sampleAt: stamp(minutesAgo: 5), usedPercent: 22)

        let rates = try db.pool.read { conn in
            try Aggregator.fetchBurnRates(
                db: conn, bucketsOfInterest: ["primary"], windowMinutes: 60)
        }
        let primary = try #require(rates["primary"])
        #expect(primary.sampleCount == 3, "all three in-window samples contribute")
        #expect(primary.percentPerMinute > 0,
                "usage climbing 10->22% over ~45min must yield a positive burn rate")
    }

    @Test("fetchMonthly counts first-of-month rows whose UTC instant is in the prior month")
    func monthly_includesLocalMonthStartAcrossUTCBoundary() throws {
        let db = try makeDatabase()
        // UTC+8: 00:00 on the 1st (local) is 16:00 on the previous month's last
        // day in UTC. The old UTC `start of month` lower bound dropped these
        // rows from the earliest bucket; the local-offset bound keeps them.
        let tz = TimeZone(secondsFromGMT: 8 * 3600)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month], from: Date())
        let thisMonthStart = cal.date(from: comps)!
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
        // 00:30 local on the 1st of last month → previous-day 16:30 in UTC.
        let earlyLastMonth = lastMonthStart.addingTimeInterval(30 * 60)

        try seedEvent(in: db, provider: "codex", sessionId: "edge",
                      at: earlyLastMonth, valueUSD: 4.00)

        let monthly = try db.pool.read { conn in
            try Aggregator.fetchMonthly(db: conn, months: 2, timeZone: tz)
        }
        let earliest = try #require(monthly.first)
        #expect(abs(earliest.valueUSD - 4.00) < 0.0001,
                "00:30 local on the 1st (prev-day in UTC) must count in its local month")
    }
}
