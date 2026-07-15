# Codex Fast Rollout Preference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute Codex Standard, Fast, and Flex pricing estimates per turn from rollout-recorded service-tier preferences, default unknown history to Standard, apply Codex long-context pricing, and exclude replayed parent usage from child sessions.

**Architecture:** Extend the typed rollout decoder with settings and task lifecycle events, then freeze a pending preference into each active turn in `RolloutParser`. A child-session gate seeds cumulative baselines without emitting replayed usage until the first self-timed task. Persist the turn ID and explicit preference on `usage_events`; pricing selects a Fast, Flex, or base catalog row, defaults missing evidence to Standard, and applies request-level long-context multipliers. v13/v14 stay compatible with databases created by the unpublished PR #91 build and force a provider-based Codex reread without assuming a default home path; v15 immediately reprices stored derived values so unchanged files cannot retain the retired fallback.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM, GRDB/SQLite, SwiftUI localization, shell QA, GitHub pull requests.

## Global Constraints

- Work only in `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-codex-fast-rollout-preference` on `codex/codex-fast-rollout-preference`; never edit the primary checkout or `main`.
- Treat `thread_settings_applied` as a future-turn preference, not a confirmed transmitted or served tier.
- `priority` estimates Fast, explicit `default` estimates Standard, explicit `flex` estimates Flex, and unknown/NULL estimates Standard.
- For supported models, input above 272K applies 2x input/cached-input and 1.5x output; Priority falls back to Standard because long context is unsupported there.
- A settings update during a turn must not change that turn's frozen preference.
- Preserve the Codex token formula, current Fast model multipliers, Claude behavior, and unsupported-model behavior; add only published Flex rates.
- Do not copy real rollouts, credentials, local paths, or substantial OpenUsage code into the repository.
- Update both changelogs and use test-first red/green cycles for every behavior change.

---

## File Structure

**New:**

- `QuotaMonitor/Core/Importer/CodexServiceTierPreference.swift` — narrow rollout-value normalization.
- `Tests/QuotaMonitorTests/CodexTierPreferenceImportTests.swift` — end-to-end importer persistence without a trace DB.
- `docs/superpowers/specs/2026-07-15-codex-fast-rollout-preference-design.md` — approved design.
- `docs/superpowers/plans/2026-07-15-codex-fast-rollout-preference.md` — execution plan.

**Modified:**

- `QuotaMonitor/Core/Importer/RolloutEvent.swift`, `RolloutParser.swift`, and `ImportEngine.swift` — decode, freeze, and persist the preference.
- `QuotaMonitor/Core/Storage/Records.swift` and `Migrations.swift` — nullable fields and compatibility migration.
- `QuotaMonitor/Core/Pricing/PricingService.swift` — per-event catalog-row selection.
- `QuotaMonitor/Core/Settings/SettingsStore.swift`, `QuotaMonitor/Core/Localization/L10n.swift`, and `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift` — retire the misleading unknown-as-Fast setting.
- `Tests/QuotaMonitorTests/RolloutEventDecoderTests.swift`, `RolloutParserTests.swift`, `MigrationsTests.swift`, `PricingValueBackfillTests.swift`, and `BrandingLocalizationTests.swift` — focused regression coverage.
- `docs/billing-logic.md`, `README.md`, `CHANGELOG.md`, and `CHANGELOG.zh-Hans.md` — current behavior and release notes.

## Interfaces

- `CodexServiceTierPreference.init?(rolloutValue: String?)` returns `.priority`, `.standard`, `.flex`, or `nil`; `.standard` persists with raw value `default`.
- `UsageDelta` produces `turnId: String?` and `serviceTierPreference: CodexServiceTierPreference?`.
- `UsageEventRecord` persists `codex_turn_id` and `codex_service_tier_preference`.
- `PricingService.backfillAllValues(in:codexFastModeBilling:)` keeps its public signature.

---

### Task 1: Decode service-tier and task lifecycle events

**Files:**

- Create: `QuotaMonitor/Core/Importer/CodexServiceTierPreference.swift`
- Modify: `QuotaMonitor/Core/Importer/RolloutEvent.swift`
- Test: `Tests/QuotaMonitorTests/RolloutEventDecoderTests.swift`

- [ ] **Step 1: Write failing normalization and decoder tests**

Add tests with these assertions:

```swift
#expect(CodexServiceTierPreference(rolloutValue: "priority") == .priority)
#expect(CodexServiceTierPreference(rolloutValue: " FAST ") == .priority)
#expect(CodexServiceTierPreference(rolloutValue: "default") == .standard)
#expect(CodexServiceTierPreference(rolloutValue: nil) == nil)
#expect(CodexServiceTierPreference(rolloutValue: "flex") == .flex)
```

Decode both canonical nested and compatible top-level settings shapes:

```json
{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
{"type":"event_msg","payload":{"type":"thread_settings_applied","service_tier":"default"}}
```

Also decode `task_started` with `turn_id = "turn-a"`, `task_complete` with a null ID, and `turn_context.turn_id`.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter RolloutEventDecoderTests`.
Expected: compile/test failure because the preference type and typed cases do not exist.

- [ ] **Step 3: Add the minimal preference type**

```swift
import Foundation

enum CodexServiceTierPreference: String, Codable, Sendable {
    case priority
    case standard = "default"
    case flex

    init?(rolloutValue: String?) {
        switch rolloutValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": self = .priority
        case "default": self = .standard
        case "flex": self = .flex
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Add narrow wire payloads and decoder dispatch**

Add `turnId` to `TurnContextPayload`, plus:

```swift
struct TaskLifecyclePayload: Decodable {
    let turnId: String?
    let startedAt: TimeInterval?
    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case startedAt = "started_at"
    }
}

struct ThreadSettingsAppliedPayload: Decodable {
    struct ThreadSettings: Decodable {
        let serviceTier: String?
        enum CodingKeys: String, CodingKey { case serviceTier = "service_tier" }
    }
    let threadSettings: ThreadSettings?
    let serviceTier: String?
    enum CodingKeys: String, CodingKey {
        case threadSettings = "thread_settings"
        case serviceTier = "service_tier"
    }
    var resolvedServiceTier: String? { threadSettings?.serviceTier ?? serviceTier }
}
```

Dispatch nested `event_msg.payload.type` to `.threadSettingsApplied`, `.taskStarted`, `.taskComplete`, or `.tokenCount`; malformed/unknown payloads remain `.other`.

- [ ] **Step 5: Confirm GREEN and commit**

Run the decoder suite again, then commit only Task 1 files with `Decode Codex rollout tier preferences`.

---

### Task 2: Freeze preference at turn start

**Files:**

- Modify: `QuotaMonitor/Core/Importer/RolloutParser.swift`
- Test: `Tests/QuotaMonitorTests/RolloutParserTests.swift`

- [ ] **Step 1: Write the failing transition test**

Create a synthetic rollout in this exact line order:

```text
settings priority
task_started turn-a
turn_context turn-a / gpt-5.5
token_count 110
settings default
token_count 55
task_complete turn-a
task_started turn-b
turn_context turn-b / gpt-5.5
token_count 33
task_complete turn-b
token_count 22
```

Use `last_token_usage` for each token line and assert:

```swift
#expect(parsed.usageDeltas.map(\.turnId) == ["turn-a", "turn-a", "turn-b", nil])
#expect(parsed.usageDeltas.map(\.serviceTierPreference) == [.priority, .priority, .standard, nil])
```

- [ ] **Step 2: Add failing edge tests**

Prove a new `task_started` with no ID clears the old ID, a `turn_context` without `task_started` can recover only the ID (not preference), one pending priority remains sticky across two completed turns, and a valid settings snapshot with a missing/unknown tier clears the pending preference before the next turn.

- [ ] **Step 3: Confirm RED**

Run `swift test --disable-keychain --filter RolloutParserTests`.
Expected: compile failure because `UsageDelta` has no turn/preference fields.

- [ ] **Step 4: Implement the minimal state machine**

```swift
private struct ActiveCodexTurn {
    var id: String?
    let serviceTierPreference: CodexServiceTierPreference?
}
```

Track a pending preference and active turn. Settings update pending only; task start always replaces and freezes; a different fallback `turn_context` gets unknown preference; token events copy the frozen fields; matching task completion clears active state but not pending state.

- [ ] **Step 5: Confirm GREEN and commit**

Run the parser suite and commit Task 2 files with `Freeze Codex tier preference per turn`.

---

### Task 3: Persist preferences and migrate existing databases

**Files:**

- Modify: `QuotaMonitor/Core/Storage/Migrations.swift`
- Modify: `QuotaMonitor/Core/Storage/Records.swift`
- Modify: `QuotaMonitor/Core/Importer/ImportEngine.swift`
- Create: `Tests/QuotaMonitorTests/CodexTierPreferenceImportTests.swift`
- Test: `Tests/QuotaMonitorTests/MigrationsTests.swift`

- [ ] **Step 1: Write failing schema and upgrade tests**

Fresh schema must contain `codex_turn_id` and `codex_service_tier_preference`, not `codex_billing_tier`. A hand-built pre-v14 DB must rename the old column, clear its Codex trace values, invalidate a Codex row at `/custom/codex-home/sessions/...`, and leave a Claude control row unchanged.

- [ ] **Step 2: Write the failing end-to-end import test**

Create a temporary Codex home with only a rollout containing `settings(priority) → task_started → turn_context → token_count`. Run `ImportEngine.performScan()` without `logs_2.sqlite`; query the two new columns and expect the synthetic turn ID plus `priority`.

- [ ] **Step 3: Confirm RED**

Run:

```sh
swift test --disable-keychain --filter MigrationsTests
swift test --disable-keychain --filter CodexTierPreferenceImportTests
```

Expected: missing columns/persistence cause failures.

- [ ] **Step 4: Add compatibility migrations**

```swift
migrator.registerMigration("v13-codex-billing-tier") { db in
    try db.alter(table: "usage_events") { t in
        t.add(column: "codex_turn_id", .text)
        t.add(column: "codex_billing_tier", .text)
    }
}

migrator.registerMigration("v14-codex-rollout-tier-preference") { db in
    try db.alter(table: "usage_events") { t in
        t.rename(column: "codex_billing_tier", to: "codex_service_tier_preference")
    }
    try db.execute(sql: "UPDATE usage_events SET codex_service_tier_preference = NULL WHERE provider = 'codex'")
    try db.execute(sql: """
        UPDATE import_state
        SET file_size = -1, file_mtime_ms = -1, byte_offset = 0
        WHERE session_id IN (SELECT session_id FROM sessions WHERE provider = 'codex')
        """)
}
```

- [ ] **Step 5: Add record and importer wiring**

Append defaulted `codexTurnId` and `codexServiceTierPreference` fields to `UsageEventRecord`, map their SQL names, and pass `delta.turnId` plus `delta.serviceTierPreference?.rawValue` from `ImportEngine`. Do not add trace readers, taggers, or tier-preservation joins.

- [ ] **Step 6: Confirm GREEN and commit**

Run both suites and commit Task 3 files with `Persist Codex tier preference per event`.

---

### Task 4: Price Standard, Fast, Flex, and long context from recorded evidence

**Files:**

- Modify: `QuotaMonitor/Core/Pricing/PricingService.swift`
- Test: `Tests/QuotaMonitorTests/PricingValueBackfillTests.swift`

- [ ] **Step 1: Extend the test INSERT helper**

Add `serviceTierPreference: String? = nil` and insert it into `codex_service_tier_preference`.

- [ ] **Step 2: Write failing precedence tests**

With controlled base, Fast, and Flex rows, prove priority gives Fast, explicit default gives Standard, explicit flex gives Flex, and NULL stays Standard even when the retained compatibility argument is true. Add supported-model tests above 272K for Standard, Priority, and Flex plus an exact-272K Priority boundary test. Keep unsupported-model and Claude tests as controls.

- [ ] **Step 3: Confirm RED**

Run `swift test --disable-keychain --filter PricingValueBackfillTests`.
Expected: unknown-as-Standard and long-context tests fail under the old SQL.

- [ ] **Step 4: Replace only the effective-model CASE**

For recognized Codex models, select recorded Priority/Flex only when supported,
otherwise use the base row. Long-context selection runs before Priority so it
falls back to Standard; Flex remains Flex. Unknown always reaches the base row:

```sql
CASE
  WHEN usage_events.codex_service_tier_preference = 'priority'
    THEN usage_events.model_id || '-fast'
  WHEN usage_events.codex_service_tier_preference = 'flex'
    THEN usage_events.model_id || '-flex'
  WHEN usage_events.codex_service_tier_preference = 'default'
    THEN usage_events.model_id
  ELSE usage_events.model_id
END
```

Retain the provider/model guards and current GPT-5.6/5.5/5.4 map. Multiply
input and cached-input by `2.0` and output by `1.5` when supported-model
`input_tokens > 272_000`.

- [ ] **Step 5: Confirm GREEN and commit**

Run the pricing suite and commit with `Estimate Codex service-tier pricing per turn`.

- [ ] **Step 6: Reprice upgraded databases**

Add `v15-codex-pricing-policy-reprice`, which seeds the catalog and runs
`backfillAllValues` during migration. Test that an existing NULL-tier event
holding an old Fast value is rewritten to Standard before any file scan.

---

### Task 5: Retire fallback UI and update release surfaces

**Files:**

- Modify: `QuotaMonitor/Core/Settings/SettingsStore.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
- Modify: `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`
- Test: `Tests/QuotaMonitorTests/BrandingLocalizationTests.swift`
- Modify: `docs/billing-logic.md`, `README.md`, `CHANGELOG.md`, and `CHANGELOG.zh-Hans.md`

- [ ] **Step 1: Remove the fallback surface**

Remove the General settings section, localized strings, stored setting plumbing,
controller callback, and diagnostic fields. Keep the pricing function's Boolean
argument temporarily so external/source callers remain compatible, but ignore it.

- [ ] **Step 2: Update docs and both changelogs**

Document the new columns, future-turn freeze, child replay gate, Standard-on-unknown policy, 272K pricing boundary, compatibility migration, and served-tier boundary. Change README wording to “Codex service-tier estimates.” Add user-readable Summary and detail entries under Unreleased in both languages.

- [ ] **Step 3: Confirm GREEN and commit**

Run the localization suite plus `git diff --check`; commit docs, copy, spec, and plan with `Document Codex Fast preference estimates`.

---

### Task 6: Verify, review, publish, and supersede #91

- [ ] **Step 1: Run focused suites fresh**

```sh
swift test --disable-keychain --filter RolloutEventDecoderTests
swift test --disable-keychain --filter RolloutParserTests
swift test --disable-keychain --filter CodexTierPreferenceImportTests
swift test --disable-keychain --filter MigrationsTests
swift test --disable-keychain --filter PricingValueBackfillTests
swift test --disable-keychain --filter BrandingLocalizationTests
```

- [ ] **Step 2: Run full deterministic gates**

```sh
swift test --disable-keychain
./qa/run-static.sh
git diff --check origin/main...HEAD
```

- [ ] **Step 3: Run isolated visible QA**

Following `quota-monitor-computer-qa`, run `./qa/run-all.sh`, then `./qa/run-interactive.sh`. Assign `ARTIFACT_DIR` to the exact directory printed by the interactive runner, read its `computer-use-qa.md`, inspect Settings → General in English and Simplified Chinese for clipping/readability, run `./qa/check-artifacts.sh "$ARTIFACT_DIR"`, and execute that directory's printed cleanup script. Never use real credentials or destructive settings actions.

- [ ] **Step 4: Independent review and repair**

Inspect status, full diff, stat, and commit log against `origin/main`. Dispatch an independent reviewer for spec compliance and code quality. Every confirmed behavior bug gets a new failing test before its fix, followed by the relevant focused and full gates.

- [ ] **Step 5: Push and create a Ready PR**

The PR body must include `Supersedes #91`, preference-versus-served semantics, the turn-freezing state machine, migration compatibility, links to OpenUsage `cfdfdd08723b` and Codex upstream source, exact verification results, interactive QA status, and both changelog updates.

- [ ] **Step 6: Verify GitHub and close #91**

Prove the replacement PR URL is accessible, non-draft, based on `main`, and points to the pushed branch. Triage checks before handoff. Comment on #91 with the replacement URL and close it as superseded.

- [ ] **Step 7: Complete the persistent goal**

Mark the goal complete only when the Ready PR is accessible and no required work remains. Lead the final response with the direct PR link and fresh verification evidence.
