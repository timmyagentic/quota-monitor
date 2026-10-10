import Foundation

enum CodexServiceTierPreference: String, Codable, Sendable {
    case priority
    case standard = "default"
    case flex

    // Decode beta.5 checkpoints without discarding their existing evidence.
    // New rollout values do not recognize this withdrawn tier.
    case legacyUltrafast = "ultrafast"

    init?(rolloutValue: String?) {
        switch rolloutValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": self = .priority
        case "default": self = .standard
        case "flex": self = .flex
        default: return nil
        }
    }
}
