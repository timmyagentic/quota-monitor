import Foundation

// Localized strings for the Dashboard's ActivitySection (the CodeX-style
// usage profile: lifetime tokens, peak day, longest task, streaks, and the
// contribution heatmap). Kept in its own file so the feature is
// self-contained; the catalog stays type-checked Swift either way.
//
// `L10n.s(_:_:)` is private to L10n.swift, so this extension uses its own
// tiny `sa(_:_:)` mirror reading the same `LocalizationStore` language.
extension L10n {

    private static func sa(_ en: String, _ zh: String) -> String {
        switch LocalizationStore.activeLanguage {
        case .english: return en
        case .simplifiedChinese: return zh
        }
    }

    // MARK: - section + data scope

    static var activitySectionTitle: String { sa("Activity", "使用画像") }
    static var activityDataSourceLabel: String {
        sa("Activity source", "活动数据来源")
    }
    static var activityDataSourceHint: String {
        sa(
            "Switch between locally indexed history and Codex account totals.",
            "在本地已索引历史与 Codex 账户汇总之间切换。")
    }
    static var activityScopeIndexed: String { sa("Local", "本地") }
    static var activityScopeAccount: String { sa("Account", "账户") }

    static func activityIndexedSummary(tokens: String) -> String {
        sa(
            "Local total \(tokens) tokens · Details are available in History and Sessions",
            "本地汇总 \(tokens) tokens · 可在“历史”和“会话”中查看明细")
    }

    /// Account-vs-local summary. Coverage is deliberately optional: callers
    /// should omit it when the two snapshots cannot be compared, and this
    /// formatter also drops non-finite or out-of-range percentages.
    static func activityAccountSummary(
        accountTokens: String,
        indexedTokens: String,
        coveragePercent: Double?
    ) -> String {
        let base = sa(
            "Account total \(accountTokens) tokens · \(indexedTokens) tokens indexed locally",
            "账户累计 \(accountTokens) tokens · 本地已索引 \(indexedTokens) tokens")
        guard let coveragePercent,
              coveragePercent.isFinite,
              (0...100).contains(coveragePercent)
        else { return base }

        let locale = LocalizationStore.activeLanguage == .simplifiedChinese
            ? Locale(identifier: "zh_Hans")
            : Locale(identifier: "en_US")
        let formatted = coveragePercent.formatted(
            .number
                .precision(.fractionLength(0...1))
                .locale(locale))
        return base + sa(" (about \(formatted)%)", "（约 \(formatted)%）")
    }

    static func activityUpdated(_ date: String) -> String {
        sa("Updated \(date)", "更新于 \(date)")
    }

    static func activityAsOf(_ date: String) -> String {
        sa("Account stats as of \(date)", "账户统计截至 \(date)")
    }

    static var activityLoadingAccount: String {
        sa("Loading account activity…", "正在载入账户活动…")
    }
    static var activityAccountUnavailable: String {
        sa(
            "Account activity is temporarily unavailable.",
            "账户活动暂时不可用。")
    }
    static var activityAccountDailyUnavailable: String {
        sa(
            "Daily account activity is temporarily unavailable.",
            "账户每日活动暂时不可用。")
    }
    static var activityShowingCachedData: String {
        sa("Cached account activity", "缓存的账户活动")
    }
    static var activityRefreshingAccount: String {
        sa("Refreshing account activity…", "正在刷新账户活动…")
    }

    // MARK: - stat strip

    static var activityLifetimeTokens: String { sa("Lifetime tokens", "累计 tokens") }
    static var activityPeakTokens: String { sa("Peak tokens", "单日峰值") }
    static var activityLongestChat: String { sa("Longest chat", "最长会话") }
    static var activityCurrentStreak: String { sa("Current streak", "当前连续") }
    static var activityLongestStreak: String { sa("Longest streak", "最长连续") }
    static var activityIndexedMetricsAccessibility: String {
        sa("Locally indexed activity metrics", "本地已索引活动指标")
    }
    static var activityAccountMetricsAccessibility: String {
        sa("Codex account activity metrics", "Codex 账户活动指标")
    }

    // Account profile uses the same labels as the existing local strip. These
    // aliases keep the source choice explicit at the call site without
    // allowing the two translations to drift.
    static var activityAccountLifetimeTokens: String { activityLifetimeTokens }
    static var activityAccountPeakTokens: String { activityPeakTokens }
    static var activityAccountLongestChat: String { activityLongestChat }
    static var activityAccountCurrentStreak: String { activityCurrentStreak }
    static var activityAccountLongestStreak: String { activityLongestStreak }

    static var activityNoData: String {
        sa("No activity recorded yet", "暂无活跃记录")
    }

    // MARK: - heatmap

    static var activityTokenActivity: String { sa("Token activity", "Token 活跃度") }
    static var activityHeatmapLess: String { sa("Less", "少") }
    static var activityHeatmapMore: String { sa("More", "多") }

    static func activityHeatmapScope(scope: String) -> String {
        sa("\(scope) · Last 365 days", "\(scope) · 最近 365 天")
    }

    /// A single VoiceOver description for the otherwise visual heatmap.
    static func activityHeatmapAccessibility(
        scope: String,
        activeDays: Int,
        totalTokens: String
    ) -> String {
        let days = activeDays == 1 ? "1 active day" : "\(activeDays) active days"
        return sa(
            "\(scope) token activity for the last 365 days: \(days), \(totalTokens) tokens total.",
            "\(scope)最近 365 天 Token 活跃度：活跃 \(activeDays) 天，共 \(totalTokens) tokens。")
    }

    // MARK: - formatted values

    /// Streak / day-count label, e.g. "38 days" / "38 天".
    static func activityStreakDays(_ count: Int) -> String {
        sa("\(count) days", "\(count) 天")
    }

    /// Compact rounded duration used by the account profile's longest-chat
    /// metric, e.g. "14h 47m" / "14小时 47分".
    static func activityDuration(seconds: Int64) -> String {
        let clamped = max(seconds, 0)
        let wholeMinutes = clamped / 60
        let totalMinutes = wholeMinutes + (clamped % 60 >= 30 ? 1 : 0)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)\(unitDayShort)") }
        if hours > 0 { parts.append("\(hours)\(unitHourShort)") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)\(unitMinuteShort)") }
        return parts.joined(separator: " ")
    }

    /// Heatmap cell tooltip, e.g. "May 12 · 1.2M tokens".
    static func activityHeatmapCell(date: String, tokens: String) -> String {
        sa("\(date) · \(tokens) tokens", "\(date) · \(tokens) tokens")
    }
}
