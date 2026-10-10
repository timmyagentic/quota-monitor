import CryptoKit
import Foundation
import GRDB

/// Request observations are deliberately separate from rollout preferences and prices.
/// Codex's default feedback log has no stable join from these observations to usage.
struct CodexRequestTierEvidence: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "codex_request_tier_evidence"
    let source: String
    let generation: String
    let rowID: Int64
    let fingerprint: String
    let timestamp: Int64
    let nanoseconds: Int64
    let threadID: String?
    let turnID: String?
    let model: String?
    let rawTier: String?
    let normalizedTier: String
    let attribution: String

    static func normalize(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": "priority"
        case "ultrafast": "ultrafast"
        case "default": "default"
        case "flex": "flex"
        case "unset": "unset"
        case nil: "unknown"
        default: "unknown"
        }
    }

    /// Queryable diagnostics, not an effective billing tier. Multiple observations
    /// in a turn remain separate, including mixed tiers and missing thread IDs.
    static func observations(in db: Database, threadID: String? = nil) throws -> [Self] {
        if let threadID {
            return try fetchAll(db, sql: "SELECT * FROM codex_request_tier_evidence WHERE threadID = ? ORDER BY timestamp, nanoseconds, rowID", arguments: [threadID])
        }
        return try fetchAll(db, sql: "SELECT * FROM codex_request_tier_evidence ORDER BY timestamp, nanoseconds, rowID")
    }
}

enum CodexRequestTierReader {
    struct Cursor: Codable, Equatable, Sendable {
        let identity: String
        let schema: String
        let generation: String
        let rowID: Int64
        let fingerprint: String?
    }

    struct Batch: Sendable {
        let cursor: Cursor
        let observations: [CodexRequestTierEvidence]
        let scannedRows: Int
        let rejectedRows: Int
    }

    enum ReadError: Error { case unsupportedSchema, sourceChanged, invalidRow }

    /// A normal SQLite read transaction includes committed WAL records. Never use
    /// immutable=1 or copy the live main file without its WAL. Fail closed on locks.
    static func read(url: URL, cursor: Cursor?, limit: Int = 2_000) throws -> Batch {
        let identity = try identity(url)
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.1)
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        let batch = try queue.read { db in
            let columns = Set(try db.columns(in: "logs").map(\.name))
            guard Set(["id", "ts", "target", "thread_id"]).isSubset(of: columns),
                  let body = ["feedback_log_body", "message"].first(where: columns.contains)
            else { throw ReadError.unsupportedSchema }
            let nanos = columns.contains("ts_nanos") ? "ts_nanos" : "0"
            let schema = "v1:\(body):\(nanos)"
            // Only feedback_tags bodies enter memory; unrelated messages are never read.
            let select = "SELECT id, ts, \(nanos) AS nanos, target, thread_id, CASE WHEN target = 'feedback_tags' THEN \(body) ELSE NULL END AS body FROM logs"
            let maximumValue = try DatabaseValue.fetchOne(db, sql: "SELECT max(id) FROM logs") ?? .null
            guard maximumValue.isNull || Int64.fromDatabaseValue(maximumValue) != nil else { throw ReadError.invalidRow }
            let maximum = Int64.fromDatabaseValue(maximumValue) ?? 0
            var previous = cursor
            if let cursor {
                let anchor = try Row.fetchOne(db, sql: select + " WHERE id = ?", arguments: [cursor.rowID])
                if cursor.identity != identity || cursor.schema != schema || maximum < cursor.rowID
                    || (cursor.rowID > 0 && anchor.map(digest) != cursor.fingerprint) {
                    previous = nil
                }
            }
            let generation = previous?.generation ?? UUID().uuidString
            let rows = try Row.fetchAll(db, sql: select + " WHERE target = 'feedback_tags' AND id > ? ORDER BY id LIMIT ?",
                                        arguments: [previous?.rowID ?? 0, max(1, min(limit, 10_000))])
            for row in rows { try validate(row) }
            let lastID: Int64 = rows.last?["id"] ?? previous?.rowID ?? 0
            let more = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM logs WHERE target = 'feedback_tags' AND id > ?)", arguments: [lastID]) ?? false
            let boundary = more ? rows.last : try Row.fetchOne(db, sql: select + " WHERE id = ?", arguments: [maximum])
            if let boundary { try validate(boundary) }
            var observations: [CodexRequestTierEvidence] = []
            var rejected = 0
            for row in rows {
                guard row["target"] as String? == "feedback_tags",
                      let text: String = row["body"] else { continue }
                guard let tags = tagsJSON(text) else {
                    if text.contains("tags_json=") { rejected += 1 }
                    continue
                }
                // Ignore feature flags, even feature.ultrafast_mode=true. Only the
                // exact top-level request field is evidence; a missing key is unknown.
                let value = tags["service_tier"]
                guard value == nil || value is NSNull || value is String else {
                    rejected += 1
                    continue
                }
                let raw = value as? String
                observations.append(CodexRequestTierEvidence(
                    source: url.path, generation: generation, rowID: row["id"], fingerprint: digest(row),
                    timestamp: row["ts"], nanoseconds: row["nanos"], threadID: row["thread_id"],
                    turnID: samplingField("turn_id", in: text), model: samplingField("model", in: text),
                    rawTier: raw, normalizedTier: CodexRequestTierEvidence.normalize(raw),
                    attribution: "unattributed"))
            }
            return Batch(cursor: Cursor(identity: identity, schema: schema, generation: generation,
                                        rowID: boundary?["id"] ?? 0,
                                        fingerprint: boundary.map(digest)),
                         observations: observations, scannedRows: rows.count, rejectedRows: rejected)
        }
        guard try self.identity(url) == identity else { throw ReadError.sourceChanged }
        return batch
    }

    private static func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
    }

    private static func digest(_ row: Row) -> String {
        // Hash only, never persist the feedback body (it may contain other metadata).
        let fields = ["id", "ts", "nanos", "target", "thread_id", "body"].map {
            String(describing: (row[$0] as DatabaseValue).storage)
        }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ row: Row) throws {
        for name in ["id", "ts", "nanos"] {
            guard case .int64 = (row[name] as DatabaseValue).storage else { throw ReadError.invalidRow }
        }
        for name in ["target", "thread_id", "body"] {
            switch (row[name] as DatabaseValue).storage {
            case .null, .string: break
            default: throw ReadError.invalidRow
            }
        }
    }

    /// Split tracing fields or JSON members only outside quoted strings/containers.
    private static func split(_ text: String, on separator: (Character) -> Bool) -> [String]? {
        var parts: [String] = []
        var start = text.startIndex
        var stack: [Character] = []
        var quoted = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" || character == "[" {
                stack.append(character)
            } else if character == "}" || character == "]" {
                guard stack.popLast() == (character == "}" ? "{" : "[") else { return nil }
            } else if stack.isEmpty && separator(character) {
                if start < index { parts.append(String(text[start..<index])) }
                start = text.index(after: index)
            }
        }
        guard !quoted && stack.isEmpty else { return nil }
        if start < text.endIndex { parts.append(String(text[start...])) }
        return parts
    }

    static func tagsJSON(_ text: String) -> [String: Any]? {
        guard let fields = split(text, on: { $0.isWhitespace }) else { return nil }
        let candidates = fields.filter { $0.hasPrefix("tags_json=") }
        guard candidates.count == 1 else { return nil }
        let json = String(candidates[0].dropFirst("tags_json=".count))
        guard json.first == "{", json.last == "}",
              let members = split(String(json.dropFirst().dropLast()), on: { $0 == "," }) else { return nil }
        // JSONSerialization otherwise silently accepts conflicting duplicate keys.
        var keys: Set<String> = []
        for member in members {
            guard let pair = split(member, on: { $0 == ":" }), pair.count == 2,
                  let key = try? JSONSerialization.jsonObject(with: Data(pair[0].utf8), options: .fragmentsAllowed) as? String,
                  keys.insert(key).inserted else { return nil }
        }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func samplingField(_ name: String, in text: String) -> String? {
        guard let tokens = split(text, on: { $0.isWhitespace }),
              let context = tokens.first, context.hasSuffix(":"),
              let start = context.range(of: "try_run_sampling_request{"),
              start.lowerBound == context.startIndex || context[context.index(before: start.lowerBound)] == ":",
              let end = context[start.upperBound...].firstIndex(of: "}") else { return nil }
        let fields = String(context[start.upperBound..<end])
        let expression = "(?:^|\\s)" + name + "=(\\\"[^\\\"]*\\\"|[^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: fields, range: NSRange(fields.startIndex..., in: fields)),
              let range = Range(match.range(at: 1), in: fields) else { return nil }
        return String(fields[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

/// Consume a bounded snapshot even when rollout files have not changed. Evidence
/// and cursor commit together; retries do not duplicate observations or usage.
enum CodexRequestTierImporter {
    struct Report: Sendable {
        let status: String
        let inserted: Int
        let scanned: Int
        let rejected: Int
    }

    static func scan(home: URL, database: DatabaseManager) async throws -> Report {
        let url = home.appendingPathComponent("logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Report(status: "missing", inserted: 0, scanned: 0, rejected: 0)
        }
        let before = try await database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT cursor FROM codex_request_tier_sources WHERE source = ?", arguments: [url.path])
        }
        let cursor = before.flatMap { try? JSONDecoder().decode(CodexRequestTierReader.Cursor.self, from: $0) }
        let batch = try CodexRequestTierReader.read(url: url, cursor: cursor)
        let encoded = try JSONEncoder().encode(batch.cursor)
        let inserted = try await database.pool.write { db in
            let current = try Data.fetchOne(db, sql: "SELECT cursor FROM codex_request_tier_sources WHERE source = ?", arguments: [url.path])
            guard current == before else { throw CodexRequestTierReader.ReadError.sourceChanged }
            var inserted = 0
            for observation in batch.observations {
                try observation.insert(db, onConflict: .ignore)
                inserted += db.changesCount
            }
            try db.execute(sql: "INSERT INTO codex_request_tier_sources(source, cursor) VALUES (?, ?) ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor", arguments: [url.path, encoded])
            return inserted
        }
        return Report(status: "observed_incomplete", inserted: inserted, scanned: batch.scannedRows, rejected: batch.rejectedRows)
    }
}
