import Foundation
import GRDB

// Installs the bundled pricing catalog and computes API-equivalent value for usage events.
//
// Codex value formula:
//   value_usd =   max(input - cached - cache_write, 0) * input_price/1M
//               + cached                                * cached_price/1M
//               + cache_write                           * cache_write_price/1M
//               + output                                * output_price/1M
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
    /// Provider-specific cache-write rate: Claude 5-minute cache creation or
    /// Codex prompt-cache writes. Values are materialized in the catalog.
    let cacheCreationPricePerMillion: Double
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
/// synthetic Fast row while stored `default` and unknown preferences select
/// the base row. The preference is pricing evidence, not confirmation of the
/// tier ultimately served by OpenAI.
///
/// **Why a hard-coded map, not catalog rows.** The bundled catalog derives
/// synthetic `-fast` rows from these numbers so every shipped tier remains
/// deterministic and versioned with the app.
///
/// Update this when OpenAI publishes a new Fast tier ratio or a new
/// model gains a Fast variant — and update the bundled rows below.
enum CodexFastMode {
    /// model_id → multiplier used only to materialize Fast catalog rows.
    /// Empty for any model not listed (toggle effectively no-ops for it).
    static let multipliers: [String: Double] = [
        "gpt-5.6-sol": 2.0,
        "gpt-5.6-terra": 2.0,
        "gpt-5.6-luna": 2.0,
        "gpt-5.5": 2.5,
        "gpt-5.4": 2.0,
        "gpt-5.3-codex": 2.0,
    ]
    /// Suffix appended to the base model_id to form the synthetic
    /// catalog row that holds Fast-tier prices.
    static let suffix = "-fast"
}

/// Codex Flex uses the published Flex-processing rates. These multipliers are
/// consumed only while materializing catalog rows.
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

/// Defines which models receive materialized Long rows. GPT-5.6 has published
/// Fast Long prices; older Fast models without such rows select Standard Long.
/// Flex retains its tier.
enum CodexLongContextPricing {
    static let inputTokenThreshold: Int64 = 272_000
    /// Used only while materializing bundled Long rows, never in event SQL.
    static let inputPriceMultiplier = 2.0
    static let outputPriceMultiplier = 1.5
    static let suffix = "-long"
    static let modelIds: Set<String> = [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
    ]
    static let fastModelIds: Set<String> = [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ]
}

struct CodexHistoricalPricePeriod: Sendable, Hashable {
    let catalogRowId: String
    let modelId: String
    let startsOn: String?
    let endsBefore: String
    let inputPricePerMillion: Double
    let cachedInputPricePerMillion: Double
    let cacheWritePricePerMillion: Double
    let outputPricePerMillion: Double
}

/// Fixed OpenAI list-price periods materialized into synthetic catalog rows.
/// Terra/Luna use OpenAI's date-only July 30 announcement boundary. Sol uses
/// the precise public announcement timestamp from OpenAI's official post; it
/// is an auditable public cutover, not a claim about an unpublished internal
/// billing-switch second.
enum CodexPriceHistory {
    static let periods: [CodexHistoricalPricePeriod] = [
        .init(
            catalogRowId: "gpt-5.6-sol-history-pre-20260821",
            modelId: "gpt-5.6-sol",
            startsOn: nil,
            endsBefore: "2026-08-21T19:34:10.000Z",
            inputPricePerMillion: 5.00,
            cachedInputPricePerMillion: 0.50,
            cacheWritePricePerMillion: 6.25,
            outputPricePerMillion: 30.00),
        .init(
            catalogRowId: "gpt-5.6-terra-history-pre-20260730",
            modelId: "gpt-5.6-terra",
            startsOn: nil,
            endsBefore: "2026-07-30",
            inputPricePerMillion: 2.50,
            cachedInputPricePerMillion: 0.25,
            cacheWritePricePerMillion: 3.125,
            outputPricePerMillion: 15.00),
        .init(
            catalogRowId: "gpt-5.6-luna-history-pre-20260730",
            modelId: "gpt-5.6-luna",
            startsOn: nil,
            endsBefore: "2026-07-30",
            inputPricePerMillion: 1.00,
            cachedInputPricePerMillion: 0.10,
            cacheWritePricePerMillion: 1.25,
            outputPricePerMillion: 6.00),
    ]
}

enum BundledPricingCatalog {
    /// Concrete catalog entries shipped with the binary. Codex variants cover
    /// final Short/Long × tier and historical prices so event valuation only
    /// chooses a row and never recalculates its prices.
    static let entries: [PricingEntry] = base
        + fastVariants
        + flexVariants
        + longVariants
        + fastLongVariants
        + flexLongVariants
        + historicalVariants

    /// Bundled rows that are valid for Codex rollout valuation. Provider
    /// scoping prevents Claude/GLM rows from accidentally entering the Codex
    /// formula merely because a rollout contains the same model id.
    static let codexModelIds: Set<String> = {
        var ids = codexBaseModelIds
        ids.formUnion(fastVariants.map(\.modelId))
        ids.formUnion(flexVariants.map(\.modelId))
        ids.formUnion(longVariants.map(\.modelId))
        ids.formUnion(fastLongVariants.map(\.modelId))
        ids.formUnion(flexLongVariants.map(\.modelId))
        ids.formUnion(historicalVariants.map(\.modelId))
        return ids
    }()

    private static let codexBaseModelIds: Set<String> = [
        "gpt-5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.3-codex",
        "codex-auto-review",
        "gpt-5.3-codex-spark",
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
    ]

    private static let base: [PricingEntry] = [
        // Legacy fallback used by RolloutParser when no model_id was ever
        // recorded for a session. Matches openai.com gpt-5 pricing.
        .init(modelId: "gpt-5", displayName: "GPT-5 (legacy fallback)",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "gpt-5", isOfficial: true,
              note: "Used for sessions that lack turn_context model metadata.",
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
              inputPricePerMillion: 4.00, cachedInputPricePerMillion: 0.40, outputPricePerMillion: 20.00,
              cacheCreationPricePerMillion: 5.00,
              effectiveModelId: "gpt-5.6-sol", isOfficial: true,
              note: "Promotional price announced at 2026-08-21T19:34:10Z; earlier usage keeps launch pricing.",
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
        .init(modelId: "gpt-5.6-terra", displayName: "GPT-5.6 Terra",
              inputPricePerMillion: 2.00, cachedInputPricePerMillion: 0.20, outputPricePerMillion: 12.00,
              cacheCreationPricePerMillion: 2.50,
              effectiveModelId: "gpt-5.6-terra", isOfficial: true,
              note: "Current price since 2026-07-30; earlier usage keeps launch pricing.",
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
        .init(modelId: "gpt-5.6-luna", displayName: "GPT-5.6 Luna",
              inputPricePerMillion: 0.20, cachedInputPricePerMillion: 0.02, outputPricePerMillion: 1.20,
              cacheCreationPricePerMillion: 0.25,
              effectiveModelId: "gpt-5.6-luna", isOfficial: true,
              note: "Current price since 2026-07-30; earlier usage keeps launch pricing.",
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
        .init(modelId: "gpt-5.5", displayName: "GPT-5.5",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 30.00,
              cacheCreationPricePerMillion: 5.00,
              effectiveModelId: "gpt-5.5", isOfficial: true, note: nil,
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.4", displayName: "GPT-5.4",
              inputPricePerMillion: 2.50, cachedInputPricePerMillion: 0.25, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 2.50,
              effectiveModelId: "gpt-5.4", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.4"),
        .init(modelId: "gpt-5.4-mini", displayName: "GPT-5.4 Mini",
              inputPricePerMillion: 0.75, cachedInputPricePerMillion: 0.075, outputPricePerMillion: 4.50,
              cacheCreationPricePerMillion: 0.75,
              effectiveModelId: "gpt-5.4-mini", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.4-mini"),
        .init(modelId: "gpt-5.4-nano", displayName: "GPT-5.4 Nano",
              inputPricePerMillion: 0.20, cachedInputPricePerMillion: 0.02, outputPricePerMillion: 1.25,
              cacheCreationPricePerMillion: 0.20,
              effectiveModelId: "gpt-5.4-nano", isOfficial: true, note: nil,
              sourceUrl: "https://openai.com/api/pricing/"),
        .init(modelId: "gpt-5.3-codex", displayName: "GPT-5.3 Codex",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              cacheCreationPricePerMillion: 1.75,
              effectiveModelId: "gpt-5.3-codex", isOfficial: true, note: nil,
              sourceUrl: "https://developers.openai.com/api/docs/pricing"),
        .init(modelId: "codex-auto-review", displayName: "Codex Auto Review",
              inputPricePerMillion: 2.50, cachedInputPricePerMillion: 0.25, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 2.50,
              effectiveModelId: "gpt-5.4", isOfficial: false,
              note: "No separate public price is available. Estimated using GPT-5.4 standard pricing.",
              sourceUrl: "https://learn.chatgpt.com/docs/sandboxing/auto-review"),
        .init(modelId: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              cacheCreationPricePerMillion: 1.75,
              effectiveModelId: "gpt-5.3-codex", isOfficial: false,
              note: "No public Spark API price was found. Using GPT-5.3 Codex pricing.",
              sourceUrl: "https://developers.openai.com/api/docs/models/gpt-5.3-codex"),
        .init(modelId: "gpt-5.2", displayName: "GPT-5.2",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              cacheCreationPricePerMillion: 1.75,
              effectiveModelId: "gpt-5.2", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.2-codex"),
        .init(modelId: "gpt-5.2-codex", displayName: "GPT-5.2 Codex",
              inputPricePerMillion: 1.75, cachedInputPricePerMillion: 0.175, outputPricePerMillion: 14.00,
              cacheCreationPricePerMillion: 1.75,
              effectiveModelId: "gpt-5.2-codex", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.2-codex"),
        .init(modelId: "gpt-5-codex", displayName: "GPT-5 Codex",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "gpt-5-codex", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5-codex"),
        .init(modelId: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "gpt-5.1-codex-max", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.1-codex-max"),
        .init(modelId: "gpt-5.1-codex", displayName: "GPT-5.1 Codex",
              inputPricePerMillion: 1.25, cachedInputPricePerMillion: 0.125, outputPricePerMillion: 10.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "gpt-5.1-codex", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.1-codex"),
        .init(modelId: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex Mini",
              inputPricePerMillion: 0.25, cachedInputPricePerMillion: 0.025, outputPricePerMillion: 2.00,
              cacheCreationPricePerMillion: 0.25,
              effectiveModelId: "gpt-5.1-codex-mini", isOfficial: true, note: nil,
              sourceUrl: "https://platform.openai.com/docs/models/gpt-5.1-codex-mini"),

        // --- Anthropic Claude (bundled catalog) ---
        // Prices ship with the app. Update them in a release when vendor rates
        // change. cache_creation_price_per_million stores the 5-minute cache
        // write rate; 1-hour writes are computed separately as 2x base input.
        .init(modelId: "claude-opus-5", displayName: "Claude Opus 5",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-5", isOfficial: true, note: nil,
              sourceUrl: "https://platform.claude.com/docs/en/about-claude/pricing"),
        .init(modelId: "claude-fable-5", displayName: "Claude Fable 5",
              inputPricePerMillion: 10.00, cachedInputPricePerMillion: 1.00, outputPricePerMillion: 50.00,
              cacheCreationPricePerMillion: 12.50,
              effectiveModelId: "claude-fable-5", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-sonnet-5", displayName: "Claude Sonnet 5",
              inputPricePerMillion: 2.00, cachedInputPricePerMillion: 0.20, outputPricePerMillion: 10.00,
              cacheCreationPricePerMillion: 2.50,
              effectiveModelId: "claude-sonnet-5", isOfficial: true,
              note: "Anthropic retained the launch price as the permanent standard price.",
              sourceUrl: "https://platform.claude.com/docs/en/about-claude/pricing"),
        .init(modelId: "claude-opus-4-8", displayName: "Claude Opus 4.8",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-8", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-7", displayName: "Claude Opus 4.7",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-7", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-6", displayName: "Claude Opus 4.6",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-6", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-opus-4-5-20251101", displayName: "Claude Opus 4.5",
              inputPricePerMillion: 5.00, cachedInputPricePerMillion: 0.50, outputPricePerMillion: 25.00,
              cacheCreationPricePerMillion: 6.25,
              effectiveModelId: "claude-opus-4-5-20251101", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6",
              inputPricePerMillion: 3.00, cachedInputPricePerMillion: 0.30, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 3.75,
              effectiveModelId: "claude-sonnet-4-6", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-sonnet-4-5-20250929", displayName: "Claude Sonnet 4.5",
              inputPricePerMillion: 3.00, cachedInputPricePerMillion: 0.30, outputPricePerMillion: 15.00,
              cacheCreationPricePerMillion: 3.75,
              effectiveModelId: "claude-sonnet-4-5-20250929", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),
        .init(modelId: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5",
              inputPricePerMillion: 1.00, cachedInputPricePerMillion: 0.10, outputPricePerMillion: 5.00,
              cacheCreationPricePerMillion: 1.25,
              effectiveModelId: "claude-haiku-4-5-20251001", isOfficial: false,
              note: "Bundled from public list pricing; updated with app releases.",
              sourceUrl: "https://www.anthropic.com/pricing"),

        // --- Zhipu GLM (Z.AI Anthropic-compatible endpoint) ---
        // Official Z.AI USD list prices for GLM models observed through the
        // Claude-style import path. No separate cache-write premium is bundled.
        .init(modelId: "glm-5.2", displayName: "GLM-5.2",
              inputPricePerMillion: 1.40, cachedInputPricePerMillion: 0.26, outputPricePerMillion: 4.40,
              effectiveModelId: "glm-5.2", isOfficial: true, note: nil,
              sourceUrl: "https://docs.z.ai/guides/overview/pricing"),
        .init(modelId: "glm-5.1", displayName: "GLM-5.1",
              inputPricePerMillion: 1.40, cachedInputPricePerMillion: 0.26, outputPricePerMillion: 4.40,
              effectiveModelId: "glm-5.1", isOfficial: true, note: nil,
              sourceUrl: "https://docs.z.ai/guides/overview/pricing"),
        .init(modelId: "glm-4.7", displayName: "GLM-4.7",
              inputPricePerMillion: 0.60, cachedInputPricePerMillion: 0.11, outputPricePerMillion: 2.20,
              effectiveModelId: "glm-4.7", isOfficial: true, note: nil,
              sourceUrl: "https://docs.z.ai/guides/overview/pricing")
    ]

    /// Synthetic Short-context Fast rows.
    private static let fastVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.modelId, $0) })
        return CodexFastMode.multipliers.keys.sorted().compactMap { baseId in
            let mul = CodexFastMode.multipliers[baseId] ?? 1
            guard let b = byId[baseId] else {
                assertionFailure("CodexFastMode multiplier references unknown base model '\(baseId)'")
                return nil
            }
            return scaledVariant(
                from: b,
                modelId: b.modelId + CodexFastMode.suffix,
                displayName: "\(b.displayName) (Fast Short)",
                inputMultiplier: mul,
                outputMultiplier: mul,
                note: "Materialized Fast Short price (= \(mul)× Standard Short).")
        }
    }()

    /// Synthetic Short-context Flex rows.
    private static let flexVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.modelId, $0) })
        return CodexFlexMode.multipliers.keys.sorted().compactMap { baseId in
            let mul = CodexFlexMode.multipliers[baseId] ?? 1
            guard let b = byId[baseId] else {
                assertionFailure("CodexFlexMode multiplier references unknown base model '\(baseId)'")
                return nil
            }
            return scaledVariant(
                from: b,
                modelId: b.modelId + CodexFlexMode.suffix,
                displayName: "\(b.displayName) (Flex Short)",
                inputMultiplier: mul,
                outputMultiplier: mul,
                note: "Materialized Flex Short price (= \(mul)× Standard Short).",
                sourceUrl: "https://developers.openai.com/api/docs/pricing?latest-pricing=flex")
        }
    }()

    /// Materialized Standard Long rows for every model with published
    /// long-context pricing.
    private static let longVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.modelId, $0) })
        return CodexLongContextPricing.modelIds.sorted().compactMap { baseId in
            guard let b = byId[baseId] else { return nil }
            return longVariant(from: b)
        }
    }()

    /// GPT-5.6 publishes Fast Long prices. Older Priority requests deliberately
    /// select the Standard Long row instead, so no older Fast Long row exists.
    private static let fastLongVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: fastVariants.map { ($0.effectiveModelId, $0) })
        return CodexLongContextPricing.fastModelIds.sorted().compactMap { baseId in
            guard let b = byId[baseId] else { return nil }
            return longVariant(from: b)
        }
    }()

    /// Flex retains its tier in Long context when both features are supported.
    private static let flexLongVariants: [PricingEntry] = {
        let byId = Dictionary(uniqueKeysWithValues: flexVariants.map { ($0.effectiveModelId, $0) })
        return CodexLongContextPricing.modelIds
            .intersection(CodexFlexMode.multipliers.keys)
            .sorted()
            .compactMap { baseId in
                guard let b = byId[baseId] else { return nil }
                return longVariant(from: b)
            }
    }()

    /// Historical rows use the same Short/Long × Standard/Flex/Fast matrix as
    /// current pricing. The event selector chooses one final row; valuation
    /// never reapplies historical tier or context multipliers.
    private static let historicalVariants: [PricingEntry] = {
        CodexPriceHistory.periods.flatMap { period -> [PricingEntry] in
            let standard = PricingEntry(
                modelId: period.catalogRowId,
                displayName: "\(period.modelId) (Historical Short)",
                inputPricePerMillion: period.inputPricePerMillion,
                cachedInputPricePerMillion: period.cachedInputPricePerMillion,
                outputPricePerMillion: period.outputPricePerMillion,
                cacheCreationPricePerMillion: period.cacheWritePricePerMillion,
                effectiveModelId: period.modelId,
                isOfficial: true,
                note: "Historical price before \(period.endsBefore).",
                sourceUrl: "https://developers.openai.com/api/docs/pricing")
            var shortRows = [standard]
            if let mul = CodexFastMode.multipliers[period.modelId] {
                shortRows.append(scaledVariant(
                    from: standard,
                    modelId: standard.modelId + CodexFastMode.suffix,
                    displayName: "\(period.modelId) (Historical Fast Short)",
                    inputMultiplier: mul,
                    outputMultiplier: mul,
                    note: "Materialized historical Fast Short price."))
            }
            if let mul = CodexFlexMode.multipliers[period.modelId] {
                shortRows.append(scaledVariant(
                    from: standard,
                    modelId: standard.modelId + CodexFlexMode.suffix,
                    displayName: "\(period.modelId) (Historical Flex Short)",
                    inputMultiplier: mul,
                    outputMultiplier: mul,
                    note: "Materialized historical Flex Short price."))
            }

            guard CodexLongContextPricing.modelIds.contains(period.modelId) else {
                return shortRows
            }
            var rows = shortRows + [longVariant(from: standard)]
            if CodexLongContextPricing.fastModelIds.contains(period.modelId),
               let fast = shortRows.first(where: {
                   $0.modelId.hasSuffix(CodexFastMode.suffix)
               }) {
                rows.append(longVariant(from: fast))
            }
            if let flex = shortRows.first(where: {
                $0.modelId.hasSuffix(CodexFlexMode.suffix)
            }) {
                rows.append(longVariant(from: flex))
            }
            return rows
        }.sorted { $0.modelId < $1.modelId }
    }()

    private static func longVariant(from entry: PricingEntry) -> PricingEntry {
        scaledVariant(
            from: entry,
            modelId: entry.modelId + CodexLongContextPricing.suffix,
            displayName: "\(entry.displayName) (Long)",
            inputMultiplier: CodexLongContextPricing.inputPriceMultiplier,
            outputMultiplier: CodexLongContextPricing.outputPriceMultiplier,
            note: "Materialized Long price for requests above 272K input tokens.")
    }

    private static func scaledVariant(
        from entry: PricingEntry,
        modelId: String,
        displayName: String,
        inputMultiplier: Double,
        outputMultiplier: Double,
        note: String,
        sourceUrl: String? = nil
    ) -> PricingEntry {
        PricingEntry(
            modelId: modelId,
            displayName: displayName,
            inputPricePerMillion: entry.inputPricePerMillion * inputMultiplier,
            cachedInputPricePerMillion: entry.cachedInputPricePerMillion * inputMultiplier,
            outputPricePerMillion: entry.outputPricePerMillion * outputMultiplier,
            cacheCreationPricePerMillion: entry.cacheCreationPricePerMillion * inputMultiplier,
            effectiveModelId: entry.effectiveModelId,
            isOfficial: false,
            note: note,
            sourceUrl: sourceUrl ?? entry.sourceUrl)
    }
}

enum PricingService {

    /// Materializes the app's bundled catalog into SQLite. The app bundle is
    /// the only supported pricing source, so every existing row is restored to
    /// its shipped values on launch. Legacy provenance columns remain in the
    /// schema for upgrade compatibility; they never select a rate, but a
    /// non-bundled marker forces the one-time historical reprice needed when
    /// upgrading from versions where local rows bypassed effective dates.
    @discardableResult
    static func installBundledCatalog(in db: Database) throws -> Bool {
        let now = ISO8601.fractional.string(from: Date())
        var pricingChanged = false
        for entry in BundledPricingCatalog.entries {
            let existing = try Row.fetchOne(db, sql: """
                SELECT input_price_per_million,
                       cached_input_price_per_million,
                       output_price_per_million,
                       cache_creation_price_per_million,
                       effective_model_id,
                       price_source
                FROM pricing_catalog
                WHERE model_id = ?
                """, arguments: [entry.modelId])
            if existing == nil {
                pricingChanged = true
            } else {
                let calculationChanged =
                    existing?["input_price_per_million"] as Double?
                        != entry.inputPricePerMillion
                    || existing?["cached_input_price_per_million"] as Double?
                        != entry.cachedInputPricePerMillion
                    || existing?["output_price_per_million"] as Double?
                        != entry.outputPricePerMillion
                    || existing?["cache_creation_price_per_million"] as Double?
                        != entry.cacheCreationPricePerMillion
                    || existing?["effective_model_id"] as String?
                        != entry.effectiveModelId
                    || existing?["price_source"] as String? != "bundled"
                pricingChanged = pricingChanged || calculationChanged
            }
            try db.execute(sql: """
                INSERT INTO pricing_catalog
                  (model_id, display_name, input_price_per_million,
                   cached_input_price_per_million, output_price_per_million,
                   cache_creation_price_per_million,
                   effective_model_id, is_official, note, source_url,
                   price_source, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,'bundled',?)
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
                  updated_at = excluded.updated_at,
                  above_200k_input_price_per_million = NULL,
                  above_200k_output_price_per_million = NULL,
                  max_input_tokens = NULL,
                  max_output_tokens = NULL,
                  price_source = 'bundled',
                  fetched_at = NULL
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
        return pricingChanged
    }

    /// One-shot UPDATE that recalculates value_usd for every usage_event whose model
    /// has a pricing entry. Provider-branched:
    ///
    ///   - **codex** (OpenAI): `input_tokens` is the gross figure that already
    ///     includes cached reads and cache writes. Ordinary input therefore
    ///     uses `max(input - cached - cache_write, 0)`; cache writes use the
    ///     precomputed catalog or historical write rate selected for the event.
    ///     `output_tokens` already includes reasoning.
    ///
    ///   - **claude**: the API breaks tokens out by category — `input_tokens`
    ///     is the **uncached** portion, `cache_read_input_tokens` is billed at
    ///     the cached rate, 5-minute `cache_creation_input_tokens` are billed
    ///     at the catalog write rate, and 1-hour cache writes are billed at
    ///     2x base input. No subtraction needed.
    ///
    /// For codex events, a stored `priority` or `flex` preference selects the
    /// matching materialized tier row when supported. A stored `default` or an
    /// unknown preference selects Standard. Requests above 272K select a
    /// materialized Long row; GPT-5.6 Priority keeps Fast there, while models
    /// without Fast Long rows select Standard Long. Only rows normalized to
    /// `price_source = 'bundled'`
    /// participate, and Codex events are restricted to the explicit Codex
    /// model set; unsupported legacy and Claude/GLM rows remain inert.
    ///
    /// Cheap (sub-second for tens of thousands of rows).
    static func backfillAllValues(
        in db: Database,
        codexFastModeBilling: Bool = false
    ) throws {
        try backfillValues(
            in: db,
            scope: .all,
            codexFastModeBilling: codexFastModeBilling)
    }

    /// Recalculate values for one rebuilt session without walking every other
    /// session. This intentionally shares the exact SQL expression used by
    /// row-targeted incremental imports and `backfillAllValues`.
    static func backfillValues(
        in db: Database,
        sessionId: String,
        provider: String,
        codexFastModeBilling: Bool = false
    ) throws {
        try backfillValues(
            in: db,
            scope: .session(sessionId: sessionId, provider: provider),
            codexFastModeBilling: codexFastModeBilling)
    }

    /// Recalculate only the rows inserted or updated by an incremental import.
    /// Batching keeps the statement below SQLite's bound-parameter limit while
    /// preserving the same pricing expression used by session and full scopes.
    static func backfillValues(
        in db: Database,
        eventIds: [Int64],
        codexFastModeBilling: Bool = false
    ) throws {
        var seen: Set<Int64> = []
        let uniqueIds = eventIds.filter { seen.insert($0).inserted }
        let batchSize = 500
        for start in stride(from: 0, to: uniqueIds.count, by: batchSize) {
            let end = min(start + batchSize, uniqueIds.count)
            try backfillValues(
                in: db,
                scope: .eventIds(Array(uniqueIds[start..<end])),
                codexFastModeBilling: codexFastModeBilling)
        }
    }

    private enum BackfillScope {
        case all
        case session(sessionId: String, provider: String)
        case eventIds([Int64])
    }

    private static func backfillValues(
        in db: Database,
        scope: BackfillScope,
        codexFastModeBilling: Bool
    ) throws {
        // Keep the argument for source compatibility with callers and older
        // settings, but missing tier evidence is now always Standard.
        _ = codexFastModeBilling
        let effectiveExpr = effectiveModelIdSQL()
        let codexModelIds = BundledPricingCatalog.codexModelIds.sorted()
        for id in codexModelIds {
            assert(!id.contains("'"),
                   "Codex catalog model id '\(id)' is not safe to interpolate")
        }
        let quotedCodexModelIds = codexModelIds
            .map { "'\($0)'" }
            .joined(separator: ",")
        let scopeClause: String
        let updateTarget: String
        let arguments: StatementArguments
        switch scope {
        case .all:
            scopeClause = ""
            updateTarget = "UPDATE usage_events"
            arguments = StatementArguments()
        case .session(let sessionId, let provider):
            scopeClause = """
              AND usage_events.session_id = ?
              AND usage_events.provider = ?
              """
            updateTarget = """
              UPDATE usage_events
              INDEXED BY index_usage_events_on_session_id_timestamp
              """
            arguments = StatementArguments([sessionId, provider])
        case .eventIds(let eventIds):
            guard !eventIds.isEmpty else { return }
            let placeholders = Array(
                repeating: "?",
                count: eventIds.count
            ).joined(separator: ",")
            scopeClause = "AND usage_events.id IN (\(placeholders))"
            updateTarget = "UPDATE usage_events"
            let values: [(any DatabaseValueConvertible)?] = eventIds.map { $0 }
            arguments = StatementArguments(values)
        }
        // SQLite can otherwise prefer the provider/history covering index for
        // this correlated UPDATE and rescan most historical rows once per
        // imported session. The existing session/timestamp index makes scoped
        // pricing proportional to that session's rows. Catalog-wide repricing
        // deliberately keeps the planner's normal choice. Row-id pricing uses
        // the table's integer primary key directly.
        let sql = """
            \(updateTarget)
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
                      (MAX(usage_events.input_tokens
                               - usage_events.cached_input_tokens
                               - usage_events.cache_creation_tokens, 0)
                          * pc.input_price_per_million
                       + usage_events.cached_input_tokens
                          * pc.cached_input_price_per_million
                       + usage_events.cache_creation_tokens
                          * pc.cache_creation_price_per_million
                       + usage_events.output_tokens
                          * pc.output_price_per_million
                      ) / 1000000.0
                  END
              FROM pricing_catalog pc
              WHERE pc.model_id = \(effectiveExpr)
                AND pc.price_source = 'bundled'
                AND (usage_events.provider <> 'codex'
                     OR pc.model_id IN (\(quotedCodexModelIds)))
            )
            WHERE EXISTS (
              SELECT 1 FROM pricing_catalog pc
              WHERE pc.model_id = \(effectiveExpr)
                AND pc.price_source = 'bundled'
                AND (usage_events.provider <> 'codex'
                     OR pc.model_id IN (\(quotedCodexModelIds)))
            )
            \(scopeClause)
            """
        try db.execute(sql: sql, arguments: arguments)
    }

    /// Resolves one fully materialized catalog row from event timestamp,
    /// context band, and stored service-tier preference. Pricing SQL reads the
    /// selected row directly and never reapplies price multipliers.
    ///
    /// We string-interpolate the model id lists and suffixes because
    /// they're code-controlled (sourced from the tier maps), never
    /// user input. Single-quote escaping is unnecessary here, but the
    /// model id assertion below makes the assumption explicit.
    private static func effectiveModelIdSQL() -> String {
        let fastIds = CodexFastMode.multipliers.keys.sorted()
        let flexIds = CodexFlexMode.multipliers.keys.sorted()
        let longContextIds = CodexLongContextPricing.modelIds.sorted()
        let fastLongContextIds = CodexLongContextPricing.fastModelIds.sorted()
        for id in Set(fastIds + flexIds + longContextIds + fastLongContextIds) {
            assert(!id.contains("'"),
                   "Codex tier multiplier key '\(id)' has a single quote — SQL not safe to interpolate")
        }
        let quotedFast = fastIds.map { "'\($0)'" }.joined(separator: ",")
        let quotedFlex = flexIds.map { "'\($0)'" }.joined(separator: ",")
        let quotedLongContext = longContextIds.map { "'\($0)'" }.joined(separator: ",")
        let quotedFastLongContext = fastLongContextIds
            .map { "'\($0)'" }
            .joined(separator: ",")
        let fastSuffix = CodexFastMode.suffix
        let flexSuffix = CodexFlexMode.suffix
        let longSuffix = CodexLongContextPricing.suffix
        let basePriceRow = historicalBasePriceRowSQL()
        return """
        CASE
          WHEN usage_events.provider = 'codex'
          THEN CASE
            WHEN usage_events.input_tokens > \(CodexLongContextPricing.inputTokenThreshold)
                 AND usage_events.model_id IN (\(quotedFastLongContext))
                 AND usage_events.codex_service_tier_preference = 'priority'
              THEN (\(basePriceRow)) || '\(fastSuffix)\(longSuffix)'
            WHEN usage_events.input_tokens > \(CodexLongContextPricing.inputTokenThreshold)
                 AND usage_events.model_id IN (\(quotedLongContext))
                 AND usage_events.codex_service_tier_preference = 'flex'
                 AND usage_events.model_id IN (\(quotedFlex))
              THEN (\(basePriceRow)) || '\(flexSuffix)\(longSuffix)'
            WHEN usage_events.input_tokens > \(CodexLongContextPricing.inputTokenThreshold)
                 AND usage_events.model_id IN (\(quotedLongContext))
              THEN (\(basePriceRow)) || '\(longSuffix)'
            WHEN usage_events.codex_service_tier_preference = 'priority'
                 AND usage_events.model_id IN (\(quotedFast))
              THEN (\(basePriceRow)) || '\(fastSuffix)'
            WHEN usage_events.codex_service_tier_preference = 'flex'
                 AND usage_events.model_id IN (\(quotedFlex))
              THEN (\(basePriceRow)) || '\(flexSuffix)'
            ELSE \(basePriceRow)
          END
          ELSE usage_events.model_id
        END
        """
    }

    private static func historicalBasePriceRowSQL() -> String {
        guard !CodexPriceHistory.periods.isEmpty else {
            return "usage_events.model_id"
        }
        let cases = CodexPriceHistory.periods.map { period -> String in
            for value in [period.catalogRowId, period.modelId, period.endsBefore] {
                assert(!value.contains("'"),
                       "Codex historical price metadata is not safe to interpolate")
            }
            if let startsOn = period.startsOn {
                assert(!startsOn.contains("'"),
                       "Codex historical price metadata is not safe to interpolate")
            }
            let lowerBound = period.startsOn.map {
                "AND usage_events.timestamp >= '\($0)'"
            } ?? ""
            return """
              WHEN usage_events.model_id = '\(period.modelId)'
                   \(lowerBound)
                   AND usage_events.timestamp < '\(period.endsBefore)'
                THEN '\(period.catalogRowId)'
            """
        }.joined(separator: "\n")
        return """
        CASE
        \(cases)
          ELSE usage_events.model_id
        END
        """
    }
}
