import Foundation

enum DistributionChannel: String, Sendable {
    case developerID = "developer-id"
    case appStore = "app-store"

    static let infoDictionaryKey = "QMDistributionChannel"

    static var current: DistributionChannel {
        from(infoDictionary: Bundle.main.infoDictionary,
             environment: ProcessInfo.processInfo.environment)
    }

    var telemetrySlug: String { rawValue }

    /// Strict telemetry resolution intentionally differs from `current`.
    /// Existing app behavior keeps its Developer ID fallback, while reporting
    /// refuses missing, mistyped, and unrecognized packaging metadata.
    static func telemetryChannel(
        infoDictionary: [String: Any]?,
        environment: [String: String] = [:]
    ) -> DistributionChannel? {
        if let rawValue = infoDictionary?[infoDictionaryKey] {
            guard let raw = rawValue as? String else { return nil }
            return DistributionChannel(rawValue: raw)
        }
        guard let raw = environment["QM_DISTRIBUTION"] else { return nil }
        return DistributionChannel(rawValue: raw)
    }

    static func from(infoDictionary: [String: Any]?,
                     environment: [String: String] = [:]) -> DistributionChannel {
        let raw = infoDictionary?[infoDictionaryKey] as? String
            ?? environment["QM_DISTRIBUTION"]
            ?? Self.developerID.rawValue
        return DistributionChannel(rawValue: raw) ?? .developerID
    }
}
