# Codex request-tier observations

QuotaMonitor reads `logs_2.sqlite` under the already-authorized Codex home during its existing history scan. This diagnostic source is independent of rollout thread preferences and **does not change `usage_events`, estimated amounts, or the pricing catalog**. There is no new polling loop, permission prompt, Codex configuration change, or beta-channel change.

The reader probes `logs` for `feedback_log_body` (current) or `message` (older). It reads only `feedback_tags` bodies and parses the exact top-level `tags_json.service_tier` JSON field. `priority`/`fast` normalize to `priority`; `ultrafast`, `default`, and `flex` remain distinct. Absent/null means unknown; literal `unset` remains unset. Neither means explicit Standard. Unknown strings retain their raw value with normalized `unknown`. Feature flags such as `feature.ultrafast_mode` never establish a tier.

## Inspecting the result

`CodexRequestTierEvidence.observations(in:threadID:)` queries the application's `codex_request_tier_evidence` table. Each observation contains source path, source generation, original row ID, a fingerprint, timestamp/nanoseconds, optional thread/turn/model, raw and normalized tier, and `attribution = unattributed`. The application stores no original feedback body. Developer Mode emits `importer.request_tier.scan` with counts and `observed_incomplete`, `missing`, or `unavailable`; it does not emit identifiers, original log text, or tier metadata. No UI or effective billing tier is implied by these diagnostics.

Evidence reads use a normal read-only SQLite transaction, including committed WAL records. A bounded batch of feedback events resumes by row ID rather than timestamp; unrelated targets do not consume that batch. Once relevant rows are exhausted, the cursor advances to the snapshot high-water mark. Source identity, schema, ID rollback, and changed/deleted boundary fingerprints invalidate the cursor. Evidence and cursor are committed atomically to QuotaMonitor's own database, with a stale-cursor check. Repeated or overlapping reads deduplicate by source/row/fingerprint. Pruning or missing source files retain previously observed evidence. A generation is a reader checkpoint generation, not proof of complete request coverage; identical replayed rows remain deduplicated across generations. Schema/permission/lock errors or invalid row types leave the last committed state intact and do not block rollout import. A damaged row can prevent this diagnostic source from advancing until repaired upstream; no complete-coverage claim is made. A damaged application cursor is safely rebuilt, preserving deduplication.

## Why observations are not prices

Official Codex revision `5ef96ab2785f3ecddf279639eff7b1b42c906fa4` emits the resolved request preference from `try_run_sampling_request`, with `turn_id` and model in its span. That span has no serialized request-instance or response ID. A turn can contain requests at different tiers. A single observed tier, matching counts, or adjacent timestamps cannot establish complete coverage when logs may be dropped, pruned, delayed, or describe failed/retried requests.

`last_model_request_id` and `last_model_response_id` are emitted separately inside `map_response_events`'s spawned task, without a common tier/request-instance field or an inherited instrumented sampling span. Matching a response ID to rollout usage therefore does not connect that usage to the tier observation. OTel completion events contain tokens and tier, but their targets are excluded from the default SQLite log filter. No time/order-based join is attempted.

Sources: [sampling event](https://github.com/openai/codex/blob/5ef96ab2785f3ecddf279639eff7b1b42c906fa4/codex-rs/core/src/session/turn.rs), [request/response events](https://github.com/openai/codex/blob/5ef96ab2785f3ecddf279639eff7b1b42c906fa4/codex-rs/core/src/client.rs), [SQLite filtering and formatting](https://github.com/openai/codex/blob/5ef96ab2785f3ecddf279639eff7b1b42c906fa4/codex-rs/state/src/log_db.rs), [tier JSON](https://github.com/openai/codex/blob/5ef96ab2785f3ecddf279639eff7b1b42c906fa4/codex-rs/core/src/feedback_config.rs).

## Compatibility and limits

Migration v26 adds separate evidence/cursor tables after the unchanged v24/v25 withdrawal compatibility migrations. It does not force history rereads, guess missing tiers, restore Ultrafast pricing, or change frozen rollout preferences/checkpoints. Existing Standard/Fast/Flex estimation continues unchanged.

All request observations remain unallocated. Accurate historical Ultrafast repricing still requires a trustworthy upstream request-to-usage bridge. Missing logs cannot reconstruct old NULL preferences. Tests use synthetic SQLite files following the official event shape; real user logs and restricted sessions are not needed or accessed.
