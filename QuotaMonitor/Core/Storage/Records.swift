import Foundation
import GRDB

// GRDB Record types. These are the row shape — domain models in `Core/Models/`
// can hold richer derived values, but writes/reads go through these structs.

struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "sessions"

    var sessionId: String
    var rootSessionId: String
    var parentSessionId: String?
    var title: String?
    var projectName: String?
    var cwd: String?
    var sourcePath: String?
    var startedAt: String?
    var updatedAt: String?
    var agentNickname: String?
    var agentRole: String?
    var lastModelId: String?
    var latestPlanType: String?
    var containsSubagents: Bool
    var createdAt: String
    var importedAt: String
    var provider: String        // 'codex' | 'claude'

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case rootSessionId = "root_session_id"
        case parentSessionId = "parent_session_id"
        case title
        case projectName = "project_name"
        case cwd
        case sourcePath = "source_path"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case agentNickname = "agent_nickname"
        case agentRole = "agent_role"
        case lastModelId = "last_model_id"
        case latestPlanType = "latest_plan_type"
        case containsSubagents = "contains_subagents"
        case createdAt = "created_at"
        case importedAt = "imported_at"
        case provider
    }
}

struct UsageEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usage_events"

    var id: Int64?
    var sessionId: String
    var timestamp: String
    var modelId: String
    var inputTokens: Int64
    var cachedInputTokens: Int64
    var outputTokens: Int64
    var reasoningOutputTokens: Int64
    var totalTokens: Int64
    var valueUsd: Double
    var cacheCreationTokens: Int64    // Claude-only; 0 for Codex
    var cacheCreation5mTokens: Int64 = 0
    var cacheCreation1hTokens: Int64 = 0
    var provider: String              // 'codex' | 'claude'
    var modelInferred: Bool           // true when parser fell back to gpt-5
    /// Stable per-message dedup key; today only Claude (`message.id`).
    /// `nil` for Codex events. The partial unique index in v5 keys off
    /// `(session_id, provider_message_id)` so re-parsing the tail of a
    /// rollout during an incremental scan can `INSERT OR IGNORE` cleanly.
    var providerMessageId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case timestamp
        case modelId = "model_id"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
        case valueUsd = "value_usd"
        case cacheCreationTokens = "cache_creation_tokens"
        case cacheCreation5mTokens = "cache_creation_5m_tokens"
        case cacheCreation1hTokens = "cache_creation_1h_tokens"
        case provider
        case modelInferred = "model_inferred"
        case providerMessageId = "provider_message_id"
    }
}

struct ImportStateRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "import_state"

    var sourcePath: String
    var sessionId: String?
    var fileSize: Int64
    var fileMtimeMs: Int64
    var lastImportedAt: String
    /// Last byte offset successfully consumed by the parser. Default 0
    /// (back-compatible with v4 rows) means "next scan starts from
    /// the beginning of the file." Bumped on every successful persist.
    var byteOffset: Int64

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case sessionId = "session_id"
        case fileSize = "file_size"
        case fileMtimeMs = "file_mtime_ms"
        case lastImportedAt = "last_imported_at"
        case byteOffset = "byte_offset"
    }
}

struct RateLimitSampleRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "rate_limit_samples"

    var id: Int64?
    var sourceKind: String          // "jsonl", "live", or "claude_oauth"
    var sourceSessionId: String?
    var bucket: String              // semantic "primary" (5h) or "secondary" (7d)
    var sampleTimestamp: String
    var planType: String?
    var limitName: String?
    var windowStart: String?        // Codex writers preserve reset - duration here
    var resetsAt: String
    var usedPercent: Double
    var remainingPercent: Double

    enum CodingKeys: String, CodingKey {
        case id
        case sourceKind = "source_kind"
        case sourceSessionId = "source_session_id"
        case bucket
        case sampleTimestamp = "sample_timestamp"
        case planType = "plan_type"
        case limitName = "limit_name"
        case windowStart = "window_start"
        case resetsAt = "resets_at"
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
    }
}
