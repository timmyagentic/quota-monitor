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
