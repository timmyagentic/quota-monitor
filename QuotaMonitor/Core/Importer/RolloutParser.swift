import Foundation

// Reads one rollout-*.jsonl file and produces a ParsedSession that's ready to insert.
//
// Key invariants:
//   1. token_count.info.last_token_usage is the preferred per-event delta
//      when present. ccusage documents this as the delta for the most recent
//      turn. Current Codex rollouts may interleave multiple cumulative
//      total_token_usage streams, so total_token_usage is not always monotonic
//      in file order.
//   2. Older rollouts may only have total_token_usage. For those, compute the
//      delta from the previous cumulative value, and treat a backwards counter
//      as the start of a fresh cumulative segment.
//   3. token_count events do not carry a model_id in today's CLI — we use the
//      most recent `turn_context.payload.model`. Defensive fallbacks on the
//      payload itself match ccusage's `extractModel` heuristic. If everything
//      fails (legacy session that ran before turn_context existed), attribute
//      to LegacyFallbackModel and flag the event so UI can asterisk the cost.
//   4. rate_limits embedded in token_count are valuable historical samples
//      (different shape from the app-server live API).

/// Models are now stamped on `turn_context`, but legacy sessions and the
/// occasional malformed rollout have no model anywhere. ccusage attributes
/// these to `gpt-5`; we follow suit so the cost is at least roughly right
/// instead of silently zero. UI flags inferred events.
let LegacyFallbackModel = "gpt-5"

struct ParsedSession {
    var sessionId: String
    var parentSessionId: String?
    var rootSessionId: String
    var title: String?
    var projectName: String?
    var cwd: String?
    var startedAt: String?
    var updatedAt: String?
    var agentNickname: String?
    var agentRole: String?
    var lastModelId: String?
    var latestPlanType: String?
    var modelIds: Set<String>
    var usageDeltas: [UsageDelta]
    var rateLimitSamples: [RateLimitSampleDraft]
}

struct UsageDelta {
    let timestamp: String
    let modelId: String
    let turnId: String?
    let serviceTierPreference: CodexServiceTierPreference?
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
    /// True iff `modelId` was inferred via the legacy fallback (no
    /// `turn_context` ever set the model in this session). Surfaced in UI
    /// so the user knows the cost is approximate.
    let modelInferred: Bool
}

private struct ActiveCodexTurn {
    var id: String?
    let serviceTierPreference: CodexServiceTierPreference?
}

private extension TaskLifecyclePayload {
    /// Codex turn IDs are UUIDv7 in current rollouts. Their first 48 bits are
    /// Unix epoch milliseconds, which gives us durable task timing when older
    /// `task_started` payloads omit `started_at` and envelope timestamps were
    /// rewritten by a child-session replay.
    var uuidV7StartedAt: TimeInterval? {
        guard let turnId else { return nil }
        let parts = turnId.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8,
              parts[1].count == 4,
              parts[2].first == "7",
              let milliseconds = UInt64(parts[0] + parts[1], radix: 16)
        else { return nil }
        return TimeInterval(milliseconds) / 1_000
    }
}

private enum ChildReplayGate {
    case childCreatedAt(TimeInterval)
    case firstSelfTimedTask

    func isCleared(
        by task: TaskLifecyclePayload,
        lineTimestamp: String?,
        sawReplayedSessionMeta: Bool
    ) -> Bool {
        switch self {
        case .childCreatedAt(let createdAt):
            if let startedAt = task.startedAt {
                return startedAt >= floor(createdAt)
            }
            if let uuidStartedAt = task.uuidV7StartedAt {
                return uuidStartedAt >= createdAt
            }
            // A direct child rollout has no replayed session_meta before its
            // first task, so that task is the child's own even in old formats
            // that lack both started_at and UUIDv7 turn IDs.
            if !sawReplayedSessionMeta { return true }
            // Last-resort compatibility for a replayed old-format rollout:
            // require a strictly later envelope time. Equality is deliberately
            // excluded because parent snapshots are commonly rewritten to the
            // child creation timestamp.
            guard let lineTimestamp,
                  let eventTime = ISO8601.parse(lineTimestamp)
            else { return false }
            return eventTime.timeIntervalSince1970 > createdAt
        case .firstSelfTimedTask:
            guard let startedAt = task.startedAt ?? task.uuidV7StartedAt else {
                return !sawReplayedSessionMeta
            }
            guard let lineTimestamp,
                  let eventTime = ISO8601.parse(lineTimestamp)
            else { return false }
            return startedAt >= floor(eventTime.timeIntervalSince1970)
        }
    }
}

struct RateLimitSampleDraft {
    let bucket: String              // semantic "primary" (5h) | "secondary" (7d)
    let windowDuration: TimeInterval?
    let sampleTimestamp: String
    let planType: String?
    let limitName: String?
    let resetsAt: String
    let usedPercent: Double
    let remainingPercent: Double
}

enum RolloutParser {

    /// Parse a full rollout file. Returns nil if no session_id can be resolved.
    static func parse(fileURL: URL, fallbackSessionId: String? = nil) throws -> ParsedSession? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var sessionId: String?
        var parentSessionId: String?
        var startedAt: String?
        var updatedAt: String?
        var agentNickname: String?
        var agentRole: String?
        var cwd: String?
        var currentModel: String?
        var currentModelIsFallback = false
        var seenModels: Set<String> = []
        var latestPlanType: String?
        var pendingServiceTierPreference: CodexServiceTierPreference?
        var activeTurn: ActiveCodexTurn?
        var sawSessionMeta = false
        var childReplayGate: ChildReplayGate?
        var sawReplayedSessionMeta = false

        var previousUsage: TokenUsageWire?
        var seenUsageSnapshots: Set<UsageSnapshotKey> = []
        var deltas: [UsageDelta] = []
        var rateLimitSamples: [RateLimitSampleDraft] = []

        for line in try LineReader(handle: handle) {
            guard let event = RolloutEvent.decode(line: line) else { continue }

            switch event {
            case .sessionMeta(let meta, let envelopeTs):
                let ts = envelopeTs ?? meta.timestamp
                if sawSessionMeta,
                   childReplayGate != nil,
                   let childId = sessionId,
                   let replayedId = meta.id,
                   replayedId != childId
                {
                    sawReplayedSessionMeta = true
                }
                if !sawSessionMeta {
                    sawSessionMeta = true
                    if meta.isChildSession {
                        if let ts, let createdAt = ISO8601.parse(ts) {
                            childReplayGate = .childCreatedAt(
                                createdAt.timeIntervalSince1970)
                        } else {
                            childReplayGate = .firstSelfTimedTask
                        }
                    }
                }
                if sessionId == nil, let id = meta.id { sessionId = id }
                if startedAt == nil { startedAt = ts ?? meta.timestamp }
                if updatedAt == nil { updatedAt = ts ?? meta.timestamp }
                if agentNickname == nil { agentNickname = meta.resolvedAgentNickname }
                if agentRole == nil { agentRole = meta.resolvedAgentRole }
                if parentSessionId == nil { parentSessionId = meta.resolvedParentSessionId }
                if cwd == nil, let metaCwd = meta.cwd, !metaCwd.isEmpty { cwd = metaCwd }

            case .turnContext(let tc, _):
                if let model = tc.model {
                    let normalized = NormalizeModelId(model)
                    currentModel = normalized
                    currentModelIsFallback = false
                    seenModels.insert(normalized)
                }

                if let turn = activeTurn {
                    if turn.id == nil {
                        activeTurn?.id = tc.turnId
                    } else if let contextTurnId = tc.turnId,
                              turn.id != contextTurnId
                    {
                        activeTurn = ActiveCodexTurn(
                            id: contextTurnId,
                            serviceTierPreference: nil)
                    }
                } else {
                    activeTurn = ActiveCodexTurn(
                        id: tc.turnId,
                        serviceTierPreference: nil)
                }

            case .threadSettingsApplied(let settings, _):
                pendingServiceTierPreference = CodexServiceTierPreference(
                    rolloutValue: settings.resolvedServiceTier)

            case .taskStarted(let task, let envelopeTs):
                if childReplayGate?.isCleared(
                    by: task,
                    lineTimestamp: envelopeTs,
                    sawReplayedSessionMeta: sawReplayedSessionMeta) == true
                {
                    childReplayGate = nil
                }
                activeTurn = ActiveCodexTurn(
                    id: task.turnId,
                    serviceTierPreference: pendingServiceTierPreference)

            case .taskComplete(let task, _):
                if let turn = activeTurn, turn.id == task.turnId {
                    activeTurn = nil
                }

            case .tokenCount(let tc, let envelopeTs):
                let timestamp = envelopeTs ?? ISO8601.fractional.string(from: Date())
                if let plan = tc.rateLimits?.planType { latestPlanType = plan }
                if childReplayGate == nil {
                    rateLimitSamples.append(contentsOf:
                        extractSamples(from: tc.rateLimits, at: timestamp))
                }

                guard let info = tc.info else { continue }

                // Resolution order: explicit on payload → tracked turn_context →
                // legacy fallback. Only the last counts as inferred.
                let payloadModel = extractPayloadModel(from: tc).map(NormalizeModelId)
                if let m = payloadModel {
                    currentModel = m
                    currentModelIsFallback = false
                }
                let resolvedModel: String
                let inferred: Bool
                if let m = payloadModel ?? currentModel {
                    resolvedModel = m
                    inferred = currentModelIsFallback
                } else {
                    resolvedModel = LegacyFallbackModel
                    inferred = true
                    currentModel = LegacyFallbackModel
                    currentModelIsFallback = true
                }
                seenModels.insert(resolvedModel)

                let delta = usageDelta(
                    from: info,
                    previousTotal: &previousUsage,
                    seenUsageSnapshots: &seenUsageSnapshots)
                if childReplayGate == nil, let delta {
                    deltas.append(UsageDelta(
                        timestamp: timestamp,
                        modelId: resolvedModel,
                        turnId: activeTurn?.id,
                        serviceTierPreference: activeTurn?.serviceTierPreference,
                        inputTokens: delta.inputTokens,
                        cachedInputTokens: delta.cachedInputTokens,
                        outputTokens: delta.outputTokens,
                        reasoningOutputTokens: delta.reasoningOutputTokens,
                        totalTokens: delta.totalTokens,
                        modelInferred: inferred))
                }
                updatedAt = timestamp

            case .other:
                continue
            }
        }

        // Fall back to the file-name derived session id if the file had no
        // recognizable session_meta event.
        if sessionId == nil { sessionId = fallbackSessionId ?? sessionIdFromFilename(fileURL) }
        guard let resolved = sessionId else { return nil }

        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? nil : leaf
        }()

        return ParsedSession(
            sessionId: resolved,
            parentSessionId: parentSessionId,
            rootSessionId: parentSessionId == nil ? resolved : (parentSessionId ?? resolved),
            title: nil,
            projectName: projectName,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            agentNickname: agentNickname,
            agentRole: agentRole,
            lastModelId: currentModel,
            latestPlanType: latestPlanType,
            modelIds: seenModels,
            usageDeltas: deltas,
            rateLimitSamples: rateLimitSamples)
    }

    // MARK: - delta logic

    private static func usageDelta(
        from info: TokenCountInfo,
        previousTotal: inout TokenUsageWire?,
        seenUsageSnapshots: inout Set<UsageSnapshotKey>
    ) -> TokenUsageWire? {
        if let total = info.totalTokenUsage {
            if total == previousTotal { return nil }
            let snapshot = UsageSnapshotKey(total: total, last: info.lastTokenUsage)
            if seenUsageSnapshots.contains(snapshot) { return nil }
            seenUsageSnapshots.insert(snapshot)
            if let last = info.lastTokenUsage {
                previousTotal = total
                return meaningfulUsage(last)
            }
            let delta = computeDelta(previous: previousTotal, current: total)
            previousTotal = total
            return delta
        }
        if let last = info.lastTokenUsage {
            return meaningfulUsage(last)
        }
        return nil
    }

    private static func meaningfulUsage(_ usage: TokenUsageWire) -> TokenUsageWire? {
        if usage == .zero { return nil }
        let hasComponentBuckets =
            usage.inputTokens != 0
            || usage.cachedInputTokens != 0
            || usage.outputTokens != 0
            || usage.reasoningOutputTokens != 0
        // Some historical Codex rows carry a huge `total_tokens` value while
        // every token bucket is zero. Pricing cannot use those rows and the
        // UI token totals become nonsense, so treat them as malformed samples.
        if usage.totalTokens > 0 && !hasComponentBuckets { return nil }
        return usage
    }

    private static func computeDelta(
        previous: TokenUsageWire?, current: TokenUsageWire
    ) -> TokenUsageWire? {
        // Fallback for older rollout rows that predate last_token_usage.
        // First event: total_token_usage is cumulative from session start, so
        // the first sample IS the delta from t=0 to now.
        guard let previous else {
            return meaningfulUsage(current)
        }
        let wentBackwards =
            current.inputTokens < previous.inputTokens
            || current.cachedInputTokens < previous.cachedInputTokens
            || current.outputTokens < previous.outputTokens
            || current.reasoningOutputTokens < previous.reasoningOutputTokens
            || current.totalTokens < previous.totalTokens
        if wentBackwards {
            // Counter went backwards → context reset. `current` is now the
            // running total of the post-reset session segment; treat it as
            // a fresh delta rather than dropping it (mirrors codex-pacer's
            // importer.rs:796-804).
            return meaningfulUsage(current)
        }

        let delta = TokenUsageWire(
            inputTokens: current.inputTokens - previous.inputTokens,
            cachedInputTokens: current.cachedInputTokens - previous.cachedInputTokens,
            outputTokens: current.outputTokens - previous.outputTokens,
            reasoningOutputTokens: current.reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: current.totalTokens - previous.totalTokens)

        // Skip zero-delta events; they're keepalives.
        return meaningfulUsage(delta)
    }

    // MARK: - rate-limit samples

    private static func extractSamples(
        from rateLimits: EmbeddedRateLimits?, at timestamp: String
    ) -> [RateLimitSampleDraft] {
        guard let rl = rateLimits else { return [] }
        var samples: [RateLimitSampleDraft] = []
        let wireWindows = [rl.primary, rl.secondary]
        for window in wireWindows {
            guard let window,
                  let resets = window.resetsAt,
                  let bucket = CodexQuotaWindowClassifier.classify(
                    duration: window.windowMinutes.map { TimeInterval($0 * 60) })
            else { continue }

            samples.append(RateLimitSampleDraft(
                bucket: bucket.rawValue,
                windowDuration: window.windowMinutes.map { TimeInterval($0 * 60) },
                sampleTimestamp: timestamp,
                planType: rl.planType,
                limitName: rl.limitName,
                resetsAt: ISO8601.fractional.string(
                    from: Date(timeIntervalSince1970: resets)),
                usedPercent: window.usedPercent,
                remainingPercent: max(0, 100 - window.usedPercent)))
        }
        return samples
    }

    // MARK: - filename fallback (`rollout-2025-11-20T19-18-52-019aa0fd-...jsonl`)

    private static func sessionIdFromFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        // session ids are UUID-ish: 8-4-4-4-12. The trailing 5 segments form it.
        return parts.suffix(5).joined(separator: "-")
    }
}

private struct UsageSnapshotKey: Hashable {
    let total: TokenUsageWire
    let last: TokenUsageWire?
}

// MARK: - line reader

/// Iterator that yields one line of bytes at a time. We don't use
/// `FileHandle.bytes.lines` because it forces String conversion before delimiting,
/// which is wasteful when most lines we'll skip.
///
/// Performance note: the obvious implementation — `firstIndex(of: 0x0A)` +
/// `removeSubrange` per line on a single growing `Data` — is catastrophically
/// slow for large files with long lines (Codex rollouts: ~21 KB/line average).
/// Measured 2.5 MB/s on a 469 MB rollout, i.e. ~3 min just to *read* the
/// file. Two reasons:
///   1. `removeSubrange` shifts the entire remaining buffer per line.
///   2. `firstIndex(of:)` re-scans from the start each call.
/// This version keeps a cursor into the buffer, scans the unread region via
/// a raw pointer, and only compacts when forced to read more. Same 469 MB
/// file: 0.65 s (760 MB/s, ~300× faster).
struct LineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    private var cursor = 0
    private var eof = false
    /// True when the most recent `next()` returned a line whose trailing
    /// `\n` had been seen in the file. False only for the final tail when
    /// the file ends without a newline (mid-write JSONL). Callers that
    /// need to track byte progress should not advance their offset over
    /// such a tail — a future scan needs to re-read it once it's been
    /// finished by the writer.
    private(set) var lastLineHadNewline = false

    init(handle: FileHandle, chunkSize: Int = 256 * 1024) throws {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    mutating func next() -> Data? {
        while true {
            if cursor < buffer.count {
                let nl: Int? = buffer.withUnsafeBytes { raw -> Int? in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                        return nil
                    }
                    var i = cursor
                    let end = buffer.count
                    while i < end {
                        if base[i] == 0x0A { return i }
                        i &+= 1
                    }
                    return nil
                }
                if let nl {
                    let line = buffer.subdata(in: cursor..<nl)
                    cursor = nl + 1
                    lastLineHadNewline = true
                    return line
                }
            }
            // No newline in the unread region — drop the consumed prefix
            // before pulling more bytes so the buffer doesn't grow unbounded.
            if cursor > 0 {
                buffer.removeSubrange(0..<cursor)
                cursor = 0
            }
            if eof {
                if !buffer.isEmpty {
                    let last = buffer
                    buffer = Data()
                    lastLineHadNewline = false
                    return last
                }
                return nil
            }
            do {
                if let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    eof = true
                }
            } catch {
                eof = true
            }
        }
    }
}

// MARK: - model id normalization

/// Mirror of codex-pacer's `normalize_model_id`: lowercase, strip whitespace.
/// Pricing-table lookups happen against the normalized id.
func NormalizeModelId(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Defensive model extraction from a `token_count` payload. Today's Codex
/// CLI never populates these fields — model lives on `turn_context` — but
/// ccusage scrapes them on every event in case future builds (or third-party
/// recorders) stamp it directly. We do the same so we don't silently lose
/// attribution if Codex starts populating them.
func extractPayloadModel(from tc: TokenCountPayload) -> String? {
    if let m = nonEmpty(tc.info?.model) { return m }
    if let m = nonEmpty(tc.info?.modelName) { return m }
    if let m = metadataModel(tc.info?.metadata) { return m }
    if let m = nonEmpty(tc.model) { return m }
    if let m = metadataModel(tc.metadata) { return m }
    return nil
}

private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
}

private func metadataModel(_ value: JSONValue?) -> String? {
    guard let value, case .object(let dict) = value,
          case .string(let m)? = dict["model"], !m.isEmpty
    else { return nil }
    return m
}
