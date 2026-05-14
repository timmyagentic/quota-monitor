import Foundation

/// Process-wide cached ISO8601 formatters.
///
/// `ISO8601DateFormatter()` allocates a CFLocale + CFCalendar + a CFDateFormatter
/// under the hood, which is expensive when called in hot loops (per-event parse,
/// per-row CSV export, per-frame timeline render). `ISO8601DateFormatter` is
/// documented thread-safe for `string(from:)` / `date(from:)` once configured,
/// so a single shared instance is safe — we annotate `nonisolated(unsafe)` to
/// satisfy strict concurrency since Foundation hasn't marked the class Sendable.
enum ISO8601 {
    /// `2025-01-02T03:04:05.678Z` — what Codex/Claude rollouts emit.
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `2025-01-02T03:04:05Z` — Anthropic responses sometimes drop the `.SSS`.
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a timestamp that might be either fractional or plain.
    static func parse(_ iso: String) -> Date? {
        fractional.date(from: iso) ?? plain.date(from: iso)
    }
}
