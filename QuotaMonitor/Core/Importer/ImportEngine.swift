import Foundation
import GRDB

// Orchestrates: scan → diff against import_state → parse changed files →
// upsert sessions / append usage_events / append rate_limit_samples.
//
// Idempotency: if a file's (size, mtime) hasn't changed, it's skipped. If the
// file grew (in-progress session being appended to), we re-parse the whole file
// and rewrite that session's usage_events to keep deltas consistent. This is
// simpler than tracking a byte offset and is fine for files of this size.

actor ImportEngine {
    private let database: DatabaseManager
    private let codexHome: URL

    struct ScanReport: Sendable {
        let scannedFiles: Int
        let changedFiles: Int
        let importedSessions: Int
        let importedEvents: Int
        let importedRateLimitSamples: Int
        let errors: [String]

        static let empty = ScanReport(
            scannedFiles: 0, changedFiles: 0,
            importedSessions: 0, importedEvents: 0,
            importedRateLimitSamples: 0, errors: [])
    }

    init(database: DatabaseManager, codexHome: URL = SessionScanner.defaultCodexHome()) {
        self.database = database
        self.codexHome = codexHome
    }

    func performScan() async throws -> ScanReport {
        // Seed pricing once per scan so freshly-added models pick up prices on relaunch.
        try await database.pool.write { db in
            try PricingService.seedCatalog(in: db)
        }

        let files = SessionScanner.scan(codexHome: codexHome)
        let priorState: [String: ImportStateRecord] = try await database.pool.read { db in
            let rows = try ImportStateRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sourcePath, $0) })
        }

        // Source paths of Codex sessions still missing a title — re-parse them
        // so the cwd-derived title fallback added later can backfill UI labels
        // without waiting for the file to change.
        let titlelessCodexPaths: Set<String> = try await database.pool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT source_path FROM sessions
                WHERE provider = 'codex'
                  AND (title IS NULL OR title = '')
                  AND source_path IS NOT NULL
                """)
            return Set(rows)
        }

        let changed = files.filter { file in
            if titlelessCodexPaths.contains(file.path) { return true }
            guard let prior = priorState[file.path] else { return true }
            return prior.fileSize != file.fileSize || prior.fileMtimeMs != file.fileMtimeMs
        }

        var importedSessions = 0
        var importedEvents = 0
        var importedSamples = 0
        var errors: [String] = []

        for file in changed {
            do {
                guard let parsed = try RolloutParser.parse(
                    fileURL: file.url,
                    fallbackSessionId: file.sessionIdHint
                ) else {
                    errors.append("no session id resolved: \(file.path)")
                    continue
                }

                let counts = try await persist(parsed: parsed, file: file)
                importedSessions += 1
                importedEvents += counts.events
                importedSamples += counts.samples
            } catch {
                errors.append("\(file.path): \(error)")
            }
        }

        // After all files are persisted, walk the parent chain to compute
        // root_session_id and contains_subagents for every Codex session.
        // Cheap (single pass, all in one transaction) and idempotent.
        try await reconcileSessionTree()

        // NOTE: PricingService.backfillAllValues is intentionally NOT called
        // here. ScanController.runScan() invokes it exactly once after both
        // engines complete, which is enough to (a) value Claude rows that
        // landed in this pass and (b) propagate price-table edits — without
        // doing the same UPDATE twice per scan.

        let report = ScanReport(
            scannedFiles: files.count,
            changedFiles: changed.count,
            importedSessions: importedSessions,
            importedEvents: importedEvents,
            importedRateLimitSamples: importedSamples,
            errors: errors)

        Log.importer.info("scan ok scanned=\(report.scannedFiles) changed=\(report.changedFiles) sessions=\(report.importedSessions) events=\(report.importedEvents) samples=\(report.importedRateLimitSamples) errors=\(report.errors.count)")
        for err in report.errors.prefix(5) {
            Log.importer.error("\(err, privacy: .public)")
        }

        return report
    }

    // MARK: - persist

    private struct PersistCounts { let events: Int; let samples: Int }

    private func persist(parsed: ParsedSession, file: SessionFile) async throws -> PersistCounts {
        let now = ISO8601.fractional.string(from: Date())

        return try await database.pool.write { db in
            // 1. Upsert the session row.
            let existed = try SessionRecord
                .filter(Column("session_id") == parsed.sessionId)
                .fetchOne(db) != nil

            let sessionRecord = SessionRecord(
                sessionId: parsed.sessionId,
                rootSessionId: parsed.rootSessionId,
                parentSessionId: parsed.parentSessionId,
                title: parsed.title,
                sourcePath: file.path,
                startedAt: parsed.startedAt,
                updatedAt: parsed.updatedAt,
                agentNickname: parsed.agentNickname,
                agentRole: parsed.agentRole,
                lastModelId: parsed.lastModelId,
                latestPlanType: parsed.latestPlanType,
                // Filled in by reconcileSessionTree() after the full scan
                // when we can see this session's children.
                containsSubagents: false,
                createdAt: existed ? (try SessionRecord
                    .filter(Column("session_id") == parsed.sessionId)
                    .fetchOne(db)?.createdAt) ?? now : now,
                importedAt: now,
                provider: "codex")
            try sessionRecord.save(db)

            // 2. Replace usage_events for this session (file may have grown).
            try UsageEventRecord
                .filter(Column("session_id") == parsed.sessionId)
                .deleteAll(db)
            for delta in parsed.usageDeltas {
                let event = UsageEventRecord(
                    id: nil,
                    sessionId: parsed.sessionId,
                    timestamp: delta.timestamp,
                    modelId: delta.modelId,
                    inputTokens: delta.inputTokens,
                    cachedInputTokens: delta.cachedInputTokens,
                    outputTokens: delta.outputTokens,
                    reasoningOutputTokens: delta.reasoningOutputTokens,
                    totalTokens: delta.totalTokens,
                    valueUsd: 0,            // pricing layer fills this later
                    cacheCreationTokens: 0,
                    provider: "codex",
                    modelInferred: delta.modelInferred)
                try event.insert(db)
            }

            // 3. Replace jsonl-sourced rate_limit_samples for this session.
            try RateLimitSampleRecord
                .filter(Column("source_kind") == "jsonl"
                    && Column("source_session_id") == parsed.sessionId)
                .deleteAll(db)
            for draft in parsed.rateLimitSamples {
                let sample = RateLimitSampleRecord(
                    id: nil,
                    sourceKind: "jsonl",
                    sourceSessionId: parsed.sessionId,
                    bucket: draft.bucket,
                    sampleTimestamp: draft.sampleTimestamp,
                    planType: draft.planType,
                    limitName: draft.limitName,
                    windowStart: nil,
                    resetsAt: draft.resetsAt,
                    usedPercent: draft.usedPercent,
                    remainingPercent: draft.remainingPercent)
                try sample.insert(db)
            }

            // 4. Update import_state.
            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: parsed.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now)
            try state.save(db)

            // Drop any other import_state rows pointing at this same session
            // under a different path. Codex moves rollouts from sessions/ to
            // archived_sessions/ on archive — without this we'd accumulate
            // stale rows forever and re-parse the same session twice on
            // every scan. Mirrors codex-pacer's prune (importer.rs:784).
            try ImportStateRecord
                .filter(Column("session_id") == parsed.sessionId
                    && Column("source_path") != file.path)
                .deleteAll(db)

            return PersistCounts(
                events: parsed.usageDeltas.count,
                samples: parsed.rateLimitSamples.count)
        }
    }

    // MARK: - reconcile session tree

    /// Walk every Codex session's parent chain and update:
    ///   - `root_session_id` to the topmost ancestor (cycle-safe; capped at 64 hops)
    ///   - `contains_subagents` to true iff the session has at least one child
    ///
    /// Mirrors codex-pacer's `recompute_conversation_links`. We don't maintain
    /// a separate `conversation_links` table — `sessions.root_session_id` and
    /// `contains_subagents` are enough for the queries we surface today.
    private func reconcileSessionTree() async throws {
        try await database.pool.write { db in
            // Pull (id, parent) for every Codex session in one query.
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, parent_session_id
                FROM sessions
                WHERE provider = 'codex'
                """)
            var parents: [String: String?] = [:]
            for row in rows {
                let id: String = row["session_id"] ?? ""
                let parent: String? = row["parent_session_id"]
                parents[id] = parent
            }

            var hasChildren: Set<String> = []
            for case let parent? in parents.values {
                hasChildren.insert(parent)
            }

            for sessionId in parents.keys {
                let root = Self.resolveRoot(sessionId, in: parents)
                let containsSubagents = hasChildren.contains(sessionId)
                try db.execute(sql: """
                    UPDATE sessions
                    SET root_session_id = ?, contains_subagents = ?
                    WHERE session_id = ?
                    """, arguments: [root, containsSubagents, sessionId])
            }
        }
    }

    /// Walk parent links until we find a session whose parent is missing or nil,
    /// or we exceed the safety cap (cycle protection). Returns the topmost id.
    private static func resolveRoot(
        _ sessionId: String, in parents: [String: String?]
    ) -> String {
        var current = sessionId
        var seen: Set<String> = [current]
        for _ in 0..<64 {
            guard let parentOpt = parents[current], let parent = parentOpt else {
                return current
            }
            if seen.contains(parent) { return current } // cycle guard
            seen.insert(parent)
            current = parent
        }
        return current
    }
}
