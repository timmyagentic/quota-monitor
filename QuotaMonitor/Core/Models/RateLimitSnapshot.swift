import Foundation

// Domain-level view of rate-limit state. Decouples the UI/storage layers from
// the wire format in `AppServerTypes.swift`, so changes to the upstream shape
// only require updating the mapping in `init(from:)`.

struct RateLimitSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let planType: String?
    let primary: Window?         // 5-hour window
    let secondary: Window?       // 7-day window
    let additional: [Additional]
    let resetCreditsAvailable: Int?

    struct Window: Equatable, Sendable {
        let usedPercent: Double
        let windowDuration: TimeInterval
        let resetAt: Date

        var remainingPercent: Double { max(0, 100 - usedPercent) }
        var timeUntilReset: TimeInterval { resetAt.timeIntervalSinceNow }

        /// Suggested pace = remaining quota / remaining time, normalized so
        /// 1.0 means "right on track to use 100% by reset". Above 1.0 = burning
        /// faster than the linear pace.
        func paceRatio(now: Date = Date()) -> Double? {
            let elapsed = windowDuration - resetAt.timeIntervalSince(now)
            guard elapsed > 0, windowDuration > 0 else { return nil }
            let elapsedFraction = elapsed / windowDuration
            guard elapsedFraction > 0 else { return nil }
            return (usedPercent / 100.0) / elapsedFraction
        }

        /// Human-readable verdict for the menu bar. See `QuotaPaceLabel`.
        func paceLabel(now: Date = Date()) -> QuotaPaceLabel.Result? {
            QuotaPaceLabel.make(
                usedPercent: usedPercent,
                paceRatio: paceRatio(now: now),
                timeUntilReset: max(0, resetAt.timeIntervalSince(now)))
        }
    }

    struct Additional: Equatable, Sendable {
        let limitName: String
        let meteredFeature: String?
        let primary: Window?
        let secondary: Window?
    }
}

extension RateLimitSnapshot {
    init(from payload: RateLimitsPayload, capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.planType = payload.planType
        self.primary = payload.rateLimit?.primaryWindow.map(Window.init)
        self.secondary = payload.rateLimit?.secondaryWindow.map(Window.init)
        self.additional = (payload.additionalRateLimits ?? []).compactMap { entry in
            guard let name = entry.limitName else { return nil }
            return Additional(
                limitName: name,
                meteredFeature: entry.meteredFeature,
                primary: entry.rateLimit?.primaryWindow.map(Window.init),
                secondary: entry.rateLimit?.secondaryWindow.map(Window.init))
        }
        self.resetCreditsAvailable = payload.resetCreditsAvailable
    }
}

private extension RateLimitSnapshot.Window {
    init(_ wire: RateLimitWindow) {
        self.usedPercent = wire.usedPercent
        self.windowDuration = wire.windowDuration
        self.resetAt = wire.resetDate
    }
}
