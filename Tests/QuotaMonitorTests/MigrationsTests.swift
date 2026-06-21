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

    @Test("usage_events has a timestamp index for all-provider History scans")
    func usageEventsTimestampIndexExists() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-usage-events-index")
        let manager = try DatabaseManager(url: url)

        let indexes = try manager.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name
                FROM pragma_index_list('usage_events')
                """)
        }

        #expect(indexes.contains("idx_usage_events_timestamp"))
    }

    @Test("usage_events has Codex billing tier columns")
    func usageEventsCodexBillingTierColumnsExist() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-billing-tier-columns")
        let manager = try DatabaseManager(url: url)

        let columns = try manager.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT name, type, "notnull", dflt_value
                FROM pragma_table_info('usage_events')
                """)
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map {
            ($0["name"] as String, $0)
        })

        let turnID = try #require(byName["turn_id"])
        #expect((turnID["type"] as String).uppercased() == "TEXT")
        #expect((turnID["notnull"] as Int64) == 0)

        let billingTier = try #require(byName["billing_tier"])
        #expect((billingTier["type"] as String).uppercased() == "TEXT")
        #expect((billingTier["notnull"] as Int64) == 1)
        #expect((billingTier["dflt_value"] as String) == "'\(CodexBillingTier.unknown.rawValue)'")

        let billingTierSource = try #require(byName["billing_tier_source"])
        #expect((billingTierSource["type"] as String).uppercased() == "TEXT")
        #expect((billingTierSource["notnull"] as Int64) == 1)
        #expect((billingTierSource["dflt_value"] as String) == "'\(CodexBillingTierSource.legacy.rawValue)'")
    }

    @Test("usage_events defaults Codex billing tier columns for legacy inserts")
    func usageEventsCodexBillingTierColumnsDefaultForLegacyInserts() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-billing-tier-defaults")
        let manager = try DatabaseManager(url: url)

        let row = try manager.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                    session_id, root_session_id, created_at, imported_at, provider
                ) VALUES (
                    'codex-default-session', 'codex-default-session',
                    '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', 'codex'
                )
                """)
            try db.execute(sql: """
                INSERT INTO usage_events (
                    session_id, timestamp, model_id,
                    input_tokens, cached_input_tokens, output_tokens,
                    reasoning_output_tokens, total_tokens, value_usd,
                    provider, model_inferred
                ) VALUES (
                    'codex-default-session', '2026-06-20T00:01:00Z', 'gpt-5',
                    1, 2, 3,
                    0, 6, 0.0,
                    'codex', 0
                )
                """)
            return try Row.fetchOne(db, sql: """
                SELECT turn_id, billing_tier, billing_tier_source
                FROM usage_events
                WHERE session_id = 'codex-default-session'
                """)
        }

        let inserted = try #require(row)
        #expect(inserted["turn_id"] == nil)
        #expect((inserted["billing_tier"] as String) == CodexBillingTier.unknown.rawValue)
        #expect((inserted["billing_tier_source"] as String) == CodexBillingTierSource.legacy.rawValue)
    }

    @Test("usage_events has provider billing tier timestamp index")
    func usageEventsProviderBillingTierTimestampIndexExists() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-usage-events-tier-index")
        let manager = try DatabaseManager(url: url)

        let indexedColumns = try manager.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT ii.name
                FROM pragma_index_list('usage_events') il
                JOIN pragma_index_info(il.name) ii
                WHERE il.name = 'idx_usage_events_provider_billing_tier_timestamp'
                ORDER BY ii.seqno
                """)
        }

        #expect(indexedColumns == ["provider", "billing_tier", "timestamp"])
    }

    @Test(
        "Claude re-read migrations reset import_state so files are rebuilt once",
        arguments: [
            "v7-claude-shared-session-reread",
            "v8-claude-last-snapshot-reread",
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

    @Test("Codex billing tier migration resets only Codex import_state rows")
    func codexBillingTierMigrationResetsOnlyCodexImportState() throws {
        let url = try temporaryDatabaseURL(prefix: "qm-codex-tier-reset")
        let migrationId = "v12-codex-billing-tier"

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """)
            var migrator = DatabaseMigrator()
            Migrations.register(in: &migrator)
            for migration in migrator.migrations where migration != migrationId {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migration])
            }
            try db.execute(sql: """
                CREATE TABLE sessions (
                    session_id TEXT PRIMARY KEY,
                    root_session_id TEXT NOT NULL,
                    parent_session_id TEXT,
                    title TEXT,
                    source_path TEXT,
                    started_at TEXT,
                    updated_at TEXT,
                    agent_nickname TEXT,
                    agent_role TEXT,
                    last_model_id TEXT,
                    latest_plan_type TEXT,
                    contains_subagents BOOLEAN NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    imported_at TEXT NOT NULL,
                    provider TEXT NOT NULL DEFAULT 'codex',
                    project_name TEXT,
                    cwd TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE usage_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
                    timestamp TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    cached_input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
                    total_tokens INTEGER NOT NULL DEFAULT 0,
                    value_usd DOUBLE NOT NULL DEFAULT 0,
                    provider TEXT NOT NULL DEFAULT 'codex',
                    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                    model_inferred BOOLEAN NOT NULL DEFAULT 0,
                    provider_message_id TEXT,
                    cache_creation_5m_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_creation_1h_tokens INTEGER NOT NULL DEFAULT 0
                )
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
                INSERT INTO sessions (
                    session_id, root_session_id, created_at, imported_at, provider
                ) VALUES
                    ('codex-session', 'codex-session', '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', 'codex'),
                    ('claude-session', 'claude-session', '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z', 'claude')
                """)
            try db.execute(sql: """
                INSERT INTO import_state
                  (source_path, session_id, file_size, file_mtime_ms,
                   last_imported_at, byte_offset)
                VALUES
                  ('/Users/timmy/.codex/sessions/a/session.jsonl',
                   'codex-session', 100, 200, '2026-06-20T00:00:00Z', 100),
                  ('/Users/timmy/.codex/archived_sessions/b/session.jsonl',
                   NULL, 300, 400, '2026-06-20T00:00:00Z', 300),
                  ('/Users/timmy/.claude/projects/c/session.jsonl',
                   'claude-session', 500, 600, '2026-06-20T00:00:00Z', 500),
                  ('/tmp/other/session.jsonl',
                   NULL, 700, 800, '2026-06-20T00:00:00Z', 700)
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
            "/Users/timmy/.codex/sessions/a/session.jsonl",
            "/Users/timmy/.codex/archived_sessions/b/session.jsonl",
        ] {
            let row = try #require(byPath[path])
            #expect((row["file_size"] as Int64) == -1)
            #expect((row["file_mtime_ms"] as Int64) == -1)
            #expect((row["byte_offset"] as Int64) == 0)
        }

        let claude = try #require(byPath["/Users/timmy/.claude/projects/c/session.jsonl"])
        #expect((claude["file_size"] as Int64) == 500)
        #expect((claude["file_mtime_ms"] as Int64) == 600)
        #expect((claude["byte_offset"] as Int64) == 500)

        let other = try #require(byPath["/tmp/other/session.jsonl"])
        #expect((other["file_size"] as Int64) == 700)
        #expect((other["file_mtime_ms"] as Int64) == 800)
        #expect((other["byte_offset"] as Int64) == 700)
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
