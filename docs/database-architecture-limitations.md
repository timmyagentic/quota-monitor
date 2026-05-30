# Database Architecture Limitations

## Issue: `usage_events` Unique Index Prevents Per-Request Metrics

### Current Architecture

The `usage_events` table uses a partial unique index on `(session_id, provider_message_id)`:

```sql
CREATE UNIQUE INDEX usage_events_session_message
ON usage_events(session_id, provider_message_id)
WHERE provider_message_id IS NOT NULL
```

Combined with `INSERT OR IGNORE` during import, this ensures:
- Only **one event per `provider_message_id`** is stored
- If multiple events share the same message ID, only the first is kept
- Subsequent events are silently ignored (intended for idempotent incremental imports)

### Why This Exists

From `ClaudeImportEngine.swift`:

> "INSERT OR IGNORE so the partial unique index on (session_id, provider_message_id)
> silently swallows any re-emitted rows. Required for incremental tail reads."

This design prevents duplicate events when:
- The JSONL writer flushes a half-written line that gets re-emitted
- Incremental scans re-parse the same slice across runs

### The Problem

Claude Code's rollout JSONL contains **multiple events per message ID**:

```json
// Event 1: thinking phase
{"type":"assistant", "message":{"id":"msg_xxx", ...}, "timestamp":"2026-05-18T14:02:25.385Z", ...}

// Event 2: tool_use response  
{"type":"assistant", "message":{"id":"msg_xxx", ...}, "timestamp":"2026-05-18T14:02:26.479Z", ...}
```

Both events share `message.id = "msg_xxx"` but have different `uuid`s and timestamps.

**Current behavior:** Only Event 1 is stored. Event 2 is ignored.

### Impact

| Metric | Status | Reason |
|--------|--------|--------|
| Lifetime tokens | ✅ Accurate | Sum of all stored events |
| Peak day tokens | ✅ Accurate | Day-aggregated, dedup doesn't affect totals |
| Current/longest streak | ✅ Accurate | Day-aggregated |
| **Longest task** | ❌ Not supported | Requires time span of multiple events per message |

Additionally:
- **Token updates may be lost** if later events have corrected token counts
- **Timestamp precision is lost** - only the first event's timestamp is kept
- **Cannot track request lifecycle** (thinking → tool_use → response phases)

### Evidence

```sql
SELECT COUNT(*) as total, COUNT(provider_message_id) as with_msg FROM usage_events;
-- Result: 15540 total, 547 with message_id

SELECT cnt, COUNT(*) FROM (
    SELECT provider_message_id, COUNT(*) as cnt 
    FROM usage_events 
    WHERE provider_message_id IS NOT NULL 
    GROUP BY provider_message_id
) GROUP BY cnt;
-- Result: Every message_id has exactly 1 event
```

### Proposed Solution

**Option A: Multi-Event Schema (Recommended)**

1. Change unique key from `(session_id, provider_message_id)` to `(session_id, provider_message_id, event_uuid)`
2. Allow multiple events per message
3. Add `event_type` column (`thinking`, `tool_use`, `message`, etc.)
4. Update aggregation logic to:
   - For token counts: use the **last** event per message (most complete)
   - For timing: use MIN/MAX timestamps across all events per message

Migration steps:
1. Add `event_uuid` column
2. Drop old unique index, create new one
3. Re-import historical data from JSONL sources
4. Update all aggregation queries

**Option B: Separate Timing Table**

Create a new `message_timings` table:
- `provider_message_id` (PK)
- `first_event_at`
- `last_event_at`
- `event_count`

Keep `usage_events` as-is (one record per message), store timing metadata separately.

**Option C: Accept Limitation (Current)**

Remove "longest task" metric and document that per-request timing is not supported.

### Decision (2025-05-30)

**Short-term:** Remove "longest task" metric from Activity section. ✅ Done

**Long-term:** Implement Option A when resources allow. This is tracked separately as a data migration project.

### References

- `ClaudeImportEngine.swift` - Import logic with `INSERT OR IGNORE`
- `AggregatorActivity.swift` - Activity metrics (formerly included `longestTaskSeconds`)
- `Migrations.swift` - Schema version 5 with partial unique index
