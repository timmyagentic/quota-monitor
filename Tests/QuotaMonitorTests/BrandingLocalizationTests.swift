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
}
