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
//          "cache_read_input_tokens": 93669,
//          "output_tokens": 710
//        }
//     }
//   }
//
// Differences from Codex JSONL:
//   1. Usage is per-message, NOT cumulative — we emit one row per `assistant`
//      event, no delta math.
//   2. Many event types are noise (file-history-snapshot, progress, user,
//      system, last-prompt). We only consume `assistant`.
//   3. Synthetic / placeholder messages have model `<synthetic>` — skipped.
//   4. Session id is in every line; the filename stem also matches (verified
//      across 126 real files on the dev machine).

actor ClaudeImportEngine {
    private let database: DatabaseManager
    private let claudeRoots: [URL]

    init(database: DatabaseManager,
         claudeRoots: [URL] = ClaudeImportEngine.defaultRoots()) {
        self.database = database
        self.claudeRoots = claudeRoots
    }

    /// Resolve the directories where Claude Code stores rollouts.
    /// Settings override → both legacy (`~/.claude/projects`) and new
    /// (`~/.config/claude/projects`) defaults. Non-existent directories are
    /// silently ignored — `scan()` just returns an empty list.
    static func defaultRoots() -> [URL] {
        var roots: [URL] = []
        let override = SettingsStore.snapshot().claudeHomeOverride
        if !override.isEmpty {
            roots.append(URL(fileURLWithPath:
                (override as NSString).expandingTildeInPath)
                .appendingPathComponent("projects", isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
        roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        // Dedup while preserving order.
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.path).inserted }
    }

    func performScan() async throws -> ImportEngine.ScanReport {
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
            let fromOffset: Int64
            /// True when we're starting a fresh read; persist clears the
            /// session's existing usage_events. False for tail reads;
            /// persist relies on the v5 partial unique index to swallow
            /// re-emitted rows.
            let resetSession: Bool
        }

        let planned: [PlannedScan] = files.compactMap { file in
            guard let prior = priorState[file.path] else {
                return PlannedScan(file: file, fromOffset: 0, resetSession: true)
            }
            if prior.fileSize == file.fileSize && prior.fileMtimeMs == file.fileMtimeMs {
                return nil
            }
            // Truncation or rotation: file is smaller than the offset we
            // last consumed, so the bytes at that offset can't possibly
            // be what they used to be. Safest is a full re-read.
            if file.fileSize < prior.byteOffset {
                return PlannedScan(file: file, fromOffset: 0, resetSession: true)
            }
            // First time we see this file post-v5 (legacy import_state row
            // had no offset). One last full read regenerates
            // `provider_message_id` so the unique index can do its job
            // on subsequent scans.
            if prior.byteOffset == 0 {
                return PlannedScan(file: file, fromOffset: 0, resetSession: true)
            }
            return PlannedScan(file: file, fromOffset: prior.byteOffset, resetSession: false)
        }

        var importedSessions = 0
        var importedEvents = 0
        var errors: [String] = []

        for plan in planned {
            do {
                let output = try ClaudeRolloutParser.parse(
                    fileURL: plan.file.url, fromOffset: plan.fromOffset)
                guard let parsed = output.session else {
                    // Either the slice contained nothing, or this is a
                    // first-pass empty file. Either way: bump import_state
                    // so we don't re-scan.
                    try await persistEmpty(file: plan.file, byteOffset: output.endOffset)
                    continue
                }
                let count = try await persist(
                    parsed: parsed,
                    file: plan.file,
                    byteOffset: output.endOffset,
                    resetSession: plan.resetSession)
                importedSessions += 1
                importedEvents += count
            } catch {
                errors.append("\(plan.file.path): \(error)")
            }
        }

        return ImportEngine.ScanReport(
            scannedFiles: files.count,
            changedFiles: planned.count,
            importedSessions: importedSessions,
            importedEvents: importedEvents,
            importedRateLimitSamples: 0,    // Claude rollouts don't carry rate-limit samples.
            errors: errors)
    }

    // MARK: - scan

    private struct ClaudeFile {
        let url: URL
        let path: String
        let fileSize: Int64
        let fileMtimeMs: Int64
        var sessionId: String { url.deletingPathExtension().lastPathComponent }
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
            let resolvedTitle: String? = {
                if !resetSession, let existing, let t = existing.title, !t.isEmpty {
                    return t
                }
                return parsed.title
            }()
            let session = SessionRecord(
                sessionId: parsed.sessionId,
                rootSessionId: parsed.sessionId,
                parentSessionId: nil,
                title: resolvedTitle,
                sourcePath: file.path,
                startedAt: resolvedStartedAt,
                updatedAt: parsed.updatedAt,
                agentNickname: nil,
                agentRole: nil,
                lastModelId: parsed.lastModelId,
                latestPlanType: nil,
                containsSubagents: false,
                createdAt: existing?.createdAt ?? now,
                importedAt: now,
                provider: "claude")
            try session.save(db)

            if resetSession {
                try UsageEventRecord
                    .filter(Column("session_id") == parsed.sessionId)
                    .deleteAll(db)
            }

            // INSERT OR IGNORE so the partial unique index on
            // (session_id, provider_message_id) silently swallows any
            // re-emitted rows. Required for incremental tail reads —
            // the writer may flush a half-written `assistant` line
            // (caught by lastLineHadNewline) which then turns into a
            // new line on the next scan; if our `byteOffset` happens
            // to land mid-message it's also possible for the SAME
            // event to arrive twice across passes.
            var inserted = 0
            for evt in parsed.events {
                let total = evt.inputTokens + evt.cacheReadTokens
                    + evt.cacheCreationTokens + evt.outputTokens
                try db.execute(literal: """
                    INSERT OR IGNORE INTO usage_events (
                        session_id, timestamp, model_id,
                        input_tokens, cached_input_tokens, output_tokens,
                        reasoning_output_tokens, total_tokens, value_usd,
                        cache_creation_tokens, provider, model_inferred,
                        provider_message_id
                    ) VALUES (
                        \(parsed.sessionId), \(evt.timestamp), \(evt.modelId),
                        \(evt.inputTokens), \(evt.cacheReadTokens), \(evt.outputTokens),
                        \(0), \(total), \(0.0),
                        \(evt.cacheCreationTokens), \("claude"), \(false),
                        \(evt.messageId)
                    )
                    """)
                inserted += db.changesCount
            }

            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: parsed.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now,
                byteOffset: byteOffset)
            try state.save(db)

            return inserted
        }
    }
}

// MARK: - Parser

struct ParsedClaudeSession {
    let sessionId: String
    let title: String?
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
    let outputTokens: Int64
    /// `message.id` from the rollout. Used as the dedup key so that
    /// re-parsing the trailing slice during incremental scans is
    /// idempotent at the SQL layer (partial unique index added in v5).
    /// `nil` when the rollout omitted it (very old Claude builds).
    let messageId: String?
}

enum ClaudeRolloutParser {

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
    ///   - When `fromOffset > 0` we don't rebuild session-header fields
    ///     (sessionId/title/startedAt) — those landed in the DB on the
    ///     first pass; we still bump `updatedAt`/`lastModelId` if the new
    ///     slice contains them.
    ///   - In-pass `seenMessageIds` still dedupes the well-known "stub then
    ///     real assistant row" pattern. Cross-pass dedup is the SQL layer's
    ///     job (partial unique index on `(session_id, provider_message_id)`).
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
        var startedAt: String? = nil
        var updatedAt: String? = nil
        var lastModelId: String? = nil
        var events: [ClaudeUsageEvent] = []

        // Same-pass dedup for the "stub then real row" pattern (see longer
        // comment below). The cross-scan analogue is the partial unique
        // index in v5 — we no longer rely on this Set carrying state across
        // invocations.
        var seenMessageIds: Set<String> = []

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
            if title == nil, let cwd = raw["cwd"] as? String {
                // Use the leaf directory name as a friendly title fallback.
                title = (cwd as NSString).lastPathComponent
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
            if let messageId {
                if !seenMessageIds.insert(messageId).inserted { continue }
            }

            lastModelId = normalized

            events.append(ClaudeUsageEvent(
                timestamp: ts ?? ISO8601.fractional.string(from: Date()),
                modelId: normalized,
                inputTokens: inputTokens,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreate,
                outputTokens: output,
                messageId: messageId))
        }

        // Fall back to the filename stem if no event carried sessionId.
        if sessionId == nil {
            sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
        guard let sid = sessionId, !events.isEmpty else {
            return Output(session: nil, endOffset: consumed)
        }

        let session = ParsedClaudeSession(
            sessionId: sid,
            title: title,
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
}
