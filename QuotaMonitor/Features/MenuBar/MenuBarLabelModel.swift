import Foundation

/// Pure row-selection + formatting for the menu-bar label, shared by the
/// AppKit `StatusItemController` (which renders the rows into an
/// `NSAttributedString`). Extracted from the former `MenuBarLabelView` so
/// the logic is unit-testable and independent of the rendering style.
enum MenuBarLabelModel {

    /// One provider's compact readout. `tag` is "CX"/"CC" (shown only in
    /// multi-provider mode by the renderer); `fiveHour`/`sevenDay` are
    /// already-formatted strings like "8%" / "94%" / "--".
    struct Row: Equatable {
        let tag: String
        let fiveHour: String
        let sevenDay: String
    }

    /// Build the ordered rows. Order is hard-coded codex-first, claude-second
    /// (Set iteration is unstable). A provider is included only when it is in
    /// both the icon-intent set AND the enabled set, and at least one of its
    /// windows has a number (otherwise it'd just hog width with "-- · --").
    static func rows(iconProviders: Set<String>,
                     enabledProviders: Set<String>,
                     rateLimits: RateLimitSnapshot?,
                     claudeUsage: ClaudeUsageSnapshot?,
                     displayMode: SettingsStore.QuotaDisplayMode) -> [Row] {
        var out: [Row] = []
        for id in ["codex", "claude"] {
            guard iconProviders.contains(id), enabledProviders.contains(id) else { continue }
            switch id {
            case "codex":
                guard let snap = rateLimits else { continue }
                let five = snap.primary?.usedPercent
                let seven = snap.secondary?.usedPercent
                guard five != nil || seven != nil else { continue }
                out.append(Row(tag: "CX",
                               fiveHour: format(five, displayMode),
                               sevenDay: format(seven, displayMode)))
            case "claude":
                guard let u = claudeUsage else { continue }
                let five = u.fiveHour?.usedPercent
                let seven = u.sevenDay?.usedPercent
                guard five != nil || seven != nil else { continue }
                out.append(Row(tag: "CC",
                               fiveHour: format(five, displayMode),
                               sevenDay: format(seven, displayMode)))
            default: break
            }
        }
        return out
    }

    /// "23%" — clamped 0...100 via the display mode (used vs remaining), no
    /// decimals (the menu bar is too narrow; the popover shows the exact
    /// figure). Nil → "--".
    static func format(_ pct: Double?,
                       _ displayMode: SettingsStore.QuotaDisplayMode) -> String {
        guard let pct else { return "--" }
        let display = displayMode.displayPercent(forUsedPercent: pct)
        return "\(Int(display.rounded()))%"
    }
}
