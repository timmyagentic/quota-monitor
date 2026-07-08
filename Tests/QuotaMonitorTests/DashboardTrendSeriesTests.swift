import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Dashboard trend series")
struct DashboardTrendSeriesTests {

    @Test("model trend collapse preserves non-top usage in Other")
    func modelTrendCollapsePreservesOtherUsage() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = (1...9).map { index in
            DailyBreakdownPoint(
                date: day,
                provider: "codex",
                key: "model-\(index)",
                label: "Model \(index)",
                valueUSD: Double(index),
                tokens: Int64(100 - index))
        }

        let collapsed = TrendSeriesBuilder.collapsedModelSeries(
            raw, topLimit: 8, otherLabel: "Other")
        let other = collapsed.first { $0.key == TrendSeriesBuilder.otherKey }

        #expect(collapsed.count == 9)
        #expect(other?.label == "Other")
        #expect(other?.tokens == 91)
        #expect(collapsed.reduce(Int64(0)) { $0 + $1.tokens }
                == raw.reduce(Int64(0)) { $0 + $1.tokens })
    }
}
