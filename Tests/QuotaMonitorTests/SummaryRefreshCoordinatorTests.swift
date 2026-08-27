import Testing
@testable import QuotaMonitor

@Suite("Summary refresh coordination")
struct SummaryRefreshCoordinatorTests {
    private let all = DashboardRefreshInputs(
        providerFilter: .all,
        enabledProviders: ["codex", "claude"],
        includesMenuBar: true)

    @Test("visible Dashboard selects one combined summary route")
    func summaryTargetFollowsDashboardVisibility() {
        #expect(AppEnvironment.summaryRefreshTarget(isDashboardVisible: false) == .menuBar)
        #expect(AppEnvironment.summaryRefreshTarget(isDashboardVisible: true)
            == .dashboardAndMenuBar)
    }

    @Test("only the latest overlapping summary generation may publish")
    func latestRefreshGenerationWins() {
        var generation = RefreshGeneration()
        let first = generation.advance()
        let second = generation.advance()

        #expect(!generation.accepts(first))
        #expect(generation.accepts(second))
    }

    @Test("identical mount requests share one Dashboard pass")
    func identicalMountRequestsDoNotQueue() {
        var coalescer = DashboardRefreshCoalescer()

        let began = coalescer.begin(inputs: all, requiresFreshPass: false)
        let duplicateBegan = coalescer.begin(inputs: all, requiresFreshPass: false)
        let trailing = coalescer.finish()

        #expect(began)
        #expect(!duplicateBegan)
        #expect(!coalescer.hasPendingRefresh)
        #expect(trailing == nil)
    }

    @Test("mount is cache-aware while named freshness triggers still trail")
    func mountDoesNotForceATrailingPass() {
        #expect(!DashboardRefreshCoalescer.requiresFreshPass(for: "internal"))
        #expect(!DashboardRefreshCoalescer.requiresFreshPass(for: "mount"))
        #expect(!DashboardRefreshCoalescer.requiresFreshPass(for: "coalesced"))
        for trigger in ["scan", "settings", "manual", "scan-fallback"] {
            #expect(DashboardRefreshCoalescer.requiresFreshPass(for: trigger))
        }
    }

    @Test("scan and settings requests coalesce into one trailing pass")
    func freshnessRequestsQueueOneTrailingPass() {
        var coalescer = DashboardRefreshCoalescer()

        let began = coalescer.begin(inputs: all, requiresFreshPass: false)
        let firstQueued = coalescer.begin(inputs: all, requiresFreshPass: true)
        let secondQueued = coalescer.begin(inputs: all, requiresFreshPass: true)
        let hadPendingRefresh = coalescer.hasPendingRefresh
        let trailing = coalescer.finish()
        let secondFinish = coalescer.finish()

        #expect(began)
        #expect(!firstQueued)
        #expect(!secondQueued)
        #expect(hadPendingRefresh)
        #expect(trailing == true)
        #expect(secondFinish == nil)
    }

    @Test("changed inputs queue a pass and preserve the strongest surface")
    func changedInputsQueueLatestPass() {
        var coalescer = DashboardRefreshCoalescer()
        let codexOnly = DashboardRefreshInputs(
            providerFilter: .codex,
            enabledProviders: ["codex"],
            includesMenuBar: false)

        let began = coalescer.begin(inputs: codexOnly, requiresFreshPass: false)
        let changedBegan = coalescer.begin(inputs: all, requiresFreshPass: false)
        let trailing = coalescer.finish()

        #expect(began)
        #expect(!changedBegan)
        #expect(trailing == true)
    }
}
