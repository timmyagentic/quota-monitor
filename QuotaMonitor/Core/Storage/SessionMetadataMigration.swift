import GRDB

enum SessionMetadataMigration {
    static func reclassifyLegacyTitles(in db: Database) throws {
        try db.execute(sql: """
            UPDATE sessions
            SET project_name = CASE
                  WHEN project_name IS NULL OR project_name = ''
                  THEN NULLIF(title, '')
                  ELSE project_name
                END,
                title = NULL
            WHERE title IS NOT NULL AND title != ''
            """)
    }

    static func forceHeaderReread(in db: Database) throws {
        try db.execute(sql: """
            UPDATE import_state
            SET file_size = -1,
                file_mtime_ms = -1,
                byte_offset = 0
            WHERE session_id IN (
                SELECT session_id
                FROM sessions
                WHERE provider IN ('codex', 'claude')
            )
            """)
    }
}
