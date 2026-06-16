import Foundation
import GRDB

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
    static func load(codexHome: URL) throws -> [String: CodexSessionMetadata] {
        var result = (try? loadSessionIndex(codexHome: codexHome)) ?? [:]
        do {
            try overlayStateDatabase(codexHome: codexHome, into: &result)
        } catch {
            Log.importer.warning("failed to read Codex state metadata: \(error.localizedDescription, privacy: .public)")
            return result
        }
        return result
    }

    private static func overlayStateDatabase(
        codexHome: URL,
        into result: inout [String: CodexSessionMetadata]
    ) throws {
        let sqlite = codexHome
            .appendingPathComponent("sqlite", isDirectory: true)
            .appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: sqlite.path) else { return }

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: sqlite.path, configuration: config)
        let rows = try db.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT id, title, cwd
                FROM threads
                WHERE id IS NOT NULL
                """)
        }
        for row in rows {
            guard let id: String = row["id"], !id.isEmpty else { continue }
            result[id] = CodexSessionMetadata(
                title: nonEmpty(row["title"]),
                cwd: nonEmpty(row["cwd"]))
        }
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
