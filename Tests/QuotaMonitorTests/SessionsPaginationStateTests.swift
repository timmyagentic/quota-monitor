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

    private func cursor(_ index: Int) -> SessionPageCursor {
        .recent(
            activityAt: "2026-07-20T12:00:00Z",
            sessionId: String(format: "session-%03d", index))
    }

    private var query: SessionsPaginationState.Query {
        .init(sort: .recent, search: "")
    }

    @Test("next page keeps a fixed size, advances the cursor, and appends")
    func fixedSizePageAdvancesCursor() throws {
        var state = SessionsPaginationState()
        let initial = state.reset(
            query: query,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        #expect(initial.trigger == .initial)
        #expect(initial.cursor == nil)
        #expect(initial.pageSize == 50)
        #expect(initial.query == query)
        #expect(state.isLoadingInitial)
        let blockedInitial = state.beginNextPage(trigger: .scroll)
        #expect(blockedInitial == nil)

        let firstRows = (0..<50).map(row)
        let firstCursor = cursor(49)
        let completedInitial = state.complete(
            SessionPage(rows: firstRows, nextCursor: firstCursor),
            for: initial)
        #expect(completedInitial)
        #expect(state.rows == firstRows)
        #expect(state.loadedCount == 50)
        #expect(state.hasMore)

        let nextValue = state.beginNextPage(
            trigger: .scroll,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let next = try #require(nextValue)
        #expect(next.trigger == .scroll)
        #expect(next.cursor == firstCursor)
        #expect(next.pageSize == 50)
        #expect(state.isLoadingNextPage)
        let blockedNext = state.beginNextPage(trigger: .scroll)
        #expect(blockedNext == nil)

        // A repeated boundary row can occur when live data changes between
        // reads. State appends the new page while suppressing that duplicate.
        let nextRows = [row(49)] + (50..<55).map(row)
        let completedNext = state.complete(
            SessionPage(rows: nextRows, nextCursor: nil),
            for: next)
        #expect(completedNext)
        #expect(state.rows == (0..<55).map(row))
        #expect(state.loadedCount == 55)
        #expect(!state.hasMore)
        let terminalRequest = state.beginNextPage(trigger: .scroll)
        #expect(terminalRequest == nil)
    }

    @Test("pagination failure keeps rows and retry reuses the cursor")
    func paginationFailureIsRetryable() throws {
        var state = SessionsPaginationState()
        let initial = state.reset(query: query)
        let firstRows = (0..<50).map(row)
        let firstCursor = cursor(49)
        let completedInitial = state.complete(
            SessionPage(rows: firstRows, nextCursor: firstCursor),
            for: initial)
        #expect(completedInitial)

        let nextValue = state.beginNextPage(trigger: .scroll)
        let next = try #require(nextValue)
        #expect(next.cursor == firstCursor)
        #expect(next.pageSize == 50)
        let failed = state.fail("database busy", for: next)
        #expect(failed)
        #expect(state.rows == firstRows)
        #expect(state.paginationFailure == .query("database busy"))
        let blocked = state.beginNextPage(trigger: .scroll)
        #expect(blocked == nil)

        let retryValue = state.beginNextPage(trigger: .retry)
        let retry = try #require(retryValue)
        #expect(retry.trigger == .retry)
        #expect(retry.cursor == firstCursor)
        #expect(retry.pageSize == 50)
        #expect(state.paginationFailure == nil)
        let retryRows = (50..<75).map(row)
        let completedRetry = state.complete(
            SessionPage(rows: retryRows, nextCursor: nil),
            for: retry)
        #expect(completedRetry)
        #expect(state.rows == (0..<75).map(row))
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
            SessionPage(rows: [row(1)], nextCursor: nil),
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
            SessionPage(rows: [row(1)], nextCursor: nil),
            for: stale)
        #expect(!completedStale)
        let failedStale = state.fail("stale", for: stale)
        #expect(!failedStale)
        state.cancel(stale)

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
            cursor: nil,
            pageSize: 50)

        state.cancel(other)
        #expect(state.inFlightRequest == current)
        state.cancel(current)
        #expect(state.inFlightRequest == nil)
        #expect(state.currentQuery == query)
    }

    @Test("successive fixed pages continue past 500 loaded rows")
    func requestsContinuePastFormerCeiling() throws {
        var state = SessionsPaginationState()
        let initial = state.reset(query: query)
        let completedInitial = state.complete(
            SessionPage(rows: (0..<50).map(row), nextCursor: cursor(49)),
            for: initial)
        #expect(completedInitial)

        for pageNumber in 2...10 {
            let requestValue = state.beginNextPage(trigger: .scroll)
            let request = try #require(requestValue)
            let firstIndex = (pageNumber - 1) * 50
            let lastIndex = pageNumber * 50 - 1
            #expect(request.pageSize == 50)
            #expect(request.cursor == cursor(firstIndex - 1))
            let completed = state.complete(
                SessionPage(
                    rows: (firstIndex...lastIndex).map(row),
                    nextCursor: cursor(lastIndex)),
                for: request)
            #expect(completed)
        }

        #expect(state.loadedCount == 500)
        let beyondValue = state.beginNextPage(trigger: .scroll)
        let beyond = try #require(beyondValue)
        #expect(beyond.pageSize == 50)
        #expect(beyond.cursor == cursor(499))
    }

    @Test("page load triggers have stable diagnostics values")
    func triggerRawValues() {
        let triggers: [SessionPageLoadTrigger] = [.initial, .scroll, .retry]
        #expect(triggers.map(\.rawValue) == ["initial", "scroll", "retry"])
    }
}
