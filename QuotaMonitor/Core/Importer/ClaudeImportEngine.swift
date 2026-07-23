import Foundation
import GRDB

// Importer for Claude Code's rollout files.
//
// Path layout: `~/.claude/projects/{flattened-cwd}/{sessionId}.jsonl`.
// (We also try `~/.config/claude/projects` for the newer layout, but no real
// machine has data there yet.)
//
// Per-line shape (what we care about):
//   { "type": "assistant",
//     "timestamp": "2026-04-28T16:17:55.836Z",
//     "sessionId": "...",
//     "uuid": "...",
//     "cwd": "/Users/foo/repo",
//     "version": "2.1.77",
//     "gitBranch": "main",
//     "message": {
//        "id": "msg_xxx",
//        "model": "claude-opus-4-7",
//        "usage": {
//          "input_tokens": 1,
//          "cache_creation_input_tokens": 1159,
//          "cache_creation": {
//             "ephemeral_1h_input_tokens": 1159,
//             "ephemeral_5m_input_tokens": 0
//          },
//          "cache_read_input_tokens": 93669,
//          "output_tokens": 710
//        }
//     }
//   }
//
// Differences from Codex JSONL:
//   1. Usage is per-message, NOT cumulative — we emit one row per `assistant`
//      MESSAGE. One message can span several `assistant` lines (one per
//      content block) whose usage snapshots grow as the message streams; the
//      largest same-day snapshot is the complete bill. If a larger snapshot
//      lands on a different local day, we keep the earlier day stable and emit
//      only the token delta on the later day.
//   2. Many event types are noise (file-history-snapshot, progress, user,
//      system, last-prompt). We only consume `assistant`.
//   3. Synthetic / placeholder messages have model `<synthetic>` — skipped.
//   4. Session id is in every line; the filename stem also matches (verified
//      across 126 real files on the dev machine).

actor ClaudeImportEngine {
    private enum PersistenceError: Error {
        case missingUpsertedUsageEvent(sessionId: String, messageId: String)
    }

    private let database: DatabaseManager
    private let claudeRoots: [URL]
    private let securityScopedAccess: any SecurityScopedResourceAccessing

    init(database: DatabaseManager,
         claudeRoots: [URL] = ClaudeImportEngine.defaultRoots(),
         securityScopedAccess: any SecurityScopedResourceAccessing =
            FoundationSecurityScopedResourceAccessing()) {
        self.database = database
        self.claudeRoots = claudeRoots
        self.securityScopedAccess = securityScopedAccess
    }

    /// Resolve the directories where Claude Code stores rollouts —
    /// both legacy (`~/.claude/projects`) and new
    /// (`~/.config/claude/projects`). Non-existent directories are
    /// silently ignored — `scan()` just returns an empty list.
    static func defaultRoots(
        distribution: DistributionChannel = .current,
        authorizations: HistoryRootAuthorizationStore = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [URL] {
        if LocalQAEnvironment.isActive(environment: environment, arguments: arguments) {
            return legacyDefaultRoots(
                home: LocalQAEnvironment.homeDirectory(
                    environment: environment,
                    arguments: arguments))
        }

        if distribution == .appStore {
            return [
                authorizations.resolvedURL(for: .claudeProjects),
                authorizations.resolvedURL(for: .claudeConfigProjects),
            ].compactMap(\.self)
        }

        return legacyDefaultRoots(
            home: LocalQAEnvironment.homeDirectory(
                environment: environment,
                arguments: arguments))
    }

    private static func legacyDefaultRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
    }

    func performScan(progress: ScanProgressHandler? = nil) async throws -> ImportEngine.ScanReport {
        let scopedAccesses = claudeRoots.map { securityScopedAccess.access($0) }
        defer { scopedAccesses.reversed().forEach { $0.stop() } }

        // App Store: a resolved bookmark whose scope wouldn't open (moved/
        // revoked folder) would enumerate to nothing. Flag it so the user is
        // told to re-select rather than seeing a silently-empty Claude import.
        let scopeUnavailable = DistributionChannel.current == .appStore
            && scopedAccesses.contains { !$0.didStart }
        let scopeErrors = scopeUnavailable
            ? scopedAccesses.filter { !$0.didStart }
                .map { "claude history folder scope unavailable: \($0.url.path)" }
            : []

        let files = scanFiles()
        let priorState: [String: ImportStateRecord] = try await database.pool.read { db in
            let rows = try ImportStateRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sourcePath, $0) })
        }

        // Decide per file: skipped, full re-read, or incremental tail.
        // - First sighting → full read from offset 0.
        // - File shrank below `byteOffset` → truncation/rotation; re-read from 0.
        // - Same size+mtime as last scan → no work.
        // - Otherwise grew or mtime moved → incremental from the recorded offset.
        struct PlannedScan {
            let file: ClaudeFile
            /// Key used to gather sibling files sharing one raw session.
            /// Prefers the content-derived session id recorded in
            /// import_state (covers any layout that shares a session id,
            /// not just `subagents/` directories); falls back to the
            /// path-derived id for files we've never seen before.
            let groupId: String
            let fromOffset: Int64
            /// True when we're starting a fresh read; persist clears the
            /// session's existing usage_events. False for tail reads;
            /// persist relies on the v5 partial unique index to swallow
            /// re-emitted rows.
            let resetSession: Bool
        }

        let groupId: (ClaudeFile) -> String = { file in
            priorState[file.path]?.sessionId ?? file.sessionId
        }
        // Session groups that already have imported state under any file.
        // A brand-new file joining a known group must NOT trigger a session
        // reset: its rows were never imported (nothing to clear), the unique
        // index dedups any overlap, and a reset would force every sibling
        // through a full re-read each time a subagent file appears.
        let knownGroupIds = Set(priorState.values.compactMap(\.sessionId))

        var plannedByPath: [String: PlannedScan] = [:]
        for file in files {
            let group = groupId(file)
            guard let prior = priorState[file.path] else {
                plannedByPath[file.path] = PlannedScan(
                    file: file, groupId: group, fromOffset: 0,
                    resetSession: !knownGroupIds.contains(group))
                continue
            }
            if prior.fileSize == file.fileSize && prior.fileMtimeMs == file.fileMtimeMs {
                continue
            }
            // Truncation or rotation: file is smaller than the offset we
            // last consumed, so the bytes at that offset can't possibly
            // be what they used to be. Safest is a full re-read.
            if file.fileSize < prior.byteOffset {
                plannedByPath[file.path] = PlannedScan(
                    file: file, groupId: group, fromOffset: 0, resetSession: true)
                continue
            }
            // First time we see this file post-v5 (legacy import_state row
            // had no offset). One last full read regenerates
            // `provider_message_id` so the unique index can do its job
            // on subsequent scans.
            if prior.byteOffset == 0 {
                plannedByPath[file.path] = PlannedScan(
                    file: file, groupId: group, fromOffset: 0, resetSession: true)
                continue
            }
            plannedByPath[file.path] = PlannedScan(
                file: file, groupId: group, fromOffset: prior.byteOffset, resetSession: false)
        }
        // Claude Code dynamic-workflow/subagent files can share one raw
        // sessionId with the main rollout file. A per-file full reset would
        // delete rows imported from sibling files in that same session, so
        // rebuild the whole session group whenever any sibling needs reset.
        let resetGroupIds = Set(
            plannedByPath.values
                .filter(\.resetSession)
                .map(\.groupId))
        if !resetGroupIds.isEmpty {
            for file in files {
                let group = groupId(file)
                guard resetGroupIds.contains(group) else { continue }
                plannedByPath[file.path] = PlannedScan(
                    file: file,
                    groupId: group,
                    fromOffset: 0,
                    resetSession: true)
            }
        }
        let planned = plannedByPath.values.sorted { $0.file.path < $1.file.path }
        await progress?(ScanProgressUpdate(
            provider: "claude",
            completedFiles: 0,
            totalFiles: planned.count,
            currentFile: planned.first?.file.url.lastPathComponent))

        var importedSessionIds: Set<String> = []
        var importedEvents = 0
        var errors: [String] = []

        var resetGroupsCompleted: Set<String> = []
        for (index, plan) in planned.enumerated() {
            do {
                let output = try ClaudeRolloutParser.parse(
                    fileURL: plan.file.url, fromOffset: plan.fromOffset)
                if let parsed = output.session {
                    let shouldReset = plan.resetSession
                        && !resetGroupsCompleted.contains(plan.groupId)
                    let count = try await persist(
                        parsed: parsed,
                        file: plan.file,
                        byteOffset: output.endOffset,
                        resetSession: shouldReset)
                    if shouldReset {
                        resetGroupsCompleted.insert(plan.groupId)
                    }
                    importedSessionIds.insert(parsed.sessionId)
                    importedEvents += count
                } else {
                    // Either the slice contained nothing, or this is a
                    // first-pass empty file. Either way: bump import_state
                    // so we don't re-scan.
                    try await persistEmpty(file: plan.file, byteOffset: output.endOffset)
                }
            } catch {
                errors.append("\(plan.file.path): \(error)")
                // A sibling's session reset may already have deleted this
                // file's rows. If its import_state were left matching the
                // on-disk size/mtime, the next scan would skip the file and
                // its usage would be silently lost — force a full re-read.
                if plan.resetSession {
                    do {
                        try await invalidateImportState(
                            file: plan.file, groupId: plan.groupId)
                    } catch {
                        errors.append(
                            "\(plan.file.path): failed to invalidate import state: \(error)")
                    }
                }
            }
            let nextIndex = index + 1
            let nextFile = nextIndex < planned.count
                ? planned[nextIndex].file.url.lastPathComponent
                : nil
            await progress?(ScanProgressUpdate(
                provider: "claude",
                completedFiles: nextIndex,
                totalFiles: planned.count,
                currentFile: nextFile))
        }

        return ImportEngine.ScanReport(
            scannedFiles: files.count,
            changedFiles: planned.count,
            importedSessions: importedSessionIds.count,
            importedEvents: importedEvents,
            importedRateLimitSamples: 0,    // Claude rollouts don't carry rate-limit samples.
            errors: errors + scopeErrors,
            scopeUnavailable: scopeUnavailable)
    }

    // MARK: - scan

    private struct ClaudeFile {
        let url: URL
        let path: String
        let fileSize: Int64
        let fileMtimeMs: Int64
        var sessionId: String {
            // `firstIndex`, not `lastIndex`: nested layouts like
            // `<sid>/subagents/<agent>/subagents/<file>.jsonl` must group
            // under the root session — grouping under the inner agent
            // would let its reset delete the root session's rows while
            // only re-reading the inner group.
            let components = url.pathComponents
            if let subagents = components.firstIndex(of: "subagents"),
               subagents > components.startIndex {
                return components[components.index(before: subagents)]
            }
            return url.deletingPathExtension().lastPathComponent
        }

        /// True for files under a `subagents/` directory — they belong to
        /// the enclosing rollout's session rather than a session of their own.
        var isSubagentFile: Bool { url.pathComponents.contains("subagents") }
    }

    private func scanFiles() -> [ClaudeFile] {
        var results: [ClaudeFile] = []
        let fm = FileManager.default
        for root in claudeRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let size = Int64(values?.fileSize ?? 0)
                let mtimeMs = Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
                results.append(ClaudeFile(
                    url: url, path: url.path,
                    fileSize: size, fileMtimeMs: mtimeMs))
            }
        }
        return results
    }

    /// Record that we visited a file that had no billable events, so
    /// the next scan can skip it via mtime/size check. Without this,
    /// every scan re-reads every empty subagent stub forever.
    private func persistEmpty(file: ClaudeFile, byteOffset: Int64) async throws {
        let now = ISO8601.fractional.string(from: Date())
        try await database.pool.write { db in
            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: file.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now,
                byteOffset: byteOffset)
            try state.save(db)
        }
    }

    /// Force a full re-read of `file` on the next scan. Used when a scan
    /// fails after a sibling's session reset may already have deleted this
    /// file's rows: the sentinel size/mtime can never match the on-disk
    /// file, and `byteOffset == 0` routes the next scan through the full
    /// reset path (same shape the v6/v7 migrations use).
    private func invalidateImportState(file: ClaudeFile, groupId: String) async throws {
        let now = ISO8601.fractional.string(from: Date())
        try await database.pool.write { db in
            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: groupId,
                fileSize: -1,
                fileMtimeMs: -1,
                lastImportedAt: now,
                byteOffset: 0)
            try state.save(db)
        }
    }

    // MARK: - persist

    private func persist(
        parsed: ParsedClaudeSession,
        file: ClaudeFile,
        byteOffset: Int64,
        resetSession: Bool
    ) async throws -> Int {
        let now = ISO8601.fractional.string(from: Date())
        return try await database.pool.write { db in
            let existing = try SessionRecord
                .filter(Column("session_id") == parsed.sessionId)
                .fetchOne(db)
            // For incremental tail reads we don't want to overwrite the
            // session's `started_at` with whatever the slice happens to
            // start at — keep the original. The other fields all want
            // the latest values regardless.
            let resolvedStartedAt: String? = {
                if !resetSession, let existing { return existing.startedAt }
                return parsed.startedAt
            }()
            let resolvedTitle = parsed.title ?? (resetSession ? nil : existing?.title)
            let resolvedProjectName = parsed.projectName ?? (resetSession ? nil : existing?.projectName)
            let resolvedCwd = parsed.cwd ?? (resetSession ? nil : existing?.cwd)
            let isSubagent = file.isSubagentFile
            // Multiple files can persist into one session row (main rollout
            // + subagent siblings, imported in path order). Last-writer-wins
            // would leave source_path pointing at whichever subagent file
            // sorted last — keep it on the main rollout.
            let resolvedSourcePath: String? = {
                if !isSubagent { return file.path }
                if let existingPath = existing?.sourcePath, !existingPath.isEmpty {
                    return existingPath
                }
                return file.path
            }()
            // A subagent file whose last event is older than the main
            // rollout's must not drag updated_at backwards. ISO-8601 UTC
            // strings compare lexicographically.
            let resolvedUpdatedAt: String? = {
                if !resetSession, let existingUpdated = existing?.updatedAt {
                    guard let parsedUpdated = parsed.updatedAt else {
                        return existingUpdated
                    }
                    return max(existingUpdated, parsedUpdated)
                }
                return parsed.updatedAt
            }()
            let resolvedContainsSubagents: Bool = {
                if resetSession { return isSubagent }
                return (existing?.containsSubagents ?? false) || isSubagent
            }()
            // Same staleness rule as updated_at: an older sibling file must
            // not overwrite the model recorded from a newer one.
            let resolvedLastModelId: String? = {
                guard let parsedModel = parsed.lastModelId else {
                    return resetSession ? nil : existing?.lastModelId
                }
                if !resetSession, let existing,
                   let existingUpdated = existing.updatedAt,
                   let parsedUpdated = parsed.updatedAt,
                   parsedUpdated < existingUpdated,
                   let existingModel = existing.lastModelId {
                    return existingModel
                }
                return parsedModel
            }()
            let session = SessionRecord(
                sessionId: parsed.sessionId,
                rootSessionId: parsed.sessionId,
                parentSessionId: nil,
                title: resolvedTitle,
                projectName: resolvedProjectName,
                cwd: resolvedCwd,
                sourcePath: resolvedSourcePath,
                startedAt: resolvedStartedAt,
                updatedAt: resolvedUpdatedAt,
                agentNickname: nil,
                agentRole: nil,
                lastModelId: resolvedLastModelId,
                latestPlanType: nil,
                containsSubagents: resolvedContainsSubagents,
                createdAt: existing?.createdAt ?? now,
                importedAt: now,
                provider: "claude")
            try session.save(db)

            if resetSession {
                try UsageEventRecord
                    .filter(Column("session_id") == parsed.sessionId)
                    .deleteAll(db)
            }

            // Upsert keyed on the v5 partial unique index
            // (session_id, provider_message_id). Same-day streaming snapshots
            // still update the original row; cross-day snapshots become a
            // later-day delta row so Dashboard history never rewrites the
            // previous local day.
            func upsert(_ evt: ClaudeUsageEvent) throws -> Int64? {
                let total = evt.tokenCounts.total
                try db.execute(literal: """
                    INSERT INTO usage_events (
                        session_id, timestamp, model_id,
                        input_tokens, cached_input_tokens, output_tokens,
                        reasoning_output_tokens, total_tokens, value_usd,
                        cache_creation_tokens,
                        cache_creation_5m_tokens, cache_creation_1h_tokens,
                        provider, model_inferred,
                        provider_message_id
                    ) VALUES (
                        \(parsed.sessionId), \(evt.timestamp), \(evt.modelId),
                        \(evt.inputTokens), \(evt.cacheReadTokens), \(evt.outputTokens),
                        \(0), \(total), \(0.0),
                        \(evt.cacheCreationTokens),
                        \(evt.cacheCreation5mTokens), \(evt.cacheCreation1hTokens),
                        \("claude"), \(false),
                        \(evt.messageId)
                    )
                    ON CONFLICT(session_id, provider_message_id)
                    WHERE provider_message_id IS NOT NULL
                    DO UPDATE SET
                        timestamp = excluded.timestamp,
                        model_id = excluded.model_id,
                        input_tokens = excluded.input_tokens,
                        cached_input_tokens = excluded.cached_input_tokens,
                        output_tokens = excluded.output_tokens,
                        total_tokens = excluded.total_tokens,
                        cache_creation_tokens = excluded.cache_creation_tokens,
                        cache_creation_5m_tokens = excluded.cache_creation_5m_tokens,
                        cache_creation_1h_tokens = excluded.cache_creation_1h_tokens,
                        value_usd = 0.0
                    WHERE usage_events.input_tokens != excluded.input_tokens
                       OR usage_events.cached_input_tokens != excluded.cached_input_tokens
                       OR usage_events.output_tokens != excluded.output_tokens
                       OR usage_events.cache_creation_tokens != excluded.cache_creation_tokens
                       OR usage_events.cache_creation_5m_tokens != excluded.cache_creation_5m_tokens
                       OR usage_events.cache_creation_1h_tokens != excluded.cache_creation_1h_tokens
                    """)
                guard db.changesCount > 0 else { return nil }
                guard let messageId = evt.messageId else {
                    // A NULL dedup key cannot conflict, so this statement was
                    // necessarily an insert and owns lastInsertedRowID.
                    return db.lastInsertedRowID
                }
                guard let eventId = try Int64.fetchOne(db, sql: """
                    SELECT id
                    FROM usage_events
                    WHERE session_id = ? AND provider_message_id = ?
                    """, arguments: [parsed.sessionId, messageId])
                else {
                    throw PersistenceError.missingUpsertedUsageEvent(
                        sessionId: parsed.sessionId,
                        messageId: messageId)
                }
                return eventId
            }

            var touchedEventIds: [Int64] = []
            touchedEventIds.reserveCapacity(parsed.events.count)
            for evt in parsed.events {
                switch try Self.crossDaySnapshotResolution(
                    db: db,
                    sessionId: parsed.sessionId,
                    event: evt,
                    resetSession: resetSession
                ) {
                case .normalUpsert(let event):
                    if let eventId = try upsert(event) {
                        touchedEventIds.append(eventId)
                    }
                case .deltaUpsert(let delta):
                    if let delta, let eventId = try upsert(delta) {
                        touchedEventIds.append(eventId)
                    }
                }
            }

            // Price this session before advancing the import offset. Keeping
            // the usage upsert, derived value, and checkpoint in one GRDB
            // write transaction means a failure cannot leave committed rows
            // at $0 that a later unchanged-file scan would skip.
            if resetSession {
                try PricingService.backfillValues(
                    in: db,
                    sessionId: parsed.sessionId,
                    provider: "claude")
            } else {
                try PricingService.backfillValues(
                    in: db,
                    eventIds: touchedEventIds)
            }

            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: parsed.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now,
                byteOffset: byteOffset)
            try state.save(db)

            return touchedEventIds.count
        }
    }

    private enum CrossDaySnapshotResolution {
        case normalUpsert(ClaudeUsageEvent)
        case deltaUpsert(ClaudeUsageEvent?)
    }

    private static func crossDaySnapshotResolution(
        db: Database,
        sessionId: String,
        event: ClaudeUsageEvent,
        resetSession: Bool
    ) throws -> CrossDaySnapshotResolution {
        guard !resetSession,
              let messageId = event.messageId,
              !ClaudeRolloutParser.isDayDeltaMessageId(messageId)
        else { return .normalUpsert(event) }

        let existingEvents = try storedClaudeEvents(
            db: db,
            sessionId: sessionId,
            baseMessageId: messageId)
        guard let base = existingEvents.first(where: { $0.messageId == messageId }) else {
            return .normalUpsert(event)
        }
        guard !ClaudeRolloutParser.isSameLocalDay(base.timestamp, event.timestamp) else {
            return .normalUpsert(ClaudeRolloutParser.preferredSnapshot(
                candidate: event,
                existing: base))
        }

        return .deltaUpsert(ClaudeRolloutParser.dayDeltaEvent(
            existingEvents: existingEvents,
            baseMessageId: messageId,
            snapshot: event))
    }

    private static func storedClaudeEvents(
        db: Database,
        sessionId: String,
        baseMessageId: String
    ) throws -> [ClaudeUsageEvent] {
        let prefix = ClaudeRolloutParser.dayDeltaMessagePrefix(for: baseMessageId)
        let likePattern = sqlLikePatternEscaping(prefix) + "%"
        let rows = try Row.fetchAll(db, sql: #"""
            SELECT timestamp, model_id, input_tokens, cached_input_tokens,
                   output_tokens, cache_creation_tokens,
                   cache_creation_5m_tokens, cache_creation_1h_tokens,
                   provider_message_id
            FROM usage_events
            WHERE session_id = ?
              AND provider = 'claude'
              AND (
                  provider_message_id = ?
                  OR provider_message_id LIKE ? ESCAPE '\'
              )
            """#, arguments: [sessionId, baseMessageId, likePattern])
        return rows.map { row in
            ClaudeUsageEvent(
                timestamp: row["timestamp"] as String,
                modelId: row["model_id"] as String,
                inputTokens: row["input_tokens"] as Int64,
                cacheReadTokens: row["cached_input_tokens"] as Int64,
                cacheCreationTokens: row["cache_creation_tokens"] as Int64,
                cacheCreation5mTokens: row["cache_creation_5m_tokens"] as Int64,
                cacheCreation1hTokens: row["cache_creation_1h_tokens"] as Int64,
                outputTokens: row["output_tokens"] as Int64,
                messageId: row["provider_message_id"] as String?)
        }
    }

    private static func sqlLikePatternEscaping(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}

// MARK: - Parser

struct ParsedClaudeSession {
    let sessionId: String
    let title: String?
    let projectName: String?
    let cwd: String?
    let startedAt: String?
    let updatedAt: String?
    let lastModelId: String?
    let events: [ClaudeUsageEvent]
}

struct ClaudeUsageEvent {
    let timestamp: String
    let modelId: String
    let inputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let cacheCreation5mTokens: Int64
    let cacheCreation1hTokens: Int64
    let outputTokens: Int64
    /// `message.id` from the rollout. Used as the dedup key so that
    /// re-parsing the trailing slice during incremental scans is
    /// idempotent at the SQL layer (partial unique index added in v5).
    /// `nil` when the rollout omitted it (very old Claude builds).
    let messageId: String?
}

fileprivate struct ClaudeUsageTokenCounts {
    let inputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let cacheCreation5mTokens: Int64
    let cacheCreation1hTokens: Int64
    let outputTokens: Int64

    static let zero = ClaudeUsageTokenCounts(
        inputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        outputTokens: 0)

    var total: Int64 {
        inputTokens + cacheReadTokens + cacheCreationTokens + outputTokens
    }

    var isZero: Bool {
        inputTokens == 0
            && cacheReadTokens == 0
            && cacheCreationTokens == 0
            && cacheCreation5mTokens == 0
            && cacheCreation1hTokens == 0
            && outputTokens == 0
    }

    func adding(_ other: ClaudeUsageTokenCounts) -> ClaudeUsageTokenCounts {
        ClaudeUsageTokenCounts(
            inputTokens: inputTokens + other.inputTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens + other.cacheCreationTokens,
            cacheCreation5mTokens: cacheCreation5mTokens + other.cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens + other.cacheCreation1hTokens,
            outputTokens: outputTokens + other.outputTokens)
    }

    func subtracting(_ baseline: ClaudeUsageTokenCounts) -> ClaudeUsageTokenCounts {
        ClaudeUsageTokenCounts(
            inputTokens: max(inputTokens - baseline.inputTokens, 0),
            cacheReadTokens: max(cacheReadTokens - baseline.cacheReadTokens, 0),
            cacheCreationTokens: max(cacheCreationTokens - baseline.cacheCreationTokens, 0),
            cacheCreation5mTokens: max(cacheCreation5mTokens - baseline.cacheCreation5mTokens, 0),
            cacheCreation1hTokens: max(cacheCreation1hTokens - baseline.cacheCreation1hTokens, 0),
            outputTokens: max(outputTokens - baseline.outputTokens, 0))
    }
}

fileprivate extension ClaudeUsageEvent {
    var tokenCounts: ClaudeUsageTokenCounts {
        ClaudeUsageTokenCounts(
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            outputTokens: outputTokens)
    }

    func replacingTokenCounts(
        _ counts: ClaudeUsageTokenCounts,
        messageId: String
    ) -> ClaudeUsageEvent {
        ClaudeUsageEvent(
            timestamp: timestamp,
            modelId: modelId,
            inputTokens: counts.inputTokens,
            cacheReadTokens: counts.cacheReadTokens,
            cacheCreationTokens: counts.cacheCreationTokens,
            cacheCreation5mTokens: counts.cacheCreation5mTokens,
            cacheCreation1hTokens: counts.cacheCreation1hTokens,
            outputTokens: counts.outputTokens,
            messageId: messageId)
    }
}

enum ClaudeRolloutParser {
    fileprivate static let dayDeltaMessageSeparator = "#quotamonitor-day-delta:"

    /// Parse result from a single read pass.
    struct Output {
        let session: ParsedClaudeSession?
        /// Byte offset in the file directly after the last newline that was
        /// fully consumed. Pass this back as `fromOffset` next time to
        /// resume incrementally. Equal to `fromOffset` when the file
        /// contained no parseable bytes after that point.
        let endOffset: Int64
    }

    /// Parse the file starting at `fromOffset`. Pass `0` for a full read.
    ///
    /// Important guarantees for the incremental path:
    ///   - We only advance `endOffset` past a complete line (we stop at the
    ///     last `\n` we saw), so a mid-write tail never gets half-parsed and
    ///     then "completed" on the next pass.
    ///   - When `fromOffset > 0`, a metadata-only tail slice can still
    ///     return a session so late `ai-title` / `cwd` lines are persisted
    ///     instead of being skipped as empty work.
    ///   - One `message.id` can span several `assistant` lines: a zero-usage
    ///     stub (skipped), then one line per content block whose
    ///     `output_tokens` grows as the message streams. The largest same-day
    ///     snapshot carries the complete usage, so in-pass duplicates replace
    ///     the earlier event only when they do not lower the token total.
    ///     Cross-day snapshots become a synthetic per-day delta event to avoid
    ///     moving yesterday's usage into today, or rewriting yesterday after
    ///     midnight.
    static func parse(
        fileURL: URL, fromOffset: Int64 = 0
    ) throws -> Output {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        if fromOffset > 0 {
            try handle.seek(toOffset: UInt64(fromOffset))
        }

        var sessionId: String? = nil
        var title: String? = nil
        var cwd: String? = nil
        var startedAt: String? = nil
        var updatedAt: String? = nil
        var lastModelId: String? = nil
        var events: [ClaudeUsageEvent] = []

        // Same-pass dedup, keeping the largest snapshot per message id (see
        // longer comment below). The cross-scan analogue is the SQL upsert
        // on the v5 partial unique index — we don't carry state across
        // invocations.
        var eventIndexByMessageId: [String: Int] = [:]

        var reader = try LineReader(handle: handle)
        var consumed: Int64 = fromOffset

        while let line = reader.next() {
            // We only commit to having "consumed" a line once we've seen
            // its terminating newline. LineReader yields the trailing
            // un-terminated tail as a final line (returning nil thereafter)
            // and reports `lastLineHadNewline == false` for it; in that
            // case, leave `consumed` pointing at the start of that tail
            // so the next scan re-reads it once it's been finished.
            let lineByteCount = Int64(line.count) + (reader.lastLineHadNewline ? 1 : 0)
            if reader.lastLineHadNewline {
                consumed &+= lineByteCount
            }

            guard !line.isEmpty,
                  let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }

            let type = raw["type"] as? String
            let ts = raw["timestamp"] as? String
            if sessionId == nil {
                sessionId = raw["sessionId"] as? String
            }
            if let ts {
                if startedAt == nil { startedAt = ts }
                updatedAt = ts
            }
            if cwd == nil, let rawCwd = raw["cwd"] as? String, !rawCwd.isEmpty {
                cwd = rawCwd
            }
            if title == nil, type == "ai-title",
               let aiTitle = raw["aiTitle"] as? String,
               !aiTitle.isEmpty {
                title = aiTitle
            }

            guard type == "assistant",
                  let message = raw["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let model = (message["model"] as? String) ?? "unknown"
            if model == "<synthetic>" { continue }
            let normalized = NormalizeModelId(model)

            let inputTokens = Self.int64(usage["input_tokens"]) ?? 0
            let cacheRead = Self.int64(usage["cache_read_input_tokens"]) ?? 0
            let cacheCreate = Self.int64(usage["cache_creation_input_tokens"]) ?? 0
            let cacheCreationBreakdown = usage["cache_creation"] as? [String: Any]
            let cacheCreate1h = Self.int64(
                cacheCreationBreakdown?["ephemeral_1h_input_tokens"]) ?? 0
            let cacheCreate5mRaw = Self.int64(
                cacheCreationBreakdown?["ephemeral_5m_input_tokens"]) ?? 0
            let splitTotal = cacheCreate1h + cacheCreate5mRaw
            // Older Claude rollouts had only `cache_creation_input_tokens`.
            // Treat any unclassified write tokens as 5-minute writes so we
            // preserve the pre-split billing behavior instead of dropping cost.
            let cacheCreate5m = cacheCreate5mRaw + max(cacheCreate - splitTotal, 0)
            let output = Self.int64(usage["output_tokens"]) ?? 0
            // Skip empty events (placeholder/system pings) BEFORE the
            // dedup check. Claude rollouts often emit two `assistant`
            // rows per message: an early stub with `usage = {input:0,
            // output:0}` then a final row with the real counts.
            // Both share the same `message.id`, so deduping first would
            // register the stub and discard the real row, zeroing the
            // entire session. (This is what produced 50 "no usage in
            // …" errors on the dev machine — every multi-snapshot
            // session was being silently dropped.)
            if inputTokens == 0 && cacheRead == 0 && cacheCreate == 0 && output == 0 { continue }

            let messageId = message["id"] as? String

            lastModelId = normalized

            let event = ClaudeUsageEvent(
                timestamp: ts ?? ISO8601.fractional.string(from: Date()),
                modelId: normalized,
                inputTokens: inputTokens,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreate,
                cacheCreation5mTokens: cacheCreate5m,
                cacheCreation1hTokens: cacheCreate1h,
                outputTokens: output,
                messageId: messageId)
            if let messageId {
                if let existingIndex = eventIndexByMessageId[messageId] {
                    let existing = events[existingIndex]
                    if Self.isSameLocalDay(existing.timestamp, event.timestamp) {
                        // Same local day: keep the largest streaming
                        // snapshot as the complete bill for that message.
                        // Normal streams grow monotonically; this also
                        // prevents a replayed or partial duplicate from
                        // lowering a completed row.
                        events[existingIndex] = Self.preferredSnapshot(
                            candidate: event,
                            existing: existing)
                    } else if let delta = Self.dayDeltaEvent(
                        existingEvents: events,
                        baseMessageId: messageId,
                        snapshot: event
                    ), let deltaMessageId = delta.messageId {
                        // Across local days: preserve the original day and
                        // count only newly observed tokens on the later day.
                        if let deltaIndex = eventIndexByMessageId[deltaMessageId] {
                            events[deltaIndex] = delta
                        } else {
                            eventIndexByMessageId[deltaMessageId] = events.count
                            events.append(delta)
                        }
                    }
                    continue
                }
                eventIndexByMessageId[messageId] = events.count
            }
            events.append(event)
        }

        // Fall back to the filename stem if no event carried sessionId.
        if sessionId == nil {
            sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
        guard let sid = sessionId else {
            return Output(session: nil, endOffset: consumed)
        }

        let hasHeaderMetadata = title != nil || cwd != nil
        guard !events.isEmpty || hasHeaderMetadata else {
            return Output(session: nil, endOffset: consumed)
        }

        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? nil : leaf
        }()

        let session = ParsedClaudeSession(
            sessionId: sid,
            title: title,
            projectName: projectName,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            lastModelId: lastModelId,
            events: events)
        return Output(session: session, endOffset: consumed)
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let d = any as? Double { return Int64(d) }
        if let n = any as? NSNumber { return n.int64Value }
        return nil
    }

    fileprivate static func isSameLocalDay(
        _ lhs: String,
        _ rhs: String,
        calendar: Calendar = .current
    ) -> Bool {
        guard let lhsDay = localDayKey(for: lhs, calendar: calendar),
              let rhsDay = localDayKey(for: rhs, calendar: calendar)
        else {
            return true
        }
        return lhsDay == rhsDay
    }

    fileprivate static func dayDeltaMessagePrefix(for messageId: String) -> String {
        "\(messageId)\(dayDeltaMessageSeparator)"
    }

    fileprivate static func isDayDeltaMessageId(_ messageId: String) -> Bool {
        messageId.contains(dayDeltaMessageSeparator)
    }

    fileprivate static func dayDeltaEvent(
        existingEvents: [ClaudeUsageEvent],
        baseMessageId: String,
        snapshot: ClaudeUsageEvent
    ) -> ClaudeUsageEvent? {
        guard let deltaMessageId = dayDeltaMessageId(
            baseMessageId: baseMessageId,
            timestamp: snapshot.timestamp),
              let currentDay = localDayKey(for: snapshot.timestamp)
        else { return nil }

        let prefix = dayDeltaMessagePrefix(for: baseMessageId)
        let baseline = existingEvents.reduce(ClaudeUsageTokenCounts.zero) { partial, event in
            guard let messageId = event.messageId,
                  messageId == baseMessageId || messageId.hasPrefix(prefix)
            else { return partial }
            if localDayKey(for: event.timestamp) == currentDay {
                return partial
            }
            return partial.adding(event.tokenCounts)
        }

        let delta = snapshot.tokenCounts.subtracting(baseline)
        guard !delta.isZero else { return nil }
        let deltaEvent = snapshot.replacingTokenCounts(
            delta, messageId: deltaMessageId)
        guard let existingDelta = existingEvents.first(where: {
            $0.messageId == deltaMessageId
        }) else {
            return deltaEvent
        }
        return preferredSnapshot(candidate: deltaEvent, existing: existingDelta)
    }

    fileprivate static func preferredSnapshot(
        candidate: ClaudeUsageEvent,
        existing: ClaudeUsageEvent
    ) -> ClaudeUsageEvent {
        candidate.tokenCounts.total >= existing.tokenCounts.total ? candidate : existing
    }

    private static func dayDeltaMessageId(
        baseMessageId: String,
        timestamp: String
    ) -> String? {
        guard let dayKey = localDayKey(for: timestamp) else { return nil }
        return "\(dayDeltaMessagePrefix(for: baseMessageId))\(dayKey)"
    }

    private static func localDayKey(
        for timestamp: String,
        calendar: Calendar = .current
    ) -> String? {
        guard let date = ISO8601.parse(timestamp) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
