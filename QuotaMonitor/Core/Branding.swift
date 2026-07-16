import Foundation

/// Single source of truth for all user-facing branding.
///
/// Change `appDisplayName` and `appCodeName` to build a variant
/// (e.g., "CodexMonitor" for new users). Internal identifiers
/// (bundle ID, database path, URL scheme, etc.) are intentionally
/// NOT here — they stay fixed for upgrade continuity.
///
/// Build scripts (`build.sh`, `make-dmg.sh`, `release.sh`, etc.)
/// extract these values via `grep`/`sed` at build time and inject
/// them into Info.plist and DMG filenames.
enum Branding {

    /// User-facing display name with spaces (e.g., "Quota Monitor").
    /// Used in window titles, menu headers, accessibility labels,
    /// localized strings, and the DMG volume name.
    static let appDisplayName = "Quota Monitor"

    /// Compact identifier without spaces (e.g., "QuotaMonitor").
    /// Used in User-Agent, DMG filenames, appcast titles, and
    /// the CFBundleName plist key.
    static let appCodeName = "QuotaMonitor"

    /// Stable allowlisted value for anonymous version statistics. Unknown
    /// build variants fail closed instead of inventing a server dimension.
    static var telemetrySlug: String? {
        telemetrySlug(forCodeName: appCodeName)
    }

    static func telemetrySlug(forCodeName codeName: String) -> String? {
        switch codeName {
        case "QuotaMonitor": "quota-monitor"
        case "CodexMonitor": "codex-monitor"
        default: nil
        }
    }

    /// Version string for User-Agent and similar protocol contexts.
    /// Reads from the bundle at runtime; falls back to "unknown".
    static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
    }
}
