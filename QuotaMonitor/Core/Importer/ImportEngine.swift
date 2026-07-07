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
    private let codexHome: URL?
    private let securityScopedAccess: any SecurityScopedResourceAccessing

    struct ScanReport: Sendable {
        let scannedFiles: Int
        let changedFiles: Int
        let importedSessions: Int
        let importedEvents: Int
        let importedRateLimitSamples: Int
        let errors: [String]
        /// True when an App Store security-scoped root resolved but its scope
        /// could not be opened (folder moved/revoked). Surfaced to the user via
        /// `lastError` so a silently-empty import prompts a re-select instead.
        let scopeUnavailable: Bool
        /// Number of Codex rows whose `codex_billing_tier` changed during this
        /// scan's priority-trace tagging. Non-zero means pricing must re-run
        /// even when no files changed (a new priority turn entered the trace).
        let codexTierUpdated: Int

        init(
            scannedFiles: Int,
            changedFiles: Int,
            importedSessions: Int,
            importedEvents: Int,
            importedRateLimitSamples: Int,
            errors: [String],
            scopeUnavailable: Bool = false,
            codexTierUpdated: Int = 0
        ) {
            self.scannedFiles = scannedFiles
            self.changedFiles = changedFiles
            self.importedSessions = importedSessions
            self.importedEvents = importedEvents
            self.importedRateLimitSamples = importedRateLimitSamples
            self.errors = errors
            self.scopeUnavailable = scopeUnavailable
            self.codexTierUpdated = codexTierUpdated
        }

        static let empty = ScanReport(
            scannedFiles: 0, changedFiles: 0,
            importedSessions: 0, importedEvents: 0,
            importedRateLimitSamples: 0, errors: [])
    }

    init(
        database: DatabaseManager,
        codexHome: URL? = SessionScanner.defaultCodexHome(),
        securityScopedAccess: any SecurityScopedResourceAccessing =
            FoundationSecurityScopedResourceAccessing()
    ) {
        self.database = database
        self.codexHome = codexHome
        self.securityScopedAccess = securityScopedAccess
    }

    func performScan(progress: ScanProgressHandler? = nil) async throws -> ScanReport {
        // Seed pricing once per scan so freshly-added models pick up prices on relaunch.
        try await database.pool.write { db in
            try PricingService.seedCatalog(in: db)
        }

        guard let codexHome else {
            return .empty
        }

        let scopedAccess = securityScopedAccess.access(codexHome)
        defer { scopedAccess.stop() }

        // App Store: the bookmark resolved but its security scope wouldn't open
        // (folder moved/revoked/TCC reset). Enumerating would silently find
        // nothing; instead report it so the user is told to re-select the folder.
        if DistributionChannel.current == .appStore, !scopedAccess.didStart {
            return ScanReport(
                scannedFiles: 0, changedFiles: 0,
                importedSessions: 0, importedEvents: 0,
                importedRateLimitSamples: 0,
                errors: ["codex history folder scope unavailable: \(codexHome.path)"],
                scopeUnavailable: true)
        }

        let files = SessionScanner.scan(codexHome: codexHome)
        let priorState: [String: ImportStateRecord] = try await database.pool.read { db in
            let rows = try ImportStateRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sourcePath, $0) })
        }

        let codexMetadata: [String: CodexSessionMetadata]
        do {
            codexMetadata = try CodexSessionMetadataStore.load(codexHome: codexHome)
        } catch {
            codexMetadata = [:]
        }
        try await backfillCodexSessionMetadata(codexMetadata)

        // Source paths of Codex sessions still missing project metadata —
        // re-parse them so the split metadata columns can be backfilled
        // without waiting for the source file to change.
        let metadataIncompleteCodexPaths: Set<String> = try await database.pool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT source_path FROM sessions
                WHERE provider = 'codex'
                  AND source_path IS NOT NULL
                  AND ((project_name IS NULL OR project_name = '')
                       OR (cwd IS NULL OR cwd = ''))
                """)
            return Set(rows)
        }

        var currentCodexPathsWithoutBackfillableProjectMetadata: [String] = []
        let changed = files.filter { file in
            guard let prior = priorState[file.path] else { return true }
            if prior.fileSize != file.fileSize || prior.fileMtimeMs != file.fileMtimeMs {
                return true
            }
            if metadataIncompleteCodexPaths.contains(file.path),
               prior.byteOffset >= 0 {
                if codexRolloutCanBackfillProjectMetadata(file) {
                    return true
                }
                currentCodexPathsWithoutBackfillableProjectMetadata.append(file.path)
            }
            return false
        }
        if !currentCodexPathsWithoutBackfillableProjectMetadata.isEmpty {
            try await markCodexRolloutsWithoutBackfillableProjectMetadata(
                currentCodexPathsWithoutBackfillableProjectMetadata)
        }
        await progress?(ScanProgressUpdate(
            provider: "codex",
            completedFiles: 0,
            totalFiles: changed.count,
            currentFile: changed.first?.url.lastPathComponent))

        var importedSessions = 0
        var importedEvents = 0
        var importedSamples = 0
        var errors: [String] = []

        for (index, file) in changed.enumerated() {
            do {
                if let parsed = try RolloutParser.parse(
                    fileURL: file.url,
                    fallbackSessionId: file.sessionIdHint
                ) {
                    var enriched = parsed
                    if let metadata = codexMetadata[parsed.sessionId] {
                        enriched.title = metadata.title
                        enriched.cwd = parsed.cwd ?? metadata.cwd
                        enriched.projectName = parsed.projectName ?? metadata.projectName
                    }
                    let counts = try await persist(parsed: enriched, file: file)
                    importedSessions += 1
                    importedEvents += counts.events
                    importedSamples += counts.samples
                } else {
                    errors.append("no session id resolved: \(file.path)")
                }
            } catch {
                errors.append("\(file.path): \(error)")
            }
            let nextIndex = index + 1
            let nextFile = nextIndex < changed.count
                ? changed[nextIndex].url.lastPathComponent
                : nil
            await progress?(ScanProgressUpdate(
                provider: "codex",
                completedFiles: nextIndex,
                totalFiles: changed.count,
                currentFile: nextFile))
        }

        // After all files are persisted, walk the parent chain to compute
        // root_session_id and contains_subagents for every Codex session.
        // Cheap (single pass, all in one transaction) and idempotent.
        try await reconcileSessionTree()

        // Attribute each turn's billing tier from the logs_2.sqlite priority
        // trace. Only when files actually changed — the trace scan is a
        // multi-second full-text pass over a large DB, so a no-change popover
        // refresh must not pay it. Best-effort: a missing/locked trace tags
        // nothing and the global Fast-Mode switch takes over.
        var codexTierUpdated = 0
        if !changed.isEmpty {
            codexTierUpdated = try await tagCodexPriority()
        }

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
            errors: errors,
            codexTierUpdated: codexTierUpdated)

        Log.importer.info("scan ok scanned=\(report.scannedFiles) changed=\(report.changedFiles) sessions=\(report.importedSessions) events=\(report.importedEvents) samples=\(report.importedRateLimitSamples) errors=\(report.errors.count)")
        DeveloperLog.eventRecord(
            "importer.scan.finish",
            category: "importer",
            result: "success",
            fields: [
                "scanned_files": .int(report.scannedFiles),
                "changed_files": .int(report.changedFiles),
                "imported_sessions": .int(report.importedSessions),
                "imported_events": .int(report.importedEvents),
                "imported_rate_limit_samples": .int(report.importedRateLimitSamples),
                "errors": .int(report.errors.count)
            ])
        for err in report.errors.prefix(5) {
            Log.importer.error("\(err, privacy: .public)")
            DeveloperLog.eventRecord(
                "importer.scan.error",
                level: .error,
                category: "importer",
                result: "failure",
                message: err)
        }

        return report
    }

    private func backfillCodexSessionMetadata(
        _ metadataBySessionId: [String: CodexSessionMetadata]
    ) async throws {
        guard !metadataBySessionId.isEmpty else { return }
        let now = ISO8601.fractional.string(from: Date())

        try await database.pool.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, title, project_name, cwd
                FROM sessions
                WHERE provider = 'codex'
                """)

            for row in rows {
                guard let sessionId: String = row["session_id"],
                      let metadata = metadataBySessionId[sessionId]
                else { continue }

                let currentTitle = Self.nonEmpty(row["title"] as String?)
                let currentProjectName = Self.nonEmpty(row["project_name"] as String?)
                let currentCwd = Self.nonEmpty(row["cwd"] as String?)
                let nextCwd = currentCwd ?? metadata.cwd
                let nextProjectName = currentProjectName ?? metadata.projectName
                let nextTitle = metadata.title ?? currentTitle

                guard nextTitle != currentTitle
                    || nextProjectName != currentProjectName
                    || nextCwd != currentCwd
                else { continue }

                try db.execute(sql: """
                    UPDATE sessions
                    SET title = ?, project_name = ?, cwd = ?, imported_at = ?
                    WHERE provider = 'codex' AND session_id = ?
                    """, arguments: [
                        nextTitle,
                        nextProjectName,
                        nextCwd,
                        now,
                        sessionId
                    ])
            }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private func markCodexRolloutsWithoutBackfillableProjectMetadata(
        _ sourcePaths: [String]
    ) async throws {
        let uniquePaths = Set(sourcePaths)
        guard !uniquePaths.isEmpty else { return }
        let now = ISO8601.fractional.string(from: Date())

        try await database.pool.write { db in
            for path in uniquePaths {
                // Codex re-parses whole JSONL files and does not consume
                // byte_offset. Use -1 as a Codex-only sentinel so current
                // no-cwd legacy files are not re-probed on every scan.
                try db.execute(sql: """
                    UPDATE import_state
                    SET byte_offset = -1,
                        last_imported_at = ?
                    WHERE source_path = ?
                      AND byte_offset >= 0
                    """, arguments: [now, path])
            }
        }
    }

    private func codexRolloutCanBackfillProjectMetadata(_ file: SessionFile) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return false }
        defer { try? handle.close() }

        do {
            for line in try LineReader(handle: handle) {
                guard let event = RolloutEvent.decode(line: line) else { continue }
                if case .sessionMeta(let meta, _) = event,
                   let cwd = Self.nonEmpty(meta.cwd) {
                    return !(cwd as NSString).lastPathComponent.isEmpty
                }
            }
        } catch {
            return false
        }
        return false
    }

    // MARK: - persist

    private struct PersistCounts { let events: Int; let samples: Int }

    private func persist(parsed: ParsedSession, file: SessionFile) async throws -> PersistCounts {
        let now = ISO8601.fractional.string(from: Date())

        return try await database.pool.write { db in
            // 1. Upsert the session row.
            let existing = try SessionRecord
                .filter(Column("session_id") == parsed.sessionId)
                .fetchOne(db)

            let sessionRecord = SessionRecord(
                sessionId: parsed.sessionId,
                rootSessionId: parsed.rootSessionId,
                parentSessionId: parsed.parentSessionId,
                title: parsed.title ?? existing?.title,
                projectName: parsed.projectName ?? existing?.projectName,
                cwd: parsed.cwd ?? existing?.cwd,
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
                createdAt: existing?.createdAt ?? now,
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
                    modelInferred: delta.modelInferred,
                    providerMessageId: nil,
                    codexTurnId: delta.turnId)
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

            // 4. Update import_state. Codex still re-parses the full file
            // every time, so leave byte_offset at 0 — the v5 schema has the
            // column but the Codex engine doesn't use it yet.
            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: parsed.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now,
                byteOffset: 0)
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

    // MARK: - codex priority tagging

    /// Read the `logs_2.sqlite` priority trace and stamp every Codex row's
    /// billing tier. Returns the number of rows whose tier changed. Best-
    /// effort: no codex home or an unreadable trace tags nothing and returns 0.
    private func tagCodexPriority() async throws -> Int {
        guard let codexHome else { return 0 }
        let logsURL = codexHome.appendingPathComponent("logs_2.sqlite")
        let trace = CodexPriorityTraceReader.read(logsDatabaseURL: logsURL)
        let changed = try await database.pool.write { db in
            try CodexPriorityTagger.tag(in: db, trace: trace)
        }
        Log.importer.info(
            "codex priority tag: \(trace.priorityTurnIds.count) priority turns, \(changed) rows retiered")
        return changed
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
