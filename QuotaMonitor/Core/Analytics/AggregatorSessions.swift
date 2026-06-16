import Foundation
import GRDB

// Sessions list, session detail, and direct-child subagent queries.

extension Aggregator {

    static func fetchSessions(
        db: Database,
        sort: SessionSort = .recent,
        search: String = "",
        provider: ProviderFilter = .all,
        limit: Int = 500
    ) throws -> [SessionRow] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearch = !trimmed.isEmpty
        let pattern = "%\(trimmed.lowercased())%"

        var sql = """
        SELECT
          s.session_id,
          s.title,
          s.project_name,
          s.cwd,
          s.agent_nickname,
          s.last_model_id,
          s.started_at,
          s.updated_at,
          s.contains_subagents,
          COALESCE(SUM(ue.value_usd), 0)        AS total_value,
          COALESCE(SUM(ue.total_tokens), 0)     AS total_tokens,
          COUNT(ue.id)                          AS event_count,
          COALESCE(MAX(ue.model_inferred), 0)   AS has_inferred_model
        FROM sessions s
        LEFT JOIN usage_events ue ON ue.session_id = s.session_id
        """
        var args: [(any DatabaseValueConvertible)?] = []
        // Stitch together the provider + search WHERE clauses.
        var predicates: [String] = []
        switch provider {
        case .all: break
        case .codex:  predicates.append("s.provider = 'codex'")
        case .claude: predicates.append("s.provider = 'claude'")
        }
        if hasSearch {
            predicates.append("""
                (LOWER(COALESCE(s.title,''))          LIKE ?
              OR LOWER(COALESCE(s.project_name,''))   LIKE ?
              OR LOWER(COALESCE(s.cwd,''))            LIKE ?
              OR LOWER(COALESCE(s.agent_nickname,'')) LIKE ?
              OR LOWER(COALESCE(s.last_model_id,''))  LIKE ?
              OR LOWER(s.session_id)                  LIKE ?)
            """)
            args.append(contentsOf: Array(repeating: pattern, count: 6))
        }
        if !predicates.isEmpty {
            sql += "\nWHERE " + predicates.joined(separator: " AND ")
        }
        sql += """

        GROUP BY s.session_id
        ORDER BY \(sort.orderClause)
        LIMIT \(limit)
        """

        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            .map { row in
                SessionRow(
                    sessionId: row["session_id"] ?? "",
                    title: row["title"],
                    projectName: row["project_name"],
                    cwd: row["cwd"],
                    agentNickname: row["agent_nickname"],
                    lastModelId: row["last_model_id"],
                    startedAt: row["started_at"],
                    updatedAt: row["updated_at"],
                    totalValueUSD: row["total_value"] ?? 0,
                    totalTokens: row["total_tokens"] ?? 0,
                    eventCount: row["event_count"] ?? 0,
                    containsSubagents: row["contains_subagents"] ?? false,
                    subagentCount: nil,
                    hasInferredModel: row["has_inferred_model"] ?? false)
            }
    }

    static func fetchSessionDetail(db: Database, sessionId: String) throws -> SessionDetail? {
        let headerRow = try Row.fetchOne(db, sql: """
            SELECT
              s.session_id,
              s.title,
              s.project_name,
              s.cwd,
              s.agent_nickname,
              s.last_model_id,
              s.started_at,
              s.updated_at,
              s.contains_subagents,
              COALESCE(SUM(ue.value_usd), 0)        AS total_value,
              COALESCE(SUM(ue.total_tokens), 0)     AS total_tokens,
              COUNT(ue.id)                          AS event_count,
              COALESCE(MAX(ue.model_inferred), 0)   AS has_inferred_model
            FROM sessions s
            LEFT JOIN usage_events ue ON ue.session_id = s.session_id
            WHERE s.session_id = ?
            GROUP BY s.session_id
            """, arguments: [sessionId])
        guard let headerRow else { return nil }

        let subagents = try fetchSubagents(db: db, parentSessionId: sessionId)

        let header = SessionRow(
            sessionId: headerRow["session_id"] ?? "",
            title: headerRow["title"],
            projectName: headerRow["project_name"],
            cwd: headerRow["cwd"],
            agentNickname: headerRow["agent_nickname"],
            lastModelId: headerRow["last_model_id"],
            startedAt: headerRow["started_at"],
            updatedAt: headerRow["updated_at"],
            totalValueUSD: headerRow["total_value"] ?? 0,
            totalTokens: headerRow["total_tokens"] ?? 0,
            eventCount: headerRow["event_count"] ?? 0,
            containsSubagents: headerRow["contains_subagents"] ?? false,
            subagentCount: subagents.count,
            hasInferredModel: headerRow["has_inferred_model"] ?? false)

        let events = try Row.fetchAll(db, sql: """
            SELECT id, timestamp, provider, model_id,
                   input_tokens, cached_input_tokens,
                   cache_creation_5m_tokens, cache_creation_1h_tokens,
                   output_tokens, reasoning_output_tokens,
                   total_tokens, value_usd, model_inferred
            FROM usage_events
            WHERE session_id = ?
            ORDER BY timestamp ASC, id ASC
            """, arguments: [sessionId]).map { row in
            SessionDetail.Event(
                id: row["id"] ?? 0,
                timestamp: row["timestamp"] ?? "",
                provider: row["provider"] ?? "codex",
                modelId: row["model_id"] ?? "unknown",
                inputTokens: row["input_tokens"] ?? 0,
                cachedInputTokens: row["cached_input_tokens"] ?? 0,
                cacheCreation5mTokens: row["cache_creation_5m_tokens"] ?? 0,
                cacheCreation1hTokens: row["cache_creation_1h_tokens"] ?? 0,
                outputTokens: row["output_tokens"] ?? 0,
                reasoningOutputTokens: row["reasoning_output_tokens"] ?? 0,
                totalTokens: row["total_tokens"] ?? 0,
                valueUSD: row["value_usd"] ?? 0,
                modelInferred: row["model_inferred"] ?? false)
        }

        let breakdown = try Row.fetchAll(db, sql: """
            SELECT
              ue.model_id,
              COALESCE(pc.display_name, ue.model_id) AS display_name,
              SUM(ue.value_usd)     AS value_usd,
              SUM(ue.total_tokens)  AS tokens,
              COUNT(*)              AS event_count
            FROM usage_events ue
            LEFT JOIN pricing_catalog pc ON pc.model_id = ue.model_id
            WHERE ue.session_id = ?
            GROUP BY ue.model_id
            ORDER BY value_usd DESC
            """, arguments: [sessionId]).map { row in
            ModelShare(
                modelId: row["model_id"] ?? "unknown",
                displayName: row["display_name"] ?? "Unknown",
                valueUSD: row["value_usd"] ?? 0,
                tokens: row["tokens"] ?? 0,
                eventCount: row["event_count"] ?? 0)
        }

        return SessionDetail(
            header: header,
            events: events,
            modelBreakdown: breakdown,
            subagents: subagents)
    }

    /// Direct-child subagent sessions of `parentSessionId`, with totals and
    /// event counts. Ordered by most-recently-active first.
    static func fetchSubagents(
        db: Database, parentSessionId: String
    ) throws -> [SessionRow] {
        try Row.fetchAll(db, sql: """
            SELECT
              s.session_id,
              s.title,
              s.project_name,
              s.cwd,
              s.agent_nickname,
              s.last_model_id,
              s.started_at,
              s.updated_at,
              s.contains_subagents,
              COALESCE(SUM(ue.value_usd), 0)        AS total_value,
              COALESCE(SUM(ue.total_tokens), 0)     AS total_tokens,
              COUNT(ue.id)                          AS event_count,
              COALESCE(MAX(ue.model_inferred), 0)   AS has_inferred_model
            FROM sessions s
            LEFT JOIN usage_events ue ON ue.session_id = s.session_id
            WHERE s.parent_session_id = ?
            GROUP BY s.session_id
            ORDER BY COALESCE(s.updated_at, s.started_at) DESC
            """, arguments: [parentSessionId]).map { row in
            SessionRow(
                sessionId: row["session_id"] ?? "",
                title: row["title"],
                projectName: row["project_name"],
                cwd: row["cwd"],
                agentNickname: row["agent_nickname"],
                lastModelId: row["last_model_id"],
                startedAt: row["started_at"],
                updatedAt: row["updated_at"],
                totalValueUSD: row["total_value"] ?? 0,
                totalTokens: row["total_tokens"] ?? 0,
                eventCount: row["event_count"] ?? 0,
                containsSubagents: row["contains_subagents"] ?? false,
                subagentCount: nil,
                hasInferredModel: row["has_inferred_model"] ?? false)
        }
    }
}
