import Foundation

/// Display tiers. Missing or unknown recorded preferences count as Standard.
enum TrendSpeedTier: String, Codable, Sendable, CaseIterable {
    case standard, fast, ultrafast, flex

    init(recordedValue: String?) {
        switch CodexServiceTierPreference(rolloutValue: recordedValue) {
        case .standard: self = .standard
        case .priority: self = .fast
        case .ultrafast: self = .ultrafast
        case .flex: self = .flex
        case nil: self = .standard
        }
    }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        case .ultrafast: "Ultrafast"
        case .flex: "Flex"
        }
    }

    var sortOrder: Int { Self.allCases.firstIndex(of: self)! }

    static func seriesKey(modelID: String, tier: Self?) -> String {
        tier.map { "\(modelID)::\($0.rawValue)" } ?? modelID
    }
}
