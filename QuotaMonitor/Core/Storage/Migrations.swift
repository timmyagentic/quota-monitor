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

        // v2: historical schema expansion. The migration identifier and
        // columns remain for databases created by older releases; current
        // runtime pricing is bundled-only and resets this legacy metadata.
        //   - cache_creation_price_per_million: provider-specific cache-write
        //     rate for Claude 5-minute creation and Codex prompt-cache writes.
        //   - above_*, price_source, fetched_at, and max_* are retained only so
        //     the append-only migration chain can open existing databases.
        migrator.registerMigration("v2-litellm-pricing") { db in
            try db.alter(table: "pricing_catalog") { t in
                t.add(column: "cache_creation_price_per_million", .double)
                    .notNull().defaults(to: 0)
                t.add(column: "above_200k_input_price_per_million", .double)
                t.add(column: "above_200k_output_price_per_million", .double)
                t.add(column: "price_source", .text)
                    .notNull().defaults(to: "bundled")
                t.add(column: "fetched_at", .text)
                t.add(column: "max_input_tokens", .integer)
                t.add(column: "max_output_tokens", .integer)
            }
        }

        // v3: multi-provider support.
        //   - sessions.provider  = 'codex' (default) | 'claude'
        //   - usage_events.provider = same; tagged at insert time so backfill
        //     can branch on Claude duration-specific cache creation vs OpenAI
        //     cached reads and prompt-cache writes without joining sessions.
        //   - usage_events.cache_creation_tokens = provider-neutral cache write
        //     input. Claude and Codex populate it from their respective wire
        //     names; early Codex importers left it at 0.
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

        // Compatibility bridge for databases created by the unpublished
        // trace-based implementation.
        migrator.registerMigration("v13-codex-billing-tier") { db in
            try db.alter(table: "usage_events") { t in
                t.add(column: "codex_turn_id", .text)
                t.add(column: "codex_billing_tier", .text)
            }
        }

        // Replace trace-derived tiers with durable rollout preferences and
        // force Codex sessions to rebuild from their source rollouts.
        migrator.registerMigration("v14-codex-rollout-tier-preference") { db in
            try db.alter(table: "usage_events") { t in
                t.rename(
                    column: "codex_billing_tier",
                    to: "codex_service_tier_preference")
            }
            try db.execute(sql: """
                UPDATE usage_events
                SET codex_service_tier_preference = NULL
                WHERE provider = 'codex'
                """)
            try db.execute(sql: """
                UPDATE import_state
                SET file_size = -1, file_mtime_ms = -1, byte_offset = 0
                WHERE session_id IN (
                    SELECT session_id FROM sessions WHERE provider = 'codex'
                )
                """)
        }

        // Recompute the derived dollar values after replacing the legacy
        // unknown-as-Fast fallback and adding Codex long-context pricing.
        // This must be a migration rather than relying on the next history
        // scan: unchanged rollouts may otherwise retain stale values forever.
        migrator.registerMigration("v15-codex-pricing-policy-reprice") { db in
            _ = try PricingService.installBundledCatalog(in: db)
            try PricingService.backfillAllValues(in: db)
        }

        // v16: History pages aggregate value, token, event, and distinct-session
        // totals from a bounded timestamp range. Cover every projected column
        // so SQLite does not bounce from the timestamp index into usage_events
        // once per matching event. Keep id directly after the range keys so
        // BillingBlocks can also satisfy ORDER BY timestamp, id without a sort.
        // These indexes retain the prefixes used by the prior timestamp-only
        // indexes, so they replace rather than duplicate those read paths.
        migrator.registerMigration("v16-history-covering-indexes") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_usage_events_history_cover
                ON usage_events(
                    timestamp, id, value_usd, total_tokens, session_id
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_usage_events_provider_history_cover
                ON usage_events(
                    provider, timestamp, id,
                    value_usd, total_tokens, session_id
                )
                """)
            try db.execute(sql: """
                DROP INDEX IF EXISTS idx_usage_events_timestamp
                """)
            try db.execute(sql: """
                DROP INDEX IF EXISTS index_usage_events_on_provider_timestamp
                """)
        }

        // v17: Codex root rollouts can resume from a byte cursor when the
        // parser's complete reducer state is available. Existing rows remain
        // lazy: unchanged files are not reread during migration, and the first
        // later change performs one final full parse to create a checkpoint.
        migrator.registerMigration("v17-codex-parser-checkpoints") { db in
            try db.alter(table: "import_state") { t in
                t.add(column: "parser_checkpoint", .blob)
                t.add(column: "metadata_probe_complete", .boolean)
                    .notNull().defaults(to: false)
            }
            // Older Codex imports used -1 as a metadata-probe sentinel. Keep
            // that information explicitly and restore byte_offset's invariant.
            try db.execute(sql: """
                UPDATE import_state
                SET metadata_probe_complete = 1,
                    byte_offset = 0
                WHERE byte_offset < 0
                  AND session_id IN (
                    SELECT session_id FROM sessions WHERE provider = 'codex'
                  )
                """)
            try db.execute(sql: """
                UPDATE import_state
                SET byte_offset = 0
                WHERE byte_offset < 0
                """)
        }

        // v18: Codex source relocation consolidates stale import-state aliases
        // by session ID. Index only populated session IDs so legacy rows that
        // have not yet been associated with a session do not enlarge it.
        migrator.registerMigration("v18-import-state-session-index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_import_state_session_id
                ON import_state(session_id)
                WHERE session_id IS NOT NULL
                """)
        }

        // v19: Install current bundled prices before repricing existing usage
        // with timestamp-dependent GPT-5.6 history. Older databases may still
        // carry external or local provenance, but bundled prices now replace it.
        migrator.registerMigration("v19-gpt56-price-history-reprice") { db in
            _ = try PricingService.installBundledCatalog(in: db)
            try PricingService.backfillAllValues(in: db)
        }

        // v20: Sessions pages read pre-aggregated totals and advance with an
        // indexed keyset cursor. Triggers keep the summary exact for every
        // insert, update, move, and delete of a usage event, including pricing
        // backfills, so list queries never need to aggregate usage_events.
        migrator.registerMigration("v20-session-summaries-keyset") { db in
            try db.execute(sql: """
                CREATE TABLE session_summaries (
                    session_id TEXT NOT NULL PRIMARY KEY
                        REFERENCES sessions(session_id) ON DELETE CASCADE,
                    activity_at TEXT NOT NULL DEFAULT '',
                    total_value_usd DOUBLE NOT NULL DEFAULT 0,
                    total_tokens INTEGER NOT NULL DEFAULT 0,
                    event_count INTEGER NOT NULL DEFAULT 0,
                    has_inferred_model BOOLEAN NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                INSERT INTO session_summaries (
                    session_id,
                    activity_at,
                    total_value_usd,
                    total_tokens,
                    event_count,
                    has_inferred_model
                )
                SELECT
                    s.session_id,
                    COALESCE(s.updated_at, s.started_at, ''),
                    COALESCE(SUM(ue.value_usd), 0),
                    COALESCE(SUM(ue.total_tokens), 0),
                    COUNT(ue.id),
                    COALESCE(MAX(ue.model_inferred), 0)
                FROM sessions s
                LEFT JOIN usage_events ue ON ue.session_id = s.session_id
                GROUP BY s.session_id
                """)

            try db.execute(sql: """
                CREATE INDEX idx_session_summaries_value_page
                ON session_summaries(total_value_usd DESC, session_id ASC)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_session_summaries_tokens_page
                ON session_summaries(total_tokens DESC, session_id ASC)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_session_summaries_recent_page
                ON session_summaries(activity_at DESC, session_id ASC)
                """)

            try db.execute(sql: """
                CREATE TRIGGER session_summaries_after_session_insert
                AFTER INSERT ON sessions
                BEGIN
                    INSERT OR IGNORE INTO session_summaries(session_id, activity_at)
                    VALUES (
                        NEW.session_id,
                        COALESCE(NEW.updated_at, NEW.started_at, '')
                    );
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER session_summaries_after_session_activity_update
                AFTER UPDATE OF updated_at, started_at ON sessions
                WHEN OLD.updated_at IS NOT NEW.updated_at
                  OR OLD.started_at IS NOT NEW.started_at
                BEGIN
                    UPDATE session_summaries
                    SET activity_at = COALESCE(
                        NEW.updated_at,
                        NEW.started_at,
                        ''
                    )
                    WHERE session_id = NEW.session_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER session_summaries_after_usage_insert
                AFTER INSERT ON usage_events
                BEGIN
                    UPDATE session_summaries
                    SET total_value_usd = total_value_usd + NEW.value_usd,
                        total_tokens = total_tokens + NEW.total_tokens,
                        event_count = event_count + 1,
                        has_inferred_model = CASE
                            WHEN NEW.model_inferred <> 0 THEN 1
                            ELSE has_inferred_model
                        END
                    WHERE session_id = NEW.session_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER session_summaries_after_usage_delete
                AFTER DELETE ON usage_events
                BEGIN
                    UPDATE session_summaries
                    SET total_value_usd = CASE
                            WHEN event_count <= 1 THEN 0
                            ELSE total_value_usd - OLD.value_usd
                        END,
                        total_tokens = CASE
                            WHEN event_count <= 1 THEN 0
                            ELSE total_tokens - OLD.total_tokens
                        END,
                        event_count = CASE
                            WHEN event_count <= 1 THEN 0
                            ELSE event_count - 1
                        END,
                        has_inferred_model = CASE
                            WHEN event_count <= 1 THEN 0
                            WHEN OLD.model_inferred = 0 THEN has_inferred_model
                            ELSE COALESCE((
                                SELECT MAX(model_inferred)
                                FROM usage_events
                                WHERE session_id = OLD.session_id
                            ), 0)
                        END
                    WHERE session_id = OLD.session_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER session_summaries_after_usage_update
                AFTER UPDATE OF session_id, value_usd, total_tokens, model_inferred
                ON usage_events
                WHEN OLD.session_id = NEW.session_id
                 AND (OLD.value_usd IS NOT NEW.value_usd
                      OR OLD.total_tokens IS NOT NEW.total_tokens
                      OR OLD.model_inferred IS NOT NEW.model_inferred)
                BEGIN
                    UPDATE session_summaries
                    SET total_value_usd = total_value_usd
                            + NEW.value_usd - OLD.value_usd,
                        total_tokens = total_tokens
                            + NEW.total_tokens - OLD.total_tokens,
                        has_inferred_model = CASE
                            WHEN OLD.model_inferred = NEW.model_inferred
                                THEN has_inferred_model
                            WHEN NEW.model_inferred <> 0 THEN 1
                            ELSE COALESCE((
                                SELECT MAX(model_inferred)
                                FROM usage_events
                                WHERE session_id = NEW.session_id
                            ), 0)
                        END
                    WHERE session_id = NEW.session_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER session_summaries_after_usage_move
                AFTER UPDATE OF session_id, value_usd, total_tokens, model_inferred
                ON usage_events
                WHEN OLD.session_id <> NEW.session_id
                BEGIN
                    UPDATE session_summaries
                    SET total_value_usd = CASE
                            WHEN event_count <= 1 THEN 0
                            ELSE total_value_usd - OLD.value_usd
                        END,
                        total_tokens = CASE
                            WHEN event_count <= 1 THEN 0
                            ELSE total_tokens - OLD.total_tokens
                        END,
                        event_count = CASE
                            WHEN event_count <= 1 THEN 0
                            ELSE event_count - 1
                        END,
                        has_inferred_model = CASE
                            WHEN event_count <= 1 THEN 0
                            WHEN OLD.model_inferred = 0 THEN has_inferred_model
                            ELSE COALESCE((
                                SELECT MAX(model_inferred)
                                FROM usage_events
                                WHERE session_id = OLD.session_id
                            ), 0)
                        END
                    WHERE session_id = OLD.session_id;

                    UPDATE session_summaries
                    SET total_value_usd = total_value_usd + NEW.value_usd,
                        total_tokens = total_tokens + NEW.total_tokens,
                        event_count = event_count + 1,
                        has_inferred_model = CASE
                            WHEN NEW.model_inferred <> 0 THEN 1
                            ELSE has_inferred_model
                        END
                    WHERE session_id = NEW.session_id;
                END
                """)
        }

        // v21: Codex rollouts now expose `cache_write_input_tokens` as a
        // disjoint subset of `input_tokens`. Reuse the provider-neutral
        // cache_creation_tokens storage column, but force every known Codex
        // source through a full parse so committed prefixes cannot retain the
        // old implicit zero. Reprice stored events immediately as well: source
        // rollouts may be unavailable, and this release also changes how
        // GPT-5.6 Priority long-context rows select Fast pricing. Install the
        // current catalog first because it materializes the complete
        // Short/Long × tier and historical matrix, including cache-write
        // rates. Claude checkpoints are unrelated and stay untouched.
        migrator.registerMigration("v21-codex-cache-write-reread") { db in
            try db.execute(sql: """
                UPDATE import_state
                SET file_size = -1,
                    file_mtime_ms = -1,
                    byte_offset = 0,
                    parser_checkpoint = NULL
                WHERE session_id IN (
                    SELECT session_id FROM sessions WHERE provider = 'codex'
                )
                """)
            _ = try PricingService.installBundledCatalog(in: db)
            try PricingService.backfillAllValues(in: db)
        }
    }
}
