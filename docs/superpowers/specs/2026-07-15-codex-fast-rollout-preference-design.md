# Codex Service-Tier Rollout Preference Attribution

**Date:** 2026-07-15
**Status:** Approved for implementation
**Supersedes:** the trace-based design in PR #91

## Goal

Estimate Codex service-tier pricing per turn from durable rollout evidence instead of
applying one account-wide setting to all history or depending on transient
`logs_2.sqlite` trace rows.

The result must distinguish four states:

- `priority`: the rollout recorded a Fast/Priority preference for this turn;
- `default`: the rollout explicitly recorded the default preference;
- `flex`: the rollout explicitly recorded the Flex preference;
- unknown: no usable preference was recorded for the turn.

These values are pricing hints, not confirmation of the service tier that the
server ultimately served. Unknown values remain `NULL` in storage and use
Standard pricing; Fast must never be inferred without a recorded `priority`.

## Evidence and terminology

OpenUsage commit
[`cfdfdd08723b`](https://github.com/robinebers/openusage/commit/cfdfdd08723bea3e7e4f5ac225b972f331b87771)
established the useful source change: stop reading today's `config.toml` and
parse each rollout's `event_msg/thread_settings_applied` records instead.

QuotaMonitor will independently implement that source because OpenUsage's
mutable `currentTierIsFast` Boolean changes immediately when a settings event
appears. Codex defines the setting as a preference for future turns, and a
turn snapshots its configuration when it starts. A settings update received
during an active turn must therefore affect the next turn, not the remainder
of the active one.

The names in storage and documentation deliberately use **preference**, not
`served_tier`, `confirmed_tier`, or an unqualified `billing_tier`:

- `thread_settings_applied` proves that a thread preference was applied;
- Codex may filter the preference by feature/model support before transmitting
  a request;
- the server's response tier is not currently persisted in the rollout.

## Non-goals

- Do not recover exact served tiers that Codex did not persist.
- Do not keep or extend the `logs_2.sqlite` reader/tagger from PR #91.
- Keep missing evidence as unknown/`NULL`; Standard is only its conservative
  pricing fallback, not an inferred or server-confirmed served tier.
- Do not copy OpenUsage source or tests; use its commit as an attributed design
  reference and implement against QuotaMonitor's typed importer.
- Do not change Fast multipliers, base token formulas, or Claude pricing.
- Do not close PR #91 until the replacement PR exists and is verified.

## Rollout decoding

`RolloutEvent` adds typed cases for three nested `event_msg` variants:

```swift
case threadSettingsApplied(serviceTier: String?, timestamp: String?)
case taskStarted(turnId: String?, startedAt: TimeInterval?, timestamp: String?)
case taskComplete(turnId: String?, timestamp: String?)
```

`thread_settings_applied` reads the canonical nested field
`payload.thread_settings.service_tier` and tolerates the older/top-level
`payload.service_tier` spelling used by compatible recorders. Normalization is
intentionally narrow:

| Raw value | Stored preference |
| --- | --- |
| `priority`, `fast` | `priority` |
| `default` | `default` |
| `flex` | `flex` |
| missing, `null`, empty, `auto`, unknown | unknown |

A syntactically valid full settings event with no recognized tier clears the
pending preference to unknown. A malformed event that cannot be decoded stays
`.other` and does not mutate parser state.

## Turn state machine

The parser processes JSONL file order; timestamps are not used to reorder or
join events.

```swift
struct ActiveCodexTurn {
    var id: String?
    let serviceTierPreference: CodexServiceTierPreference?
}

var pendingServiceTierPreference: CodexServiceTierPreference?
var activeTurn: ActiveCodexTurn?
```

Transitions:

1. `thread_settings_applied` updates only
   `pendingServiceTierPreference`.
2. `task_started` always replaces `activeTurn`, even when `turn_id` is absent,
   and freezes the pending preference for the new turn.
3. `turn_context` keeps the existing model behavior. Its `turn_id` fills a
   missing active ID; if it reveals a different turn without a preceding
   `task_started`, the new turn keeps an unknown preference rather than
   inheriting stale state.
4. `token_count` copies the active turn ID and frozen preference into the
   emitted `UsageDelta`.
5. `task_complete` clears the matching active turn but leaves the pending
   preference sticky for future turns.
6. Tokens outside an active/fallback `turn_context` boundary remain unknown.

This pins the important regression: `priority → task A → default update →`
more task-A tokens must keep task A as `priority`; task B becomes `default`.

### Child replay gate

A child or fork rollout can replay the parent's full history with rewritten
envelope timestamps. The first child `session_meta` arms a replay gate. During
the gate, token totals update the cumulative baseline but emit no usage. The
gate opens only at the first `task_started` whose `started_at` is at or after
the child creation time. Repeated rows whose cumulative `total_token_usage`
did not change are also non-billable even when `last_token_usage` differs.

For older `task_started` rows without `started_at`, extract the millisecond
timestamp from a UUIDv7 `turn_id`. A direct child with no replayed parent
`session_meta` may open on its first task; rewritten envelope timestamps are
only a last resort and must be strictly later than child creation.

## Storage and migration

`usage_events` gains:

| Column | Meaning |
| --- | --- |
| `codex_turn_id TEXT NULL` | Stable Codex turn identifier when present. |
| `codex_service_tier_preference TEXT NULL` | `priority`, `default`, `flex`, or unknown. |

The replacement keeps PR #91's unpublished migration identifier
`v13-codex-billing-tier` as a compatibility bridge for developers who ran that
branch. Fresh databases first add `codex_turn_id` and the old
`codex_billing_tier` column. `v14-codex-rollout-tier-preference` then renames
the old column, clears any trace-derived values, and invalidates imported Codex
rollouts by joining `import_state.session_id` to `sessions.provider = 'codex'`.
That invalidation works for default, custom, and App Store-selected Codex homes
without matching `/.codex/` in the path.

`ImportEngine` writes the parsed values directly while rebuilding a rollout's
events. It does not preserve an older tier when the current rollout lacks the
marker: missing durable evidence must become unknown rather than retaining a
stale trace inference.

## Pricing policy

For Codex models listed in the corresponding tier maps:

| Per-event preference | Effective catalog row |
| --- | --- |
| `priority` at or below 272K input | `model_id + "-fast"` |
| `flex` | `model_id + "-flex"` |
| `default` | `model_id` |
| unknown | `model_id` |

The legacy setting that treated unknown usage as Fast is retired. Its stored
UserDefaults value is harmless and ignored; no UI remains for changing it.

A one-time pricing-policy migration seeds current catalog rows and runs the
full value backfill during database initialization. Existing databases must
therefore adopt Standard-on-unknown and long-context pricing before any launch
query, even when no rollout file changes.

Flex rows use OpenAI's published `0.5x` Standard rates for supported models.
Unsupported tier/model combinations and Claude rows retain their base catalog
selection.

For supported models, requests with `input_tokens > 272_000` multiply the
entire request's Standard or Flex input/cached-input rates by `2.0` and output
rate by `1.5`. Priority does not support long context, so a recorded
`priority` above this boundary selects the Standard row before applying those
multipliers. Exactly 272K remains eligible for ordinary Priority pricing.

## Documentation and release notes

Update:

- `docs/billing-logic.md` with the new fields, state/evidence boundary, pricing
  precedence, migration behavior, and remaining served-tier limitation;
- `README.md` so Settings no longer advertises an account-wide Fast override;
- both changelogs under `Unreleased` with user-readable summary and detail;
- the PR body with links to OpenUsage's source change and Codex's upstream
  future-turn semantics.

No real rollout lines, credentials, or local filesystem data may enter fixtures
or documentation.

## Verification

Automated coverage must prove:

- typed decoding of nested/top-level preferences and task lifecycle events;
- priority/default/flex normalization plus unknown preservation;
- child replay exclusion, cumulative-baseline seeding, and unchanged-total
  deduplication;
- sticky settings, turn-start freezing, mid-turn updates, missing IDs,
  `turn_context` fallback, task completion, and stray tokens;
- schema compatibility and provider-based invalidation for a custom path;
- importer persistence without any `logs_2.sqlite` file;
- priority/default/flex/unknown pricing precedence, unsupported-model behavior, and
  Claude isolation;
- missing-tier Standard behavior and 272K boundary behavior.

Required gates:

```sh
swift test --disable-keychain --filter RolloutEventDecoderTests
swift test --disable-keychain --filter RolloutParserTests
swift test --disable-keychain --filter CodexTierPreferenceImportTests
swift test --disable-keychain --filter MigrationsTests
swift test --disable-keychain --filter PricingValueBackfillTests
swift test --disable-keychain
./qa/run-static.sh
```

Because the Settings copy changes visibly, also run the isolated app QA flow
from `quota-monitor-computer-qa` after deterministic checks pass.

## Pull request strategy

Build the replacement from current `origin/main` in an independent
`codex/codex-fast-rollout-preference` worktree. Do not rebase or force-push
PR #91's trace-heavy branch. Open a Ready PR with `Supersedes #91`, verify its
checks and page, then close #91 with a link to the replacement.
