import Foundation

/// Shared pace-label generator used by both `RateLimitSnapshot.Window` and
/// `ClaudeUsageSnapshot.Window`. Lets the menu bar render identical
/// human-friendly verdicts for Codex and Claude quotas without having to
/// recompute pace math at the call site.
///
/// Inputs: `usedPercent` (0..100), `paceRatio` (1.0 = matching the linear
/// pace), and the time until reset. Output is one of three short
/// sentences inspired by CodexBar's UI:
///
/// - "On pace"          — pace is between 0.85 and 1.15 (within ±15%)
/// - "X% in deficit · Runs out in 47m"  — burning faster, projects to hit 100%
/// - "X% in reserve"    — burning slower, won't exhaust before reset
///
/// We hide the label entirely when `usedPercent < 3`. At cold-start there
/// isn't enough signal: a single $0.50 turn shows up as "+200% pace"
/// which alarms the user for no reason. CodexBar uses the same threshold.
enum QuotaPaceLabel {
    struct Result: Equatable {
        let text: String
        /// Tint hint — UI may use it for the label color.
        let severity: Severity
    }
    enum Severity: Equatable { case neutral, good, warning, danger }

    static func make(
        usedPercent: Double,
        paceRatio: Double?,
        timeUntilReset: TimeInterval
    ) -> Result? {
        guard usedPercent >= 3 else { return nil }
        guard let ratio = paceRatio, ratio.isFinite, ratio > 0 else { return nil }

        if ratio >= 0.85 && ratio <= 1.15 {
            return .init(text: L10n.paceOnPace, severity: .neutral)
        }

        let deltaPct = Int((abs(ratio - 1) * 100).rounded())

        if ratio > 1.15 {
            // Burning hot — extrapolate when we hit 100%.
            // Current burn = used / elapsed; remaining = 100 - used;
            // ETA = remaining / burn = remaining * elapsed / used.
            // We already have `ratio = (used / 100) / (elapsed / window)`,
            // but the simpler path is to treat the current trend as
            // linear and project a remaining-share-of-window.
            let etaSeconds = etaToHundred(usedPercent: usedPercent,
                                          paceRatio: ratio,
                                          timeUntilReset: timeUntilReset)
            if let eta = etaSeconds {
                let runsOut = formatDuration(eta)
                return .init(text: L10n.paceDeficitRunsOut(percent: deltaPct, eta: runsOut),
                             severity: deltaPct > 50 ? .danger : .warning)
            }
            return .init(text: L10n.paceDeficit(percent: deltaPct), severity: .warning)
        }

        // Slower than linear — under-consuming, will not exhaust.
        return .init(text: L10n.paceReserve(percent: deltaPct), severity: .good)
    }

    /// Returns seconds until usedPercent hits 100, capped at the time
    /// remaining in the current window. Nil when the projection lands
    /// after the natural reset (the reset will save you, no point
    /// alarming the user).
    private static func etaToHundred(
        usedPercent: Double,
        paceRatio: Double,
        timeUntilReset: TimeInterval
    ) -> TimeInterval? {
        // pace = (used/100) / elapsedFrac → elapsedFrac = (used/100) / pace.
        // Remaining elapsedFrac before 100% = (1 - used/100) / pace * (used/100)/(used/100)
        // Simpler: total fraction of window to hit 100% = (1.0) / pace.
        guard paceRatio > 0 else { return nil }
        let fractionToHundred = 1.0 / paceRatio
        // Window length = elapsed + remaining. We have remaining and the
        // elapsed fraction; back out window:
        let elapsedFraction = (usedPercent / 100) / paceRatio
        guard elapsedFraction > 0, elapsedFraction < 1 else { return nil }
        let windowLen = timeUntilReset / (1 - elapsedFraction)
        let etaFromStart = fractionToHundred * windowLen
        let elapsed = elapsedFraction * windowLen
        let etaFromNow = etaFromStart - elapsed
        guard etaFromNow > 0, etaFromNow < timeUntilReset else { return nil }
        return etaFromNow
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMin = Int(seconds / 60)
        let dUnit = L10n.unitDayShort
        let hUnit = L10n.unitHourShort
        let mUnit = L10n.unitMinuteShort
        if totalMin >= 1440 {
            let d = totalMin / 1440
            let h = (totalMin % 1440) / 60
            return h == 0 ? "\(d)\(dUnit)" : "\(d)\(dUnit) \(h)\(hUnit)"
        }
        if totalMin >= 60 {
            let h = totalMin / 60
            let m = totalMin % 60
            return m == 0 ? "\(h)\(hUnit)" : "\(h)\(hUnit) \(m)\(mUnit)"
        }
        return "\(totalMin)\(mUnit)"
    }
}
