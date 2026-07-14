import Foundation

// Wire model for one line of a `rollout-*.jsonl` file.
//
// Each line is `{"timestamp": "...", "type": "...", "payload": {...}}`.
// We discriminate on `type` and lazily decode `payload` only for the cases we care about.
// Any unknown `type` yields `.other(type:)` — the parser logs and skips.

enum RolloutEvent {
    case sessionMeta(SessionMetaPayload, timestamp: String?)
    case turnContext(TurnContextPayload, timestamp: String?)
    case threadSettingsApplied(ThreadSettingsAppliedPayload, timestamp: String?)
    case taskStarted(TaskLifecyclePayload, timestamp: String?)
    case taskComplete(TaskLifecyclePayload, timestamp: String?)
    case tokenCount(TokenCountPayload, timestamp: String?)
    case other(type: String, timestamp: String?)
}

// MARK: - session_meta

struct SessionMetaPayload: Decodable {
    let id: String?
    let timestamp: String?
    let cwd: String?
    let originator: String?
    let cliVersion: String?
    let source: JSONValue?      // sometimes nested with subagent thread_spawn info
    let parentSessionId: String?
    let forkedFromId: String?
    let agentNickname: String?
    let agentRole: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, cwd, originator, source
        case cliVersion = "cli_version"
        case parentSessionId = "parent_session_id"
        case forkedFromId = "forked_from_id"
        case agentNickname = "agent_nickname"
        case agentRole = "agent_role"
    }

    /// Resolved parent id, preferring (in order):
    ///   1. `parent_session_id`
    ///   2. `forked_from_id`
    ///   3. nested `source.subagent.thread_spawn.parent_thread_id`
    /// Mirrors codex-pacer's `importer.rs` behavior.
    var resolvedParentSessionId: String? {
        if let p = parentSessionId, !p.isEmpty { return p }
        if let f = forkedFromId, !f.isEmpty { return f }
        return threadSpawn?["parent_thread_id"].flatMap(Self.string)
    }

    /// Effective nickname: top-level wins, else nested under thread_spawn.
    var resolvedAgentNickname: String? {
        if let n = agentNickname, !n.isEmpty { return n }
        return threadSpawn?["agent_nickname"].flatMap(Self.string)
    }

    /// Effective role: top-level wins, else nested under thread_spawn.
    var resolvedAgentRole: String? {
        if let r = agentRole, !r.isEmpty { return r }
        return threadSpawn?["agent_role"].flatMap(Self.string)
    }

    private var threadSpawn: [String: JSONValue]? {
        guard case .object(let obj) = source ?? .null,
              case .object(let sub) = obj["subagent"] ?? .null,
              case .object(let spawn) = sub["thread_spawn"] ?? .null
        else { return nil }
        return spawn
    }

    private static func string(_ v: JSONValue) -> String? {
        if case .string(let s) = v, !s.isEmpty { return s }
        return nil
    }
}

// MARK: - turn_context

struct TurnContextPayload: Decodable {
    let model: String?
    let turnId: String?

    enum CodingKeys: String, CodingKey {
        case model
        case turnId = "turn_id"
    }
}

// MARK: - event_msg

struct TaskLifecyclePayload: Decodable {
    let turnId: String?

    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
    }
}

struct ThreadSettingsAppliedPayload: Decodable {
    struct ThreadSettings: Decodable {
        let serviceTier: String?

        enum CodingKeys: String, CodingKey {
            case serviceTier = "service_tier"
        }
    }

    let threadSettings: ThreadSettings?
    let serviceTier: String?

    enum CodingKeys: String, CodingKey {
        case threadSettings = "thread_settings"
        case serviceTier = "service_tier"
    }

    var resolvedServiceTier: String? {
        threadSettings?.serviceTier ?? serviceTier
    }
}

// MARK: - event_msg / token_count

struct TokenCountPayload: Decodable {
    let info: TokenCountInfo?
    let rateLimits: EmbeddedRateLimits?
    /// Defensive: future Codex builds (or third-party recorders) may stamp the
    /// model id directly on the token_count payload. Today's CLI puts it on
    /// `turn_context` only.
    let model: String?
    let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case info, model, metadata
        case rateLimits = "rate_limits"
    }
}

struct TokenCountInfo: Decodable {
    let totalTokenUsage: TokenUsageWire?
    let lastTokenUsage: TokenUsageWire?
    let modelContextWindow: Int?
    /// Same defensive extraction as `TokenCountPayload`. ccusage scrapes these
    /// keys on every event; we do the same so we don't silently lose model
    /// attribution if Codex starts populating them.
    let model: String?
    let modelName: String?
    let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
        case modelContextWindow = "model_context_window"
        case model
        case modelName = "model_name"
        case metadata
    }
}

struct TokenUsageWire: Decodable, Equatable, Hashable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    static let zero = TokenUsageWire(
        inputTokens: 0, cachedInputTokens: 0,
        outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)
}

// Embedded in token_count events. Note this schema is DIFFERENT from the
// app-server's `account/rateLimits/read` shape — uses `window_minutes`
// and `resets_at` (epoch seconds) instead of `limit_window_seconds`.
struct EmbeddedRateLimits: Decodable {
    let primary: Window?
    let secondary: Window?
    let planType: String?
    let limitId: String?
    let limitName: String?

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case planType = "plan_type"
        case limitId = "limit_id"
        case limitName = "limit_name"
    }
}

// MARK: - decoder dispatch

extension RolloutEvent {
    /// Decode one jsonl line. Returns nil if the line is empty or unparseable;
    /// returns `.other` for unknown discriminators.
    static func decode(line: Data) -> RolloutEvent? {
        guard !line.isEmpty else { return nil }
        guard let type = RolloutLineScanner.stringValue(forKey: "type", in: line) else {
            return nil
        }
        let timestamp = RolloutLineScanner.stringValue(forKey: "timestamp", in: line)
        let decoder = JSONDecoder()

        switch type {
        case "session_meta":
            guard let data = RolloutLineScanner.objectValue(forKey: "payload", in: line),
                  let meta = try? decoder.decode(SessionMetaPayload.self, from: data)
            else { return .other(type: type, timestamp: timestamp) }
            return .sessionMeta(meta, timestamp: timestamp)

        case "turn_context":
            guard let data = RolloutLineScanner.objectValue(forKey: "payload", in: line),
                  let tc = try? decoder.decode(TurnContextPayload.self, from: data)
            else { return .other(type: type, timestamp: timestamp) }
            return .turnContext(tc, timestamp: timestamp)

        case "event_msg":
            guard let data = RolloutLineScanner.objectValue(forKey: "payload", in: line),
                  let nestedType = RolloutLineScanner.stringValue(forKey: "type", in: data)
            else { return .other(type: type, timestamp: timestamp) }

            switch nestedType {
            case "thread_settings_applied":
                guard let payload = try? decoder.decode(
                    ThreadSettingsAppliedPayload.self,
                    from: data)
                else { return .other(type: type, timestamp: timestamp) }
                return .threadSettingsApplied(payload, timestamp: timestamp)

            case "task_started":
                guard let payload = try? decoder.decode(TaskLifecyclePayload.self, from: data)
                else { return .other(type: type, timestamp: timestamp) }
                return .taskStarted(payload, timestamp: timestamp)

            case "task_complete":
                guard let payload = try? decoder.decode(TaskLifecyclePayload.self, from: data)
                else { return .other(type: type, timestamp: timestamp) }
                return .taskComplete(payload, timestamp: timestamp)

            case "token_count":
                guard let payload = try? decoder.decode(TokenCountPayload.self, from: data)
                else { return .other(type: type, timestamp: timestamp) }
                return .tokenCount(payload, timestamp: timestamp)

            default:
                return .other(type: type, timestamp: timestamp)
            }

        default:
            return .other(type: type, timestamp: timestamp)
        }
    }
}

private enum RolloutLineScanner {
    static func stringValue(forKey key: String, in data: Data) -> String? {
        guard let range = valueRange(forKey: key, in: data),
              range.lowerBound < range.upperBound,
              data[range.lowerBound] == quote
        else { return nil }
        return decodeStringLiteral(range, in: data)
    }

    static func objectValue(forKey key: String, in data: Data) -> Data? {
        guard let range = valueRange(forKey: key, in: data),
              range.lowerBound < range.upperBound,
              data[range.lowerBound] == openBrace
        else { return nil }
        return data.subdata(in: range)
    }

    private static func valueRange(forKey key: String, in data: Data) -> Range<Int>? {
        let keyBytes = Array(key.utf8)
        return data.withUnsafeBytes { raw -> Range<Int>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            let count = raw.count
            var index = skipWhitespace(base, 0, count)
            guard index < count, base[index] == openBrace else { return nil }
            index += 1

            while index < count {
                index = skipWhitespaceAndCommas(base, index, count)
                if index >= count || base[index] == closeBrace { return nil }
                guard let keyLiteral = scanString(base, index, count) else { return nil }
                let keyMatches = !keyLiteral.hadEscape
                    && bytesEqual(base, keyLiteral.content, keyBytes)
                index = skipWhitespace(base, keyLiteral.next, count)
                guard index < count, base[index] == colon else { return nil }
                index = skipWhitespace(base, index + 1, count)
                guard let valueEnd = skipValue(base, index, count) else { return nil }
                if keyMatches { return index..<valueEnd }
                index = valueEnd
            }
            return nil
        }
    }

    private static func decodeStringLiteral(_ range: Range<Int>, in data: Data) -> String? {
        let literal = data.subdata(in: range)
        if literal.contains(backslash) {
            return try? JSONDecoder().decode(String.self, from: literal)
        }
        guard range.count >= 2 else { return nil }
        return String(decoding: data[(range.lowerBound + 1)..<(range.upperBound - 1)],
                      as: UTF8.self)
    }

    private static func scanString(
        _ base: UnsafePointer<UInt8>, _ start: Int, _ count: Int
    ) -> (content: Range<Int>, literal: Range<Int>, hadEscape: Bool, next: Int)? {
        guard start < count, base[start] == quote else { return nil }
        var index = start + 1
        var escaped = false
        var hadEscape = false
        while index < count {
            let byte = base[index]
            if escaped {
                escaped = false
            } else if byte == backslash {
                hadEscape = true
                escaped = true
            } else if byte == quote {
                return ((start + 1)..<index, start..<(index + 1), hadEscape, index + 1)
            }
            index += 1
        }
        return nil
    }

    private static func skipValue(
        _ base: UnsafePointer<UInt8>, _ start: Int, _ count: Int
    ) -> Int? {
        guard start < count else { return nil }
        switch base[start] {
        case quote:
            return scanString(base, start, count)?.next
        case openBrace, openBracket:
            var depth = 0
            var index = start
            while index < count {
                switch base[index] {
                case quote:
                    guard let str = scanString(base, index, count) else { return nil }
                    index = str.next
                    continue
                case openBrace, openBracket:
                    depth += 1
                case closeBrace, closeBracket:
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < count {
                switch base[index] {
                case comma, closeBrace, closeBracket:
                    return index
                default:
                    index += 1
                }
            }
            return index
        }
    }

    private static func skipWhitespace(
        _ base: UnsafePointer<UInt8>, _ start: Int, _ count: Int
    ) -> Int {
        var index = start
        while index < count, isWhitespace(base[index]) { index += 1 }
        return index
    }

    private static func skipWhitespaceAndCommas(
        _ base: UnsafePointer<UInt8>, _ start: Int, _ count: Int
    ) -> Int {
        var index = start
        while index < count, isWhitespace(base[index]) || base[index] == comma {
            index += 1
        }
        return index
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private static func bytesEqual(
        _ base: UnsafePointer<UInt8>, _ range: Range<Int>, _ expected: [UInt8]
    ) -> Bool {
        guard range.count == expected.count else { return false }
        for offset in 0..<expected.count {
            if base[range.lowerBound + offset] != expected[offset] {
                return false
            }
        }
        return true
    }

    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let colon: UInt8 = 0x3A
    private static let comma: UInt8 = 0x2C
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
}
