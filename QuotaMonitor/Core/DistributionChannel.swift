import Foundation

enum DistributionChannel: String, Sendable {
    case developerID = "developer-id"
    case appStore = "app-store"

    static let infoDictionaryKey = "QMDistributionChannel"

    static var current: DistributionChannel {
        from(infoDictionary: Bundle.main.infoDictionary,
             environment: ProcessInfo.processInfo.environment)
    }

    static func from(infoDictionary: [String: Any]?,
                     environment: [String: String] = [:]) -> DistributionChannel {
        let raw = infoDictionary?[infoDictionaryKey] as? String
            ?? environment["QM_DISTRIBUTION"]
            ?? Self.developerID.rawValue
        return DistributionChannel(rawValue: raw) ?? .developerID
    }
}
