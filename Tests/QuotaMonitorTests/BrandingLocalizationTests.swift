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

    @Test("Codex Fast fallback copy is precise in both languages")
    func codexFastFallbackCopy() {
        let en = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.codexFastModeBillingLabel,
                L10n.codexFastModeBillingHelp
            )
        }
        let zh = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.codexFastModeBillingLabel,
                L10n.codexFastModeBillingHelp
            )
        }

        #expect(en.0 == "Untagged Codex Usage as Fast")
        #expect(en.1 == "Recent Codex usage is estimated per turn from its recorded service-tier preference. This switch only treats older or untagged usage as Fast; explicitly Standard turns stay Standard.")
        #expect(zh.0 == "未标记的 Codex 用量按 Fast 估算")
        #expect(zh.1 == "近期 Codex 用量会按每个 turn 记录的服务档位偏好估算。此开关只把旧版或未标记用量按 Fast 计费；明确记录为 Standard 的 turn 仍按 Standard。")
    }
}
