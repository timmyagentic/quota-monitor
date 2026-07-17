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
