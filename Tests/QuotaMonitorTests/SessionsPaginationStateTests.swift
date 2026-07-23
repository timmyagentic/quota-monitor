import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Sessions pagination state")
struct SessionsPaginationStateTests {
    private func row(_ index: Int) -> SessionRow {
        SessionRow(
            sessionId: String(format: "session-%03d", index),
            title: "Session \(index)",
            projectName: nil,
            cwd: nil,
            agentNickname: nil,
            lastModelId: "gpt-5.6-sol",
            startedAt: nil,
            updatedAt: nil,
            totalValueUSD: Double(index),
            totalTokens: Int64(index),
            eventCount: 1,
            containsSubagents: false,
            subagentCount: nil,
            hasInferredModel: false)
    }

    private var query: SessionsPaginationState.Query {
        .init(sort: .recent, search: "")
    }

    @Test("initial 50-row prefix grows by 50 and is replaced atomically")
    func prefixGrowsByOnePage() throws {
        var state = SessionsPaginationState()
        let initial = state.reset(
            query: query,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        #expect(initial.trigger == .initial)
        #expect(initial.limit == 50)
        #expect(initial.query == query)
        #expect(state.isLoadingInitial)
        let blockedInitial = state.beginNextPage(trigger: .scroll)
        #expect(blockedInitial == nil)

        let firstRows = (0..<50).map(row)
        let completedInitial = state.complete(
            SessionPage(rows: firstRows, hasMore: true),
            for: initial)
        #expect(completedInitial)
        #expect(state.rows == firstRows)
        #expect(state.loadedLimit == 50)
        #expect(state.hasMore)

        let nextValue = state.beginNextPage(
            trigger: .scroll,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let next = try #require(nextValue)
        #expect(next.trigger == .scroll)
        #expect(next.limit == 100)
        #expect(state.isLoadingNextPage)
        let blockedNext = state.beginNextPage(trigger: .scroll)
        #expect(blockedNext == nil)

        let allRows = (0..<55).map(row)
        let completedNext = state.complete(
            SessionPage(rows: allRows, hasMore: false),
            for: next)
        #expect(completedNext)
        #expect(state.rows == allRows)
        #expect(state.loadedLimit == 100)
        #expect(!state.hasMore)
        let terminalRequest = state.beginNextPage(trigger: .scroll)
        #expect(terminalRequest == nil)
    }

    @Test("pagination failure keeps rows and retry keeps the target limit")
    func paginationFailureIsRetryable() throws {
        var state = SessionsPaginationState()
        let initial = state.reset(query: query)
        let firstRows = (0..<50).map(row)
        let completedInitial = state.complete(
            SessionPage(rows: firstRows, hasMore: true),
            for: initial)
        #expect(completedInitial)

        let nextValue = state.beginNextPage(trigger: .scroll)
        let next = try #require(nextValue)
        #expect(next.limit == 100)
        let failed = state.fail("database busy", for: next)
        #expect(failed)
        #expect(state.rows == firstRows)
        #expect(state.paginationFailure == .query("database busy"))
        let blocked = state.beginNextPage(trigger: .scroll)
        #expect(blocked == nil)

        let retryValue = state.beginNextPage(trigger: .retry)
        let retry = try #require(retryValue)
        #expect(retry.trigger == .retry)
        #expect(retry.limit == 100)
        #expect(state.paginationFailure == nil)
        let retryRows = (0..<75).map(row)
        let completedRetry = state.complete(
            SessionPage(rows: retryRows, hasMore: false),
            for: retry)
        #expect(completedRetry)
        #expect(state.rows == retryRows)
        #expect(state.paginationFailure == nil)
    }

    @Test("query reset rejects stale page results")
    func queryResetRejectsStaleResults() {
        var state = SessionsPaginationState()
        let stale = state.reset(query: query)
        let replacementQuery = SessionsPaginationState.Query(
            sort: .value,
            search: "quota monitor")
        let current = state.reset(query: replacementQuery)

        let completedStale = state.complete(
            SessionPage(rows: [row(1)], hasMore: false),
            for: stale)
        #expect(!completedStale)
        let failedStale = state.fail("stale", for: stale)
        #expect(!failedStale)
        state.cancel(stale)

        #expect(state.currentQuery == replacementQuery)
        #expect(state.inFlightRequest == current)
        #expect(state.rows.isEmpty)
        #expect(state.initialFailure == nil)
        #expect(state.paginationFailure == nil)
    }

    @Test("request identity rejects stale work for the same query")
    func requestIdentityRejectsSameQueryStaleWork() {
        var state = SessionsPaginationState()
        let stale = state.reset(
            query: query,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        let current = state.reset(
            query: query,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!)

        let completedStale = state.complete(
            SessionPage(rows: [row(1)], hasMore: false),
            for: stale)
        let failedStale = state.fail("stale", for: stale)
        state.cancel(stale)

        #expect(!completedStale)
        #expect(!failedStale)
        #expect(state.inFlightRequest == current)
        #expect(state.rows.isEmpty)
        #expect(state.initialFailure == nil)
    }

    @Test("cancellation clears only the matching request")
    func cancellationMatchesRequest() {
        var state = SessionsPaginationState()
        let current = state.reset(query: query)
        let other = SessionsPaginationState.Request(
            id: UUID(),
            trigger: .initial,
            query: query,
            limit: 50)

        state.cancel(other)
        #expect(state.inFlightRequest == current)
        state.cancel(current)
        #expect(state.inFlightRequest == nil)
        #expect(state.currentQuery == query)
    }

    @Test("successive requests continue past a 500-row loaded prefix")
    func requestsContinuePastFormerCeiling() throws {
        var state = SessionsPaginationState()
        let initial = state.reset(query: query)
        let completedInitial = state.complete(
            SessionPage(rows: (0..<50).map(row), hasMore: true),
            for: initial)
        #expect(completedInitial)

        for pageNumber in 2...10 {
            let requestValue = state.beginNextPage(trigger: .scroll)
            let request = try #require(requestValue)
            #expect(request.limit == pageNumber * 50)
            let completed = state.complete(
                SessionPage(
                    rows: (0..<(pageNumber * 50)).map(row),
                    hasMore: true),
                for: request)
            #expect(completed)
        }

        #expect(state.loadedLimit == 500)
        let beyondValue = state.beginNextPage(trigger: .scroll)
        let beyond = try #require(beyondValue)
        #expect(beyond.limit == 550)
    }

    @Test("page load triggers have stable diagnostics values")
    func triggerRawValues() {
        let triggers: [SessionPageLoadTrigger] = [.initial, .scroll, .retry]
        #expect(triggers.map(\.rawValue) == ["initial", "scroll", "retry"])
    }
}
