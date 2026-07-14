import Foundation
import GRDB

// Schema mirrors the original codex-pacer SQLite layout (`src-tauri/src/database.rs`)
// but only contains the tables we actually need for Day-2.
// Subscription / sync_settings / session_overrides are deferred until the UI needs them.

enum Migrations {

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.create(table: "sessions") { t in
                t.primaryKey("session_id", .text)
                t.column("root_session_id", .text).notNull()
                t.column("parent_session_id", .text)
                t.column("title", .text)
                t.column("source_path", .text)
                t.column("started_at", .text)
                t.column("updated_at", .text)
                t.column("agent_nickname", .text)
                t.column("agent_role", .text)
                t.column("last_model_id", .text)
                t.column("latest_plan_type", .text)
                t.column("contains_subagents", .boolean)
                    .notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("imported_at", .text).notNull()
            }

            try db.create(table: "usage_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("timestamp", .text).notNull()
                t.column("model_id", .text).notNull()
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("cached_input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("reasoning_output_tokens", .integer).notNull().defaults(to: 0)
                t.column("total_tokens", .integer).notNull().defaults(to: 0)
                t.column("value_usd", .double).notNull().defaults(to: 0)
            }
            try db.create(
                indexOn: "usage_events", columns: ["session_id", "timestamp"])

            try db.create(table: "import_state") { t in
                t.primaryKey("source_path", .text)
                t.column("session_id", .text)
                t.column("file_size", .integer).notNull()
                t.column("file_mtime_ms", .integer).notNull()
                t.column("last_imported_at", .text).notNull()
            }

            try db.create(table: "rate_limit_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_kind", .text).notNull()      // "jsonl", "live", or "claude_oauth"
                t.column("source_session_id", .text)
                t.column("bucket", .text).notNull()           // semantic 5h / 7d bucket
                t.column("sample_timestamp", .text).notNull()
                t.column("plan_type", .text)
                t.column("limit_name", .text)
                t.column("window_start", .text)               // also preserves Codex duration
                t.column("resets_at", .text).notNull()
                t.column("used_percent", .double).notNull()
                t.column("remaining_percent", .double).notNull()
            }
            try db.create(
                indexOn: "rate_limit_samples",
                columns: ["bucket", "sample_timestamp"])

            try db.create(table: "pricing_catalog") { t in
                t.primaryKey("model_id", .text)
                t.column("display_name", .text).notNull()
                t.column("input_price_per_million", .double).notNull()
                t.column("cached_input_price_per_million", .double).notNull()
                t.column("output_price_per_million", .double).notNull()
                t.column("effective_model_id", .text).notNull()
                t.column("is_official", .boolean).notNull().defaults(to: false)
                t.column("note", .text)
                t.column("source_url", .text)
                t.column("updated_at", .text).notNull()
            }
        }

        // v2: extend pricing_catalog with LiteLLM-derived fields.
        //   - cache_creation_price_per_million: Claude-only 5-minute cache write rate. 0 for OpenAI models.
        //   - above_*: tiered prices for >200k context (LiteLLM exposes these as
        //     `*_cost_per_token_above_200k_tokens`). Stored but not yet billed.
        //   - price_source: 'seed' | 'litellm' | 'local'. Locally-edited rows are
        //     locked from automatic LiteLLM updates.
        //   - fetched_at: when these prices were last refreshed from LiteLLM.
        migrator.registerMigration("v2-litellm-pricing") { db in
            try db.alter(table: "pricing_catalog") { t in
                t.add(column: "cache_creation_price_per_million", .double)
                    .notNull().defaults(to: 0)
                t.add(column: "above_200k_input_price_per_million", .double)
                t.add(column: "above_200k_output_price_per_million", .double)
                t.add(column: "price_source", .text)
                    .notNull().defaults(to: "seed")
                t.add(column: "fetched_at", .text)
                t.add(column: "max_input_tokens", .integer)
                t.add(column: "max_output_tokens", .integer)
            }
        }

        // v3: multi-provider support.
        //   - sessions.provider  = 'codex' (default) | 'claude'
        //   - usage_events.provider = same; tagged at insert time so backfill
        //     can branch on Claude (cache_creation billing) vs OpenAI (cached
        //     read only) without joining sessions.
        //   - usage_events.cache_creation_tokens = Claude-specific cache write tokens;
        //     stays 0 for Codex/OpenAI events.
        migrator.registerMigration("v3-multi-provider") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "provider", .text)
                    .notNull().defaults(to: "codex")
            }
            try db.alter(table: "usage_events") { t in
                t.add(column: "provider", .text)
                    .notNull().defaults(to: "codex")
                t.add(column: "cache_creation_tokens", .integer)
                    .notNull().defaults(to: 0)
            }
            try db.create(
                indexOn: "usage_events", columns: ["provider", "timestamp"])
        }

        // v4: model attribution flag.
        //   - usage_events.model_inferred: true when the parser couldn't find a
        //     model on turn_context or the token_count payload and fell back to
        //     gpt-5 (LegacyFallbackModel). Surfaced in UI so users know the
        //     cost is approximate. Pre-existing rows that ended up with
        //     "unknown" get retroactively converted to the legacy fallback.
        migrator.registerMigration("v4-model-inferred") { db in
            try db.alter(table: "usage_events") { t in
                t.add(column: "model_inferred", .boolean)
                    .notNull().defaults(to: false)
            }
            // Convert legacy "unknown" rows to the gpt-5 fallback so they
            // pick up pricing and stop being silently free. Mark them
            // inferred so UI flags them with an asterisk.
            try db.execute(sql: """
                UPDATE usage_events
                SET model_id = 'gpt-5', model_inferred = 1
                WHERE model_id = 'unknown'
                """)
            // Same retroactive fix for the session header.
            try db.execute(sql: """
                UPDATE sessions
                SET last_model_id = 'gpt-5'
                WHERE last_model_id = 'unknown'
                """)
        }

        // v5: incremental rollout reads (Claude only for now).
        //   - import_state.byte_offset: last successfully-parsed byte offset
        //     into the source file. Default 0 means "next scan reads the
        //     whole file" — back-compatible with rows written by v4 and
        //     earlier. ClaudeImportEngine bumps this on every successful
        //     persist; if the file later shrinks below the recorded offset
        //     (truncation, rotation), the engine resets to 0.
        //   - usage_events.provider_message_id: stable per-message dedup key
        //     (Claude's `message.id`). Nullable because Codex doesn't have
        //     one. The partial unique index lets `INSERT OR IGNORE` swallow
        //     duplicates that arise from re-parsing the trailing window
        //     during incremental scans, so we no longer need an in-memory
        //     `seenMessageIds` Set across scan invocations.
        migrator.registerMigration("v5-incremental-imports") { db in
            try db.alter(table: "import_state") { t in
                t.add(column: "byte_offset", .integer)
                    .notNull().defaults(to: 0)
            }
            try db.alter(table: "usage_events") { t in
                t.add(column: "provider_message_id", .text)
            }
            // Partial unique index: only enforced when the column is set,
            // so Codex rows (which leave it NULL) aren't constrained.
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_events_provider_message
                ON usage_events(session_id, provider_message_id)
                WHERE provider_message_id IS NOT NULL
                """)
        }

        // v6: Claude cache creation duration split.
        //   - Claude rollouts expose both `cache_creation_input_tokens` and
        //     `usage.cache_creation.ephemeral_{5m,1h}_input_tokens`.
        //   - The total stays in `cache_creation_tokens` for rollups; pricing
        //     uses these split columns so 1h writes can bill at 2x input while
        //     5m writes keep the catalog's cache_creation rate.
        //   - Force a one-time full Claude re-read so existing imported rows
        //     pick up the split instead of staying at the default zeros.
        migrator.registerMigration("v6-claude-cache-creation-duration") { db in
            try db.alter(table: "usage_events") { t in
                t.add(column: "cache_creation_5m_tokens", .integer)
                    .notNull().defaults(to: 0)
                t.add(column: "cache_creation_1h_tokens", .integer)
                    .notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1,
                    byte_offset = 0
                WHERE source_path LIKE '%/.claude/projects/%'
                   OR source_path LIKE '%/.config/claude/projects/%'
                """)
        }

        // v7: Claude Code dynamic-workflow/subagent files may share the same
        // raw sessionId as the main rollout file. Importer versions before v7
        // reset by session per file, so one sibling could delete rows imported
        // from another sibling and leave per-model stats incomplete. Force one
        // full Claude re-read under the fixed group-reset importer.
        migrator.registerMigration("v7-claude-shared-session-reread") { db in
            try db.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1,
                    byte_offset = 0
                WHERE source_path LIKE '%/.claude/projects/%'
                   OR source_path LIKE '%/.config/claude/projects/%'
                """)
        }

        // v8: one Claude `message.id` can span several `assistant` lines
        // whose usage snapshots grow as the message streams (output_tokens
        // in particular). Importer versions before v8 kept the FIRST
        // non-zero snapshot — both the parser's in-pass dedup and the SQL
        // `INSERT OR IGNORE` were first-wins — undercounting output tokens
        // (~389k tokens across 619 messages on a real machine). Force one
        // full Claude re-read under the fixed last-snapshot-wins importer
        // so existing rows pick up the final per-message usage.
        migrator.registerMigration("v8-claude-last-snapshot-reread") { db in
            try db.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1,
                    byte_offset = 0
                WHERE source_path LIKE '%/.claude/projects/%'
                   OR source_path LIKE '%/.config/claude/projects/%'
                """)
        }

        // v9: indexes for bounded live rate-limit sample retention.
        //
        // The prune runs inside the Codex/Claude poller write transaction, so
        // it must avoid scanning jsonl rows that are intentionally exempt from
        // retention and may be large on long-lived installs.
        migrator.registerMigration("v9-rate-limit-samples-retention-indexes") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_retention_cutoff
                ON rate_limit_samples(source_kind, sample_timestamp)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_rate_limit_samples_retention_latest
                ON rate_limit_samples(
                    source_kind,
                    bucket,
                    COALESCE(limit_name, ''),
                    sample_timestamp DESC,
                    id DESC
                )
                """)
        }

        // v10: History fetchDays now scans usage_events by timestamp descending
        // and stops after collecting the requested number of local days. The
        // existing (provider, timestamp) index covers provider-filtered scans;
        // all-provider History needs a timestamp-only index to avoid sorting
        // the whole event table before the cursor can stop.
        migrator.registerMigration("v10-usage-events-timestamp-index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp
                ON usage_events(timestamp)
                """)
        }

        // v11: split session title from project metadata.
        //
        // Before v11, Codex and Claude importers stored cwd leaf names in
        // sessions.title as a friendly fallback. That made History and
        // Sessions show project names as if they were session names. Move
        // those legacy values into project_name, clear title, and force one
        // scan so importers can repopulate true titles where the source has
        // them.
        migrator.registerMigration("v11-session-project-metadata") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "project_name", .text)
                t.add(column: "cwd", .text)
            }
            try SessionMetadataMigration.reclassifyLegacyTitles(in: db)
            try SessionMetadataMigration.forceHeaderReread(in: db)
        }

        // v12: Claude streaming snapshots can cross a local-day boundary.
        // Importer versions before v12 updated the original
        // (session_id, provider_message_id) row wholesale when a later
        // snapshot arrived, which could rewrite the previous day's Dashboard
        // usage after midnight. Force one full Claude re-read under the
        // day-delta importer so existing rows are rebuilt into stable local
        // day buckets.
        migrator.registerMigration("v12-claude-cross-day-delta-reread") { db in
            try db.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1,
                    byte_offset = 0
                WHERE source_path LIKE '%/.claude/projects/%'
                   OR source_path LIKE '%/.config/claude/projects/%'
                """)
        }
    }
}
