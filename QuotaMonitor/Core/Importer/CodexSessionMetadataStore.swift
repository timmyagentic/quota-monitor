import Darwin
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

struct CodexSessionMetadataSourceFingerprint: Equatable, Sendable {
    enum FileState: Equatable, Sendable {
        case missing
        case present(
            size: Int64,
            device: Int64,
            inode: Int64,
            birthtimeNs: Int64,
            modificationTimeNs: Int64,
            changeTimeNs: Int64)
    }

    let files: [FileState]
}

struct CodexSessionMetadataLoadResult: Sendable {
    let metadata: [String: CodexSessionMetadata]
    let isComplete: Bool
}

enum CodexSessionMetadataStore {
    private static let sqliteErrorDomain = "CodexSessionMetadataStore.SQLite"

    private struct StateDatabaseLoadResult {
        let metadata: [String: CodexSessionMetadata]
        let isComplete: Bool
        let attempted: Bool
        let firstError: Error?
    }

    static func load(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        loadResult(codexHome: codexHome).metadata
    }

    static func loadResult(codexHome: URL) -> CodexSessionMetadataLoadResult {
        var result: [String: CodexSessionMetadata] = [:]
        var isComplete = true

        do {
            result = try loadSessionIndex(codexHome: codexHome)
        } catch {
            isComplete = false
            Log.importer.warning("failed to read Codex session index: \(error.localizedDescription, privacy: .public)")
        }

        let state = loadStateDatabaseResult(codexHome: codexHome)
        if !state.isComplete, let error = state.firstError {
            Log.importer.warning("failed to read Codex state metadata: \(error.localizedDescription, privacy: .public)")
        }
        isComplete = isComplete && state.isComplete
        for (id, stateMetadata) in state.metadata {
            let existing = result[id]
            result[id] = CodexSessionMetadata(
                title: existing?.title,
                cwd: existing?.cwd ?? stateMetadata.cwd)
        }

        return CodexSessionMetadataLoadResult(
            metadata: result,
            isComplete: isComplete)
    }

    static func loadStateDatabase(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        let loadResult = loadStateDatabaseResult(codexHome: codexHome)
        if loadResult.metadata.isEmpty,
           loadResult.attempted,
           let firstError = loadResult.firstError {
            throw firstError
        }
        return loadResult.metadata
    }

    static func sourceFingerprint(
        codexHome: URL
    ) throws -> CodexSessionMetadataSourceFingerprint {
        let sessionIndex = codexHome.appendingPathComponent("session_index.jsonl")
        let stateFiles = stateDatabaseCandidates(codexHome: codexHome).flatMap { sqlite in
            [sqlite, URL(fileURLWithPath: sqlite.path + "-wal")]
        }
        return CodexSessionMetadataSourceFingerprint(
            files: try ([sessionIndex] + stateFiles).map(fileState))
    }

    private static func loadStateDatabaseResult(
        codexHome: URL
    ) -> StateDatabaseLoadResult {
        var result: [String: CodexSessionMetadata] = [:]
        var firstError: Error?
        var attempted = false
        var isComplete = true

        for sqlite in stateDatabaseCandidates(codexHome: codexHome) {
            guard FileManager.default.fileExists(atPath: sqlite.path) else { continue }
            attempted = true
            do {
                let rows = try loadStateRows(sqlite: sqlite)
                for row in rows {
                    let existing = result[row.id]
                    result[row.id] = CodexSessionMetadata(
                        title: existing?.title,
                        cwd: existing?.cwd ?? row.cwd)
                }
            } catch {
                firstError = firstError ?? error
                isComplete = false
            }
        }

        return StateDatabaseLoadResult(
            metadata: result,
            isComplete: isComplete,
            attempted: attempted,
            firstError: firstError)
    }

    private static func stateDatabaseCandidates(codexHome: URL) -> [URL] {
        [
            codexHome
                .appendingPathComponent("sqlite", isDirectory: true)
                .appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("state_5.sqlite")
        ]
    }

    private struct StateRow {
        let id: String
        let cwd: String?
    }

    private static func loadStateRows(sqlite: URL) throws -> [StateRow] {
        do {
            return try readStateRows(sqlite: sqlite)
        } catch {
            guard shouldRetryFromSnapshot(error) else { throw error }
            return try withStateDatabaseSnapshot(sqlite: sqlite) { snapshot in
                do {
                    return try readStateRows(sqlite: snapshot)
                } catch {
                    let wal = URL(fileURLWithPath: snapshot.path + "-wal")
                    guard !FileManager.default.fileExists(atPath: wal.path),
                          shouldRetryFromSnapshot(error)
                    else { throw error }
                    return try readStateRows(sqlite: snapshot, immutable: true)
                }
            }
        }
    }

    private static func readStateRows(sqlite: URL, immutable: Bool = false) throws -> [StateRow] {
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
        // In current Codex data, threads.title can be the first prompt.
        // Session titles come from session_index.jsonl.thread_name; state DB
        // is used only for cwd/project metadata.
        let sql = """
            SELECT id, cwd
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
                    cwd: nonEmpty(sqliteColumnText(statement, 1))))
            case SQLITE_DONE:
                return rows
            default:
                throw sqliteError(database, code: stepCode, operation: "step threads query")
            }
        }
    }

    private static func stateDatabaseURI(sqlite: URL, immutable: Bool = false) -> String {
        var uri = sqlite.absoluteString
        uri += uri.contains("?") ? "&mode=ro" : "?mode=ro"
        if immutable {
            uri += "&immutable=1"
        }
        return uri
    }

    private static func withStateDatabaseSnapshot<T>(
        sqlite: URL,
        perform body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-codex-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = directory.appendingPathComponent(sqlite.lastPathComponent)
        try FileManager.default.copyItem(at: sqlite, to: snapshot)

        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sqlite.path + suffix)
            guard FileManager.default.fileExists(atPath: sourceSidecar.path) else { continue }
            let targetSidecar = URL(fileURLWithPath: snapshot.path + suffix)
            try FileManager.default.copyItem(at: sourceSidecar, to: targetSidecar)
        }

        return try body(snapshot)
    }

    private static func sqliteColumnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: text)
    }

    private static func shouldRetryFromSnapshot(_ error: Error) -> Bool {
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

    private static func fileState(
        _ url: URL
    ) throws -> CodexSessionMetadataSourceFingerprint.FileState {
        var value = Darwin.stat()
        let status = url.path.withCString { path in
            Darwin.lstat(path, &value)
        }
        guard status == 0 else {
            let code = errno
            if code == ENOENT {
                return .missing
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey: "lstat Codex metadata source failed: \(url.path)"
                ])
        }

        return .present(
            size: Int64(value.st_size),
            device: Int64(value.st_dev),
            inode: Int64(bitPattern: UInt64(value.st_ino)),
            birthtimeNs: nanoseconds(value.st_birthtimespec),
            modificationTimeNs: nanoseconds(value.st_mtimespec),
            changeTimeNs: nanoseconds(value.st_ctimespec))
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
