import Foundation

// Domain-level view of rate-limit state. Decouples the UI/storage layers from
// the wire format in `AppServerTypes.swift`, so changes to the upstream shape
// only require updating the mapping in `init(from:)`.

enum CodexQuotaWindowBucket: String, Sendable {
    case primary
    case secondary
}

/// Maps upstream windows to QuotaMonitor's semantic 5-hour / 7-day buckets.
///
/// Codex normally sends those windows in fields named `primary` and
/// `secondary`, but those field positions are not stable: when only the weekly
/// limit is active, Codex can send it in `primary`. Duration is therefore the
/// source of truth. Missing or unsupported durations are omitted instead of
/// being given a misleading 5-hour / 7-day label.
enum CodexQuotaWindowClassifier {
    static let fiveHourDuration: TimeInterval = 5 * 60 * 60
    static let sevenDayDuration: TimeInterval = 7 * 24 * 60 * 60
    private static let legacyFiveHourTolerance: TimeInterval = 5 * 60

    static func classify(duration: TimeInterval?) -> CodexQuotaWindowBucket? {
        guard let duration, duration > 0 else { return nil }
        if isApproximately(duration, fiveHourDuration) { return .primary }
        if isApproximately(duration, sevenDayDuration) { return .secondary }
        return nil
    }

    private static func isApproximately(
        _ actual: TimeInterval,
        _ expected: TimeInterval
    ) -> Bool {
        actual >= expected * 0.95 && actual <= expected * 1.05
    }

    /// Classifies a row persisted by either the current writers or an older
    /// QuotaMonitor build. Current writers encode the real duration as
    /// `resetAt - windowStart`. Legacy rows left `window_start` empty, so only
    /// conclusions that are provable from the remaining time are accepted:
    /// a primary row more than five hours from reset must be weekly, while a
    /// shorter primary row is treated as 5h only when a same-snapshot weekly
    /// partner proves the old two-slot layout. Ambiguous primary-only rows are
    /// omitted until a fresh live snapshot arrives.
    static func classifyPersisted(
        legacySlot: CodexQuotaWindowBucket,
        windowStart: Date?,
        sampleAt: Date,
        resetAt: Date,
        hasPairedSecondary: Bool
    ) -> CodexQuotaWindowBucket? {
        if let windowStart {
            return classify(duration: resetAt.timeIntervalSince(windowStart))
        }

        switch legacySlot {
        case .secondary:
            return .secondary
        case .primary:
            if resetAt.timeIntervalSince(sampleAt)
                > fiveHourDuration + legacyFiveHourTolerance {
                return .secondary
            }
            return hasPairedSecondary ? .primary : nil
        }
    }

    static func duration(for bucket: CodexQuotaWindowBucket) -> TimeInterval {
        switch bucket {
        case .primary: fiveHourDuration
        case .secondary: sevenDayDuration
        }
    }
}

struct RateLimitSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let planType: String?
    let primary: Window?         // semantic 5-hour window
    let secondary: Window?       // semantic 7-day window
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
        let windows = Self.normalizedWindows(from: payload.rateLimit)
        self.capturedAt = capturedAt
        self.planType = payload.planType
        self.primary = windows.primary
        self.secondary = windows.secondary
        self.additional = (payload.additionalRateLimits ?? []).compactMap { entry in
            guard let name = entry.limitName else { return nil }
            let windows = Self.normalizedWindows(from: entry.rateLimit)
            return Additional(
                limitName: name,
                meteredFeature: entry.meteredFeature,
                primary: windows.primary,
                secondary: windows.secondary)
        }
        self.resetCreditsAvailable = payload.resetCreditsAvailable
    }

    private static func normalizedWindows(
        from group: RateLimitGroup?
    ) -> (primary: Window?, secondary: Window?) {
        guard let group else { return (nil, nil) }
        var primary: Window?
        var secondary: Window?

        let wireWindows = [group.primaryWindow, group.secondaryWindow]
        for wire in wireWindows {
            guard let wire,
                  let bucket = CodexQuotaWindowClassifier.classify(
                    duration: wire.windowDuration)
            else { continue }

            switch bucket {
            case .primary:
                if primary == nil { primary = Window(wire) }
            case .secondary:
                if secondary == nil { secondary = Window(wire) }
            }
        }
        return (primary, secondary)
    }
}

private extension RateLimitSnapshot.Window {
    init(_ wire: RateLimitWindow) {
        self.usedPercent = wire.usedPercent
        self.windowDuration = wire.windowDuration
        self.resetAt = wire.resetDate
    }
}
