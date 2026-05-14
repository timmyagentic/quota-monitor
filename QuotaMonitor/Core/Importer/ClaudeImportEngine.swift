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

        let changed = files.filter { file in
            guard let prior = priorState[file.path] else { return true }
            return prior.fileSize != file.fileSize || prior.fileMtimeMs != file.fileMtimeMs
        }

        var importedSessions = 0
        var importedEvents = 0
        var errors: [String] = []

        for file in changed {
            do {
                guard let parsed = try ClaudeRolloutParser.parse(fileURL: file.url) else {
                    // File parsed cleanly but contained zero billable
                    // assistant events (subagent stubs, prompt-only
                    // sessions, etc). Not an error — record import
                    // state so we don't re-scan it next pass, but stay
                    // silent in the UI.
                    try await persistEmpty(file: file)
                    continue
                }
                let count = try await persist(parsed: parsed, file: file)
                importedSessions += 1
                importedEvents += count
            } catch {
                errors.append("\(file.path): \(error)")
            }
        }

        return ImportEngine.ScanReport(
            scannedFiles: files.count,
            changedFiles: changed.count,
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
    private func persistEmpty(file: ClaudeFile) async throws {
        let now = ISO8601.fractional.string(from: Date())
        try await database.pool.write { db in
            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: file.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now)
            try state.save(db)
        }
    }

    // MARK: - persist

    private func persist(parsed: ParsedClaudeSession, file: ClaudeFile) async throws -> Int {
        let now = ISO8601.fractional.string(from: Date())
        return try await database.pool.write { db in
            let existing = try SessionRecord
                .filter(Column("session_id") == parsed.sessionId)
                .fetchOne(db)
            let session = SessionRecord(
                sessionId: parsed.sessionId,
                rootSessionId: parsed.sessionId,
                parentSessionId: nil,
                title: parsed.title,
                sourcePath: file.path,
                startedAt: parsed.startedAt,
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

            try UsageEventRecord
                .filter(Column("session_id") == parsed.sessionId)
                .deleteAll(db)
            for evt in parsed.events {
                let row = UsageEventRecord(
                    id: nil,
                    sessionId: parsed.sessionId,
                    timestamp: evt.timestamp,
                    modelId: evt.modelId,
                    inputTokens: evt.inputTokens,
                    cachedInputTokens: evt.cacheReadTokens,
                    outputTokens: evt.outputTokens,
                    reasoningOutputTokens: 0,
                    totalTokens: evt.inputTokens + evt.cacheReadTokens
                                + evt.cacheCreationTokens + evt.outputTokens,
                    valueUsd: 0,
                    cacheCreationTokens: evt.cacheCreationTokens,
                    provider: "claude",
                    modelInferred: false)
                try row.insert(db)
            }

            let state = ImportStateRecord(
                sourcePath: file.path,
                sessionId: parsed.sessionId,
                fileSize: file.fileSize,
                fileMtimeMs: file.fileMtimeMs,
                lastImportedAt: now)
            try state.save(db)

            return parsed.events.count
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
}

enum ClaudeRolloutParser {

    static func parse(fileURL: URL) throws -> ParsedClaudeSession? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var sessionId: String? = nil
        var title: String? = nil
        var startedAt: String? = nil
        var updatedAt: String? = nil
        var lastModelId: String? = nil
        var events: [ClaudeUsageEvent] = []

        // Dedup by message.id — the same assistant message can appear in
        // multiple rollout snapshots if Claude rewrites the file mid-session.
        // ccusage uses (sessionId, requestId, messageId); we just use messageId
        // because Claude Code's id is request-scoped.
        var seenMessageIds: Set<String> = []

        for line in try LineReader(handle: handle) {
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

            if let messageId = message["id"] as? String {
                if !seenMessageIds.insert(messageId).inserted { continue }
            }

            lastModelId = normalized

            events.append(ClaudeUsageEvent(
                timestamp: ts ?? ISO8601.fractional.string(from: Date()),
                modelId: normalized,
                inputTokens: inputTokens,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreate,
                outputTokens: output))
        }

        // Fall back to the filename stem if no event carried sessionId.
        if sessionId == nil {
            sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
        guard let sid = sessionId, !events.isEmpty else { return nil }

        return ParsedClaudeSession(
            sessionId: sid,
            title: title,
            startedAt: startedAt,
            updatedAt: updatedAt,
            lastModelId: lastModelId,
            events: events)
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let d = any as? Double { return Int64(d) }
        if let n = any as? NSNumber { return n.int64Value }
        return nil
    }
}
