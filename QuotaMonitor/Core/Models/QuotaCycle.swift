import Foundation
import CryptoKit

/// A reset deadline is authoritative; its preceding start usually is not.
/// Keep that distinction with the observation so relaunches retain evidence.
struct QuotaCycle: Codable, Equatable, Sendable, Identifiable {
    enum Basis: String, Codable, Sendable {
        case estimated, observedRollover, observedChange, unresolved
    }

    struct Observation: Codable, Equatable, Sendable {
        let provider: String
        let bucket: String
        let scope: String?
        let plan: String?
        let capturedAt: Date
        let resetAt: Date
        let duration: TimeInterval
        let usedPercent: Double
    }

    let observation: Observation
    let start: Date?
    /// Earliest possible boundary for an early change seen between polls.
    /// Statistics use `start` (the first new observation), never the midpoint.
    let possibleStart: Date?
    let basis: Basis

    var id: String { observation.provider + "/" + observation.bucket }

    var allowsPaceEstimate: Bool {
        basis == .estimated || basis == .observedRollover
    }

    func isCurrent(at now: Date) -> Bool {
        observation.capturedAt <= now && observation.resetAt > now
    }

    static func scope(provider: String, value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return SHA256.hash(data: Data((provider + ":" + value).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(_ current: Observation, previous: Self?) -> Self {
        if let previous, current.capturedAt < previous.observation.capturedAt
            || current == previous.observation {
            return previous
        }
        let inferred = current.resetAt.addingTimeInterval(-current.duration)
        let valid = current.duration.isFinite && current.duration > 0
            && current.usedPercent.isFinite && current.usedPercent >= 0
            && current.resetAt > current.capturedAt && inferred <= current.capturedAt
        func make(_ basis: Basis, start: Date?, possible: Date? = nil) -> Self {
            Self(observation: current, start: start, possibleStart: possible, basis: basis)
        }
        guard valid else { return make(.unresolved, start: nil) }
        guard let previous, let scope = current.scope,
              scope == previous.observation.scope,
              current.provider == previous.observation.provider,
              current.bucket == previous.observation.bucket,
              current.plan == previous.observation.plan,
              abs(current.duration - previous.observation.duration) <= 2
        else { return make(.estimated, start: inferred) }

        let prior = previous.observation
        let deadlineDelta = current.resetAt.timeIntervalSince(prior.resetAt)
        let usageDropped = current.usedPercent < prior.usedPercent - 0.0001
        if abs(deadlineDelta) <= 2 {
            // A manual reset can preserve the deadline. A correction or plan
            // adjustment looks the same; neither proves a usable new start.
            if usageDropped { return make(.unresolved, start: nil) }
            return make(previous.basis, start: previous.start, possible: previous.possibleStart)
        }
        if deadlineDelta > 2, current.capturedAt >= prior.resetAt,
           abs(inferred.timeIntervalSince(prior.resetAt)) <= 2 {
            return make(.observedRollover, start: prior.resetAt)
        }
        if current.capturedAt < prior.resetAt {
            if deadlineDelta > 2 && usageDropped {
                return make(.observedChange, start: current.capturedAt, possible: prior.capturedAt)
            }
            return make(.unresolved, start: nil)
        }
        // A new window after idle time / a long offline gap is only inferred.
        return make(.estimated, start: inferred)
    }
}
