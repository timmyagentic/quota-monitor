import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Activity localization", .serialized)
struct ActivityLocalizationTests {
    @Test("data source control and status copy are bilingual")
    func dataSourceAndStatusCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.activityDataSourceLabel,
                L10n.activityDataSourceHint,
                L10n.activityScopeIndexed,
                L10n.activityScopeAccount,
                L10n.activityIndexedSummary(tokens: "13B"),
                L10n.activityLoadingAccount,
                L10n.activityAccountUnavailable,
                L10n.activityAccountDailyUnavailable,
                L10n.activityShowingCachedData,
                L10n.activityRefreshingAccount
            )
        }
        #expect(en.0 == "Activity source")
        #expect(en.1 == "Switch between locally indexed history and Codex account totals.")
        #expect(en.2 == "Local")
        #expect(en.3 == "Account")
        #expect(en.4 == "Local total 13B tokens · Details are available in History and Sessions")
        #expect(en.5 == "Loading account activity…")
        #expect(en.6 == "Account activity is temporarily unavailable.")
        #expect(en.7 == "Daily account activity is temporarily unavailable.")
        #expect(en.8 == "Cached account activity")
        #expect(en.9 == "Refreshing account activity…")

        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.activityDataSourceLabel,
                L10n.activityDataSourceHint,
                L10n.activityScopeIndexed,
                L10n.activityScopeAccount,
                L10n.activityIndexedSummary(tokens: "130亿"),
                L10n.activityLoadingAccount,
                L10n.activityAccountUnavailable,
                L10n.activityAccountDailyUnavailable,
                L10n.activityShowingCachedData,
                L10n.activityRefreshingAccount
            )
        }
        #expect(zh.0 == "活动数据来源")
        #expect(zh.1 == "在本地已索引历史与 Codex 账户汇总之间切换。")
        #expect(zh.2 == "本地")
        #expect(zh.3 == "账户")
        #expect(zh.4 == "本地汇总 130亿 tokens · 可在“历史”和“会话”中查看明细")
        #expect(zh.5 == "正在载入账户活动…")
        #expect(zh.6 == "账户活动暂时不可用。")
        #expect(zh.7 == "账户每日活动暂时不可用。")
        #expect(zh.8 == "缓存的账户活动")
        #expect(zh.9 == "正在刷新账户活动…")
    }

    @Test("summary dates and safe optional coverage are localized")
    func summariesAndDates() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.activityAccountSummary(
                    accountTokens: "30.8B",
                    indexedTokens: "13B",
                    coveragePercent: 42.26),
                L10n.activityAccountSummary(
                    accountTokens: "30.8B",
                    indexedTokens: "13B",
                    coveragePercent: nil),
                L10n.activityUpdated("Jul 23"),
                L10n.activityAsOf("Jul 21")
            )
        }
        #expect(en.0 == "Account total 30.8B tokens · 13B tokens indexed locally (about 42.3%)")
        #expect(en.1 == "Account total 30.8B tokens · 13B tokens indexed locally")
        #expect(en.2 == "Updated Jul 23")
        #expect(en.3 == "Account stats as of Jul 21")

        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.activityAccountSummary(
                    accountTokens: "308亿",
                    indexedTokens: "130亿",
                    coveragePercent: 42.26),
                L10n.activityUpdated("7月23日"),
                L10n.activityAsOf("7月21日")
            )
        }
        #expect(zh.0 == "账户累计 308亿 tokens · 本地已索引 130亿 tokens（约 42.3%）")
        #expect(zh.1 == "更新于 7月23日")
        #expect(zh.2 == "账户统计截至 7月21日")

        for invalidCoverage in [Double.nan, .infinity, -0.1, 100.1] {
            let text = LocalizationTestSupport.withLanguage(.english) {
                L10n.activityAccountSummary(
                    accountTokens: "30.8B",
                    indexedTokens: "13B",
                    coveragePercent: invalidCoverage)
            }
            #expect(text == "Account total 30.8B tokens · 13B tokens indexed locally")
        }
    }

    @Test("account metric labels and rounded duration are bilingual")
    func accountMetricCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.activityAccountLifetimeTokens,
                L10n.activityAccountPeakTokens,
                L10n.activityAccountLongestChat,
                L10n.activityAccountCurrentStreak,
                L10n.activityAccountLongestStreak,
                L10n.activityAccountMetricsAccessibility,
                L10n.activityDuration(seconds: 53_214)
            )
        }
        #expect(en.0 == "Lifetime tokens")
        #expect(en.1 == "Peak tokens")
        #expect(en.2 == "Longest chat")
        #expect(en.3 == "Current streak")
        #expect(en.4 == "Longest streak")
        #expect(en.5 == "Codex account activity metrics")
        #expect(en.6 == "14h 47m")

        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.activityAccountLifetimeTokens,
                L10n.activityAccountPeakTokens,
                L10n.activityAccountLongestChat,
                L10n.activityAccountCurrentStreak,
                L10n.activityAccountLongestStreak,
                L10n.activityAccountMetricsAccessibility,
                L10n.activityDuration(seconds: 53_214)
            )
        }
        #expect(zh.0 == "累计 tokens")
        #expect(zh.1 == "单日峰值")
        #expect(zh.2 == "最长会话")
        #expect(zh.3 == "当前连续")
        #expect(zh.4 == "最长连续")
        #expect(zh.5 == "Codex 账户活动指标")
        #expect(zh.6 == "14小时 47分")
    }

    @Test("heatmap scope and VoiceOver summary are bilingual")
    func heatmapCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.activityHeatmapScope(scope: L10n.activityScopeAccount),
                L10n.activityHeatmapAccessibility(
                    scope: L10n.activityScopeAccount,
                    activeDays: 91,
                    totalTokens: "30.8B"),
                L10n.activityHeatmapAccessibility(
                    scope: L10n.activityScopeIndexed,
                    activeDays: 1,
                    totalTokens: "1.2M")
            )
        }
        #expect(en.0 == "Account · Last 365 days")
        #expect(en.1 == "Account token activity for the last 365 days: 91 active days, 30.8B tokens total.")
        #expect(en.2 == "Local token activity for the last 365 days: 1 active day, 1.2M tokens total.")

        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.activityHeatmapScope(scope: L10n.activityScopeAccount),
                L10n.activityHeatmapAccessibility(
                    scope: L10n.activityScopeAccount,
                    activeDays: 91,
                    totalTokens: "308亿")
            )
        }
        #expect(zh.0 == "账户 · 最近 365 天")
        #expect(zh.1 == "账户最近 365 天 Token 活跃度：活跃 91 天，共 308亿 tokens。")
    }
}
