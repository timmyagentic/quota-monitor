import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

struct CodexServiceTierTraceStore: Sendable {
    let databaseURL: URL

    static func defaultDatabaseURL(codexHome: URL) -> URL? {
        let rootDatabase = codexHome.appending(path: "logs_2.sqlite")
        if FileManager.default.fileExists(atPath: rootDatabase.path) {
            return rootDatabase
        }

        let fallbackDatabase = codexHome
            .appending(path: "sqlite", directoryHint: .isDirectory)
            .appending(path: "logs_2.sqlite")
        if FileManager.default.fileExists(atPath: fallbackDatabase.path) {
            return fallbackDatabase
        }

        return nil
    }

    func loadLookup(start: Date, end: Date) throws -> CodexTurnBillingLookup {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) }
            if let db {
                sqlite3_close(db)
            }
            throw TraceStoreError.openFailed(message)
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ts, ts_nanos, feedback_log_body
        FROM logs
        WHERE ts >= ? AND ts < ?
          AND feedback_log_body IS NOT NULL
          AND (
            feedback_log_body LIKE '%service_tier%'
            OR feedback_log_body LIKE '%response.completed%'
          )
        ORDER BY ts ASC, ts_nanos ASC, id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TraceStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let startBindResult = sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        guard startBindResult == SQLITE_OK else {
            throw TraceStoreError.bindFailed(
                parameter: "start timestamp",
                message: String(cString: sqlite3_errmsg(db)))
        }

        let endBindResult = sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        guard endBindResult == SQLITE_OK else {
            throw TraceStoreError.bindFailed(
                parameter: "end timestamp",
                message: String(cString: sqlite3_errmsg(db)))
        }

        var tracesByTurnID: [String: CodexTurnBillingTrace] = [:]
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let timestampSeconds = sqlite3_column_int64(statement, 0)
                guard let bodyPointer = sqlite3_column_text(statement, 2) else { continue }
                let body = String(cString: bodyPointer)
                let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampSeconds))
                if let parsed = Self.parseRequestTraceRow(body) {
                    tracesByTurnID[parsed.turnID] = CodexTurnBillingTrace(
                        tier: parsed.tier,
                        source: parsed.source,
                        modelId: parsed.modelID,
                        timestamp: timestamp)
                    continue
                }

                guard let completed = Self.parseCompletedTraceRow(body),
                      var existing = tracesByTurnID[completed.turnID],
                      existing.modelId == nil,
                      let modelID = completed.modelID
                else {
                    continue
                }
                existing = CodexTurnBillingTrace(
                    tier: existing.tier,
                    source: existing.source,
                    modelId: modelID,
                    timestamp: existing.timestamp ?? timestamp)
                tracesByTurnID[completed.turnID] = existing
            case SQLITE_DONE:
                return CodexTurnBillingLookup(available: true, tracesByTurnID: tracesByTurnID)
            default:
                throw TraceStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        #else
        return .unavailable
        #endif
    }

    private static func parseRequestTraceRow(_ body: String) -> ParsedTrace? {
        let marker = "websocket request:"
        guard let markerRange = body.range(of: marker) else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let jsonObject = extractJSONObject(from: jsonText),
            let data = jsonObject.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            decoded["type"] as? String == "response.create",
            let classification = billingClassification(
                from: decoded["service_tier"] as? String
                    ?? decoded["preferred_service_tier"] as? String)
        else {
            return nil
        }

        let turnID = turnIDFromPrefix(prefix) ?? turnIDFromJSON(decoded)
        guard let turnID else { return nil }

        return ParsedTrace(
            turnID: turnID,
            tier: classification.tier,
            source: classification.source,
            modelID: decoded["model"] as? String)
    }

    private static func parseCompletedTraceRow(_ body: String) -> CompletedTrace? {
        let marker = "websocket event:"
        guard let markerRange = body.range(of: marker) else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let jsonObject = extractJSONObject(from: jsonText),
            let data = jsonObject.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            decoded["type"] as? String == "response.completed"
        else {
            return nil
        }

        let response = decoded["response"] as? [String: Any]
        let turnID = turnIDFromPrefix(prefix) ?? turnIDFromJSON(decoded) ?? response.flatMap(turnIDFromJSON)
        guard let turnID else { return nil }

        return CompletedTrace(
            turnID: turnID,
            modelID: response?["model"] as? String ?? decoded["model"] as? String)
    }

    private static func billingClassification(
        from rawValue: String?
    ) -> (tier: CodexBillingTier, source: CodexBillingTierSource)? {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else { return nil }

        switch normalized {
        case "fast", "priority":
            return (.fast, .trace)
        case "default", "standard":
            return (.standard, .trace)
        case "auto", "flex", "scale":
            return (.unknown, .traceUnsupported)
        default:
            return (.unknown, .traceUnsupported)
        }
    }

    private static func turnIDFromPrefix(_ prefix: String) -> String? {
        for key in ["turn.id", "turn_id", "turnId"] {
            if let value = prefixedValue(in: prefix, key: key) {
                return value
            }
        }
        return nil
    }

    private static func prefixedValue(in text: String, key: String) -> String? {
        var searchStart = text.startIndex
        while let keyRange = text.range(of: key, range: searchStart..<text.endIndex) {
            guard hasKeyBoundaryBefore(keyRange.lowerBound, in: text) else {
                searchStart = keyRange.upperBound
                continue
            }

            let separatorIndex = keyRange.upperBound
            guard separatorIndex < text.endIndex else { return nil }
            let separator = text[separatorIndex]
            guard separator == "=" || separator == ":" else {
                searchStart = keyRange.upperBound
                continue
            }

            let valueStart = text.index(after: separatorIndex)
            let valueEnd = text[valueStart...].firstIndex { !isTurnIDCharacter($0) } ?? text.endIndex
            if valueStart < valueEnd {
                return String(text[valueStart..<valueEnd])
            }

            searchStart = valueStart
        }
        return nil
    }

    private static func hasKeyBoundaryBefore(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let precedingCharacter = text[text.index(before: index)]
        return !isIdentifierishCharacter(precedingCharacter)
    }

    private static func turnIDFromJSON(_ object: [String: Any]) -> String? {
        for key in ["turn_id", "turnId"] {
            guard
                let value = object[key] as? String,
                !value.isEmpty,
                value.allSatisfy(isTurnIDCharacter)
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func isTurnIDCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    private static func isIdentifierishCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaping = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private struct ParsedTrace {
        let turnID: String
        let tier: CodexBillingTier
        let source: CodexBillingTierSource
        let modelID: String?
    }

    private struct CompletedTrace {
        let turnID: String
        let modelID: String?
    }

    private enum TraceStoreError: LocalizedError {
        case openFailed(String?)
        case prepareFailed(String)
        case bindFailed(parameter: String, message: String)
        case stepFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message):
                return "Failed to open Codex service tier trace database: \(message ?? "unknown SQLite error")"
            case .prepareFailed(let message):
                return "Failed to prepare Codex service tier trace query: \(message)"
            case .bindFailed(let parameter, let message):
                return "Failed to bind \(parameter) for Codex service tier trace query: \(message)"
            case .stepFailed(let message):
                return "Failed to read Codex service tier trace rows: \(message)"
            }
        }
    }
}
