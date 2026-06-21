# Codex Fast Mode Detection Implementation Plan

**Goal:** Detect Codex Fast/Standard usage from local rollout JSONL markers,
persist the result on `usage_events`, price confirmed Fast rows with synthetic
`*-fast` catalog entries, and keep the existing setting as a fallback for rows
whose tier is still unknown.

**Reference:** `codex-pacer` reads `fast_mode` / `quick_mode` markers directly
from Codex JSONL lines. It does not depend on `logs_2.sqlite`, request traces, or
`service_tier` response events. QuotaMonitor follows the same local-history
method for this PR.

## Billing Invariants

- Token counts must not change. The existing `token_count` delta algorithm stays
  the source of truth for input, cached input, output, reasoning, and total
  token buckets.
- `fast_mode: true` or `quick_mode: true` on the current `turn_context` marks
  subsequent token usage for that turn as `fast`.
- `fast_mode: false` or `quick_mode: false` on the current `turn_context` marks
  subsequent token usage for that turn as `standard`.
- Missing markers stay `unknown`; they are not guessed as Standard.
- The existing `codexFastModeBilling` setting applies only to `unknown` Codex
  rows. It must not override rows explicitly classified as `standard`.
- No raw JSONL payload or prompt-like data is persisted beyond the existing
  parsed event fields.
- Any migration that can change historical dollar values must force a Codex
  reimport and then run value backfill.

## Data Model

Stored tiers:

```swift
enum CodexBillingTier: String, Codable, Sendable {
    case standard
    case fast
    case unknown
}
```

Stored sources:

```swift
enum CodexBillingTierSource: String, Codable, Sendable {
    case jsonl
    case missingMarker = "missing_marker"
    case legacy
    case notCodex = "not_codex"
}
```

Classification rules:

| Condition | Stored tier | Source |
| --- | --- | --- |
| Current `turn_context` has `fast_mode: true` or `quick_mode: true` | `fast` | `jsonl` |
| Current `turn_context` has `fast_mode: false` or `quick_mode: false` | `standard` | `jsonl` |
| Current `turn_context` has no Fast marker | `unknown` | `missing_marker` |
| Non-Codex rows | `unknown` | `not_codex` |
| Pre-migration rows before reimport | `unknown` | `legacy` |

## Implementation Map

- `CodexBillingTier.swift`: tier/source enums and a small classifier for
  optional explicit Fast markers.
- `RolloutEvent.swift`: decode `turn_context.payload.fast_mode`,
  `quick_mode`, `turn_id`, and `turnId`.
- `RolloutParser.swift`: track the current turn id and explicit Fast marker;
  attach `billingTier` and `billingTierSource` to every `UsageDelta`.
- `ImportEngine.swift`: persist the parser's tier fields with each
  `usage_events` row. No external trace lookup is needed.
- `Migrations.swift`: add `turn_id`, `billing_tier`, and
  `billing_tier_source`, then force a Codex-only reimport.
- `PricingService.swift`: route `fast` Codex rows to `<model>-fast`, keep
  `standard` on the base row, and apply the existing fallback only to
  `unknown`.
- Aggregator/UI/CSV: surface the stored tier split without reimplementing
  pricing.

## Verification

- Parser tests cover `fast_mode`, `quick_mode`, explicit Standard, missing
  marker, and `turnId` decoding.
- Importer tests cover persisted Fast/Standard/Unknown rows after a full scan
  and prove unchanged JSONL files can be skipped without waiting for external
  trace data.
- Pricing tests cover event-level Fast, explicit Standard ignoring the global
  fallback, unknown fallback on/off, unlisted model behavior, and Claude
  isolation.
