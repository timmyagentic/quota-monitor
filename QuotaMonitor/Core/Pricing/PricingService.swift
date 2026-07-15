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
    let cacheCreationPricePerMillion: Double    // Claude 5m cache write; 0 for OpenAI
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

/// Codex Fast estimation multipliers. Rollout JSONL can record a service-tier
/// preference that the importer freezes per turn. Stored `priority` selects a
/// synthetic Fast row, stored `default` selects the base row, and only unknown
/// preferences follow the global fallback. The preference is pricing evidence,
/// not confirmation of the tier ultimately served by OpenAI.
///
/// **Why a hard-coded map, not catalog rows.** We seed synthetic
/// `-fast` rows in `PricingSeed.entries` derived from these numbers so
/// the catalog stays the single source of truth; `applyLiteLLMUpdate`
/// keeps them in sync whenever the base row is refreshed.
///
/// Update this when OpenAI publishes a new Fast tier ratio or a new
/// model gains a Fast variant — and tweak the seed rows below.
enum CodexFastMode {
    /// model_id → multiplier (applied to input, cached, output rates).
    /// Empty for any model not listed (toggle effectively no-ops for it).
    static let multipliers: [String: Double] = [
        "gpt-5.6-sol": 2.0,
        "gpt-5.6-terra": 2.0,
        "gpt-5.6-luna": 2.0,
        "gpt-5.5": 2.5,
        "gpt-5.4": 2.0,
    ]
    /// Suffix appended to the base model_id to form the synthetic
    /// catalog row that holds Fast-tier prices.
    static let suffix = "-fast"
}

/// Codex Flex uses the published Flex-processing rates. These are half of
/// standard input, cached-input, and output prices for the supported models.
/// As with Fast, rollout preference is pricing evidence rather than proof of
/// the tier ultimately served by OpenAI.
enum CodexFlexMode {
    static let multipliers: [String: Double] = [
        "gpt-5.6-sol": 0.5,
        "gpt-5.6-terra": 0.5,
        "gpt-5.6-luna": 0.5,
        "gpt-5.5": 0.5,
        "gpt-5.4": 0.5,
        "gpt-5.4-mini": 0.5,
        "gpt-5.4-nano": 0.5,
    ]
    static let suffix = "-flex"
}

enum PricingSeed {
    /// Concrete catalog entries shipped with the binary. Includes the
    /// real model rows plus synthetic `*-fast` siblings derived from
    /// `CodexFastMode.multipliers` so per-event preference and fallback
    /// selection can JOIN against them directly.
    static let entries: [PricingEntry] = base + fastVariants + flexVariants

    private static let base: [PricingEntry] = [
        // Legacy fallback used by RolloutParser when no model_id was ever
        // recorded for a session. Matches openai.com gpt-5 pricing.
        .init(modelId: "gpt-5", displayName: "GPT-5 (legacy fallback)",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              effectiveModelId: "gpt-5", isOfficial: true,
              note: "Used for sessions that lack turn_context model metadata.",
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 30.00,
              effectiveModelId: "gpt-5.6-sol", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
        .init(modelId: "gpt-5.6-terra", displayName: "GPT-5.6 Terra",
              inputPricePerMillion: 2.50, cachedInputPricePerMillion: 0.25, outputPricePerMillion: 15.00,
              effectiveModelId: "gpt-5.6-terra", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
        .init(modelId: "gpt-5.6-luna", displayName: "GPT-5.6 Luna",
              inputPricePerMillion: 1.00, cachedInputPricePerMillion: 0.10, outputPricePerMillion: 6.00,
              effectiveModelId: "gpt-5.6-luna", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
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
        // sane even if LiteLLM is unreachable. cache_creation_price_per_million
        // stores the 5-minute cache write rate; 1-hour writes are computed
        // separately as 2x base input during backfill.
        .init(modelId: "claude-fable-5", displayName: "Claude Fable 5",
              inputPricePerMillion: 10.00, cachedInputPricePerMillion: 1.00, outputPricePerMillion: 50.00,
              cacheCreationPricePerMillion: 12.50,
              effectiveModelId: "claude-fable-5", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-8", displayName: "Claude Opus 4.8",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-8", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-7", displayName: "Claude Opus 4.7",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-7", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-6", displayName: "Claude Opus 4.6",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-6", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-5-20251101", displayName: "Claude Opus 4.5",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-5-20251101", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6",
              inputPricePerMillion: 3.00, cachedInputPricePerMillion: 0.30, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 3.75,
              effectiveModelId: "claude-sonnet-4-6", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-sonnet-4-5-20250929", displayName: "Claude Sonnet 4.5",
              inputPricePerMillion: 3.00, cachedInputPricePerMillion: 0.30, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 3.75,
              effectiveModelId: "claude-sonnet-4-5-20250929", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5",
              inputPricePerMillion: 1.00, cachedInputPricePerMillion: 0.10, outputPricePerMillion: 5.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "claude-haiku-4-5-20251001", isOfficial: false,
              note: "Seeded from public list price; refresh from LiteLLM for authoritative values.",
              sourceUrl: "https://www.anthropic.com/pricing"),

        // --- Zhipu GLM (Z.AI Anthropic-compatible endpoint) ---
        // Official Z.AI USD list prices for GLM models observed through the
        // Claude-style import path. No separate cache-write premium is seeded.
        .init(modelId: "glm-5.1", displayName: "GLM-5.1",
              inputPricePerMillion: 1.40, cachedInputPricePerMillion: 0.26, outputPricePerMillion: 4.40,
              effectiveModelId: "glm-5.1", isOfficial: true, note: nil,
              sourceUrl: "https://docs.z.ai/guides/overview/pricing"),
        .init(modelId: "glm-4.7", displayName: "GLM-4.7",
              inputPricePerMillion: 0.60, cachedInputPricePerMillion: 0.11, outputPricePerMillion: 2.20,
              effectiveModelId: "glm-4.7", isOfficial: true, note: nil,
              sourceUrl: "https://docs.z.ai/guides/overview/pricing")
    ]

    /// Synthetic `*-fast` rows for every entry in `CodexFastMode.multipliers`.
    /// We require the base model to exist in `base` so a typo in the
    /// multiplier dict surfaces immediately rather than seeding zero
    /// prices. Source URL points at the base model's pricing page (the
    /// Fast tier multipliers don't have their own canonical doc).
    private static let fastVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.modelId, $0) })
        return CodexFastMode.multipliers.compactMap { (baseId, mul) -> PricingEntry? in
            guard let b = byId[baseId] else {
                assertionFailure("CodexFastMode multiplier references unknown base model '\(baseId)'")
                return nil
            }
            return PricingEntry(
                modelId: b.modelId + CodexFastMode.suffix,
                displayName: "\(b.displayName) (Fast)",
                inputPricePerMillion: b.inputPricePerMillion * mul,
                cachedInputPricePerMillion: b.cachedInputPricePerMillion * mul,
                outputPricePerMillion: b.outputPricePerMillion * mul,
                cacheCreationPricePerMillion: b.cacheCreationPricePerMillion * mul,
                effectiveModelId: b.effectiveModelId,
                isOfficial: false,
                note: "Codex Fast-Mode tier (= \(mul)× standard). Synthetic row used when 'Bill as Fast Mode' is enabled.",
                sourceUrl: b.sourceUrl)
        }
        // Sort so seeding is deterministic across launches / test runs.
        .sorted { $0.modelId < $1.modelId }
    }()

    /// Synthetic `*-flex` rows derived from OpenAI's published Flex rates.
    private static let flexVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.modelId, $0) })
        return CodexFlexMode.multipliers.compactMap { (baseId, mul) -> PricingEntry? in
            guard let b = byId[baseId] else {
                assertionFailure("CodexFlexMode multiplier references unknown base model '\(baseId)'")
                return nil
            }
            return PricingEntry(
                modelId: b.modelId + CodexFlexMode.suffix,
                displayName: "\(b.displayName) (Flex)",
                inputPricePerMillion: b.inputPricePerMillion * mul,
                cachedInputPricePerMillion: b.cachedInputPricePerMillion * mul,
                outputPricePerMillion: b.outputPricePerMillion * mul,
                cacheCreationPricePerMillion: b.cacheCreationPricePerMillion * mul,
                effectiveModelId: b.effectiveModelId,
                isOfficial: false,
                note: "Codex Flex tier (= \(mul)× standard). Synthetic row selected by recorded flex preference.",
                sourceUrl: "https://developers.openai.com/api/docs/pricing?latest-pricing=flex")
        }
        .sorted { $0.modelId < $1.modelId }
    }()
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
    static func applyLiteLLMUpdate(
        entries: [LiteLLMEntry],
        in db: Database,
        codexFastModeBilling: Bool = false
    ) throws -> Int {
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

            // If this base model has a Fast-Mode variant, keep its
            // synthetic `<model>-fast` row in sync. We re-derive the
            // Fast prices from the *just-updated* base prices so a
            // LiteLLM refresh that bumps gpt-5.5 also bumps
            // gpt-5.5-fast (no drift between Standard and Fast).
            // price_source on the fast row stays 'litellm' so a
            // subsequent Restore Defaults won't blow it away unless
            // the user truly intends that.
            if let mul = CodexFastMode.multipliers[modelId] {
                let fastId = modelId + CodexFastMode.suffix
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
                        updated_at = ?
                    WHERE model_id = ? AND price_source != 'local'
                    """, arguments: [
                        inP * mul,
                        cachedP * mul,
                        outP * mul,
                        (entry.perMillionCacheCreation ?? 0) * mul,
                        entry.perMillionAbove200kInput.map { $0 * mul },
                        entry.perMillionAbove200kOutput.map { $0 * mul },
                        entry.maxInputTokens,
                        entry.maxOutputTokens,
                        now,
                        now,
                        fastId
                    ])
                updated += db.changesCount
            }

            // Flex rows are also derived from the refreshed base rates. Keep
            // them synchronized so a LiteLLM update cannot leave stale Flex
            // prices behind.
            if let mul = CodexFlexMode.multipliers[modelId] {
                let flexId = modelId + CodexFlexMode.suffix
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
                        updated_at = ?
                    WHERE model_id = ? AND price_source != 'local'
                    """, arguments: [
                        inP * mul,
                        cachedP * mul,
                        outP * mul,
                        (entry.perMillionCacheCreation ?? 0) * mul,
                        entry.perMillionAbove200kInput.map { $0 * mul },
                        entry.perMillionAbove200kOutput.map { $0 * mul },
                        entry.maxInputTokens,
                        entry.maxOutputTokens,
                        now,
                        now,
                        flexId
                    ])
                updated += db.changesCount
            }
        }

        if updated > 0 {
            try backfillAllValues(in: db,
                                  codexFastModeBilling: codexFastModeBilling)
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
    ///     the cached rate, 5-minute `cache_creation_input_tokens` are billed
    ///     at the catalog write rate, and 1-hour cache writes are billed at
    ///     2x base input. No subtraction needed.
    ///
    /// For codex events, a stored `priority` or `flex` preference selects the
    /// matching synthetic tier row when supported. A stored `default` selects
    /// the base row, and `codexFastModeBilling` chooses the Fast fallback only
    /// when the stored preference is unknown.
    ///
    /// Cheap (sub-second for tens of thousands of rows).
    static func backfillAllValues(
        in db: Database,
        codexFastModeBilling: Bool = false
    ) throws {
        let effectiveExpr = effectiveModelIdSQL(codexFastModeBilling: codexFastModeBilling)
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
                       + CASE
                           WHEN (usage_events.cache_creation_5m_tokens
                                 + usage_events.cache_creation_1h_tokens) > 0
                           THEN usage_events.cache_creation_5m_tokens
                           ELSE usage_events.cache_creation_tokens
                         END
                          * pc.cache_creation_price_per_million
                       + CASE
                           WHEN (usage_events.cache_creation_5m_tokens
                                 + usage_events.cache_creation_1h_tokens) > 0
                           THEN usage_events.cache_creation_1h_tokens
                           ELSE 0
                         END
                          * (pc.input_price_per_million * 2.0)
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
              WHERE pc.model_id = \(effectiveExpr)
            )
            WHERE EXISTS (
              SELECT 1 FROM pricing_catalog pc
              WHERE pc.model_id = \(effectiveExpr)
            )
            """)
    }

    /// SQL expression that resolves to the catalog `model_id` we should
    /// price this event against. A recognized codex event's stored tier
    /// preference wins; the Fast-Mode setting only handles unknown rows.
    /// Other providers and models keep `usage_events.model_id`.
    ///
    /// We string-interpolate the model id lists and suffixes because
    /// they're code-controlled (sourced from the tier maps), never
    /// user input. Single-quote escaping is unnecessary here, but the
    /// model id assertion below makes the assumption explicit.
    private static func effectiveModelIdSQL(codexFastModeBilling: Bool) -> String {
        guard !CodexFastMode.multipliers.isEmpty,
              !CodexFlexMode.multipliers.isEmpty
        else {
            return "usage_events.model_id"
        }
        // Determinism + simpler diffs.
        let fastIds = CodexFastMode.multipliers.keys.sorted()
        let flexIds = CodexFlexMode.multipliers.keys.sorted()
        for id in Set(fastIds + flexIds) {
            assert(!id.contains("'"),
                   "Codex tier multiplier key '\(id)' has a single quote — SQL not safe to interpolate")
        }
        let quotedFast = fastIds.map { "'\($0)'" }.joined(separator: ",")
        let quotedFlex = flexIds.map { "'\($0)'" }.joined(separator: ",")
        let fastSuffix = CodexFastMode.suffix
        let flexSuffix = CodexFlexMode.suffix
        let globalFast = codexFastModeBilling ? 1 : 0
        return """
        CASE
          WHEN usage_events.provider = 'codex'
          THEN CASE
            WHEN usage_events.codex_service_tier_preference = 'priority'
                 AND usage_events.model_id IN (\(quotedFast))
              THEN usage_events.model_id || '\(fastSuffix)'
            WHEN usage_events.codex_service_tier_preference = 'flex'
                 AND usage_events.model_id IN (\(quotedFlex))
              THEN usage_events.model_id || '\(flexSuffix)'
            WHEN usage_events.codex_service_tier_preference = 'default'
              THEN usage_events.model_id
            WHEN usage_events.codex_service_tier_preference IS NULL
                 AND \(globalFast) = 1
                 AND usage_events.model_id IN (\(quotedFast))
              THEN usage_events.model_id || '\(fastSuffix)'
            ELSE usage_events.model_id
          END
          ELSE usage_events.model_id
        END
        """
    }
}
