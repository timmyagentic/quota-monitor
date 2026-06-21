import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex billing copy", .serialized)
struct CodexBillingCopyTests {
    @Test("Fast Mode fallback copy only applies to unclassified rows")
    func fastModeFallbackCopyScopesToUnclassifiedRows() {
        LocalizationTestSupport.withLanguage(.english) {
            #expect(L10n.codexFastModeBillingLabel == "Bill unclassified Codex as Fast Mode")
            #expect(L10n.codexFastModeBillingHelp.contains("local Codex history markers"))
            #expect(L10n.codexFastModeBillingHelp.contains("only affects Codex events whose tier could not be identified"))
        }

        LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            #expect(L10n.codexFastModeBillingLabel == "未识别的 Codex 按 Fast Mode 计费")
            #expect(L10n.codexFastModeBillingHelp.contains("本地 Codex 历史标记"))
            #expect(L10n.codexFastModeBillingHelp.contains("只影响无法识别档位的 Codex 事件"))
        }
    }

    @Test("split caption localizes tier labels and token unit")
    func splitCaptionLocalizesTierLabelsAndTokenUnit() {
        let share = ModelShare(
            modelId: "gpt-5",
            displayName: "GPT-5",
            valueUSD: 157.50,
            standardValueUSD: 35.00,
            fastValueUSD: 87.50,
            unknownValueUSD: 35.00,
            tokens: 600,
            standardTokens: 100,
            fastTokens: 200,
            unknownTokens: 300,
            eventCount: 3)

        let english = LocalizationTestSupport.withLanguage(.english) {
            share.billingSplitCaption(tokenFormatLocale: Locale(identifier: "en_US"))
        }
        #expect(english == "Fast 200 tokens / $87.50 · Standard 100 tokens / $35.00 · Unknown 300 tokens / $35.00")

        let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            share.billingSplitCaption(tokenFormatLocale: Locale(identifier: "zh_CN"))
        }
        #expect(chinese?.contains("快速 200 个 token") == true)
        #expect(chinese?.contains("标准 100 个 token") == true)
        #expect(chinese?.contains("未知 300 个 token") == true)
    }

    @Test("split caption hides when no Codex split pieces are present")
    func splitCaptionHidesWithoutSplitPieces() {
        let share = ModelShare(
            modelId: "claude-opus",
            displayName: "Claude Opus",
            valueUSD: 12.50,
            standardValueUSD: 0,
            fastValueUSD: 0,
            unknownValueUSD: 0,
            tokens: 123,
            standardTokens: 0,
            fastTokens: 0,
            unknownTokens: 0,
            eventCount: 1)

        #expect(share.billingSplitCaption(tokenFormatLocale: Locale(identifier: "en_US")) == nil)
    }
}
