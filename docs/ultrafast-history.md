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

## Upgrade behavior

Older versions discarded `ultrafast` settings as NULL, even inside parser
checkpoints. Repricing stored events alone cannot recover that evidence.
Migration `v24-codex-ultrafast-reread` invalidates Codex file metadata and cursors
once, without deleting events, sessions, or rate samples. Checkpoint version 2
also prevents resuming a v1 reducer with already-lost tier evidence.

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
checkpoint serialization/version rejection, unchanged-file migration with and
without checkpoints, missing and partial source recovery, migration idempotency,
all pricing backfill scopes, cache accounting, context boundaries, and other tiers.
