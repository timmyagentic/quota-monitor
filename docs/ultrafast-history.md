# Codex Ultrafast valuation and recovery

Verified against OpenAI's [pricing](https://developers.openai.com/api/docs/pricing),
[Ultrafast API guide](https://developers.openai.com/api/docs/guides/ultrafast-mode),
and [Codex speed guide](https://learn.chatgpt.com/docs/agent-configuration/speed)
on 2026-10-10. `value_usd` estimates API-equivalent value, not included subscription
allowance consumption: Ultrafast is 6× Standard API pricing, not the 8× allowance rate.

Only `gpt-6-astra` and `gpt-6.1-sol` have bundled Ultrafast rows. Values below are
USD per million tokens, ordered input / cache read / cache write / output:

| Model | Input ≤272,000 | Input >272,000 |
| --- | --- | --- |
| GPT-6 Astra | 60 / 6 / 75 / 300 | 120 / 12 / 150 / 450 |
| GPT-6.1 Sol | 12 / 0.6 / 15 / 60 | 24 / 1.2 / 30 / 90 |

The catalog materializes all four prices; event SQL selects a row without applying
runtime price multipliers. Cached reads and writes are disjoint subsets of total
input. Output already includes reasoning. Turn preferences remain frozen at task
start; a settings change applies to the next turn. Unsupported model/tier
combinations keep the existing Standard fallback; no Ultrafast rate is invented.

## Same estimation policy as Fast

Both tiers use the same source and reducer: rollout
`thread_settings_applied.thread_settings.service_tier` → pending preference →
`task_started` freezes the turn → usage persists `codex_service_tier_preference` →
SQL selects the materialized model price. No `logs_2.sqlite` reader, request-join
heuristic or separate Ultrafast attribution policy is added. The prior beta.5
implementation used this same chain.

This is a recorded-preference estimate, equally limited for Fast and Ultrafast:
single-turn overrides absent from the recorded thread settings, live changes
within a frozen turn, and hidden child/root inheritance are not reconstructed.
Missing/unknown preferences keep the existing Standard fallback. Task/context
conflicts use the same existing reducer behavior for both tiers. This equivalence
does not claim server-confirmed billing accuracy.

Eight existing parser scenarios now run identical fixtures with only `priority`
replaced by `ultrafast`: freezing/switching, missing IDs, late context, missing
start, mismatched context, sticky settings, missing/null/unknown settings and
mismatched completion. Checkpoint resume and historical recovery also run both
tiers through the same path. Prices are tested independently because supported
model sets and published rates legitimately differ.

## Upgrade behavior

Older versions discarded `ultrafast` settings as NULL, even inside parser
checkpoints. Repricing stored events alone cannot recover that evidence.
Migration `v26-codex-ultrafast-restore` invalidates Codex file metadata and cursors
once, without deleting events, sessions, or rate samples. It works after the
retained v24/v25 compatibility migrations, including databases that already ran
the beta.5 reread or subsequent withdrawal. All old Codex checkpoints are cleared
by this migration, so an old reducer cannot resume with lost tier evidence. The
checkpoint format remains version 2 and retains v1/v2 decoding compatibility.
Existing raw Ultrafast events are repriced even if their original source is gone;
NULL events are never inferred to be Ultrafast.

The next scan rereads even unchanged Codex sources from byte zero. Existing
transactional fragment replacement and pricing update rows together with their
new cursor. A crash before commit leaves the old rows and pending cursor intact;
a later scan retries. Repeated successful scans skip unchanged files and do not
duplicate events. Sibling fragments retain their own provenance. Claude cursors
are not invalidated.

If a source is missing, unreadable, or has an incomplete trailing record, its
committed history is retained. Recovery retries when a complete source is available
again. Without the original source, NULL stays unknown/Standard: the application
cannot reconstruct an erased preference or claim that history is fully recovered.
The first scan can take longer because existing Codex logs are read once again.

Regression fixtures are synthetic and cover normalization, frozen turns,
checkpoint serialization/legacy decoding, unchanged-file migration with and
without checkpoints, missing and partial source recovery, migration idempotency,
all pricing backfill scopes, cache accounting, context boundaries, and other tiers.
