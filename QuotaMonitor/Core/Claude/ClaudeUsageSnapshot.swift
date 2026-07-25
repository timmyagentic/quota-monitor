import Foundation

/// Domain-level view of Anthropic's `/api/oauth/usage` response. Decoupled
/// from the wire shape so a future API tweak only changes the mapping.
///
/// Source: [CodexBar `docs/claude.md`] documents the same endpoint and
/// fields. Anthropic doesn't publicly advertise this — it backs the
/// official `claude` CLI's quota indicator — so the shape may evolve. We
/// decode defensively (every nested field optional).
struct ClaudeUsageSnapshot: Equatable, Sendable {
    let capturedAt: Date
    /// "pro" | "max5x" | "max20x" | "team" | "enterprise" | "free" — used
    /// for the badge next to the Claude block. Nil = the API didn't say.
    let tier: String?
    let fiveHour: Window?
    /// Last known 5-hour window after Anthropic has stopped returning
    /// `five_hour` because that window reset and no new current window has
    /// started. UI can render this through the stale-row treatment without
    /// confusing it with the active `fiveHour` slot.
    let staleFiveHour: Window?
    let sevenDay: Window?
    /// Per-model 7-day windows. Pro / Max users see Opus + Sonnet
    /// separately because Opus has a tighter sub-limit; Free / lower tiers
    /// may omit one or both.
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    /// Modern `/api/oauth/usage` responses carry model-specific weekly
    /// limits in a self-describing `limits[]` array instead of adding more
    /// top-level `seven_day_*` fields. Fable 5 is the first observed entry.
    let weeklyScoped: [WeeklyScopedLimit]

    init(
        capturedAt: Date,
        tier: String?,
        fiveHour: Window?,
        staleFiveHour: Window? = nil,
        sevenDay: Window?,
        sevenDayOpus: Window?,
        sevenDaySonnet: Window?,
        weeklyScoped: [WeeklyScopedLimit] = []
    ) {
        self.capturedAt = capturedAt
        self.tier = tier
        self.fiveHour = fiveHour
        self.staleFiveHour = staleFiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.weeklyScoped = Self.deduplicated(weeklyScoped)
    }

    /// Convenience for callers that care about Anthropic's current named
    /// allowance while keeping the stored model generic for future limits.
    var sevenDayFable: Window? {
        weeklyScoped.first { $0.key == "fable" }?.window
    }

    /// Prefer the current 5-hour window, but keep the last completed window
    /// visible when Anthropic temporarily omits `five_hour` from a later
    /// weekly-only response.
    var fiveHourForDisplay: Window? {
        fiveHour ?? staleFiveHour
    }

    /// The OAuth branch should remain active for model-only responses too.
    /// Anthropic can omit the aggregate windows while still returning a
    /// valid model-scoped weekly allowance.
    var hasRenderableQuotaWindow: Bool {
        fiveHour != nil || staleFiveHour != nil || hasRenderableWeeklyQuotaWindow
    }

    /// Whether the snapshot has a weekly row that the UI will actually show.
    /// The menu popover uses this to retain the idle 5h slot for aggregate
    /// and model-only weekly responses alike.
    var hasRenderableWeeklyQuotaWindow: Bool {
        sevenDay != nil || !ClaudeScopedQuotaRows.visibleRows(for: self).isEmpty
    }

    func preservingStaleFiveHour(from previous: ClaudeUsageSnapshot?) -> ClaudeUsageSnapshot {
        guard fiveHour == nil,
              staleFiveHour == nil,
              hasCurrentQuotaWindow,
              let previousWindow = previous?.fiveHour ?? previous?.staleFiveHour,
              previousWindow.resetAt <= capturedAt else {
            return self
        }
        return ClaudeUsageSnapshot(
            capturedAt: capturedAt,
            tier: tier,
            fiveHour: fiveHour,
            staleFiveHour: previousWindow,
            sevenDay: sevenDay,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet,
            weeklyScoped: weeklyScoped)
    }

    private var hasCurrentQuotaWindow: Bool {
        sevenDay != nil || sevenDayOpus != nil || sevenDaySonnet != nil
            || !weeklyScoped.isEmpty
    }

    struct WeeklyScopedLimit: Equatable, Sendable, Identifiable {
        let key: String
        let displayName: String
        let window: Window

        var id: String { key }

        init(key: String, displayName: String? = nil, window: Window) {
            self.key = key
            self.displayName = Self.productDisplayName(
                for: key,
                fallback: displayName)
            self.window = window
        }

        static func canonicalKey(for displayName: String) -> String? {
            let folded = displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            let parts = folded
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let rawKey = parts.joined(separator: "_")
            let key: String
            switch rawKey {
            case "fable", "fable_5", "claude_fable_5": key = "fable"
            default: key = rawKey
            }
            return key.isEmpty ? nil : key
        }

        static func productDisplayName(
            for key: String,
            fallback: String? = nil
        ) -> String {
            switch key {
            case "fable": return "Fable 5"
            case "opus": return "Opus"
            case "sonnet": return "Sonnet"
            default:
                if let fallback, !fallback.isEmpty { return fallback }
                return key.split(separator: "_")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            }
        }
    }

    struct Window: Equatable, Sendable {
        let usedPercent: Double
        let resetAt: Date
        /// Window duration in seconds, derived from labels in the API
        /// response (`five_hour` → 18000, `seven_day` → 604800).
        let windowDuration: TimeInterval

        var remainingPercent: Double { max(0, 100 - usedPercent) }
        var timeUntilReset: TimeInterval { resetAt.timeIntervalSinceNow }

        /// Same definition as `RateLimitSnapshot.Window.paceRatio`. Lets us
        /// reuse the QuotaRow UI without forking it for Anthropic.
        func paceRatio(now: Date = Date()) -> Double? {
            let elapsed = windowDuration - resetAt.timeIntervalSince(now)
            guard elapsed > 0, windowDuration > 0 else { return nil }
            let elapsedFraction = elapsed / windowDuration
            guard elapsedFraction > 0 else { return nil }
            return (usedPercent / 100.0) / elapsedFraction
        }

        /// Human-readable verdict, identical formatting to Codex.
        func paceLabel(now: Date = Date()) -> QuotaPaceLabel.Result? {
            QuotaPaceLabel.make(
                usedPercent: usedPercent,
                paceRatio: paceRatio(now: now),
                timeUntilReset: max(0, resetAt.timeIntervalSince(now)))
        }
    }

    private static func deduplicated(
        _ limits: [WeeklyScopedLimit]
    ) -> [WeeklyScopedLimit] {
        var seen = Set<String>()
        return limits.filter { seen.insert($0.key).inserted }
    }
}

/// Shared model-weekly row selection for persistence and the two visible
/// quota surfaces. Structured `limits[]` entries win over legacy top-level
/// Opus/Sonnet fields. Presence is enough to show a structured entry (even
/// 0%); legacy fields keep their existing >0.5% noise filter in the UI.
enum ClaudeScopedQuotaRows {
    /// Prefix stored in `rate_limit_samples.limit_name` for entries that
    /// came from the modern self-describing `limits[]` payload. Legacy
    /// top-level Opus/Sonnet fields keep their plain names so hydration can
    /// preserve the different visibility semantics after a relaunch.
    static let structuredStoragePrefix = "scoped:"

    struct Row: Equatable, Identifiable {
        let key: String
        let displayName: String
        let window: ClaudeUsageSnapshot.Window

        var id: String { key }
    }

    struct PersistedRow: Equatable {
        let limitName: String
        let window: ClaudeUsageSnapshot.Window
    }

    static func persistedRows(for snapshot: ClaudeUsageSnapshot) -> [PersistedRow] {
        var result = snapshot.weeklyScoped.map {
            PersistedRow(
                limitName: structuredStoragePrefix + $0.displayName,
                window: $0.window)
        }
        let structuredKeys = Set(snapshot.weeklyScoped.map(\.key))

        if let window = snapshot.sevenDayOpus,
           !structuredKeys.contains("opus") {
            result.append(PersistedRow(limitName: "opus", window: window))
        }
        if let window = snapshot.sevenDaySonnet,
           !structuredKeys.contains("sonnet") {
            result.append(PersistedRow(limitName: "sonnet", window: window))
        }
        return result
    }

    static func visibleRows(for snapshot: ClaudeUsageSnapshot) -> [Row] {
        let structuredKeys = Set(snapshot.weeklyScoped.map(\.key))
        var result = snapshot.weeklyScoped.map {
            Row(key: $0.key, displayName: $0.displayName, window: $0.window)
        }

        if let window = snapshot.sevenDayOpus,
           window.usedPercent > 0.5,
           !structuredKeys.contains("opus") {
            result.append(Row(key: "opus", displayName: "Opus", window: window))
        }
        if let window = snapshot.sevenDaySonnet,
           window.usedPercent > 0.5,
           !structuredKeys.contains("sonnet") {
            result.append(Row(key: "sonnet", displayName: "Sonnet", window: window))
        }
        return result
    }
}
