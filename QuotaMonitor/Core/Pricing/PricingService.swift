import Foundation
import GRDB

// Seeds the pricing_catalog table and computes API-equivalent value for usage events.
//
// Value formula (matches codex-pacer):
//   value_usd =   max(input - cached, 0) * input_price/1M
//               + cached                  * cached_price/1M
//               + output                  * output_price/1M
//
// Why not `+ reasoning_output_tokens * output_price`? Empirical check across 300
// token_count events in real Codex JSONL: every single one satisfies
// `total_tokens == input_tokens + output_tokens` and NONE satisfy
// `total_tokens == input_tokens + output_tokens + reasoning_output_tokens`.
// In other words `output_tokens` already INCLUDES the reasoning portion (OpenAI
// reports `completion_tokens` as the superset; `reasoning_tokens` is a
// breakdown of it, not an addend). Adding reasoning again would double-bill it
// at the output rate. We keep the column for surfacing in UI but exclude it
// from the price calculation.

struct PricingEntry: Sendable, Hashable {
    let modelId: String
    let displayName: String
    let inputPricePerMillion: Double
    let cachedInputPricePerMillion: Double
    let outputPricePerMillion: Double
    let cacheCreationPricePerMillion: Double    // Claude only; 0 for OpenAI
    let effectiveModelId: String
    let isOfficial: Bool
    let note: String?
    let sourceUrl: String

    init(modelId: String, displayName: String,
         inputPricePerMillion: Double,
         cachedInputPricePerMillion: Double,
         outputPricePerMillion: Double,
         cacheCreationPricePerMillion: Double = 0,
         effectiveModelId: String,
         isOfficial: Bool,
         note: String?,
         sourceUrl: String) {
        self.modelId = modelId
        self.displayName = displayName
        self.inputPricePerMillion = inputPricePerMillion
        self.cachedInputPricePerMillion = cachedInputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheCreationPricePerMillion = cacheCreationPricePerMillion
        self.effectiveModelId = effectiveModelId
        self.isOfficial = isOfficial
        self.note = note
        self.sourceUrl = sourceUrl
    }
}

enum PricingSeed {
    static let entries: [PricingEntry] = [
        // Legacy fallback used by RolloutParser when no model_id was ever
        // recorded for a session. Matches openai.com gpt-5 pricing.
        .init(modelId: "gpt-5", displayName: "GPT-5 (legacy fallback)",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              effectiveModelId: "gpt-5", isOfficial: true,
              note: "Used for sessions that lack turn_context model metadata.",
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.5", displayName: "GPT-5.5",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 30.00,
              effectiveModelId: "gpt-5.5", isOfficial: true, note: nil,
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.4", displayName: "GPT-5.4",
              inputPricePerMillion: 2.50, cachedInputPricePerMillion: 0.25, outputPricePerMillion: 15.00,
              effectiveModelId: "gpt-5.4", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.4"),
        .init(modelId: "gpt-5.4-mini", displayName: "GPT-5.4 Mini",
              inputPricePerMillion: 0.75, cachedInputPricePerMillion: 0.075, outputPricePerMillion: 4.50,
              effectiveModelId: "gpt-5.4-mini", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.4-mini"),
        .init(modelId: "gpt-5.4-nano", displayName: "GPT-5.4 Nano",
              inputPricePerMillion: 0.20, cachedInputPricePerMillion: 0.02, outputPricePerMillion: 1.25,
              effectiveModelId: "gpt-5.4-nano", isOfficial: true, note: nil,
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.3-codex", displayName: "GPT-5.3 Codex",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              effectiveModelId: "gpt-5.3-codex", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.3-codex"),
        .init(modelId: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              effectiveModelId: "gpt-5.3-codex", isOfficial: false,
              note: "No public Spark API price was found. Using GPT-5.3 Codex pricing.",
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.3-codex"),
        .init(modelId: "gpt-5.2", displayName: "GPT-5.2",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              effectiveModelId: "gpt-5.2", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.2-codex"),
        .init(modelId: "gpt-5.2-codex", displayName: "GPT-5.2 Codex",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              effectiveModelId: "gpt-5.2-codex", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.2-codex"),
        .init(modelId: "gpt-5-codex", displayName: "GPT-5 Codex",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              effectiveModelId: "gpt-5-codex", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5-codex"),
        .init(modelId: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              effectiveModelId: "gpt-5.1-codex-max", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.1-codex-max"),
        .init(modelId: "gpt-5.1-codex", displayName: "GPT-5.1 Codex",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              effectiveModelId: "gpt-5.1-codex", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.1-codex"),
        .init(modelId: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex Mini",
              inputPricePerMillion: 0.25, cachedInputPricePerMillion: 0.025, outputPricePerMillion: 2.00,
              effectiveModelId: "gpt-5.1-codex-mini", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.1-codex-mini"),

        // --- Anthropic Claude (placeholder seeds; LiteLLM refresh overwrites) ---
        // Seeded with public April-2026 list prices so first-launch values are
        // sane even if LiteLLM is unreachable. cache_creation is filled by the
        // dedicated migration column (5x rate), not represented in this struct
        // — applyLiteLLMUpdate stamps it from `cache_creation_input_token_cost`.
        .init(modelId: "claude-opus-4-7", displayName: "Claude Opus 4.7",
              inputPricePerMillion: 15.00, cachedInputPricePerMillion: 1.50, outputPricePerMillion: 75.00,
              cacheCreationPricePerMillion: 18.75,
              effectiveModelId: "claude-opus-4-7", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-6", displayName: "Claude Opus 4.6",
              inputPricePerMillion: 15.00, cachedInputPricePerMillion: 1.50, outputPricePerMillion: 75.00,
              cacheCreationPricePerMillion: 18.75,
              effectiveModelId: "claude-opus-4-6", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6",
              inputPricePerMillion: 3.00, cachedInputPricePerMillion: 0.30, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 3.75,
              effectiveModelId: "claude-sonnet-4-6", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5",
              inputPricePerMillion: 1.00, cachedInputPricePerMillion: 0.10, outputPricePerMillion: 5.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "claude-haiku-4-5-20251001", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing")
    ]
}

enum PricingService {

    /// Idempotent seed write. Run once on app startup; cheap enough to re-run on every launch.
    /// IMPORTANT: rows previously stamped `price_source = 'litellm'` or `'local'`
    /// must NOT be reverted to seed values, otherwise a relaunch would erase the
    /// LiteLLM refresh / user's edits. We INSERT new rows but only UPDATE when
    /// price_source is still 'seed'.
    static func seedCatalog(in db: Database) throws {
        let now = ISO8601.fractional.string(from: Date())
        for entry in PricingSeed.entries {
            try db.execute(sql: """
                INSERT INTO pricing_catalog
                  (model_id, display_name, input_price_per_million,
                   cached_input_price_per_million, output_price_per_million,
                   cache_creation_price_per_million,
                   effective_model_id, is_official, note, source_url, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(model_id) DO UPDATE SET
                  display_name = excluded.display_name,
                  input_price_per_million = excluded.input_price_per_million,
                  cached_input_price_per_million = excluded.cached_input_price_per_million,
                  output_price_per_million = excluded.output_price_per_million,
                  cache_creation_price_per_million = excluded.cache_creation_price_per_million,
                  effective_model_id = excluded.effective_model_id,
                  is_official = excluded.is_official,
                  note = excluded.note,
                  source_url = excluded.source_url,
                  updated_at = excluded.updated_at
                WHERE pricing_catalog.price_source = 'seed'
                """, arguments: [
                    entry.modelId,
                    entry.displayName,
                    entry.inputPricePerMillion,
                    entry.cachedInputPricePerMillion,
                    entry.outputPricePerMillion,
                    entry.cacheCreationPricePerMillion,
                    entry.effectiveModelId,
                    entry.isOfficial,
                    entry.note,
                    entry.sourceUrl,
                    now
                ])
        }
    }

    /// Apply a LiteLLM fetch result to `pricing_catalog`.
    ///
    /// Behavior:
    ///   - Only rows already in the catalog are touched (we don't auto-add new
    ///     models — Phase 2 handles unknown providers).
    ///   - Rows whose `price_source = 'local'` are skipped (user edits win).
    ///   - For matched rows we overwrite input/cached/output prices, plus the
    ///     LiteLLM-only fields (cache_creation, above_200k tiers, max tokens),
    ///     and stamp `price_source='litellm'`, `fetched_at=now`.
    ///
    /// Returns the number of rows actually updated.
    @discardableResult
    static func applyLiteLLMUpdate(entries: [LiteLLMEntry], in db: Database) throws -> Int {
        let now = ISO8601.fractional.string(from: Date())

        let existingIds = try String.fetchAll(db, sql:
            "SELECT model_id FROM pricing_catalog WHERE price_source != 'local'")
        let allowed = Set(existingIds)

        // index entries by model id (LiteLLM occasionally lists the same model
        // under prefixed aliases like "openai/gpt-4o"; we match on the bare id
        // we have in our catalog).
        var byId: [String: LiteLLMEntry] = [:]
        for entry in entries {
            byId[entry.modelId] = entry
            // Also index without provider prefix ("openai/gpt-4o" -> "gpt-4o").
            if let slash = entry.modelId.firstIndex(of: "/") {
                let bare = String(entry.modelId[entry.modelId.index(after: slash)...])
                if byId[bare] == nil { byId[bare] = entry }
            }
        }

        var updated = 0
        for modelId in allowed {
            guard let entry = byId[modelId] else { continue }
            // Need at least input + output to be meaningful.
            guard let inP = entry.perMillionInput,
                  let outP = entry.perMillionOutput else { continue }

            // cached read price: LiteLLM's cache_read_input_token_cost; if
            // missing, fall back to the existing seed cached price (read it
            // first so we don't blow it away).
            let existingCached = try Double.fetchOne(db, sql:
                "SELECT cached_input_price_per_million FROM pricing_catalog WHERE model_id = ?",
                arguments: [modelId]) ?? 0
            let cachedP = entry.perMillionCacheRead ?? existingCached

            try db.execute(sql: """
                UPDATE pricing_catalog
                SET input_price_per_million = ?,
                    cached_input_price_per_million = ?,
                    output_price_per_million = ?,
                    cache_creation_price_per_million = ?,
                    above_200k_input_price_per_million = ?,
                    above_200k_output_price_per_million = ?,
                    max_input_tokens = ?,
                    max_output_tokens = ?,
                    price_source = 'litellm',
                    fetched_at = ?,
                    updated_at = ?,
                    is_official = 1
                WHERE model_id = ? AND price_source != 'local'
                """, arguments: [
                    inP,
                    cachedP,
                    outP,
                    entry.perMillionCacheCreation ?? 0,
                    entry.perMillionAbove200kInput,
                    entry.perMillionAbove200kOutput,
                    entry.maxInputTokens,
                    entry.maxOutputTokens,
                    now,
                    now,
                    modelId
                ])
            updated += db.changesCount
        }

        if updated > 0 {
            try backfillAllValues(in: db)
        }
        return updated
    }

    /// One-shot UPDATE that recalculates value_usd for every usage_event whose model
    /// has a pricing entry. Provider-branched:
    ///
    ///   - **codex** (OpenAI): `input_tokens` is the gross figure that already
    ///     includes the cached portion, so the input rate only applies to
    ///     `max(input - cached, 0)`. `output_tokens` already includes reasoning;
    ///     no cache_creation involved.
    ///
    ///   - **claude**: the API breaks tokens out by category — `input_tokens`
    ///     is the **uncached** portion, `cache_read_input_tokens` is billed at
    ///     the cached rate, `cache_creation_input_tokens` is billed at the 5x
    ///     write rate. No subtraction needed.
    ///
    /// Cheap (sub-second for tens of thousands of rows).
    static func backfillAllValues(in db: Database) throws {
        try db.execute(sql: """
            UPDATE usage_events
            SET value_usd = (
              SELECT
                  CASE usage_events.provider
                    WHEN 'claude' THEN
                      (usage_events.input_tokens
                          * pc.input_price_per_million
                       + usage_events.cached_input_tokens
                          * pc.cached_input_price_per_million
                       + usage_events.cache_creation_tokens
                          * pc.cache_creation_price_per_million
                       + usage_events.output_tokens
                          * pc.output_price_per_million
                      ) / 1000000.0
                    ELSE
                      (MAX(usage_events.input_tokens - usage_events.cached_input_tokens, 0)
                          * pc.input_price_per_million
                       + usage_events.cached_input_tokens
                          * pc.cached_input_price_per_million
                       + usage_events.output_tokens
                          * pc.output_price_per_million
                      ) / 1000000.0
                  END
              FROM pricing_catalog pc
              WHERE pc.model_id = usage_events.model_id
            )
            WHERE EXISTS (
              SELECT 1 FROM pricing_catalog pc
              WHERE pc.model_id = usage_events.model_id
            )
            """)
    }
}
