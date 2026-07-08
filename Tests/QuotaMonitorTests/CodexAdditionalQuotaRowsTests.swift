import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex additional quota rows")
struct CodexAdditionalQuotaRowsTests {
    @Test("active model-specific quota renders both 5-hour and 7-day rows")
    func activeAdditionalQuotaRendersBothWindows() {
        LocalizationTestSupport.withLanguage(.english) {
            let rows = CodexAdditionalQuotaRows.visibleRows(for: [
                RateLimitSnapshot.Additional(
                    limitName: "GPT-5.3-Codex-Spark",
                    meteredFeature: nil,
                    primary: window(usedPercent: 1, duration: 18_000),
                    secondary: window(usedPercent: 4, duration: 604_800))
            ])

            #expect(rows.map(\.title) == [
                "GPT-5.3-Codex-Spark 5-hour",
                "GPT-5.3-Codex-Spark 7-day"
            ])
            #expect(rows.map(\.window.usedPercent) == [1, 4])
        }
    }

    @Test("unused model-specific quota stays hidden")
    func unusedAdditionalQuotaStaysHidden() {
        let rows = CodexAdditionalQuotaRows.visibleRows(for: [
            RateLimitSnapshot.Additional(
                limitName: "GPT-5.3-Codex-Spark",
                meteredFeature: nil,
                primary: window(usedPercent: 0, duration: 18_000),
                secondary: window(usedPercent: 0, duration: 604_800))
        ])

        #expect(rows.isEmpty)
    }

    private func window(
        usedPercent: Double,
        duration: TimeInterval
    ) -> RateLimitSnapshot.Window {
        RateLimitSnapshot.Window(
            usedPercent: usedPercent,
            windowDuration: duration,
            resetAt: Date(timeIntervalSince1970: 1_781_510_400))
    }
}
