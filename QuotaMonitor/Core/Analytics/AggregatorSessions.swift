import Foundation
import GRDB

// Sessions list, session detail, and direct-child subagent queries.

private struct SessionPageCandidate {
    let row: SessionRow
    let cursor: SessionPageCursor
}

extension Aggregator {

    static func fetchSessionsPage(
        db: Database,
        sort: SessionSort = .recent,
        search: String = "",
        provider: ProviderFilter = .all,
        after cursor: SessionPageCursor? = nil,
        pageSize: Int = 50
    ) throws -> SessionPage {
        precondition(pageSize > 0 && pageSize < Int.max)
        let candidates = try fetchSessionCandidates(
            db: db,
            sort: sort,
            search: search,
            provider: provider,
            after: cursor,
            limit: pageSize + 1)
        let hasMore = candidates.count > pageSize
        let pageCandidates = Array(candidates.prefix(pageSize))
        return SessionPage(
            rows: pageCandidates.map(\.row),
            nextCursor: hasMore ? pageCandidates.last?.cursor : nil)
    }

    static func fetchSessions(
        db: Database,
        sort: SessionSort = .recent,
        search: String = "",
        provider: ProviderFilter = .all,
        limit: Int = 500
    ) throws -> [SessionRow] {
        precondition(limit > 0)
        return try fetchSessionCandidates(
            db: db,
            sort: sort,
            search: search,
            provider: provider,
            after: nil,
            limit: limit
        ).map(\.row)
    }

    static func makeSessionsPageQuery(
        sort: SessionSort,
        search: String,
        provider: ProviderFilter,
        after cursor: SessionPageCursor?,
        limit: Int
    ) throws -> (sql: String, arguments: StatementArguments) {
        precondition(limit > 0)
        guard cursor == nil || cursor?.sort == sort else {
            throw SessionPaginationError.cursorSortMismatch
        }

        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "%\(trimmed.lowercased())%"
        let searchArguments = Array(repeating: pattern, count: 6)

        let pageIndex: String
        let orderClause: String
        switch sort {
        case .recent:
            pageIndex = "idx_session_summaries_recent_page"
            orderClause = "activity_at DESC, session_id ASC"
        case .value:
            pageIndex = "idx_session_summaries_value_page"
            orderClause = "total_value DESC, session_id ASC"
        case .tokens:
            pageIndex = "idx_session_summaries_tokens_page"
            orderClause = "total_tokens DESC, session_id ASC"
        }

        var basePredicates: [String] = []
        switch provider {
        case .all: break
        case .codex: basePredicates.append("s.provider = 'codex'")
        case .claude: basePredicates.append("s.provider = 'claude'")
        }
        if !trimmed.isEmpty {
            basePredicates.append("""
                (LOWER(COALESCE(s.title,''))          LIKE ?
              OR LOWER(COALESCE(s.project_name,''))   LIKE ?
              OR LOWER(COALESCE(s.cwd,''))            LIKE ?
              OR LOWER(COALESCE(s.agent_nickname,'')) LIKE ?
              OR LOWER(COALESCE(s.last_model_id,''))  LIKE ?
              OR LOWER(s.session_id)                  LIKE ?)
            """)
        }

        func selectBranch(cursorPredicate: String? = nil) -> String {
            var predicates = basePredicates
            if let cursorPredicate {
                predicates.append(cursorPredicate)
            }
            let whereClause = predicates.isEmpty
                ? ""
                : "\nWHERE " + predicates.joined(separator: " AND ")
            return """
                SELECT
                  ss.session_id AS session_id,
                  s.title,
                  s.project_name,
                  s.cwd,
                  s.agent_nickname,
                  s.last_model_id,
                  s.started_at,
                  s.updated_at,
                  s.contains_subagents,
                  ss.activity_at                       AS activity_at,
                  ss.total_value_usd                   AS total_value,
                  ss.total_tokens                      AS total_tokens,
                  ss.event_count                       AS event_count,
                  ss.has_inferred_model                AS has_inferred_model
                FROM session_summaries ss INDEXED BY \(pageIndex)
                JOIN sessions s ON s.session_id = ss.session_id\(whereClause)
                """
        }

        var args: [(any DatabaseValueConvertible)?] = []
        let sql: String
        if let cursor {
            let lowerPredicate: String
            let tiedPredicate: String
            if !trimmed.isEmpty {
                args.append(contentsOf: searchArguments)
            }
            switch cursor {
            case .recent(let activityAt, let sessionId):
                lowerPredicate = "ss.activity_at < ?"
                tiedPredicate = "ss.activity_at = ? AND ss.session_id > ?"
                args.append(activityAt)
                if !trimmed.isEmpty {
                    args.append(contentsOf: searchArguments)
                }
                args.append(activityAt)
                args.append(sessionId)
            case .value(let totalValueUSD, let sessionId):
                lowerPredicate = "ss.total_value_usd < ?"
                tiedPredicate = "ss.total_value_usd = ? AND ss.session_id > ?"
                args.append(totalValueUSD)
                if !trimmed.isEmpty {
                    args.append(contentsOf: searchArguments)
                }
                args.append(totalValueUSD)
                args.append(sessionId)
            case .tokens(let totalTokens, let sessionId):
                lowerPredicate = "ss.total_tokens < ?"
                tiedPredicate = "ss.total_tokens = ? AND ss.session_id > ?"
                args.append(totalTokens)
                if !trimmed.isEmpty {
                    args.append(contentsOf: searchArguments)
                }
                args.append(totalTokens)
                args.append(sessionId)
            }
            sql = """
                \(selectBranch(cursorPredicate: lowerPredicate))
                UNION ALL
                \(selectBranch(cursorPredicate: tiedPredicate))
                ORDER BY \(orderClause)
                LIMIT ?
                """
        } else {
            if !trimmed.isEmpty {
                args.append(contentsOf: searchArguments)
            }
            sql = """
                \(selectBranch())
                ORDER BY \(orderClause)
                LIMIT ?
                """
        }
        args.append(limit)
        return (sql, StatementArguments(args))
    }

    private static func fetchSessionCandidates(
        db: Database,
        sort: SessionSort,
        search: String,
        provider: ProviderFilter,
        after cursor: SessionPageCursor?,
        limit: Int
    ) throws -> [SessionPageCandidate] {
        let query = try makeSessionsPageQuery(
            sort: sort,
            search: search,
            provider: provider,
            after: cursor,
            limit: limit)
        return try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
            .map { row in
                let sessionId: String = row["session_id"] ?? ""
                let totalValueUSD: Double = row["total_value"] ?? 0
                let totalTokens: Int64 = row["total_tokens"] ?? 0
                let pageCursor: SessionPageCursor
                switch sort {
                case .recent:
                    pageCursor = .recent(
                        activityAt: row["activity_at"] ?? "",
                        sessionId: sessionId)
                case .value:
                    pageCursor = .value(
                        totalValueUSD: totalValueUSD,
                        sessionId: sessionId)
                case .tokens:
                    pageCursor = .tokens(
                        totalTokens: totalTokens,
                        sessionId: sessionId)
                }
                return SessionPageCandidate(
                    row: SessionRow(
                        sessionId: sessionId,
                        title: row["title"],
                        projectName: row["project_name"],
                        cwd: row["cwd"],
                        agentNickname: row["agent_nickname"],
                        lastModelId: row["last_model_id"],
                        startedAt: row["started_at"],
                        updatedAt: row["updated_at"],
                        totalValueUSD: totalValueUSD,
                        totalTokens: totalTokens,
                        eventCount: row["event_count"] ?? 0,
                        containsSubagents: row["contains_subagents"] ?? false,
                        subagentCount: nil,
                        hasInferredModel: row["has_inferred_model"] ?? false),
                    cursor: pageCursor)
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
                   cache_creation_tokens,
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
                cacheWriteInputTokens: row["cache_creation_tokens"] ?? 0,
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
