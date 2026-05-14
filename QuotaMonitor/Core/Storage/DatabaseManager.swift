import Foundation
import GRDB

// Thin wrapper around a GRDB DatabasePool. We don't add an actor on top because
// GRDB already serializes writes and allows concurrent reads via `read`/`write`.

final class DatabaseManager: Sendable {
    let pool: DatabasePool

    init(url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)

        var config = Configuration()
        // GRDB defaults to 5 concurrent reader connections. The app only
        // has 3 read paths that can plausibly overlap (refreshMenuBar,
        // refreshDashboard, ImportEngine.scan's import_state lookup), so
        // the extra two connections sit idle each holding ~2 MB of
        // SQLite page cache + an fd. Capping at 3 covers the realistic
        // worst case (user mashes Refresh while the dashboard is open
        // mid-scan) without leaving spare connections lying around.
        config.maximumReaderCount = 3
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = 10000")
        }
        self.pool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(pool)
    }

    /// Default DB location: ~/Library/Application Support/QuotaMonitor/quotamonitor.sqlite
    ///
    /// On the first launch under the new (post-rename) bundle id this also
    /// migrates an existing legacy database from the old `CodexMonitor/`
    /// directory. The migration is idempotent: it no-ops if the new file
    /// already exists or if there's nothing legacy to move.
    static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        migrateLegacyDatabaseIfNeeded(appSupportRoot: appSupport)
        return appSupport
            .appendingPathComponent("QuotaMonitor", isDirectory: true)
            .appendingPathComponent("quotamonitor.sqlite", isDirectory: false)
    }

    /// One-shot migration from the pre-rename `CodexMonitor/codexmonitor.sqlite`
    /// layout to `QuotaMonitor/quotamonitor.sqlite`. Moves the main DB plus
    /// its `-wal` / `-shm` siblings in lockstep so SQLite's WAL stays
    /// consistent. The caller MUST have ensured the old process is no
    /// longer running (otherwise SQLite may still hold the WAL lock).
    private static func migrateLegacyDatabaseIfNeeded(appSupportRoot: URL) {
        let oldDir = appSupportRoot.appendingPathComponent("CodexMonitor", isDirectory: true)
        let newDir = appSupportRoot.appendingPathComponent("QuotaMonitor", isDirectory: true)
        let oldDB = oldDir.appendingPathComponent("codexmonitor.sqlite", isDirectory: false)
        let newDB = newDir.appendingPathComponent("quotamonitor.sqlite", isDirectory: false)

        let fm = FileManager.default
        // Already migrated, or fresh install — nothing to do.
        if fm.fileExists(atPath: newDB.path) { return }
        // No legacy data — nothing to do.
        if !fm.fileExists(atPath: oldDB.path) { return }

        do {
            try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        } catch {
            Log.storage.error("legacy DB migration: createDirectory failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Move .sqlite then -wal then -shm. Order matters: the WAL has no
        // meaning without its main DB, so a partial move that leaves the
        // WAL behind is safer than the inverse.
        var moved = 0
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: oldDB.path + suffix)
            let to = URL(fileURLWithPath: newDB.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            do {
                try fm.moveItem(at: from, to: to)
                moved += 1
            } catch {
                Log.storage.error("legacy DB migration: failed to move \(from.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Best-effort: remove the now-empty legacy dir so a subsequent
        // `defaults`/`mv` cleanup doesn't trip over it.
        if let leftover = try? fm.contentsOfDirectory(atPath: oldDir.path), leftover.isEmpty {
            try? fm.removeItem(at: oldDir)
        }

        Log.storage.info("migrated legacy CodexMonitor DB → QuotaMonitor (\(moved, privacy: .public) files) at \(newDB.path, privacy: .public)")
    }
}
