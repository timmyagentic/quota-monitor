import Foundation

enum CodexBillingTier: String, Codable, Sendable {
    case standard
    case fast
    case unknown
}

enum CodexBillingTierSource: String, Codable, Sendable {
    case jsonl
    case missingMarker = "missing_marker"
    case legacy
    case notCodex = "not_codex"
}

struct CodexBillingTierClassifier {
    static func classify(
        explicitFastMode: Bool?
    ) -> (tier: CodexBillingTier, source: CodexBillingTierSource) {
        guard let explicitFastMode else {
            return (.unknown, .missingMarker)
        }
        return (explicitFastMode ? .fast : .standard, .jsonl)
    }
}
