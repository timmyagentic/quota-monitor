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
    /// (Set iteration is unstable). A provider is included when it is in both
    /// the icon-intent set AND the enabled set. Missing windows render as "--"
    /// so the status item stays visually consistent with the Settings choice;
    /// the gauge fallback is reserved for the deliberate "show no providers"
    /// state.
    static func rows(iconProviders: Set<String>,
                     enabledProviders: Set<String>,
                     rateLimits: RateLimitSnapshot?,
                     claudeUsage: ClaudeUsageSnapshot?,
                     codexQuota: CodexQuotaSnapshot? = nil,
                     displayMode: SettingsStore.QuotaDisplayMode) -> [Row] {
        var out: [Row] = []
        for id in ["codex", "claude"] {
            guard iconProviders.contains(id), enabledProviders.contains(id) else { continue }
            switch id {
            case "codex":
                let five = rateLimits?.primary?.usedPercent
                    ?? codexQuota?.primary?.usedPercent
                let seven = rateLimits?.secondary?.usedPercent
                    ?? codexQuota?.secondary?.usedPercent
                out.append(Row(tag: "CX",
                               fiveHour: format(five, displayMode),
                               sevenDay: format(seven, displayMode)))
            case "claude":
                let five = claudeUsage?.fiveHour?.usedPercent
                let seven = claudeUsage?.sevenDay?.usedPercent
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
