import Foundation

enum CodexServiceTierPreference: String, Codable, Sendable {
    case priority
    case standard = "default"

    init?(rolloutValue: String?) {
        switch rolloutValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": self = .priority
        case "default": self = .standard
        default: return nil
        }
    }
}
