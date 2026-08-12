import Foundation
import Testing
import GRDB
@testable import QuotaMonitor

/// Coverage for `PricingService.backfillAllValues` — the single SQL UPDATE
/// that recomputes `usage_events.value_usd` from the current pricing
/// catalog.
///
/// Pre-2026-04-30 zero coverage. Risk: a typo in the JOIN, a wrong column
/// name, or an `OR` that misses a row would silently corrupt every
/// dollar amount in the menu bar. We pin:
///
///   - codex formula: cached tokens are subtracted from input before
///     pricing (`MAX(input - cached, 0) * input_price + cached * cached_price …`)
///   - claude formula: input/cached/cache_creation are billed independently,
///     with 1h cache writes split from 5m writes when the importer has that
///     breakdown
///   - rows with model_id NOT in pricing_catalog stay at their previous
///     value_usd (the WHERE EXISTS clause)
///   - second run is idempotent (math is deterministic)
@Suite("PricingService.backfillAllValues")
struct PricingValueBackfillTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "pricing-\(UUID().uuidString).sqlite")
        return try DatabaseManager(url: url)
    }

    /// Insert a pricing_catalog row with a known set of per-million prices.
    /// We bypass `installBundledCatalog` so each formula test can pin its own
    /// model id and numbers without depending on the shipped catalog.
    private func insertPriceRow(
        in db: DatabaseManager,
        modelId: String,
        input: Double, cached: Double,
        output: Double, cacheCreation: Double = 0,
        priceSource: String = "bundled"
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT INTO pricing_catalog
                  (model_id, display_name,
                   input_price_per_million,
                   cached_input_price_per_million,
                   output_price_per_million,
                   cache_creation_price_per_million,
                   effective_model_id, is_official, note, source_url,
                   updated_at, price_source)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(model_id) DO UPDATE SET
                  input_price_per_million = excluded.input_price_per_million,
                  cached_input_price_per_million = excluded.cached_input_price_per_million,
                  output_price_per_million = excluded.output_price_per_million,
                  cache_creation_price_per_million = excluded.cache_creation_price_per_million,
                  updated_at = excluded.updated_at,
                  price_source = excluded.price_source
                """, arguments: [
                    modelId, modelId, input, cached, output, cacheCreation,
                    modelId, true, nil, "https://example/", now, priceSource
                ])
        }
    }

    /// Insert a usage_events row. `valueUSD` is the seed value; backfill
    /// will overwrite it.
    @discardableResult
    private func insertUsageEvent(
        in db: DatabaseManager,
        provider: String,
        modelId: String,
        input: Int64, cached: Int64,
        output: Int64, cacheCreation: Int64 = 0,
        cacheCreation5m: Int64 = 0,
        cacheCreation1h: Int64 = 0,
        serviceTierPreference: String? = nil,
        seedValueUSD: Double = -1,
        sessionId: String? = nil,
        timestamp: String = "2026-04-29T10:00:00Z"
    ) throws -> String {
        let stamp = timestamp
        let sid = sessionId ?? "s-\(UUID().uuidString)"
        try db.pool.write { conn in
            try conn.execute(sql: """
                INSERT OR IGNORE INTO sessions
                (session_id, root_session_id, parent_session_id, title,
                 source_path, started_at, updated_at, agent_nickname,
                 agent_role, last_model_id, latest_plan_type,
                 contains_subagents, created_at, imported_at, provider)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL, ?,
                        NULL, 0, ?, ?, ?)
                """, arguments: [
                    sid, sid, stamp, stamp, modelId, stamp, stamp, provider
                ])
            try conn.execute(sql: """
                INSERT INTO usage_events
                (session_id, timestamp, model_id,
                 input_tokens, cached_input_tokens, output_tokens,
                 reasoning_output_tokens, total_tokens, value_usd,
                 provider, cache_creation_tokens,
                 cache_creation_5m_tokens, cache_creation_1h_tokens,
                 codex_service_tier_preference,
                 model_inferred)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, 0)
                """, arguments: [
                    sid, stamp, modelId,
                    input, cached, output,
                    input + output + cacheCreation,
                    seedValueUSD,
                    provider, cacheCreation, cacheCreation5m, cacheCreation1h,
                    serviceTierPreference
                ])
        }
        return sid
    }

    private func valueUSD(in db: DatabaseManager, sessionPrefix: String? = nil) throws -> [Double] {
        try db.pool.read { conn in
            try Double.fetchAll(conn, sql: """
                SELECT value_usd FROM usage_events ORDER BY id ASC
                """)
        }
    }

    private func valueBitPatterns(
        in db: DatabaseManager,
        sessionId: String
    ) throws -> [UInt64] {
        try db.pool.read { conn in
            try Double.fetchAll(conn, sql: """
                SELECT value_usd
                FROM usage_events
                WHERE session_id = ?
                ORDER BY id ASC
                """, arguments: [sessionId])
                .map(\.bitPattern)
        }
    }

    // MARK: - codex formula: subtracts cached from input

    @Test("codex: value = max(input - cached, 0)*in_$ + cached*cached_$ + output*out_$")
    func codexFormulaSubtractsCachedFromInput() throws {
        let db = try makeDatabase()
        // 1.00 / 0.10 / 8.00 per-million: simple decimals so the expected
        // dollar amount is obvious.
        try insertPriceRow(in: db, modelId: "gpt-test",
                           input: 1.00, cached: 0.10, output: 8.00)
        // 1_000_000 input, 200_000 cached, 100_000 output:
        //   uncached input = 1_000_000 - 200_000 = 800_000 → 0.80
        //   cached         = 200_000 * 0.10 / 1M       = 0.02
        //   output         = 100_000 * 8.00 / 1M       = 0.80
        //   total = 1.62
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-test",
                             input: 1_000_000, cached: 200_000, output: 100_000)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let values = try valueUSD(in: db)
        #expect(values.count == 1)
        #expect(abs(values[0] - 1.62) < 1e-6,
                "codex math expected 1.62, got \(values[0])")
    }

    // MARK: - claude formula: every category billed independently

    @Test("claude: value sums input + cached + output + cache_creation independently (no subtraction)")
    func claudeFormulaIsAdditive() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "claude-test",
                           input: 3.00, cached: 0.30,
                           output: 15.00, cacheCreation: 3.75)
        // 100_000 input, 50_000 cached, 200_000 output, 10_000 cache_creation:
        //   input          = 100_000 * 3.00  / 1M = 0.30
        //   cached         = 50_000  * 0.30  / 1M = 0.015
        //   cache_creation = 10_000  * 3.75  / 1M = 0.0375
        //   output         = 200_000 * 15.00 / 1M = 3.00
        //   total = 3.3525
        try insertUsageEvent(in: db, provider: "claude", modelId: "claude-test",
                             input: 100_000, cached: 50_000,
                             output: 200_000, cacheCreation: 10_000)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let values = try valueUSD(in: db)
        #expect(values.count == 1)
        #expect(abs(values[0] - 3.3525) < 1e-6,
                "claude math expected 3.3525, got \(values[0])")
    }

    @Test("claude: 1h cache creation bills at 2x input, 5m cache creation uses catalog write rate")
    func claudeCacheCreationDurationSplit() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "claude-opus-test",
                           input: 5.00, cached: 0.50,
                           output: 25.00, cacheCreation: 6.25)
        try insertUsageEvent(in: db, provider: "claude",
                             modelId: "claude-opus-test",
                             input: 0, cached: 0, output: 0,
                             cacheCreation: 2_000_000,
                             cacheCreation5m: 1_000_000,
                             cacheCreation1h: 1_000_000)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let values = try valueUSD(in: db)
        #expect(values.count == 1)
        #expect(abs(values[0] - 16.25) < 1e-6,
                "5m: 1M * 6.25 + 1h: 1M * (5.00 * 2) = 16.25, got \(values[0])")
    }

    @Test("database initialization seeds Claude Opus 4.5 so imported usage can be priced")
    func databaseInitializationSeedsClaudeOpus45() throws {
        let db = try makeDatabase()

        let row = try db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT input_price_per_million,
                       cached_input_price_per_million,
                       cache_creation_price_per_million,
                       output_price_per_million
                FROM pricing_catalog
                WHERE model_id = 'claude-opus-4-5-20251101'
                """)
        }
        #expect(row != nil)
        #expect(abs((row?["input_price_per_million"] as Double? ?? 0) - 5.00) < 1e-6)
        #expect(abs((row?["cached_input_price_per_million"] as Double? ?? 0) - 0.50) < 1e-6)
        #expect(abs((row?["cache_creation_price_per_million"] as Double? ?? 0) - 6.25) < 1e-6)
        #expect(abs((row?["output_price_per_million"] as Double? ?? 0) - 25.00) < 1e-6)
    }

    @Test("database initialization seeds recent Claude and GLM models")
    func databaseInitializationSeedsRecentClaudeAndGLMModels() throws {
        let db = try makeDatabase()
        struct ExpectedSeed {
            let modelId: String
            let input: Double
            let cached: Double
            let cacheCreation: Double
            let output: Double
            let isOfficial: Bool
        }
        let expected: [ExpectedSeed] = [
            .init(modelId: "claude-opus-5",
                  input: 5.00, cached: 0.50, cacheCreation: 6.25,
                  output: 25.00, isOfficial: true),
            .init(modelId: "claude-sonnet-5",
                  input: 2.00, cached: 0.20, cacheCreation: 2.50,
                  output: 10.00, isOfficial: true),
            .init(modelId: "claude-fable-5",
                  input: 10.00, cached: 1.00, cacheCreation: 12.50,
                  output: 50.00, isOfficial: false),
            .init(modelId: "claude-opus-4-8",
                  input: 5.00, cached: 0.50, cacheCreation: 6.25,
                  output: 25.00, isOfficial: false),
            .init(modelId: "claude-sonnet-4-5-20250929",
                  input: 3.00, cached: 0.30, cacheCreation: 3.75,
                  output: 15.00, isOfficial: false),
            .init(modelId: "glm-4.7",
                  input: 0.60, cached: 0.11, cacheCreation: 0,
                  output: 2.20, isOfficial: true),
            .init(modelId: "glm-5.1",
                  input: 1.40, cached: 0.26, cacheCreation: 0,
                  output: 4.40, isOfficial: true),
            .init(modelId: "glm-5.2",
                  input: 1.40, cached: 0.26, cacheCreation: 0,
                  output: 4.40, isOfficial: true),
            .init(modelId: "codex-auto-review",
                  input: 2.50, cached: 0.25, cacheCreation: 0,
                  output: 15.00, isOfficial: false),
        ]

        let rows = try db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT model_id,
                       input_price_per_million,
                       cached_input_price_per_million,
                       cache_creation_price_per_million,
                       output_price_per_million,
                       is_official
                FROM pricing_catalog
                WHERE model_id IN (
                  'claude-opus-5',
                  'claude-sonnet-5',
                  'claude-fable-5',
                  'claude-opus-4-8',
                  'claude-sonnet-4-5-20250929',
                  'glm-4.7',
                  'glm-5.1',
                  'glm-5.2',
                  'codex-auto-review'
                )
                ORDER BY model_id
                """)
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["model_id"] as String, row)
        })

        for item in expected {
            let row = byId[item.modelId]
            #expect(row != nil, "\(item.modelId) should be bundled")
            #expect(abs((row?["input_price_per_million"] as Double? ?? 0) - item.input) < 1e-6)
            #expect(abs((row?["cached_input_price_per_million"] as Double? ?? 0) - item.cached) < 1e-6)
            #expect(abs((row?["cache_creation_price_per_million"] as Double? ?? 0) - item.cacheCreation) < 1e-6)
            #expect(abs((row?["output_price_per_million"] as Double? ?? 0) - item.output) < 1e-6)
            #expect((row?["is_official"] as Bool?) == item.isOfficial)
        }
    }

    @Test("Claude Sonnet 5 usage uses the permanent launch price")
    func claudeSonnet5UsesPermanentLaunchPrice() throws {
        let db = try makeDatabase()
        // Simulate a user whose existing catalog has the cancelled increase.
        // Installing the bundled catalog must normalize that history.
        try db.pool.write { conn in
            try conn.execute(sql: """
                UPDATE pricing_catalog
                SET input_price_per_million = 3,
                    cached_input_price_per_million = 0.3,
                    cache_creation_price_per_million = 3.75,
                    output_price_per_million = 15,
                    price_source = 'local'
                WHERE model_id = 'claude-sonnet-5'
                """)
        }
        try insertUsageEvent(
            in: db,
            provider: "claude",
            modelId: "claude-sonnet-5",
            input: 1_000_000,
            cached: 1_000_000,
            output: 1_000_000,
            cacheCreation: 2_000_000,
            cacheCreation5m: 1_000_000,
            cacheCreation1h: 1_000_000,
            seedValueUSD: 0)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let increasedValue = try #require(valueUSD(in: db).first)
        #expect(abs(increasedValue - 28.05) < 1e-6)

        let repaired = try db.pool.write { conn in
            let changed = try PricingService.installBundledCatalog(in: conn)
            try PricingService.backfillAllValues(in: conn)
            return changed
        }

        let values = try valueUSD(in: db)
        let value = try #require(values.first)
        // Permanent input/read/5m-write/1h-write/output rates:
        // 2 + 0.20 + 2.50 + 4 + 10 = 18.70.
        #expect(repaired)
        #expect(abs(value - 18.70) < 1e-6)
    }

    @Test("bundled GPT-5.3 Codex Fast and Auto Review rows price imported usage")
    func selectedCodexRowsPriceImportedUsage() throws {
        let db = try makeDatabase()
        try insertUsageEvent(
            in: db,
            provider: "codex",
            modelId: "gpt-5.3-codex",
            input: 1_000_000,
            cached: 200_000,
            output: 100_000,
            serviceTierPreference: "priority",
            seedValueUSD: 0)
        try insertUsageEvent(
            in: db,
            provider: "codex",
            modelId: "codex-auto-review",
            input: 1_000_000,
            cached: 200_000,
            output: 100_000,
            seedValueUSD: 0)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        // GPT-5.3 Codex Fast: .8M * $3.50 + .2M * $0.35 + .1M * $28 = $5.67.
        #expect(abs(values[0] - 5.67) < 1e-6)
        // Auto Review estimate: .8M * $2.50 + .2M * $0.25 + .1M * $15 = $3.55.
        #expect(abs(values[1] - 3.55) < 1e-6)
    }

    // MARK: - rows without a matching catalog row are left alone

    @Test("rows whose model_id has no pricing_catalog match keep their prior value_usd untouched")
    func unknownModelIdLeavesValueAlone() throws {
        let db = try makeDatabase()
        // Catalog has only "known-model".
        try insertPriceRow(in: db, modelId: "known-model",
                           input: 2.00, cached: 0.20, output: 10.00)
        // One event uses "known-model" (will be recomputed) and one uses
        // "ghost-model" (no catalog row → must be left alone).
        try insertUsageEvent(in: db, provider: "codex", modelId: "known-model",
                             input: 500_000, cached: 0, output: 0,
                             seedValueUSD: -1)
        // ghost-model: seed value 99.99 — must survive the backfill.
        try insertUsageEvent(in: db, provider: "codex", modelId: "ghost-model",
                             input: 100, cached: 0, output: 100,
                             seedValueUSD: 99.99)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let values = try valueUSD(in: db)
        #expect(values.count == 2)
        // Order is by id ASC, which mirrors insert order.
        #expect(abs(values[0] - 1.00) < 1e-6,
                "known-model: 500_000 * 2.00 / 1M = 1.00, got \(values[0])")
        #expect(abs(values[1] - 99.99) < 1e-6,
                "ghost-model row must NOT be overwritten; expected 99.99 to survive, got \(values[1])")
    }

    // MARK: - idempotency

    @Test("bundled catalog restores legacy rows and reports only pricing-semantic changes")
    func bundledCatalogSemanticChangeDetectionIsStable() throws {
        let db = try makeDatabase()

        let unchanged = try db.pool.write { conn in
            try PricingService.installBundledCatalog(in: conn)
        }
        #expect(!unchanged, "an identical bundled catalog must not request a full reprice")

        try db.pool.write { conn in
            try conn.execute(sql: """
                UPDATE pricing_catalog
                SET input_price_per_million = 999,
                    price_source = 'local',
                    fetched_at = '2026-07-01T00:00:00Z'
                WHERE model_id = 'gpt-5.4'
                """)
        }
        let repaired = try db.pool.write { conn in
            try PricingService.installBundledCatalog(in: conn)
        }
        #expect(repaired, "a changed legacy calculation field must request a full reprice")

        let normalized = try db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT input_price_per_million, price_source, fetched_at
                FROM pricing_catalog WHERE model_id = 'gpt-5.4'
                """)
        }
        #expect(abs((normalized?["input_price_per_million"] as Double? ?? 0) - 2.50) < 1e-9)
        #expect((normalized?["price_source"] as String?) == "bundled")
        #expect((normalized?["fetched_at"] as String?) == nil)

        let stableAgain = try db.pool.write { conn in
            try PricingService.installBundledCatalog(in: conn)
        }
        #expect(!stableAgain, "the repaired catalog must be stable on the next launch")
    }

    @Test("database startup reprices finished history after a bundled price changes")
    func databaseStartupRepricesAfterBundledPriceChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexmonitor-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "pricing-startup-\(UUID().uuidString).sqlite")

        var initial: DatabaseManager? = try DatabaseManager(url: url)
        let sessionId = try insertUsageEvent(
            in: try #require(initial),
            provider: "codex",
            modelId: "gpt-5.4",
            input: 100,
            cached: 20,
            output: 10,
            seedValueUSD: -1)
        try initial?.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let expected = try valueBitPatterns(
            in: try #require(initial),
            sessionId: sessionId)
        try initial?.pool.write { conn in
            try conn.execute(sql: """
                UPDATE pricing_catalog
                SET input_price_per_million = 999
                WHERE model_id = 'gpt-5.4' AND price_source = 'bundled'
                """)
            try conn.execute(
                sql: "UPDATE usage_events SET value_usd = -1 WHERE session_id = ?",
                arguments: [sessionId])
        }
        initial = nil

        let reopened = try DatabaseManager(url: url)
        let values = try valueBitPatterns(in: reopened, sessionId: sessionId)
        #expect(values == expected,
                "startup must repair historical values when bundled pricing changes")
    }

    @Test("running backfill twice produces the same value (deterministic)")
    func idempotentOnSecondRun() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-test",
                           input: 1.00, cached: 0.10, output: 8.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-test",
                             input: 1_000_000, cached: 200_000, output: 100_000)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let after1 = try valueUSD(in: db)
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let after2 = try valueUSD(in: db)
        #expect(after1 == after2,
                "second backfill must not change values (formula is pure)")
    }

    @Test("session-targeted pricing is bit-for-bit identical to full backfill")
    func targetedBackfillMatchesFullBackfillBitForBit() throws {
        let db = try makeDatabase()
        try insertPriceRow(
            in: db, modelId: "gpt-test",
            input: 1.00, cached: 0.10, output: 8.00)
        try insertPriceRow(
            in: db, modelId: "gpt-5.5",
            input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(
            in: db, modelId: "gpt-5.5-fast",
            input: 12.50, cached: 1.25, output: 75.00)
        try insertPriceRow(
            in: db, modelId: "gpt-5.5-flex",
            input: 2.50, cached: 0.25, output: 15.00)

        let affected = "targeted-pricing-session"
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-test",
            input: 1_000_000, cached: 200_000, output: 100_000,
            seedValueUSD: -10, sessionId: affected)
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.5",
            input: 100_000, cached: 20_000, output: 100_000,
            serviceTierPreference: "priority",
            seedValueUSD: -11, sessionId: affected)
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.5",
            input: 100_000, cached: 20_000, output: 100_000,
            serviceTierPreference: "flex",
            seedValueUSD: -12, sessionId: affected)
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.5",
            input: CodexLongContextPricing.inputTokenThreshold + 1,
            cached: 50_000, output: 20_000,
            serviceTierPreference: "priority",
            seedValueUSD: -13, sessionId: affected)
        // Both paths deliberately leave models with no catalog entry alone.
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "ghost-model",
            input: 100, cached: 0, output: 10,
            seedValueUSD: -14, sessionId: affected)

        let unaffected = try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-test",
            input: 500_000, cached: 100_000, output: 50_000,
            seedValueUSD: -99)

        try db.pool.write { conn in
            try PricingService.backfillValues(
                in: conn,
                sessionId: affected,
                provider: "codex")
        }
        let targetedBits = try valueBitPatterns(in: db, sessionId: affected)
        #expect(
            try valueBitPatterns(in: db, sessionId: unaffected)
                == [Double(-99).bitPattern],
            "targeted pricing must not rewrite another session")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let fullBits = try valueBitPatterns(in: db, sessionId: affected)

        #expect(targetedBits == fullBits,
                "targeted and full pricing must produce identical Double bits")
        #expect(
            try valueBitPatterns(in: db, sessionId: unaffected)
                != [Double(-99).bitPattern],
            "full pricing should still cover sessions outside the target")
    }

    // MARK: - codex Fast-Mode billing remaps to -fast catalog row

    @Test("codex Fast-Mode: stored priority uses fast pricing")
    func codexPriorityPreferenceUsesFastPricing() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 100_000, cached: 0, output: 100_000,
                             serviceTierPreference: "priority")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }

        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 8.75) < 1e-6,
                "stored priority expected 8.75, got \(values[0])")
    }

    @Test("codex Fast-Mode: stored default uses base pricing when legacy flag is on")
    func codexDefaultPreferenceUsesStandardWithLegacyFlag() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 100_000, cached: 0, output: 100_000,
                             serviceTierPreference: "default")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }

        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 3.50) < 1e-6,
                "stored default expected 3.50 even with legacy flag on, got \(values[0])")
    }

    @Test("codex Flex: stored flex uses half-price row when legacy flag is on")
    func codexFlexPreferenceUsesFlexPricing() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-flex",
                           input: 2.50, cached: 0.25, output: 15.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 100_000, cached: 20_000, output: 100_000,
                             serviceTierPreference: "flex")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }

        let values = try valueUSD(in: db)
        // Gross input includes cached input:
        //   0.08M * $2.50 + 0.02M * $0.25 + 0.1M * $15 = $1.705.
        #expect(abs(values[0] - 1.705) < 1e-6,
                "stored flex expected 1.705 even with legacy flag on, got \(values[0])")
    }

    @Test("database initialization seeds current Codex Flex prices")
    func databaseInitializationSeedsCodexFlexPrices() throws {
        let db = try makeDatabase()

        let row = try db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT input_price_per_million,
                       cached_input_price_per_million,
                       output_price_per_million
                FROM pricing_catalog
                WHERE model_id = 'gpt-5.5-flex'
                """)
        }

        #expect(row != nil)
        #expect(abs((row?["input_price_per_million"] as Double? ?? 0) - 2.50) < 1e-6)
        #expect(abs((row?["cached_input_price_per_million"] as Double? ?? 0) - 0.25) < 1e-6)
        #expect(abs((row?["output_price_per_million"] as Double? ?? 0) - 15.00) < 1e-6)
    }

    @Test("database initialization seeds post-July-30 GPT-5.6 prices and tiers")
    func databaseInitializationSeedsCurrentGPT56Prices() throws {
        let db = try makeDatabase()

        let rows = try db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT model_id, input_price_per_million,
                       cached_input_price_per_million, output_price_per_million
                FROM pricing_catalog
                WHERE model_id IN (
                  'gpt-5.6-terra', 'gpt-5.6-terra-fast', 'gpt-5.6-terra-flex',
                  'gpt-5.6-luna', 'gpt-5.6-luna-fast', 'gpt-5.6-luna-flex'
                )
                """)
        }
        let prices = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["model_id"] as String, (
                row["input_price_per_million"] as Double,
                row["cached_input_price_per_million"] as Double,
                row["output_price_per_million"] as Double))
        })
        let expected: [String: (Double, Double, Double)] = [
            "gpt-5.6-terra": (2.00, 0.20, 12.00),
            "gpt-5.6-terra-fast": (4.00, 0.40, 24.00),
            "gpt-5.6-terra-flex": (1.00, 0.10, 6.00),
            "gpt-5.6-luna": (0.20, 0.02, 1.20),
            "gpt-5.6-luna-fast": (0.40, 0.04, 2.40),
            "gpt-5.6-luna-flex": (0.10, 0.01, 0.60),
        ]

        #expect(prices.count == expected.count)
        for (modelId, price) in expected {
            #expect(abs((prices[modelId]?.0 ?? -1) - price.0) < 1e-9)
            #expect(abs((prices[modelId]?.1 ?? -1) - price.1) < 1e-9)
            #expect(abs((prices[modelId]?.2 ?? -1) - price.2) < 1e-9)
        }
    }

    @Test("GPT-5.6 Terra and Luna use launch prices before July 30 and reduced prices from July 30")
    func gpt56PriceCutoverUsesEventTimestamp() throws {
        let db = try makeDatabase()
        for modelId in ["gpt-5.6-terra", "gpt-5.6-luna"] {
            try insertUsageEvent(
                in: db, provider: "codex", modelId: modelId,
                input: 200_000, cached: 40_000, output: 20_000,
                timestamp: "2026-07-29T23:59:59.999Z")
            try insertUsageEvent(
                in: db, provider: "codex", modelId: modelId,
                input: 200_000, cached: 40_000, output: 20_000,
                timestamp: "2026-07-30T00:00:00.000Z")
        }

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        #expect(values.count == 4)
        #expect(abs(values[0] - 0.7100) < 1e-9) // Terra launch price.
        #expect(abs(values[1] - 0.5680) < 1e-9) // Terra reduced price.
        #expect(abs(values[2] - 0.2840) < 1e-9) // Luna launch price.
        #expect(abs(values[3] - 0.0568) < 1e-9) // Luna reduced price.
    }

    @Test("GPT-5.6 historical prices preserve Fast, Flex, and long-context rules")
    func gpt56PriceCutoverPreservesTierAndContextRules() throws {
        let db = try makeDatabase()
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-luna",
            input: 200_000, cached: 40_000, output: 20_000,
            serviceTierPreference: "priority",
            timestamp: "2026-07-29T12:00:00Z")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-luna",
            input: 200_000, cached: 40_000, output: 20_000,
            serviceTierPreference: "priority",
            timestamp: "2026-07-30T12:00:00Z")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-terra",
            input: 200_000, cached: 40_000, output: 20_000,
            serviceTierPreference: "flex",
            timestamp: "2026-07-29T12:00:00Z")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-terra",
            input: 200_000, cached: 40_000, output: 20_000,
            serviceTierPreference: "flex",
            timestamp: "2026-07-30T12:00:00Z")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-terra",
            input: 300_000, cached: 100_000, output: 10_000,
            timestamp: "2026-07-29T12:00:00Z")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-terra",
            input: 300_000, cached: 100_000, output: 10_000,
            timestamp: "2026-07-30T12:00:00Z")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        #expect(values.count == 6)
        #expect(abs(values[0] - 0.5680) < 1e-9) // Luna launch Fast.
        #expect(abs(values[1] - 0.1136) < 1e-9) // Luna reduced Fast.
        #expect(abs(values[2] - 0.3550) < 1e-9) // Terra launch Flex.
        #expect(abs(values[3] - 0.2840) < 1e-9) // Terra reduced Flex.
        #expect(abs(values[4] - 1.2750) < 1e-9) // Terra launch long context.
        #expect(abs(values[5] - 1.0200) < 1e-9) // Terra reduced long context.
    }

    @Test("bundled catalog replaces legacy local prices before historical reprice")
    func bundledCatalogReplacesLegacyLocalPrices() throws {
        let db = try makeDatabase()
        try insertPriceRow(
            in: db, modelId: "gpt-5.6-terra",
            // Match the current bundled numbers exactly. The legacy source
            // alone must still force a reprice because older versions let a
            // local row bypass effective-date history.
            input: 2.00, cached: 0.20, output: 12.00,
            priceSource: "local")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-terra",
            input: 200_000, cached: 40_000, output: 20_000,
            timestamp: "2026-07-29T12:00:00Z")
        try insertUsageEvent(
            in: db, provider: "codex", modelId: "gpt-5.6-terra",
            input: 200_000, cached: 40_000, output: 20_000,
            timestamp: "2026-07-30T12:00:00Z")

        try db.pool.write { conn in
            #expect(try PricingService.installBundledCatalog(in: conn))
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        #expect(values.count == 2)
        #expect(abs(values[0] - 0.7100) < 1e-9)
        #expect(abs(values[1] - 0.5680) < 1e-9)

        let metadata = try db.pool.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT price_source, fetched_at
                FROM pricing_catalog WHERE model_id = 'gpt-5.6-terra'
                """)
        }
        #expect((metadata?["price_source"] as String?) == "bundled")
        #expect((metadata?["fetched_at"] as String?) == nil)
    }

    @Test("codex without recorded tier stays Standard even when legacy fallback is on")
    func codexUnknownTierStaysStandard() throws {
        let db = try makeDatabase()
        // Standard rate (matches the bundled catalog shape; numbers chosen
        // so the maths is hand-verifiable).
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        // Synthetic fast row = 2.5× base (mirrors `CodexFastMode.multipliers`).
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        // 100_000 input, 0 cached, 100_000 output:
        //   Standard: 0.1*5 + 0 + 0.1*30 = $3.50
        //   Fast:     0.1*12.5 + 0 + 0.1*75 = $8.75
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 100_000, cached: 0, output: 100_000)

        // Standard billing produces $3.50.
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }
        let standard = try valueUSD(in: db)
        #expect(abs(standard[0] - 3.50) < 1e-6,
                "standard-tier expected 3.50, got \(standard[0])")

        // The retired fallback must not turn missing evidence into Fast.
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }
        let legacyFallbackEnabled = try valueUSD(in: db)
        #expect(abs(legacyFallbackEnabled[0] - 3.50) < 1e-6,
                "missing tier evidence must remain Standard")

        // And toggling back puts us right where we started — the flag
        // is the only thing that changed, not the event row.
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }
        let backToStandard = try valueUSD(in: db)
        #expect(abs(backToStandard[0] - 3.50) < 1e-6)
    }

    @Test("codex Standard long context doubles input and uses 1.5x output")
    func codexStandardLongContextPricing() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.4",
                           input: 2.50, cached: 0.25, output: 15.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.4",
                             input: 300_000, cached: 100_000, output: 10_000)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        // 0.2M * $5 + 0.1M * $0.50 + 0.01M * $22.50 = $1.275.
        #expect(abs(values[0] - 1.275) < 1e-6)
    }

    @Test("codex Priority long context falls back to Standard long-context pricing")
    func codexPriorityLongContextUsesStandardLongPricing() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.4",
                           input: 2.50, cached: 0.25, output: 15.00)
        try insertPriceRow(in: db, modelId: "gpt-5.4-fast",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.4",
                             input: 300_000, cached: 100_000, output: 10_000,
                             serviceTierPreference: "priority")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 1.275) < 1e-6)
    }

    @Test("codex Flex long context applies long-context multipliers to Flex rates")
    func codexFlexLongContextPricing() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.4",
                           input: 2.50, cached: 0.25, output: 15.00)
        try insertPriceRow(in: db, modelId: "gpt-5.4-flex",
                           input: 1.25, cached: 0.125, output: 7.50)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.4",
                             input: 300_000, cached: 100_000, output: 10_000,
                             serviceTierPreference: "flex")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        // 0.2M * $2.50 + 0.1M * $0.25 + 0.01M * $11.25 = $0.6375.
        #expect(abs(values[0] - 0.6375) < 1e-6)
    }

    @Test("exactly 272K input remains eligible for Priority short-context pricing")
    func codexPriorityAtLongContextBoundary() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.4",
                           input: 2.50, cached: 0.25, output: 15.00)
        try insertPriceRow(in: db, modelId: "gpt-5.4-fast",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.4",
                             input: 272_000, cached: 72_000, output: 10_000,
                             serviceTierPreference: "priority")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }

        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 1.336) < 1e-6)
    }

    @Test("codex Fast-Mode: only listed models reroute; gpt-5-codex stays on its own row")
    func codexFastModeIgnoresUnlistedModels() throws {
        let db = try makeDatabase()
        // gpt-5-codex is NOT in CodexFastMode.multipliers, so even when
        // the flag is on it should JOIN against its base row.
        try insertPriceRow(in: db, modelId: "gpt-5-codex",
                           input: 1.25, cached: 0.125, output: 10.00)
        // We intentionally also seed an unrelated `-fast` row to prove
        // the JOIN is not falling back to "any *-fast row".
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 99.00, cached: 99.00, output: 99.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5-codex",
                             input: 1_000_000, cached: 0, output: 1_000_000)
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }
        let values = try valueUSD(in: db)
        // 1 * 1.25 + 1 * 10.00 = 11.25
        #expect(abs(values[0] - 11.25) < 1e-6,
                "unlisted codex model must price against its base row even with fast mode on, got \(values[0])")
    }

    @Test("claude events ignore codex Fast-Mode flag")
    func claudeUntouchedByCodexFastMode() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "claude-test",
                           input: 3.00, cached: 0.30,
                           output: 15.00, cacheCreation: 3.75)
        // Distractor: even if a claude model id happened to collide
        // with a CodexFastMode key, the provider='codex' guard in the
        // CASE blocks the remap. We don't have such a collision today,
        // but the test pins the contract.
        try insertUsageEvent(in: db, provider: "claude", modelId: "claude-test",
                             input: 100_000, cached: 50_000,
                             output: 200_000, cacheCreation: 10_000)
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }
        let values = try valueUSD(in: db)
        // Same math as the additive-claude test: 0.30 + 0.015 + 0.0375 + 3.00 = 3.3525
        #expect(abs(values[0] - 3.3525) < 1e-6,
                "claude event must not be affected by codex Fast-Mode, got \(values[0])")
    }

    // MARK: - bundled catalog revision propagates

    @Test("a bundled catalog revision reprices only matching rows")
    func bundledCatalogRevisionRepricesAffectedRowsOnly() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "model-a",
                           input: 1.00, cached: 0.10, output: 1.00)
        try insertPriceRow(in: db, modelId: "model-b",
                           input: 2.00, cached: 0.20, output: 2.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "model-a",
                             input: 1_000_000, cached: 0, output: 1_000_000)
        try insertUsageEvent(in: db, provider: "codex", modelId: "model-b",
                             input: 1_000_000, cached: 0, output: 1_000_000)

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let before = try valueUSD(in: db)
        // model-a: 1*1 + 1*1 = 2.00; model-b: 2 + 2 = 4.00
        #expect(abs(before[0] - 2.00) < 1e-6)
        #expect(abs(before[1] - 4.00) < 1e-6)

        // Simulate a later app release revising model-a upward. model-b is unchanged.
        try insertPriceRow(in: db, modelId: "model-a",
                           input: 10.00, cached: 1.00, output: 10.00,
                           priceSource: "bundled")
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn)
        }
        let after = try valueUSD(in: db)
        #expect(abs(after[0] - 20.00) < 1e-6,
                "model-a should reprice to 20.00, got \(after[0])")
        #expect(abs(after[1] - 4.00) < 1e-6,
                "model-b must not change when only model-a's row was edited, got \(after[1])")
    }
}
