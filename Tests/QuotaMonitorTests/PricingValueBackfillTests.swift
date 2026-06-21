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
    /// We bypass `seedCatalog` so each test can pin its own model id +
    /// numbers without depending on PricingSeed.entries (which can shift).
    private func insertPriceRow(
        in db: DatabaseManager,
        modelId: String,
        input: Double, cached: Double,
        output: Double, cacheCreation: Double = 0,
        priceSource: String = "seed"
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
                  updated_at = excluded.updated_at
                """, arguments: [
                    modelId, modelId, input, cached, output, cacheCreation,
                    modelId, true, nil, "https://example/", now, priceSource
                ])
        }
    }

    /// Insert a usage_events row. `valueUSD` is the seed value; backfill
    /// will overwrite it.
    private func insertUsageEvent(
        in db: DatabaseManager,
        provider: String,
        modelId: String,
        input: Int64, cached: Int64,
        output: Int64, cacheCreation: Int64 = 0,
        cacheCreation5m: Int64 = 0,
        cacheCreation1h: Int64 = 0,
        seedValueUSD: Double = -1,
        billingTier: String = "unknown",
        billingTierSource: String = "legacy"
    ) throws {
        let stamp = "2026-04-29T10:00:00Z"
        let sid = "s-\(UUID().uuidString)"
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
                 model_inferred, billing_tier, billing_tier_source)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [
                    sid, stamp, modelId,
                    input, cached, output,
                    input + output + cacheCreation,
                    seedValueUSD,
                    provider, cacheCreation, cacheCreation5m, cacheCreation1h,
                    billingTier, billingTierSource
                ])
        }
    }

    private func valueUSD(in db: DatabaseManager, sessionPrefix: String? = nil) throws -> [Double] {
        try db.pool.read { conn in
            try Double.fetchAll(conn, sql: """
                SELECT value_usd FROM usage_events ORDER BY id ASC
                """)
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
                  'claude-fable-5',
                  'claude-opus-4-8',
                  'claude-sonnet-4-5-20250929',
                  'glm-4.7',
                  'glm-5.1'
                )
                ORDER BY model_id
                """)
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["model_id"] as String, row)
        })

        for item in expected {
            let row = byId[item.modelId]
            #expect(row != nil, "\(item.modelId) should be seeded")
            #expect(abs((row?["input_price_per_million"] as Double? ?? 0) - item.input) < 1e-6)
            #expect(abs((row?["cached_input_price_per_million"] as Double? ?? 0) - item.cached) < 1e-6)
            #expect(abs((row?["cache_creation_price_per_million"] as Double? ?? 0) - item.cacheCreation) < 1e-6)
            #expect(abs((row?["output_price_per_million"] as Double? ?? 0) - item.output) < 1e-6)
            #expect((row?["is_official"] as Bool?) == item.isOfficial)
        }
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

    // MARK: - codex Fast-Mode billing remaps to -fast catalog row

    @Test("codex Fast-Mode fallback: unknown-tier gpt-5.5 event reprices against gpt-5.5-fast catalog row")
    func codexFastModeRoutesUnknownTierToFastVariant() throws {
        let db = try makeDatabase()
        // Standard rate (matches base PricingSeed shape; numbers chosen
        // so the maths is hand-verifiable).
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        // Synthetic fast row = 2.5× base (mirrors `CodexFastMode.multipliers`).
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        // 1_000_000 input, 0 cached, 1_000_000 output:
        //   Standard: 1*5 + 0 + 1*30 = $35.00
        //   Fast:     1*12.5 + 0 + 1*75 = $87.50  (= 35 * 2.5)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 1_000_000, cached: 0, output: 1_000_000)

        // Standard billing leaves us at $35.
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }
        let standard = try valueUSD(in: db)
        #expect(abs(standard[0] - 35.00) < 1e-6,
                "standard-tier expected 35.00, got \(standard[0])")

        // Fast-mode flips the JOIN to gpt-5.5-fast → $87.50.
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }
        let fast = try valueUSD(in: db)
        #expect(abs(fast[0] - 87.50) < 1e-6,
                "fast-tier expected 87.50 (= 35 * 2.5), got \(fast[0])")

        // And toggling back puts us right where we started — the flag
        // is the only thing that changed, not the event row.
        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }
        let backToStandard = try valueUSD(in: db)
        #expect(abs(backToStandard[0] - 35.00) < 1e-6,
                "toggling Fast-Mode off must restore standard pricing")
    }

    @Test("event-level fast prices as Fast with fallback off")
    func eventLevelFastPricesAsFastWithFallbackOff() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 1_000_000, cached: 0, output: 1_000_000,
                             billingTier: "fast")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }
        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 87.50) < 1e-6,
                "event-level fast expected 87.50 with fallback off, got \(values[0])")
    }

    @Test("explicit standard ignores global Fast fallback")
    func explicitStandardIgnoresGlobalFallback() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 1_000_000, cached: 0, output: 1_000_000,
                             billingTier: "standard")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }
        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 35.00) < 1e-6,
                "explicit standard expected 35.00 with fallback on, got \(values[0])")
    }

    @Test("unknown tier uses standard pricing when fallback off")
    func unknownUsesStandardWhenFallbackOff() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 1_000_000, cached: 0, output: 1_000_000,
                             billingTier: "unknown")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: false)
        }
        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 35.00) < 1e-6,
                "unknown tier expected 35.00 with fallback off, got \(values[0])")
    }

    @Test("unknown tier uses Fast pricing when fallback on")
    func unknownUsesFastWhenFallbackOn() throws {
        let db = try makeDatabase()
        try insertPriceRow(in: db, modelId: "gpt-5.5",
                           input: 5.00, cached: 0.50, output: 30.00)
        try insertPriceRow(in: db, modelId: "gpt-5.5-fast",
                           input: 12.50, cached: 1.25, output: 75.00)
        try insertUsageEvent(in: db, provider: "codex", modelId: "gpt-5.5",
                             input: 1_000_000, cached: 0, output: 1_000_000,
                             billingTier: "unknown")

        try db.pool.write { conn in
            try PricingService.backfillAllValues(in: conn,
                                                 codexFastModeBilling: true)
        }
        let values = try valueUSD(in: db)
        #expect(abs(values[0] - 87.50) < 1e-6,
                "unknown tier expected 87.50 with fallback on, got \(values[0])")
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

    // MARK: - price edit propagates

    @Test("after editing a price, backfill recomputes only matching rows")
    func priceEditRepricesAffectedRowsOnly() throws {
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

        // Edit model-a's prices upward (10x). model-b unchanged.
        try insertPriceRow(in: db, modelId: "model-a",
                           input: 10.00, cached: 1.00, output: 10.00,
                           priceSource: "user")
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
