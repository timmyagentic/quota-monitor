import Foundation
import SQLite3

struct CodexSessionMetadata: Sendable, Equatable {
    let title: String?
    let cwd: String?

    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let leaf = (cwd as NSString).lastPathComponent
        return leaf.isEmpty ? nil : leaf
    }
}

enum CodexSessionMetadataStore {
    private static let sqliteErrorDomain = "CodexSessionMetadataStore.SQLite"

    static func load(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        var result = (try? loadSessionIndex(codexHome: codexHome)) ?? [:]
        do {
            let stateMetadata = try loadStateDatabase(codexHome: codexHome)
            result.merge(stateMetadata) { _, state in state }
        } catch {
            Log.importer.warning("failed to read Codex state metadata: \(error.localizedDescription, privacy: .public)")
            return result
        }
        return result
    }

    static func loadStateDatabase(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        let sqlite = codexHome
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: sqlite.path) else { return [:] }

        let rows = try loadStateRows(sqlite: sqlite)
        var result: [String: CodexSessionMetadata] = [:]
        for row in rows {
            result[row.id] = CodexSessionMetadata(title: row.title, cwd: row.cwd)
        }
        return result
    }

    private struct StateRow {
        let id: String
        let title: String?
        let cwd: String?
    }

    private static func loadStateRows(sqlite: URL) throws -> [StateRow] {
        do {
            return try readStateRows(sqlite: sqlite, immutable: false)
        } catch {
            guard shouldRetryAsImmutable(error) else { throw error }
            return try readStateRows(sqlite: sqlite, immutable: true)
        }
    }

    private static func readStateRows(sqlite: URL, immutable: Bool) throws -> [StateRow] {
        let uri = stateDatabaseURI(sqlite: sqlite, immutable: immutable)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let openCode = sqlite3_open_v2(uri, &database, flags, nil)
        guard openCode == SQLITE_OK else {
            let error = sqliteError(
                database,
                code: openCode,
                operation: immutable ? "open immutable" : "open read-only")
            if let database {
                sqlite3_close(database)
            }
            throw error
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        var statement: OpaquePointer?
        let sql = """
            SELECT id, title, cwd
            FROM threads
            WHERE id IS NOT NULL
            """
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK else {
            throw sqliteError(database, code: prepareCode, operation: "prepare threads query")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [StateRow] = []
        while true {
            let stepCode = sqlite3_step(statement)
            switch stepCode {
            case SQLITE_ROW:
                guard let id = sqliteColumnText(statement, 0), !id.isEmpty else {
                    continue
                }
                rows.append(StateRow(
                    id: id,
                    title: nonEmpty(sqliteColumnText(statement, 1)),
                    cwd: nonEmpty(sqliteColumnText(statement, 2))))
            case SQLITE_DONE:
                return rows
            default:
                throw sqliteError(database, code: stepCode, operation: "step threads query")
            }
        }
    }

    private static func stateDatabaseURI(sqlite: URL, immutable: Bool) -> String {
        var uri = sqlite.absoluteString
        uri += uri.contains("?") ? "&mode=ro" : "?mode=ro"
        if immutable {
            uri += "&immutable=1"
        }
        return uri
    }

    private static func sqliteColumnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: text)
    }

    private static func shouldRetryAsImmutable(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == sqliteErrorDomain else { return false }
        return error.code == Int(SQLITE_BUSY)
            || error.code == Int(SQLITE_LOCKED)
            || error.code == Int(SQLITE_CANTOPEN)
    }

    private static func sqliteError(
        _ database: OpaquePointer?,
        code: Int32,
        operation: String
    ) -> NSError {
        let extendedCode = database.map { sqlite3_extended_errcode($0) } ?? code
        let primaryCode = extendedCode & 0xFF
        let message: String = {
            guard let database, let raw = sqlite3_errmsg(database) else {
                return "SQLite result code \(code)"
            }
            return String(cString: raw)
        }()
        return NSError(
            domain: sqliteErrorDomain,
            code: Int(primaryCode),
            userInfo: [
                NSLocalizedDescriptionKey: "Codex state database \(operation) failed: \(message)",
                "SQLiteExtendedCode": Int(extendedCode)
            ])
    }

    private static func loadSessionIndex(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data = try Data(contentsOf: url)
        var result: [String: CodexSessionMetadata] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  !id.isEmpty
            else { continue }
            result[id] = CodexSessionMetadata(
                title: nonEmpty(object["thread_name"] as? String),
                cwd: nil)
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
