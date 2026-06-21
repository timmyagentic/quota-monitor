import Foundation

enum CodexBillingTier: String, Codable, Sendable {
    case standard
    case fast
    case unknown
}

enum CodexBillingTierSource: String, Codable, Sendable {
    case trace
    case traceUnsupported = "trace_unsupported"
    case missingTurnID = "missing_turn_id"
    case traceUnavailable = "trace_unavailable"
    case traceMissing = "trace_missing"
    case legacy
    case notCodex = "not_codex"
}

struct CodexTurnBillingTrace: Sendable, Equatable {
    let tier: CodexBillingTier
    let source: CodexBillingTierSource
    let modelId: String?
    let timestamp: Date?
}

struct CodexTurnBillingLookup: Sendable {
    let available: Bool
    let tracesByTurnID: [String: CodexTurnBillingTrace]

    static let unavailable = CodexTurnBillingLookup(
        available: false,
        tracesByTurnID: [:])

    func classify(turnID: String?) -> (tier: CodexBillingTier, source: CodexBillingTierSource) {
        guard available else { return (.unknown, .traceUnavailable) }
        guard let turnID, !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.unknown, .missingTurnID) }
        guard let trace = tracesByTurnID[turnID] else { return (.standard, .trace) }
        return (trace.tier, trace.source)
    }
}
