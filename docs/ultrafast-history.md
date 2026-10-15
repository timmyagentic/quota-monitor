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
the beta.5 reread or subsequent withdrawal. The cursor is set to zero while the
original checkpoint blob is retained for source identity and prefix matching.
The parser requires a positive cursor matching the checkpoint offset to resume,
so retaining that blob cannot skip the full reread. Its internal offset, hashes,
and v1/v2 encoding remain unchanged until a successful import replaces it.

`v27-codex-reread-preserve-source-identity` requests the same full reread for
databases that already ran v26, retaining any checkpoint evidence still present.
Neither migration deletes history or invalidates Claude cursors.
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

### Already-cleared provenance

The originally shipped v26 cleared checkpoints. If a previous source is gone and
only a differently named replay remains, its stored token counts, timestamps,
turn IDs and logical session ID cannot prove that it is the same physical
fragment. v27 deliberately preserves this history; it cannot safely remove an
existing duplicate or prevent every duplicate in that ambiguous legacy state.
A missing, corrupt or size-capped checkpoint has the same limitation. A complete
source returning at its recorded path can be retried, but this is not a promise
that all previously duplicated rows will be automatically repaired. Preserve a
backup and original rollout evidence before any separately reviewed recovery.

### Proof required before cross-source replacement

A retained recovery checkpoint is not deletion authorization by itself. In
particular, a matching inode or 4 KiB header cannot authorize recovery replacement.
The parser stores hashes of `[0, min(n, 4096))` and `[max(0, n - 4096), n)`, where
`n` is the committed offset. For `0 < n <= 8192`, those windows cover every
committed byte; both are checked when the prefix extends beyond the first window.
For larger prefixes, the original source must still be readable with matching
identity/window evidence, and its complete committed prefix must match the new
source. Comparisons stream in bounded chunks and check file snapshots for change.
If the original is gone, equal head/tail hashes leave an unproven middle: retain
history, even for an identical long replay or a same-inode rename.

Current differently named files are grouped only after comparing their complete
common prefix. Recovery relocation requires one proven predecessor, and recovery
evidence is rechecked in the write transaction before replacement. Before any
row is deleted, that transaction computes the complete predecessor set, including
the selected relocated source. If another matching alias appeared meanwhile,
relocated replacement is deferred without changing history. Cleanup uses this
same frozen decision rather than recomputing uniqueness after deleting the first
source, and is skipped for incomplete output. An ambiguous partial replay may therefore add a
new source while retaining prior aliases; completion or reopening is not a promise
of automatic consolidation. No token, timestamp, turn or logical-session match is
used to guess a missing source's identity.

Regression fixtures are synthetic and cover normalization, frozen turns,
checkpoint serialization/legacy decoding, unchanged-file migration with and
without checkpoints, missing and partial source recovery, migration idempotency,
all pricing backfill scopes, cache accounting, context boundaries, and other tiers.
