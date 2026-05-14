import Foundation

// Reads one rollout-*.jsonl file and produces a ParsedSession that's ready to insert.
//
// Key invariants (lifted from codex-pacer's importer.rs):
//   1. token_count.info.total_token_usage is CUMULATIVE per session.
//      The first sample IS the delta from t=0; subsequent samples are
//      computed as the diff against the previous cumulative value.
//   2. If the cumulative counter ever decreases (context reset / new turn),
//      the current sample is itself the post-reset running total — emit it
//      as a fresh delta rather than dropping it.
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

struct RateLimitSampleDraft {
    let bucket: String              // "primary" | "secondary"
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

        var previousUsage: TokenUsageWire?
        var deltas: [UsageDelta] = []
        var rateLimitSamples: [RateLimitSampleDraft] = []

        for line in try LineReader(handle: handle) {
            guard let event = RolloutEvent.decode(line: line) else { continue }

            switch event {
            case .sessionMeta(let meta, let envelopeTs):
                let ts = envelopeTs ?? meta.timestamp
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

            case .tokenCount(let tc, let envelopeTs):
                guard let info = tc.info,
                      let total = info.totalTokenUsage else { continue }
                let timestamp = envelopeTs ?? ISO8601.fractional.string(from: Date())

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

                if let delta = computeDelta(previous: previousUsage, current: total) {
                    deltas.append(UsageDelta(
                        timestamp: timestamp,
                        modelId: resolvedModel,
                        inputTokens: delta.inputTokens,
                        cachedInputTokens: delta.cachedInputTokens,
                        outputTokens: delta.outputTokens,
                        reasoningOutputTokens: delta.reasoningOutputTokens,
                        totalTokens: delta.totalTokens,
                        modelInferred: inferred))
                }
                previousUsage = total
                updatedAt = timestamp

                if let plan = tc.rateLimits?.planType { latestPlanType = plan }
                rateLimitSamples.append(contentsOf:
                    extractSamples(from: tc.rateLimits, at: timestamp))

            case .other:
                continue
            }
        }

        // Fall back to the file-name derived session id if the file had no
        // recognizable session_meta event.
        if sessionId == nil { sessionId = fallbackSessionId ?? sessionIdFromFilename(fileURL) }
        guard let resolved = sessionId else { return nil }

        // Codex rollouts don't carry a user-facing title. Mirror Claude's
        // importer and use the cwd's leaf directory name as a friendly fallback
        // so the UI shows something more useful than "Untitled session".
        let title: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? nil : leaf
        }()

        return ParsedSession(
            sessionId: resolved,
            parentSessionId: parentSessionId,
            rootSessionId: parentSessionId == nil ? resolved : (parentSessionId ?? resolved),
            title: title,
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

    private static func computeDelta(
        previous: TokenUsageWire?, current: TokenUsageWire
    ) -> TokenUsageWire? {
        // First event: total_token_usage is cumulative from session start, so
        // the first sample IS the delta from t=0 to now. Mirrors codex-pacer's
        // importer.rs which clones `current` when `previous` is None
        // (importer.rs:719-723). The earlier "skip first sample" behavior
        // here was a bug that systematically dropped the opening event of
        // every session.
        guard let previous else {
            return current == .zero ? nil : current
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
            return current == .zero ? nil : current
        }

        let delta = TokenUsageWire(
            inputTokens: current.inputTokens - previous.inputTokens,
            cachedInputTokens: current.cachedInputTokens - previous.cachedInputTokens,
            outputTokens: current.outputTokens - previous.outputTokens,
            reasoningOutputTokens: current.reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: current.totalTokens - previous.totalTokens)

        // Skip zero-delta events; they're keepalives.
        if delta == .zero { return nil }
        return delta
    }

    // MARK: - rate-limit samples

    private static func extractSamples(
        from rateLimits: EmbeddedRateLimits?, at timestamp: String
    ) -> [RateLimitSampleDraft] {
        guard let rl = rateLimits else { return [] }
        var samples: [RateLimitSampleDraft] = []
        if let primary = rl.primary, let resets = primary.resetsAt {
            samples.append(RateLimitSampleDraft(
                bucket: "primary",
                sampleTimestamp: timestamp,
                planType: rl.planType,
                limitName: rl.limitName,
                resetsAt: ISO8601.fractional.string(
                    from: Date(timeIntervalSince1970: resets)),
                usedPercent: primary.usedPercent,
                remainingPercent: max(0, 100 - primary.usedPercent)))
        }
        if let secondary = rl.secondary, let resets = secondary.resetsAt {
            samples.append(RateLimitSampleDraft(
                bucket: "secondary",
                sampleTimestamp: timestamp,
                planType: rl.planType,
                limitName: rl.limitName,
                resetsAt: ISO8601.fractional.string(
                    from: Date(timeIntervalSince1970: resets)),
                usedPercent: secondary.usedPercent,
                remainingPercent: max(0, 100 - secondary.usedPercent)))
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
