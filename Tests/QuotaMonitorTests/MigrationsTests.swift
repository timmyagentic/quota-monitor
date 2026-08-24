import Foundation
import GRDB
import Testing
@testable import QuotaMonitor

@Suite("Database migrations")
struct MigrationsTests {

    private func temporaryDatabaseURL(prefix: String = "qm-migration") throws -> URL {
        let dir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("\(prefix)-\(UUID().uuidString)",
                                 isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quotamonitor.sqlite")
    }

    @Test("fresh schema stores Codex rollout tier preferences")
    func freshSchemaStoresCodexRolloutTierPreferences() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-tier-fresh")
        let manager = try DatabaseManager(url: url)

        let columns = try manager.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name
                FROM pragma_table_info('usage_events')
                """)
        }

        #expect(columns.contains("codex_turn_id"))
        #expect(columns.contains("codex_service_tier_preference"))
        #expect(!columns.contains("codex_billing_tier"))
    }

    @Test("pricing policy migration reprices unknown Codex tiers as Standard")
    func pricingPolicyMigrationRepricesUnknownCodexTier() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-pricing-policy")
        let manager = try DatabaseManager(url: url)
        let migrationId = "v15-codex-pricing-policy-reprice"
        let stamp = "2026-07-15T00:00:00Z"

        try manager.pool.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [migrationId])
            try db.execute(sql: """
                INSERT INTO sessions
                    (session_id, root_session_id, started_at, updated_at,
                     last_model_id, created_at, imported_at, provider)
                VALUES
                    ('legacy-fast', 'legacy-fast', ?, ?, 'gpt-5.5', ?, ?, 'codex')
                """, arguments: [stamp, stamp, stamp, stamp])
            try db.execute(sql: """
                INSERT INTO usage_events
                    (session_id, timestamp, model_id,
                     input_tokens, cached_input_tokens, output_tokens,
                     reasoning_output_tokens, total_tokens, value_usd,
                     provider, codex_service_tier_preference)
                VALUES
                    ('legacy-fast', ?, 'gpt-5.5',
                     100000, 0, 100000, 0, 200000, 8.75,
                     'codex', NULL)
                """, arguments: [stamp])
        }

        _ = try DatabaseManager(url: url)

        let repriced = try manager.pool.read { db in
            try Double.fetchOne(db, sql: """
                SELECT value_usd FROM usage_events
                WHERE session_id = 'legacy-fast'
                """)
        }
        #expect(abs((repriced ?? 0) - 3.50) < 1e-6)
    }

    @Test("GPT-5.6 history migration replaces legacy price sources with bundled prices")
    func gpt56HistoryMigrationInstallsBundledCatalog() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-gpt56-history-reprice")
        let manager = try DatabaseManager(url: url)
        let migrationId = "v19-gpt56-price-history-reprice"
        let beforeCutover = "2026-07-29T23:59:59.999Z"
        let afterCutover = "2026-07-30T00:00:00.000Z"

        try manager.pool.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [migrationId])
            // Simulate an older database containing both external and local
            // provenance. The migration must replace every supported row with
            // the catalog shipped by the current app.
            let stalePrices: [(String, Double, Double, Double, String)] = [
                ("gpt-5.6-terra", 2.50, 0.20, 15.00, "litellm"),
                ("gpt-5.6-terra-fast", 5.00, 0.50, 30.00, "local"),
                ("gpt-5.6-terra-flex", 1.25, 0.125, 7.50, "litellm"),
                ("gpt-5.6-luna", 1.00, 0.10, 6.00, "local"),
                ("gpt-5.6-luna-fast", 2.00, 0.20, 12.00, "litellm"),
                ("gpt-5.6-luna-flex", 0.50, 0.05, 3.00, "local"),
            ]
            for (modelId, input, cached, output, source) in stalePrices {
                try db.execute(sql: """
                    UPDATE pricing_catalog
                    SET input_price_per_million = ?,
                        cached_input_price_per_million = ?,
                        output_price_per_million = ?,
                        price_source = ?,
                        fetched_at = '2026-07-01T00:00:00Z'
                    WHERE model_id = ?
                    """, arguments: [input, cached, output, source, modelId])
            }
            try db.execute(sql: """
                INSERT INTO sessions
                    (session_id, root_session_id, started_at, updated_at,
                     last_model_id, created_at, imported_at, provider)
                VALUES
                    ('gpt56-bundled-history', 'gpt56-bundled-history', ?, ?,
                     'gpt-5.6-terra', ?, ?, 'codex')
                """, arguments: [beforeCutover, beforeCutover,
                                  beforeCutover, beforeCutover])
            try db.execute(sql: """
                INSERT INTO usage_events
                    (session_id, timestamp, model_id,
                     input_tokens, cached_input_tokens, output_tokens,
                     reasoning_output_tokens, total_tokens, value_usd,
                     provider, codex_service_tier_preference)
                VALUES
                    ('gpt56-bundled-history', ?, 'gpt-5.6-terra',
                     200000, 40000, 20000, 0, 220000, 0.568,
                     'codex', NULL),
                    ('gpt56-bundled-history', ?, 'gpt-5.6-terra',
                     200000, 40000, 20000, 0, 220000, 0.568,
                     'codex', NULL)
                """, arguments: [beforeCutover, afterCutover])
        }

        _ = try DatabaseManager(url: url)

        let values = try manager.pool.read { db in
            try Double.fetchAll(db, sql: """
                SELECT value_usd
                FROM usage_events
                WHERE session_id = 'gpt56-bundled-history'
                ORDER BY timestamp
                """)
        }
        let prices = try manager.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT model_id, input_price_per_million,
                       cached_input_price_per_million, output_price_per_million,
                       price_source, fetched_at
                FROM pricing_catalog
                WHERE model_id IN (
                  'gpt-5.6-terra', 'gpt-5.6-terra-fast',
                  'gpt-5.6-terra-flex', 'gpt-5.6-luna',
                  'gpt-5.6-luna-fast', 'gpt-5.6-luna-flex'
                )
                """)
        }
        let priceByModel = Dictionary(uniqueKeysWithValues: prices.map { row in
            (row["model_id"] as String, (
                row["input_price_per_million"] as Double,
                row["cached_input_price_per_million"] as Double,
                row["output_price_per_million"] as Double))
        })
        let expectedPrices: [String: (Double, Double, Double)] = [
            "gpt-5.6-terra": (2.00, 0.20, 12.00),
            "gpt-5.6-terra-fast": (4.00, 0.40, 24.00),
            "gpt-5.6-terra-flex": (1.00, 0.10, 6.00),
            "gpt-5.6-luna": (0.20, 0.02, 1.20),
            "gpt-5.6-luna-fast": (0.40, 0.04, 2.40),
            "gpt-5.6-luna-flex": (0.10, 0.01, 0.60),
        ]
        #expect(priceByModel.count == expectedPrices.count)
        for (modelId, expected) in expectedPrices {
            #expect(abs((priceByModel[modelId]?.0 ?? -1) - expected.0) < 1e-9)
            #expect(abs((priceByModel[modelId]?.1 ?? -1) - expected.1) < 1e-9)
            #expect(abs((priceByModel[modelId]?.2 ?? -1) - expected.2) < 1e-9)
        }
        for row in prices {
            #expect((row["price_source"] as String?) == "bundled")
            #expect((row["fetched_at"] as String?) == nil)
        }
        #expect(values.count == 2)
        #expect(abs(values[0] - 0.7100) < 1e-9)
        #expect(abs(values[1] - 0.5680) < 1e-9)
    }

    @Test("pre-v14 schema clears only Codex tiers and invalidates Codex sessions")
    func preV14SchemaMigratesCodexTierPreferences() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-tier-v14")
        let queue = try DatabaseQueue(path: url.path)

        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        let v14 = "v14-codex-rollout-tier-preference"
        let appliedMigrations = Set(
            migrator.migrations.filter { $0 != v14 }
        ).union(["v13-codex-billing-tier"])

        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """)
            for migration in appliedMigrations.sorted() {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migration])
            }

            try db.execute(sql: """
                CREATE TABLE sessions (
                    session_id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                INSERT INTO sessions (session_id, provider)
                VALUES ('codex-custom', 'codex'), ('claude-control', 'claude')
                """)

            try db.execute(sql: """
                CREATE TABLE usage_events (
                    id INTEGER PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    codex_turn_id TEXT,
                    codex_billing_tier TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO usage_events
                    (id, session_id, provider, codex_turn_id, codex_billing_tier)
                VALUES
                    (1, 'codex-custom', 'codex', 'turn-codex', 'priority'),
                    (2, 'claude-control', 'claude', 'turn-claude', 'priority')
                """)

            try db.execute(sql: """
                CREATE TABLE import_state (
                    source_path TEXT PRIMARY KEY,
                    session_id TEXT,
                    file_size INTEGER NOT NULL,
                    file_mtime_ms INTEGER NOT NULL,
                    last_imported_at TEXT NOT NULL,
                    byte_offset INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                INSERT INTO import_state
                    (source_path, session_id, file_size, file_mtime_ms,
                     last_imported_at, byte_offset)
                VALUES
                    ('/custom/codex-home/sessions/2026/07/15/rollout-custom.jsonl',
                     'codex-custom', 111, 222, '2026-07-15T00:00:00Z', 111),
                    ('/custom/claude-home/projects/control.jsonl',
                     'claude-control', 333, 444, '2026-07-15T00:00:00Z', 123)
                """)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let columns = try String.fetchAll(db, sql: """
                SELECT name
                FROM pragma_table_info('usage_events')
                """)
            try #require(columns.contains("codex_service_tier_preference"))
            #expect(!columns.contains("codex_billing_tier"))

            let usageRows = try Row.fetchAll(db, sql: """
                SELECT provider, codex_turn_id, codex_service_tier_preference
                FROM usage_events
                ORDER BY id
                """)
            let codex = try #require(usageRows.first)
            #expect(codex["provider"] as String == "codex")
            #expect(codex["codex_turn_id"] as String? == "turn-codex")
            #expect(codex["codex_service_tier_preference"] as String? == nil)

            let claude = try #require(usageRows.last)
            #expect(claude["provider"] as String == "claude")
            #expect(claude["codex_turn_id"] as String? == "turn-claude")
            #expect(claude["codex_service_tier_preference"] as String? == "priority")

            let stateRows = try Row.fetchAll(db, sql: """
                SELECT session_id, file_size, file_mtime_ms, byte_offset
                FROM import_state
                ORDER BY session_id
                """)
            let bySession = Dictionary(uniqueKeysWithValues: stateRows.map {
                ($0["session_id"] as String, $0)
            })

            let codexState = try #require(bySession["codex-custom"])
            #expect(codexState["file_size"] as Int64 == -1)
            #expect(codexState["file_mtime_ms"] as Int64 == -1)
            #expect(codexState["byte_offset"] as Int64 == 0)

            let claudeState = try #require(bySession["claude-control"])
            #expect(claudeState["file_size"] as Int64 == 333)
            #expect(claudeState["file_mtime_ms"] as Int64 == 444)
            #expect(claudeState["byte_offset"] as Int64 == 123)
        }
    }

    @Test("Codex cache-write migration invalidates only Codex checkpoints")
    func codexCacheWriteMigrationForcesCodexReread() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-cache-write-v21")
        let manager = try DatabaseManager(url: url)
        let migrationId = "v21-codex-cache-write-reread"
        let stamp = "2026-08-24T00:00:00Z"

        try manager.pool.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [migrationId])
            try db.execute(sql: """
                INSERT INTO sessions
                    (session_id, root_session_id, started_at, updated_at,
                     last_model_id, created_at, imported_at, provider)
                VALUES
                    ('codex-cache-write', 'codex-cache-write', ?, ?,
                     'gpt-5.6-terra', ?, ?, 'codex'),
                    ('claude-control', 'claude-control', ?, ?,
                     'claude-opus-5', ?, ?, 'claude')
                """, arguments: [
                    stamp, stamp, stamp, stamp,
                    stamp, stamp, stamp, stamp,
                ])
            try db.execute(sql: """
                INSERT INTO import_state
                    (source_path, session_id, file_size, file_mtime_ms,
                     last_imported_at, byte_offset, parser_checkpoint,
                     metadata_probe_complete)
                VALUES
                    ('/custom/codex/rollout.jsonl', 'codex-cache-write',
                     111, 222, ?, 111, X'0102', 1),
                    ('/custom/claude/session.jsonl', 'claude-control',
                     333, 444, ?, 333, X'0304', 1)
                """, arguments: [stamp, stamp])
        }

        _ = try DatabaseManager(url: url)

        try manager.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, file_size, file_mtime_ms, byte_offset,
                       parser_checkpoint, metadata_probe_complete
                FROM import_state
                ORDER BY session_id
                """)
            let bySession = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["session_id"] as String, $0)
            })

            let claude = try #require(bySession["claude-control"])
            #expect(claude["file_size"] as Int64 == 333)
            #expect(claude["file_mtime_ms"] as Int64 == 444)
            #expect(claude["byte_offset"] as Int64 == 333)
            #expect(claude["parser_checkpoint"] as Data? == Data([0x03, 0x04]))

            let codex = try #require(bySession["codex-cache-write"])
            #expect(codex["file_size"] as Int64 == -1)
            #expect(codex["file_mtime_ms"] as Int64 == -1)
            #expect(codex["byte_offset"] as Int64 == 0)
            #expect(codex["parser_checkpoint"] as Data? == nil)
            #expect(codex["metadata_probe_complete"] as Bool == true)
        }
    }

    @Test("usage_events has covering indexes for History aggregates")
    func usageEventsHistoryCoveringIndexesExist() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-usage-events-index")
        let manager = try DatabaseManager(url: url)

        let indexes = try manager.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name
                FROM pragma_index_list('usage_events')
                """)
        }

        #expect(indexes.contains("idx_usage_events_history_cover"))
        #expect(indexes.contains("idx_usage_events_provider_history_cover"))
        #expect(!indexes.contains("idx_usage_events_timestamp"))
        #expect(!indexes.contains("index_usage_events_on_provider_timestamp"))
    }

    @Test("v16 replaces legacy History indexes without losing events")
    func historyCoveringIndexesUpgradeFromV15() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-history-index-upgrade")
        let migrationId = "v16-history-covering-indexes"
        let stamp = "2026-07-15T16:06:20.471Z"

        do {
            let queue = try DatabaseQueue(path: url.path)
            var migrator = DatabaseMigrator()
            Migrations.register(in: &migrator)
            try migrator.migrate(queue, upTo: "v15-codex-pricing-policy-reprice")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions
                        (session_id, root_session_id, started_at, updated_at,
                         last_model_id, created_at, imported_at, provider)
                    VALUES
                        ('history-v15', 'history-v15', ?, ?, 'gpt-5.5', ?, ?, 'codex')
                    """, arguments: [stamp, stamp, stamp, stamp])
                try db.execute(sql: """
                    INSERT INTO usage_events
                        (session_id, timestamp, model_id, total_tokens,
                         value_usd, provider)
                    VALUES ('history-v15', ?, 'gpt-5.5', 42, 0.25, 'codex')
                    """, arguments: [stamp])

                let indexes = try String.fetchAll(db, sql: """
                    SELECT name FROM pragma_index_list('usage_events')
                    """)
                #expect(indexes.contains("idx_usage_events_timestamp"))
                #expect(indexes.contains("index_usage_events_on_provider_timestamp"))
                #expect(!indexes.contains("idx_usage_events_history_cover"))
            }
        }

        let manager = try DatabaseManager(url: url)
        try manager.pool.read { db in
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM pragma_index_list('usage_events')
                """)
            #expect(indexes.contains("idx_usage_events_history_cover"))
            #expect(indexes.contains("idx_usage_events_provider_history_cover"))
            #expect(!indexes.contains("idx_usage_events_timestamp"))
            #expect(!indexes.contains("index_usage_events_on_provider_timestamp"))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events") == 1)
            #expect(try String.fetchOne(
                db,
                sql: "SELECT identifier FROM grdb_migrations WHERE identifier = ?",
                arguments: [migrationId]) == migrationId)
        }
    }

    @Test("v20 pre-aggregates existing Sessions history and installs maintenance triggers")
    func sessionSummaryMigrationBackfillsExistingHistory() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-session-summary-v20")
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue, upTo: "v19-gpt56-price-history-reprice")

        let stamp = "2026-07-20T12:00:00Z"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions
                    (session_id, root_session_id, started_at, updated_at,
                     last_model_id, created_at, imported_at, provider)
                VALUES
                    ('summary-populated', 'summary-populated', ?, ?,
                     'gpt-5.6-sol', ?, ?, 'codex'),
                    ('summary-empty', 'summary-empty', ?, ?,
                     'gpt-5.6-sol', ?, ?, 'codex')
                """, arguments: [
                    stamp, stamp, stamp, stamp,
                    stamp, stamp, stamp, stamp,
                ])
            try db.execute(sql: """
                INSERT INTO usage_events
                    (session_id, timestamp, model_id, total_tokens,
                     value_usd, provider, model_inferred)
                VALUES
                    ('summary-populated', ?, 'gpt-5.6-sol', 10, 1, 'codex', 0),
                    ('summary-populated', ?, 'gpt-5.6-sol', 20, 2.5, 'codex', 1)
                """, arguments: [stamp, stamp])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let fetchedPopulated = try Row.fetchOne(db, sql: """
                SELECT total_value_usd, total_tokens, event_count, has_inferred_model
                FROM session_summaries
                WHERE session_id = 'summary-populated'
                """)
            let populated = try #require(fetchedPopulated)
            #expect(abs((populated["total_value_usd"] as Double) - 3.5) < 1e-9)
            #expect((populated["total_tokens"] as Int64) == 30)
            #expect((populated["event_count"] as Int) == 2)
            #expect((populated["has_inferred_model"] as Bool) == true)

            let fetchedEmpty = try Row.fetchOne(db, sql: """
                SELECT total_value_usd, total_tokens, event_count, has_inferred_model
                FROM session_summaries
                WHERE session_id = 'summary-empty'
                """)
            let empty = try #require(fetchedEmpty)
            #expect((empty["total_value_usd"] as Double) == 0)
            #expect((empty["total_tokens"] as Int64) == 0)
            #expect((empty["event_count"] as Int) == 0)
            #expect((empty["has_inferred_model"] as Bool) == false)

            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND name LIKE '%_page'
                """)
            #expect(indexes.contains("idx_session_summaries_value_page"))
            #expect(indexes.contains("idx_session_summaries_tokens_page"))
            #expect(indexes.contains("idx_session_summaries_recent_page"))

            let triggers = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND name LIKE 'session_summaries_%'
                """)
            #expect(Set(triggers) == [
                "session_summaries_after_session_insert",
                "session_summaries_after_session_activity_update",
                "session_summaries_after_usage_insert",
                "session_summaries_after_usage_delete",
                "session_summaries_after_usage_update",
                "session_summaries_after_usage_move",
            ])
        }
    }

    @Test("v17 adds lazy Codex checkpoints and removes negative offsets")
    func codexCheckpointMigrationIsLazyAndPreservesProbeState() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-checkpoint-v17")
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue, upTo: "v16-history-covering-indexes")

        let stamp = "2026-07-19T00:00:00Z"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions
                    (session_id, root_session_id, created_at, imported_at, provider)
                VALUES
                    ('codex-probed', 'codex-probed', ?, ?, 'codex'),
                    ('claude-control', 'claude-control', ?, ?, 'claude')
                """, arguments: [stamp, stamp, stamp, stamp])
            try db.execute(sql: """
                INSERT INTO import_state
                    (source_path, session_id, file_size, file_mtime_ms,
                     last_imported_at, byte_offset)
                VALUES
                    ('/codex/probed.jsonl', 'codex-probed', 100, 200, ?, -1),
                    ('/claude/control.jsonl', 'claude-control', 300, 400, ?, 250)
                """, arguments: [stamp, stamp])
        }

        try migrator.migrate(queue, upTo: "v17-codex-parser-checkpoints")

        try queue.read { db in
            let columns = try String.fetchAll(db, sql: """
                SELECT name FROM pragma_table_info('import_state')
                """)
            #expect(columns.contains("parser_checkpoint"))
            #expect(columns.contains("metadata_probe_complete"))

            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, file_size, file_mtime_ms, byte_offset,
                       parser_checkpoint, metadata_probe_complete
                FROM import_state
                ORDER BY session_id
                """)
            let bySession = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["session_id"] as String, $0)
            })

            let codex = try #require(bySession["codex-probed"])
            #expect(codex["file_size"] as Int64 == 100)
            #expect(codex["file_mtime_ms"] as Int64 == 200)
            #expect(codex["byte_offset"] as Int64 == 0)
            #expect(codex["parser_checkpoint"] as Data? == nil)
            #expect(codex["metadata_probe_complete"] as Bool == true)

            let claude = try #require(bySession["claude-control"])
            #expect(claude["byte_offset"] as Int64 == 250)
            #expect(claude["parser_checkpoint"] as Data? == nil)
            #expect(claude["metadata_probe_complete"] as Bool == false)
        }
    }

    @Test("import_state has a partial session lookup index")
    func importStateSessionLookupIndexIsPartial() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-import-state-index")
        let manager = try DatabaseManager(url: url)

        try manager.pool.read { db in
            let fetchedIndex = try Row.fetchOne(db, sql: """
                SELECT name, partial
                FROM pragma_index_list('import_state')
                WHERE name = 'idx_import_state_session_id'
                """)
            let index = try #require(fetchedIndex)
            #expect(index["name"] as String == "idx_import_state_session_id")
            #expect(index["partial"] as Int == 1)

            let columns = try String.fetchAll(db, sql: """
                SELECT name
                FROM pragma_index_info('idx_import_state_session_id')
                ORDER BY seqno
                """)
            #expect(columns == ["session_id"])
        }
    }

    @Test("v18 import_state session index can be reapplied safely")
    func importStateSessionLookupIndexMigrationIsIdempotent() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-import-state-index-idempotence")
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(queue)

        let migrationId = "v18-import-state-session-index"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO import_state
                    (source_path, session_id, file_size, file_mtime_ms,
                     last_imported_at, byte_offset)
                VALUES
                    ('/codex/old.jsonl', 'session-a', 100, 200,
                     '2026-07-21T00:00:00Z', 100),
                    ('/codex/unassigned.jsonl', NULL, 0, 0,
                     '2026-07-21T00:00:00Z', 0)
                """)
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [migrationId])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let indexCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM pragma_index_list('import_state')
                WHERE name = 'idx_import_state_session_id'
                """)
            let stateCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM import_state")
            let migrationCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM grdb_migrations
                WHERE identifier = ?
                """, arguments: [migrationId])
            #expect(indexCount == 1)
            #expect(stateCount == 2)
            #expect(migrationCount == 1)
        }
    }

    @Test("importer relocation cleanup uses the import_state session index")
    func importerRelocationCleanupUsesImportStateSessionIndex() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-import-state-index-plan")
        let manager = try DatabaseManager(url: url)

        let plan = try manager.pool.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                DELETE FROM import_state
                WHERE session_id = ? AND source_path <> ?
                """, arguments: ["session-a", "/codex/current.jsonl"])
                .map { $0["detail"] as String }
        }

        #expect(plan.contains {
            $0.contains("USING INDEX idx_import_state_session_id")
        })
        #expect(plan.allSatisfy { !$0.contains("SCAN import_state") })
    }

    @Test(
        "Claude re-read migrations reset import_state so files are rebuilt once",
        arguments: [
            "v7-claude-shared-session-reread",
            "v8-claude-last-snapshot-reread",
            "v12-claude-cross-day-delta-reread",
        ])
    func claudeRereadMigrationResetsImportState(migrationId: String) throws {
        let url = try temporaryDatabaseURL()

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """)
            // Mark every registered migration EXCEPT the one under test as
            // already applied, so opening the database below runs exactly
            // that migration. Deriving the list from `Migrations.register`
            // keeps this test scoped when future migrations are added — a
            // v9 would otherwise run against this hand-built schema and
            // break.
            var migrator = DatabaseMigrator()
            Migrations.register(in: &migrator)
            for migration in migrator.migrations where migration != migrationId {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migration])
            }
            try db.execute(sql: """
                CREATE TABLE import_state (
                    source_path TEXT PRIMARY KEY,
                    session_id TEXT,
                    file_size INTEGER NOT NULL,
                    file_mtime_ms INTEGER NOT NULL,
                    last_imported_at TEXT NOT NULL,
                    byte_offset INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE pricing_catalog (
                    model_id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    input_price_per_million DOUBLE NOT NULL,
                    cached_input_price_per_million DOUBLE NOT NULL,
                    output_price_per_million DOUBLE NOT NULL,
                    effective_model_id TEXT NOT NULL,
                    is_official BOOLEAN NOT NULL DEFAULT 0,
                    note TEXT,
                    source_url TEXT,
                    updated_at TEXT NOT NULL,
                    cache_creation_price_per_million DOUBLE NOT NULL DEFAULT 0,
                    above_200k_input_price_per_million DOUBLE,
                    above_200k_output_price_per_million DOUBLE,
                    price_source TEXT NOT NULL DEFAULT 'seed',
                    fetched_at TEXT,
                    max_input_tokens INTEGER,
                    max_output_tokens INTEGER
                )
                """)
            try db.execute(sql: """
                INSERT INTO import_state
                  (source_path, session_id, file_size, file_mtime_ms,
                   last_imported_at, byte_offset)
                VALUES
                  ('/Users/timmy/.claude/projects/a/session.jsonl',
                   'claude-a', 100, 200, '2026-06-10T00:00:00Z', 100),
                  ('/Users/timmy/.config/claude/projects/b/session.jsonl',
                   'claude-b', 300, 400, '2026-06-10T00:00:00Z', 300),
                  ('/Users/timmy/.codex/sessions/c/session.jsonl',
                   'codex-c', 500, 600, '2026-06-10T00:00:00Z', 500)
                """)
        }

        _ = try DatabaseManager(url: url)

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_path, file_size, file_mtime_ms, byte_offset
                FROM import_state
                ORDER BY source_path
                """)
        }
        let byPath = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["source_path"] as String, $0)
        })

        for path in [
            "/Users/timmy/.claude/projects/a/session.jsonl",
            "/Users/timmy/.config/claude/projects/b/session.jsonl",
        ] {
            let row = try #require(byPath[path])
            #expect((row["file_size"] as Int64) == -1)
            #expect((row["file_mtime_ms"] as Int64) == -1)
            #expect((row["byte_offset"] as Int64) == 0)
        }

        let codex = try #require(byPath["/Users/timmy/.codex/sessions/c/session.jsonl"])
        #expect((codex["file_size"] as Int64) == 500)
        #expect((codex["file_mtime_ms"] as Int64) == 600)
        #expect((codex["byte_offset"] as Int64) == 500)
    }

    @Test("rate_limit_samples retention indexes are created")
    func rateLimitSampleRetentionIndexesCreated() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-retention-index")
        let manager = try DatabaseManager(url: url)

        let indexNames = try manager.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name
                FROM pragma_index_list('rate_limit_samples')
                """)
        }

        #expect(indexNames.contains("idx_rate_limit_samples_retention_cutoff"))
        #expect(indexNames.contains("idx_rate_limit_samples_retention_latest"))
    }
}
