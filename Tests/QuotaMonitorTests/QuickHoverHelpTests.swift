import Testing
@testable import QuotaMonitor

@Suite("Quick hover help")
struct QuickHoverHelpTests {

    @Test
    func toolbarTimingMatchesExistingFastHoverPattern() {
        #expect(QuickHoverHelpTiming.toolbar.showDelayMilliseconds == 200)
        #expect(QuickHoverHelpTiming.toolbar.hideDelayMilliseconds == 120)
        #expect(QuickHoverHelpTiming.toolbar.showDelayMilliseconds < 500)
    }
}
