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

    @Test("Anonymous version reporting copy is precise in both languages")
    func anonymousVersionReportingCopyIsPrecise() {
        let english = LocalizationTestSupport.withLanguage(.english) {
            [
                L10n.anonymousVersionReportingHelp,
                L10n.anonymousVersionReportingDisableHelp,
                L10n.anonymousVersionReportingDisclosureMessage,
                L10n.anonymousVersionReportingQAHelp,
            ].joined(separator: " ")
        }
        let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            [
                L10n.anonymousVersionReportingHelp,
                L10n.anonymousVersionReportingDisableHelp,
                L10n.anonymousVersionReportingDisclosureMessage,
                L10n.anonymousVersionReportingQAHelp,
            ].joined(separator: " ")
        }

        for term in [
            "protocol/schema version", "UTC date", "app version", "brand",
            "distribution channel", "fresh random daily token", "UTC day",
            "deduplicated", "failed delivery attempts", "same day's token",
            "account", "usage history", "path", "device ID", "stable ID",
            "received by the service", "Settings",
        ] {
            #expect(english.localizedCaseInsensitiveContains(term))
        }
        for term in [
            "协议/模式版本", "UTC 日期", "应用版本", "品牌", "分发渠道",
            "每日新生成的随机 token", "UTC 日", "去重", "发送失败",
            "同一天的 token", "账号", "使用记录", "路径", "设备 ID", "稳定 ID",
            "服务端已接收", "设置",
        ] {
            #expect(chinese.localizedCaseInsensitiveContains(term))
        }
        #expect(L10n.anonymousVersionReportingPrivacyURL.absoluteString
            == "https://quota-monitor.timmyagentic.com/privacy")
    }

    @Test("General settings exposes the consent setter and privacy link")
    func generalSettingsWiresAnonymousVersionConsent() throws {
        let source = try String(
            contentsOf: Self.repoRoot().appendingPathComponent(
                "QuotaMonitor/Features/Settings/GeneralSettingsTab.swift"),
            encoding: .utf8)

        #expect(source.contains("Section(L10n.sectionPrivacy)"))
        #expect(source.contains("settings.setAnonymousVersionReportingConsent"))
        #expect(source.contains("L10n.anonymousVersionReportingPrivacyURL"))
        #expect(source.contains("LocalQAEnvironment.isActive"))
    }

}
