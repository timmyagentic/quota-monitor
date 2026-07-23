import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Branding localization")
struct BrandingLocalizationTests {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/QuotaMonitorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    @Test("update-available copy is driven by Branding.appCodeName")
    func updateAvailableCopyUsesBrandingCodeName() throws {
        let sourceURL = Self.repoRoot()
            .appendingPathComponent("QuotaMonitor/Core/Localization/L10n.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let signature = "static func updateVersionAvailable(_ version: String) -> String"
        let start = try #require(source.range(of: signature)?.lowerBound)
        let remainder = source[start...]
        let end = try #require(remainder.range(of: "\n    }\n")?.upperBound)
        let body = String(remainder[..<end])

        #expect(body.contains("Branding.appCodeName"))
        #expect(!body.contains("\"QuotaMonitor \\(version)"))
    }

    @Test("Claude live quota rate-limit copy is precise and avoids Chinese spacing bug")
    func claudeLiveQuotaRateLimitCopyIsPrecise() {
        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            L10n.claudeRateLimitedRetryIn("5 分钟", lastUpdated: "11:24")
        }
        let en = LocalizationTestSupport.withLanguage(.english) {
            L10n.claudeRateLimitedRetryIn("5 min", lastUpdated: "11:24")
        }

        #expect(zh == "Claude live quota 接口被限速，约 5 分钟后重试 · 上次更新 11:24")
        #expect(!zh.contains("分钟 后"))
        #expect(en == "Claude live quota API rate limited, retry in 5 min · updated 11:24")
    }

    @Test("Codex reset-card copy is concise in both languages")
    func codexResetCardCopy() {
        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.codexResetCardsTitle,
                L10n.codexResetCardsAvailable(2),
                L10n.codexResetCardsNoActive
            )
        }
        let en = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.codexResetCardsTitle,
                L10n.codexResetCardsAvailable(2),
                L10n.codexResetCardsNoActive
            )
        }

        #expect(zh.0 == "主动重置卡")
        #expect(zh.1 == "剩余 2 次")
        #expect(zh.2 == "无可用卡片")
        #expect(en.0 == "Reset cards")
        #expect(en.1 == "2 available")
        #expect(en.2 == "No active cards")
    }

    @Test("History pagination copy is bilingual")
    func historyPaginationCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (L10n.historyNoUsageLatestTwentyOneDays,
             L10n.historyLoadingOlder,
             L10n.historyLoadOlderFailed,
             L10n.retry)
        }
        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (L10n.historyNoUsageLatestTwentyOneDays,
             L10n.historyLoadingOlder,
             L10n.historyLoadOlderFailed,
             L10n.retry)
        }
        #expect(en.0 == "No usage in the latest 21 days")
        #expect(en.1 == "Loading older history")
        #expect(en.2 == "Couldn't load older history.")
        #expect(en.3 == "Retry")
        #expect(zh.0 == "最近 21 天暂无使用记录")
        #expect(zh.1 == "正在加载更早的历史记录")
        #expect(zh.2 == "加载更早的历史记录失败。")
        #expect(zh.3 == "重试")
    }

    @Test("Sessions pagination copy is bilingual")
    func sessionsPaginationCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (L10n.sessionsLoadingMore, L10n.sessionsLoadMoreFailed)
        }
        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (L10n.sessionsLoadingMore, L10n.sessionsLoadMoreFailed)
        }

        #expect(en.0 == "Loading more sessions")
        #expect(en.1 == "Couldn't load more sessions.")
        #expect(zh.0 == "正在加载更多会话")
        #expect(zh.1 == "加载更多会话失败。")
    }

    @Test("History cache hit rate copy is bilingual")
    func historyCacheHitRateCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (L10n.cacheHitRateTitle,
             L10n.cacheHitRateUnavailable)
        }
        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (L10n.cacheHitRateTitle,
             L10n.cacheHitRateUnavailable)
        }

        #expect(en.0 == "Cache hit rate")
        #expect(en.1 == "No eligible input tokens")
        #expect(zh.0 == "缓存命中率")
        #expect(zh.1 == "暂无可计算的输入 Token")
    }

}
