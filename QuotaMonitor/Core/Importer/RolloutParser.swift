import CryptoKit
import Darwin
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

struct ParsedSession: Sendable {
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

struct UsageDelta: Equatable, Sendable {
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

struct ActiveCodexTurn: Codable, Equatable, Sendable {
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

enum ChildReplayGate: Codable, Equatable, Sendable {
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

struct RateLimitSampleDraft: Equatable, Sendable {
    let bucket: String              // semantic "primary" (5h) | "secondary" (7d)
    let windowDuration: TimeInterval?
    let sampleTimestamp: String
    let planType: String?
    let limitName: String?
    let resetsAt: String
    let usedPercent: Double
    let remainingPercent: Double
}

struct UsageSnapshotKey: Codable, Hashable, Sendable, Comparable {
    let total: TokenUsageWire
    let last: TokenUsageWire?

    static func < (lhs: UsageSnapshotKey, rhs: UsageSnapshotKey) -> Bool {
        lhs.sortValues.lexicographicallyPrecedes(rhs.sortValues)
    }

    private var sortValues: [Int64] {
        [
            total.inputTokens,
            total.cachedInputTokens,
            total.outputTokens,
            total.reasoningOutputTokens,
            total.totalTokens,
            last == nil ? 0 : 1,
            last?.inputTokens ?? 0,
            last?.cachedInputTokens ?? 0,
            last?.outputTokens ?? 0,
            last?.reasoningOutputTokens ?? 0,
            last?.totalTokens ?? 0,
        ]
    }
}

/// Everything the Codex reducer needs in order to continue at an exact JSONL
/// record boundary. Emitted usage/rate-limit rows deliberately do not live in
/// this value: a checkpoint describes parser state, not already-persisted data.
struct CodexRolloutReducerState: Codable, Equatable, Sendable {
    var sessionId: String?
    var parentSessionId: String?
    var startedAt: String?
    var updatedAt: String?
    var agentNickname: String?
    var agentRole: String?
    var cwd: String?
    var currentModel: String?
    var currentModelIsFallback = false
    var seenModels: [String] = []
    var latestPlanType: String?
    var pendingServiceTierPreference: CodexServiceTierPreference?
    var activeTurn: ActiveCodexTurn?
    var sawSessionMeta = false
    var childReplayGate: ChildReplayGate?
    var sawReplayedSessionMeta = false
    var previousUsage: TokenUsageWire?
    var seenUsageSnapshots: [UsageSnapshotKey] = []
    /// True only when a real session_meta established one stable root session
    /// and no later metadata introduced a parent/fork/subagent marker.
    var isIncrementalRootEligible = false

    var canResumeIncrementally: Bool {
        isIncrementalRootEligible
            && sawSessionMeta
            && sessionId?.isEmpty == false
            && parentSessionId == nil
            && childReplayGate == nil
    }

    init(
        sessionId: String? = nil,
        parentSessionId: String? = nil,
        startedAt: String? = nil,
        updatedAt: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        cwd: String? = nil,
        currentModel: String? = nil,
        currentModelIsFallback: Bool = false,
        seenModels: [String] = [],
        latestPlanType: String? = nil,
        pendingServiceTierPreference: CodexServiceTierPreference? = nil,
        activeTurn: ActiveCodexTurn? = nil,
        sawSessionMeta: Bool = false,
        childReplayGate: ChildReplayGate? = nil,
        sawReplayedSessionMeta: Bool = false,
        previousUsage: TokenUsageWire? = nil,
        seenUsageSnapshots: [UsageSnapshotKey] = [],
        isIncrementalRootEligible: Bool = false
    ) {
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.cwd = cwd
        self.currentModel = currentModel
        self.currentModelIsFallback = currentModelIsFallback
        self.seenModels = seenModels
        self.latestPlanType = latestPlanType
        self.pendingServiceTierPreference = pendingServiceTierPreference
        self.activeTurn = activeTurn
        self.sawSessionMeta = sawSessionMeta
        self.childReplayGate = childReplayGate
        self.sawReplayedSessionMeta = sawReplayedSessionMeta
        self.previousUsage = previousUsage
        self.seenUsageSnapshots = seenUsageSnapshots
        self.isIncrementalRootEligible = isIncrementalRootEligible
        normalizeCollections()
    }

    mutating func normalizeCollections() {
        seenModels = Array(Set(seenModels)).sorted()
        seenUsageSnapshots = Array(Set(seenUsageSnapshots)).sorted()
    }
}

struct CodexRolloutCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let offset: Int64
    let state: CodexRolloutReducerState
    let sourceIdentity: RolloutSourceIdentity
    /// Hash of the first fingerprint window in the committed prefix.
    let prefixHash: Data
    /// Hash of the fingerprint window immediately before `offset`.
    let boundaryHash: Data

    init(
        offset: Int64,
        state: CodexRolloutReducerState,
        sourceIdentity: RolloutSourceIdentity,
        prefixHash: Data,
        boundaryHash: Data
    ) {
        var canonical = state
        canonical.normalizeCollections()
        self.version = Self.currentVersion
        self.offset = offset
        self.state = canonical
        self.sourceIdentity = sourceIdentity
        self.prefixHash = prefixHash
        self.boundaryHash = boundaryHash
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> CodexRolloutCheckpoint {
        let checkpoint = try JSONDecoder().decode(Self.self, from: data)
        guard checkpoint.version == currentVersion else {
            throw RolloutParserError.unsupportedCheckpointVersion(checkpoint.version)
        }
        guard checkpoint.offset >= 0 else {
            throw RolloutParserError.invalidCheckpointOffset(checkpoint.offset)
        }
        return CodexRolloutCheckpoint(
            offset: checkpoint.offset,
            state: checkpoint.state,
            sourceIdentity: checkpoint.sourceIdentity,
            prefixHash: checkpoint.prefixHash,
            boundaryHash: checkpoint.boundaryHash)
    }
}

enum RolloutParserError: Error, Equatable, CustomStringConvertible {
    case unsupportedCheckpointVersion(Int)
    case invalidCheckpointOffset(Int64)
    case checkpointIsNotRoot
    case requiresFullRebuild(String)

    var description: String {
        switch self {
        case .unsupportedCheckpointVersion(let version):
            return "unsupported Codex checkpoint version: \(version)"
        case .invalidCheckpointOffset(let offset):
            return "invalid Codex checkpoint offset: \(offset)"
        case .checkpointIsNotRoot:
            return "Codex checkpoint is not eligible for root-session incremental import"
        case .requiresFullRebuild(let reason):
            return "Codex incremental import requires a full rebuild: \(reason)"
        }
    }
}

struct RolloutFileSnapshot: Codable, Equatable, Sendable {
    let size: Int64
    let mtimeMs: Int64
    let device: Int64
    let inode: Int64
    let birthtimeNs: Int64

    var sourceIdentity: RolloutSourceIdentity {
        RolloutSourceIdentity(
            device: device,
            inode: inode,
            birthtimeNs: birthtimeNs)
    }

    static func modificationTimeMilliseconds(
        seconds: Int64,
        nanoseconds: Int64
    ) -> Int64 {
        seconds * 1_000 + nanoseconds / 1_000_000
    }
}

struct RolloutSourceIdentity: Codable, Equatable, Hashable, Sendable {
    let device: Int64
    let inode: Int64
    let birthtimeNs: Int64
}

struct CodexRolloutParseOutput: Sendable {
    let session: ParsedSession?
    let checkpoint: CodexRolloutCheckpoint?
    let endOffset: Int64
    let snapshot: RolloutFileSnapshot
    let startPrefixHash: Data
    let prefixHash: Data
    let startBoundaryHash: Data
    let endBoundaryHash: Data
    let sequentialBytesRead: Int64
    let hasIncompleteTail: Bool
}

enum RolloutParser {

    static let fingerprintWindowBytes: Int64 = 4 * 1024

    /// Parse a full rollout file. Returns nil if no session_id can be resolved.
    static func parse(fileURL: URL, fallbackSessionId: String? = nil) throws -> ParsedSession? {
        try parseIncrementally(
            fileURL: fileURL,
            fallbackSessionId: fallbackSessionId
        ).session
    }

    /// Full parse when `checkpoint` is nil; otherwise resumes exactly after the
    /// checkpoint's last committed JSONL record. Codex rollouts are append-only;
    /// descriptor identity plus head/boundary fingerprints detect rotation,
    /// truncation, and common replacement without rereading the whole committed
    /// prefix. The reader snapshots file size from the opened descriptor and
    /// never crosses that limit, so concurrent appends wait for the next scan.
    static func parseIncrementally(
        fileURL: URL,
        fallbackSessionId: String? = nil,
        checkpoint: CodexRolloutCheckpoint? = nil
    ) throws -> CodexRolloutParseOutput {
        if let checkpoint {
            guard checkpoint.version == CodexRolloutCheckpoint.currentVersion else {
                throw RolloutParserError.unsupportedCheckpointVersion(checkpoint.version)
            }
            guard checkpoint.offset >= 0 else {
                throw RolloutParserError.invalidCheckpointOffset(checkpoint.offset)
            }
            guard checkpoint.state.canResumeIncrementally else {
                throw RolloutParserError.checkpointIsNotRoot
            }
        }

        let startOffset = checkpoint?.offset ?? 0
        let reader: RolloutRecordReader
        do {
            reader = try RolloutRecordReader(
                fileURL: fileURL,
                startOffset: startOffset)
        } catch RolloutRecordReaderError.invalidOffset where checkpoint != nil {
            throw RolloutParserError.requiresFullRebuild(
                "file shrank below the committed offset")
        }
        defer { try? reader.close() }

        let startPrefixEnd = min(startOffset, fingerprintWindowBytes)
        let startBoundaryStart = max(0, startOffset - fingerprintWindowBytes)
        let startPrefixHash = try reader.sha256(in: 0..<startPrefixEnd)
        let startBoundaryHash = try reader.sha256(in: startBoundaryStart..<startOffset)
        if let checkpoint {
            guard checkpoint.sourceIdentity == reader.snapshot.sourceIdentity else {
                throw RolloutParserError.requiresFullRebuild("source identity changed")
            }
            guard checkpoint.prefixHash == startPrefixHash else {
                throw RolloutParserError.requiresFullRebuild(
                    "rollout head fingerprint changed")
            }
            guard checkpoint.boundaryHash == startBoundaryHash else {
                throw RolloutParserError.requiresFullRebuild("checkpoint boundary changed")
            }
        }

        var reducer = CodexRolloutReducer(
            state: checkpoint?.state ?? CodexRolloutReducerState(),
            isResumingRoot: checkpoint != nil)
        var deltas: [UsageDelta] = []
        var rateLimitSamples: [RateLimitSampleDraft] = []
        var endOffset = startOffset

        while let record = try reader.next() {
            if let event = RolloutEvent.decode(line: record.data) {
                let effects = try reducer.consume(event)
                if let delta = effects.usageDelta { deltas.append(delta) }
                rateLimitSamples.append(contentsOf: effects.rateLimitSamples)
            }
            // A newline-terminated malformed record is still a complete JSONL
            // record and matches the legacy parser's skip-and-continue behavior.
            endOffset = record.endOffset
        }

        reducer.resolveSessionId(
            fallbackSessionId ?? sessionIdFromFilename(fileURL))
        let state = reducer.checkpointState()
        let session = reducer.parsedSession(
            usageDeltas: deltas,
            rateLimitSamples: rateLimitSamples)
        let endBoundaryStart = max(0, endOffset - fingerprintWindowBytes)
        let endPrefixHash = try reader.sha256(
            in: 0..<min(endOffset, fingerprintWindowBytes))
        let endBoundaryHash = try reader.sha256(in: endBoundaryStart..<endOffset)
        let nextCheckpoint: CodexRolloutCheckpoint? = state.canResumeIncrementally
            ? CodexRolloutCheckpoint(
                offset: endOffset,
                state: state,
                sourceIdentity: reader.snapshot.sourceIdentity,
                prefixHash: endPrefixHash,
                boundaryHash: endBoundaryHash)
            : nil

        return CodexRolloutParseOutput(
            session: session,
            checkpoint: nextCheckpoint,
            endOffset: endOffset,
            snapshot: reader.snapshot,
            startPrefixHash: startPrefixHash,
            prefixHash: endPrefixHash,
            startBoundaryHash: startBoundaryHash,
            endBoundaryHash: endBoundaryHash,
            sequentialBytesRead: reader.sequentialBytesRead,
            hasIncompleteTail: reader.hasIncompleteTail)
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

struct CodexRolloutReduction: Sendable {
    let usageDelta: UsageDelta?
    let rateLimitSamples: [RateLimitSampleDraft]

    static let none = CodexRolloutReduction(
        usageDelta: nil,
        rateLimitSamples: [])
}

/// Pure, replayable state machine shared by full and resumed parsing.
struct CodexRolloutReducer {
    private(set) var state: CodexRolloutReducerState
    private let isResumingRoot: Bool
    private var seenModels: Set<String>
    private var seenUsageSnapshots: Set<UsageSnapshotKey>

    init(
        state: CodexRolloutReducerState = CodexRolloutReducerState(),
        isResumingRoot: Bool = false
    ) {
        var canonical = state
        canonical.normalizeCollections()
        self.state = canonical
        self.isResumingRoot = isResumingRoot
        self.seenModels = Set(canonical.seenModels)
        self.seenUsageSnapshots = Set(canonical.seenUsageSnapshots)
    }

    mutating func consume(_ event: RolloutEvent) throws -> CodexRolloutReduction {
        switch event {
        case .sessionMeta(let meta, let envelopeTs):
            if isResumingRoot {
                if meta.isChildSession {
                    throw RolloutParserError.requiresFullRebuild(
                        "tail session_meta introduced child/fork lineage")
                }
                if let metaId = meta.id,
                   let checkpointId = state.sessionId,
                   metaId != checkpointId
                {
                    throw RolloutParserError.requiresFullRebuild(
                        "tail session_meta changed session id")
                }
            }

            let ts = envelopeTs ?? meta.timestamp
            if state.sawSessionMeta,
               state.childReplayGate != nil,
               let childId = state.sessionId,
               let replayedId = meta.id,
               replayedId != childId
            {
                state.sawReplayedSessionMeta = true
            }

            if !state.sawSessionMeta {
                state.sawSessionMeta = true
                state.isIncrementalRootEligible = meta.id?.isEmpty == false
                    && !meta.isChildSession
                if meta.isChildSession {
                    if let ts, let createdAt = ISO8601.parse(ts) {
                        state.childReplayGate = .childCreatedAt(
                            createdAt.timeIntervalSince1970)
                    } else {
                        state.childReplayGate = .firstSelfTimedTask
                    }
                }
            } else {
                if meta.isChildSession {
                    state.isIncrementalRootEligible = false
                }
                if let existingId = state.sessionId,
                   let metaId = meta.id,
                   metaId != existingId
                {
                    state.isIncrementalRootEligible = false
                }
            }

            if state.sessionId == nil, let id = meta.id { state.sessionId = id }
            if state.startedAt == nil { state.startedAt = ts ?? meta.timestamp }
            if state.updatedAt == nil { state.updatedAt = ts ?? meta.timestamp }
            if state.agentNickname == nil {
                state.agentNickname = meta.resolvedAgentNickname
            }
            if state.agentRole == nil { state.agentRole = meta.resolvedAgentRole }
            if state.parentSessionId == nil {
                state.parentSessionId = meta.resolvedParentSessionId
            }
            if state.parentSessionId != nil {
                state.isIncrementalRootEligible = false
            }
            if state.cwd == nil, let metaCwd = meta.cwd, !metaCwd.isEmpty {
                state.cwd = metaCwd
            }
            return .none

        case .turnContext(let context, _):
            if let model = context.model {
                let normalized = NormalizeModelId(model)
                state.currentModel = normalized
                state.currentModelIsFallback = false
                seenModels.insert(normalized)
            }

            if let turn = state.activeTurn {
                if turn.id == nil {
                    state.activeTurn?.id = context.turnId
                } else if let contextTurnId = context.turnId,
                          turn.id != contextTurnId
                {
                    state.activeTurn = ActiveCodexTurn(
                        id: contextTurnId,
                        serviceTierPreference: nil)
                }
            } else {
                state.activeTurn = ActiveCodexTurn(
                    id: context.turnId,
                    serviceTierPreference: nil)
            }
            return .none

        case .threadSettingsApplied(let settings, _):
            state.pendingServiceTierPreference = CodexServiceTierPreference(
                rolloutValue: settings.resolvedServiceTier)
            return .none

        case .taskStarted(let task, let envelopeTs):
            if state.childReplayGate?.isCleared(
                by: task,
                lineTimestamp: envelopeTs,
                sawReplayedSessionMeta: state.sawReplayedSessionMeta) == true
            {
                state.childReplayGate = nil
            }
            state.activeTurn = ActiveCodexTurn(
                id: task.turnId,
                serviceTierPreference: state.pendingServiceTierPreference)
            return .none

        case .taskComplete(let task, _):
            if let turn = state.activeTurn, turn.id == task.turnId {
                state.activeTurn = nil
            }
            return .none

        case .tokenCount(let tokenCount, let envelopeTs):
            let timestamp = envelopeTs ?? ISO8601.fractional.string(from: Date())
            if let plan = tokenCount.rateLimits?.planType {
                state.latestPlanType = plan
            }
            let samples = state.childReplayGate == nil
                ? Self.extractSamples(from: tokenCount.rateLimits, at: timestamp)
                : []

            guard let info = tokenCount.info else {
                return CodexRolloutReduction(
                    usageDelta: nil,
                    rateLimitSamples: samples)
            }

            // Resolution order: explicit on payload → tracked turn_context →
            // legacy fallback. Only the last counts as inferred.
            let payloadModel = extractPayloadModel(from: tokenCount).map(NormalizeModelId)
            if let payloadModel {
                state.currentModel = payloadModel
                state.currentModelIsFallback = false
            }
            let resolvedModel: String
            let inferred: Bool
            if let model = payloadModel ?? state.currentModel {
                resolvedModel = model
                inferred = state.currentModelIsFallback
            } else {
                resolvedModel = LegacyFallbackModel
                inferred = true
                state.currentModel = LegacyFallbackModel
                state.currentModelIsFallback = true
            }
            seenModels.insert(resolvedModel)

            let tokenDelta = Self.usageDelta(
                from: info,
                previousTotal: &state.previousUsage,
                seenUsageSnapshots: &seenUsageSnapshots)
            let usage: UsageDelta?
            if state.childReplayGate == nil, let tokenDelta {
                usage = UsageDelta(
                    timestamp: timestamp,
                    modelId: resolvedModel,
                    turnId: state.activeTurn?.id,
                    serviceTierPreference: state.activeTurn?.serviceTierPreference,
                    inputTokens: tokenDelta.inputTokens,
                    cachedInputTokens: tokenDelta.cachedInputTokens,
                    outputTokens: tokenDelta.outputTokens,
                    reasoningOutputTokens: tokenDelta.reasoningOutputTokens,
                    totalTokens: tokenDelta.totalTokens,
                    modelInferred: inferred)
            } else {
                usage = nil
            }
            state.updatedAt = timestamp
            return CodexRolloutReduction(
                usageDelta: usage,
                rateLimitSamples: samples)

        case .other:
            return .none
        }
    }

    mutating func resolveSessionId(_ fallback: String?) {
        if state.sessionId == nil { state.sessionId = fallback }
    }

    mutating func checkpointState() -> CodexRolloutReducerState {
        state.seenModels = seenModels.sorted()
        state.seenUsageSnapshots = seenUsageSnapshots.sorted()
        return state
    }

    func parsedSession(
        usageDeltas: [UsageDelta],
        rateLimitSamples: [RateLimitSampleDraft]
    ) -> ParsedSession? {
        guard let resolved = state.sessionId else { return nil }
        let projectName: String? = {
            guard let cwd = state.cwd, !cwd.isEmpty else { return nil }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? nil : leaf
        }()

        return ParsedSession(
            sessionId: resolved,
            parentSessionId: state.parentSessionId,
            rootSessionId: state.parentSessionId == nil
                ? resolved
                : (state.parentSessionId ?? resolved),
            title: nil,
            projectName: projectName,
            cwd: state.cwd,
            startedAt: state.startedAt,
            updatedAt: state.updatedAt,
            agentNickname: state.agentNickname,
            agentRole: state.agentRole,
            lastModelId: state.currentModel,
            latestPlanType: state.latestPlanType,
            modelIds: seenModels,
            usageDeltas: usageDeltas,
            rateLimitSamples: rateLimitSamples)
    }

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
        previous: TokenUsageWire?,
        current: TokenUsageWire
    ) -> TokenUsageWire? {
        guard let previous else { return meaningfulUsage(current) }
        let wentBackwards =
            current.inputTokens < previous.inputTokens
            || current.cachedInputTokens < previous.cachedInputTokens
            || current.outputTokens < previous.outputTokens
            || current.reasoningOutputTokens < previous.reasoningOutputTokens
            || current.totalTokens < previous.totalTokens
        if wentBackwards { return meaningfulUsage(current) }

        return meaningfulUsage(TokenUsageWire(
            inputTokens: current.inputTokens - previous.inputTokens,
            cachedInputTokens: current.cachedInputTokens - previous.cachedInputTokens,
            outputTokens: current.outputTokens - previous.outputTokens,
            reasoningOutputTokens: current.reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: current.totalTokens - previous.totalTokens))
    }

    private static func extractSamples(
        from rateLimits: EmbeddedRateLimits?,
        at timestamp: String
    ) -> [RateLimitSampleDraft] {
        guard let rateLimits else { return [] }
        var samples: [RateLimitSampleDraft] = []
        for window in [rateLimits.primary, rateLimits.secondary] {
            guard let window,
                  let resets = window.resetsAt,
                  let bucket = CodexQuotaWindowClassifier.classify(
                    duration: window.windowMinutes.map { TimeInterval($0 * 60) })
            else { continue }
            samples.append(RateLimitSampleDraft(
                bucket: bucket.rawValue,
                windowDuration: window.windowMinutes.map { TimeInterval($0 * 60) },
                sampleTimestamp: timestamp,
                planType: rateLimits.planType,
                limitName: rateLimits.limitName,
                resetsAt: ISO8601.fractional.string(
                    from: Date(timeIntervalSince1970: resets)),
                usedPercent: window.usedPercent,
                remainingPercent: max(0, 100 - window.usedPercent)))
        }
        return samples
    }
}

// MARK: - bounded incremental record reader

struct RolloutRecord: Equatable, Sendable {
    let data: Data
    let startOffset: Int64
    let endOffset: Int64
    let hadNewline: Bool
}

enum RolloutRecordReaderError: Error, Equatable, CustomStringConvertible {
    case invalidOffset(offset: Int64, fileSize: Int64)
    case invalidRange(Range<Int64>, fileSize: Int64)
    case unexpectedEOF(expectedSize: Int64, bytesReadThrough: Int64)

    var description: String {
        switch self {
        case .invalidOffset(let offset, let fileSize):
            return "invalid rollout offset \(offset) for \(fileSize)-byte file"
        case .invalidRange(let range, let fileSize):
            return "invalid rollout byte range \(range) for \(fileSize)-byte file"
        case .unexpectedEOF(let expectedSize, let bytesReadThrough):
            return "rollout truncated while reading snapshot size \(expectedSize) at \(bytesReadThrough)"
        }
    }
}

/// Throwing JSONL reader whose upper bound is the file size captured from the
/// same opened descriptor. Unlike `LineReader`, it never converts I/O failure
/// into EOF and it exposes exact record offsets for durable checkpointing.
final class RolloutRecordReader {
    let snapshot: RolloutFileSnapshot
    private(set) var sequentialBytesRead: Int64 = 0
    private(set) var newlineBytesScanned: Int64 = 0
    private(set) var hasIncompleteTail = false

    private let handle: FileHandle
    private let chunkSize: Int
    private var remainingBytes: Int64
    private var buffer = Data()
    private var cursor = 0
    private var newlineSearchOffset = 0
    private var recordStartOffset: Int64
    private var finished = false
    private var closed = false

    init(
        fileURL: URL,
        startOffset: Int64 = 0,
        chunkSize: Int = 256 * 1024
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        do {
            let snapshot = try Self.snapshot(for: handle)
            guard startOffset >= 0, startOffset <= snapshot.size else {
                throw RolloutRecordReaderError.invalidOffset(
                    offset: startOffset,
                    fileSize: snapshot.size)
            }
            try handle.seek(toOffset: UInt64(startOffset))
            self.handle = handle
            self.snapshot = snapshot
            self.chunkSize = max(1, chunkSize)
            self.remainingBytes = snapshot.size - startOffset
            self.recordStartOffset = startOffset
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        try handle.close()
    }

    func next() throws -> RolloutRecord? {
        guard !finished else { return nil }

        while true {
            try Task.checkCancellation()

            if cursor < buffer.count {
                // Keep loop bounds local. Reading `buffer.count` through this
                // class on every byte triggers Swift exclusivity checks and
                // makes large rollout scans several times slower.
                // `newlineSearchOffset` survives chunk refills so a single
                // multi-megabyte JSON record is scanned once, not once per
                // progressively larger buffer.
                let scanStart = max(cursor, newlineSearchOffset)
                let scanEnd = buffer.count
                if scanStart < scanEnd {
                    let newline: Int? = buffer.withUnsafeBytes { raw -> Int? in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                            return nil
                        }
                        var index = scanStart
                        while index < scanEnd {
                            if base[index] == 0x0A { return index }
                            index &+= 1
                        }
                        return nil
                    }
                    if let newline {
                        newlineBytesScanned += Int64(newline - scanStart + 1)
                        let start = recordStartOffset
                        let line = buffer.subdata(in: cursor..<newline)
                        cursor = newline + 1
                        newlineSearchOffset = cursor
                        let end = start + Int64(line.count) + 1
                        recordStartOffset = end
                        return RolloutRecord(
                            data: line,
                            startOffset: start,
                            endOffset: end,
                            hadNewline: true)
                    }
                    newlineBytesScanned += Int64(scanEnd - scanStart)
                    newlineSearchOffset = scanEnd
                }
            }

            // Drop only bytes belonging to records already returned. The
            // unread suffix (possibly one very large JSON object) stays intact.
            if cursor > 0 {
                let consumed = cursor
                buffer.removeSubrange(0..<consumed)
                newlineSearchOffset = max(0, newlineSearchOffset - consumed)
                cursor = 0
            }

            if remainingBytes == 0 {
                finished = true
                guard !buffer.isEmpty else { return nil }
                guard Self.isCompleteEOFRecord(buffer) else {
                    hasIncompleteTail = true
                    buffer.removeAll(keepingCapacity: false)
                    return nil
                }
                let start = recordStartOffset
                let end = start + Int64(buffer.count)
                let line = buffer
                buffer = Data()
                recordStartOffset = end
                return RolloutRecord(
                    data: line,
                    startOffset: start,
                    endOffset: end,
                    hadNewline: false)
            }

            let requestCount = Int(min(Int64(chunkSize), remainingBytes))
            guard let chunk = try handle.read(upToCount: requestCount),
                  !chunk.isEmpty
            else {
                throw RolloutRecordReaderError.unexpectedEOF(
                    expectedSize: snapshot.size,
                    bytesReadThrough: snapshot.size - remainingBytes)
            }
            buffer.append(chunk)
            let count = Int64(chunk.count)
            remainingBytes -= count
            sequentialBytesRead += count
        }
    }

    /// Read a small fingerprint window without disturbing the sequential file
    /// cursor. `pread` keeps identity and content checks tied to this descriptor.
    func readBytes(in range: Range<Int64>) throws -> Data {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= snapshot.size
        else {
            throw RolloutRecordReaderError.invalidRange(
                range,
                fileSize: snapshot.size)
        }
        let length64 = range.upperBound - range.lowerBound
        guard length64 <= Int64(Int.max) else {
            throw RolloutRecordReaderError.invalidRange(
                range,
                fileSize: snapshot.size)
        }
        let length = Int(length64)
        if length == 0 { return Data() }

        var data = Data(count: length)
        var total = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < length {
                try Task.checkCancellation()
                let count = Darwin.pread(
                    handle.fileDescriptor,
                    base.advanced(by: total),
                    length - total,
                    off_t(range.lowerBound + Int64(total)))
                if count < 0 {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "pread rollout fingerprint failed"])
                }
                if count == 0 {
                    throw RolloutRecordReaderError.unexpectedEOF(
                        expectedSize: snapshot.size,
                        bytesReadThrough: range.lowerBound + Int64(total))
                }
                total += count
            }
        }
        return data
    }

    func sha256(in range: Range<Int64>) throws -> Data {
        Data(SHA256.hash(data: try readBytes(in: range)))
    }

    private static func snapshot(for handle: FileHandle) throws -> RolloutFileSnapshot {
        var value = Darwin.stat()
        guard Darwin.fstat(handle.fileDescriptor, &value) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "fstat rollout failed"])
        }
        let mtimeMs = RolloutFileSnapshot.modificationTimeMilliseconds(
            seconds: Int64(value.st_mtimespec.tv_sec),
            nanoseconds: Int64(value.st_mtimespec.tv_nsec))
        let birthtimeNs = Int64(value.st_birthtimespec.tv_sec) * 1_000_000_000
            + Int64(value.st_birthtimespec.tv_nsec)
        return RolloutFileSnapshot(
            size: Int64(value.st_size),
            mtimeMs: mtimeMs,
            device: Int64(value.st_dev),
            inode: Int64(bitPattern: UInt64(value.st_ino)),
            birthtimeNs: birthtimeNs)
    }

    private static func isCompleteEOFRecord(_ data: Data) -> Bool {
        if data.allSatisfy({ byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D
        }) {
            return true
        }
        return (try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed])) != nil
    }
}

// MARK: - legacy line reader

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
