import Foundation

enum CodexServiceTierPreference: String, Codable, Sendable {
    case priority
    case standard = "default"
    case flex

    init?(rolloutValue: String?) {
        switch rolloutValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": self = .priority
        case "default": self = .standard
        case "flex": self = .flex
        default: return nil
        }
    }
}
