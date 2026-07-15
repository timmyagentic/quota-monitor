import Foundation
import Testing
@testable import QuotaMonitor

@Suite("History pagination state")
struct HistoryPaginationStateTests {
    private func day(_ key: String, valueUSD: Double = 1) -> DaySummary {
        DaySummary(
            day: key,
            date: ISO8601.parse("\(key)T00:00:00Z")!,
            valueUSD: valueUSD,
            tokens: 10,
            eventCount: 1,
            sessionCount: 1)
    }

    @Test("initial completion replaces days and records page metadata")
    func initialCompletionReplacesDays() {
        var state = HistoryPaginationState()
        let first = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001")!)
        let firstCursor = Date(timeIntervalSince1970: 2_000)
        let completedFirst = state.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: firstCursor,
                hasMore: true),
            for: first)
        #expect(completedFirst)

        let replacement = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000002")!)
        let replacementCursor = Date(timeIntervalSince1970: 1_000)
        #expect(replacement.id == UUID(
            uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(replacement.trigger == .initial)
        #expect(replacement.cursor == nil)
        #expect(state.isLoadingInitial)
        #expect(!state.isLoadingNextPage)
        #expect(state.days.isEmpty)
        let completedReplacement = state.complete(
            HistoryPage(
                days: [day("2026-07-14"), day("2026-07-13")],
                nextCursor: replacementCursor,
                hasMore: false),
            for: replacement)
        #expect(completedReplacement)

        #expect(state.days.map(\.day) == ["2026-07-14", "2026-07-13"])
        #expect(state.nextCursor == replacementCursor)
        #expect(!state.hasMore)
        #expect(state.initialFailure == nil)
        #expect(state.paginationFailure == nil)
        #expect(state.inFlightRequest == nil)
        #expect(!state.isLoadingInitial)
    }

    @Test("one next-page request is in flight and retry keeps the cursor")
    func singleFlightAndRetry() throws {
        var state = HistoryPaginationState()
        let initialID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011")!
        let nextID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000012")!
        let blockedID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000013")!
        let retryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000014")!
        let initial = state.reset(requestID: initialID)
        let cursor = Date(timeIntervalSince1970: 1_000)
        let completedInitial = state.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: cursor,
                hasMore: true),
            for: initial)
        #expect(completedInitial)

        let nextRequest = state.beginNextPage(
            trigger: .scroll, requestID: nextID)
        let next = try #require(nextRequest)
        #expect(next.id == nextID)
        #expect(next.cursor == cursor)
        #expect(next.trigger == .scroll)
        #expect(state.isLoadingNextPage)
        #expect(!state.isLoadingInitial)
        let blocked = state.beginNextPage(
            trigger: .scroll, requestID: blockedID)
        #expect(blocked == nil)
        let failed = state.fail("database busy", for: next)
        #expect(failed)
        #expect(state.days.map(\.day) == ["2026-07-15"])
        #expect(state.nextCursor == cursor)
        #expect(state.hasMore)
        #expect(state.initialFailure == nil)
        #expect(state.paginationFailure == .query("database busy"))

        let retryRequest = state.beginNextPage(
            trigger: .retry, requestID: retryID)
        let retry = try #require(retryRequest)
        #expect(retry.id == retryID)
        #expect(retry.cursor == cursor)
        #expect(retry.trigger == .retry)
        #expect(state.paginationFailure == nil)
    }

    @Test("pagination appends only unseen IDs and keeps existing rows stable")
    func paginationDeduplicatesDays() throws {
        var state = HistoryPaginationState()
        let initial = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000021")!)
        let cursor = Date(timeIntervalSince1970: 1_000)
        let completedInitial = state.complete(
            HistoryPage(
                days: [
                    day("2026-07-15"),
                    day("2026-07-14", valueUSD: 14),
                ],
                nextCursor: cursor,
                hasMore: true),
            for: initial)
        #expect(completedInitial)
        let nextRequest = state.beginNextPage(
            trigger: .scroll,
            requestID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000022")!)
        let next = try #require(nextRequest)
        let olderCursor = Date(timeIntervalSince1970: 500)

        let completedNext = state.complete(
            HistoryPage(
                days: [
                    day("2026-07-14", valueUSD: 99),
                    day("2026-07-08"),
                ],
                nextCursor: olderCursor,
                hasMore: false),
            for: next)
        #expect(completedNext)

        #expect(state.days.map(\.day) == [
            "2026-07-15", "2026-07-14", "2026-07-08",
        ])
        #expect(state.days[1].valueUSD == 14)
        #expect(state.nextCursor == olderCursor)
        #expect(!state.hasMore)
        #expect(state.paginationFailure == nil)
        #expect(state.inFlightRequest == nil)
    }

    @Test("stale completion failure and cancellation leave current flight unchanged")
    func staleWorkIsRejected() {
        var state = HistoryPaginationState()
        let stale = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000031")!)
        let current = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000032")!)

        let completedStale = state.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: Date(timeIntervalSince1970: 1_000),
                hasMore: true),
            for: stale)
        #expect(!completedStale)
        let failedStale = state.fail("stale error", for: stale)
        #expect(!failedStale)
        state.cancel(stale)

        #expect(state.days.isEmpty)
        #expect(state.nextCursor == nil)
        #expect(!state.hasMore)
        #expect(state.initialFailure == nil)
        #expect(state.paginationFailure == nil)
        #expect(state.inFlightRequest == current)
        #expect(state.isLoadingInitial)
    }

    @Test("pagination rejects equal or newer cursors without changing loaded page")
    func paginationRequiresOlderCursor() throws {
        let requestCursor = Date(timeIntervalSince1970: 1_000)
        let invalidCursors = [
            requestCursor,
            Date(timeIntervalSince1970: 1_001),
        ]

        for (offset, invalidCursor) in invalidCursors.enumerated() {
            var state = HistoryPaginationState()
            let initial = state.reset(requestID: UUID(
                uuidString: "00000000-0000-0000-0000-00000000004\(offset + 1)")!)
            let completedInitial = state.complete(
                HistoryPage(
                    days: [day("2026-07-15")],
                    nextCursor: requestCursor,
                    hasMore: true),
                for: initial)
            #expect(completedInitial)
            let nextRequest = state.beginNextPage(
                trigger: .scroll,
                requestID: UUID(
                    uuidString: "00000000-0000-0000-0000-00000000005\(offset + 1)")!)
            let next = try #require(nextRequest)

            let completedInvalid = state.complete(
                HistoryPage(
                    days: [day("2026-07-08")],
                    nextCursor: invalidCursor,
                    hasMore: false),
                for: next)
            #expect(!completedInvalid)
            #expect(state.days.map(\.day) == ["2026-07-15"])
            #expect(state.nextCursor == requestCursor)
            #expect(state.hasMore)
            #expect(state.paginationFailure == .nonAdvancingCursor)
            #expect(state.inFlightRequest == nil)
        }
    }

    @Test("cancellation clears only the matching request")
    func cancellationMatchesRequest() throws {
        var state = HistoryPaginationState()
        let initial = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000061")!)
        let cursor = Date(timeIntervalSince1970: 1_000)
        let completedInitial = state.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: cursor,
                hasMore: true),
            for: initial)
        #expect(completedInitial)
        let currentRequest = state.beginNextPage(
            trigger: .scroll,
            requestID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000062")!)
        let current = try #require(currentRequest)
        let other = HistoryPaginationState.Request(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000063")!,
            trigger: .scroll,
            cursor: cursor)

        state.cancel(other)
        #expect(state.inFlightRequest == current)
        state.cancel(current)

        #expect(state.inFlightRequest == nil)
        #expect(state.days.map(\.day) == ["2026-07-15"])
        #expect(state.nextCursor == cursor)
        #expect(state.hasMore)
        #expect(state.initialFailure == nil)
        #expect(state.paginationFailure == nil)
    }

    @Test("initial and pagination errors stay in their own failure slots")
    func failuresAreScopedToLoadKind() throws {
        var initialState = HistoryPaginationState()
        let failedInitial = initialState.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000071")!)

        let initialFailed = initialState.fail("initial error", for: failedInitial)
        #expect(initialFailed)
        #expect(initialState.initialFailure == .query("initial error"))
        #expect(initialState.paginationFailure == nil)
        #expect(initialState.days.isEmpty)
        #expect(initialState.nextCursor == nil)
        #expect(initialState.inFlightRequest == nil)

        var paginationState = HistoryPaginationState()
        let initial = paginationState.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000072")!)
        let cursor = Date(timeIntervalSince1970: 1_000)
        let completedInitial = paginationState.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: cursor,
                hasMore: true),
            for: initial)
        #expect(completedInitial)
        let nextRequest = paginationState.beginNextPage(
            trigger: .scroll,
            requestID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000073")!)
        let next = try #require(nextRequest)

        let pageFailed = paginationState.fail("page error", for: next)
        #expect(pageFailed)
        #expect(paginationState.initialFailure == nil)
        #expect(paginationState.paginationFailure == .query("page error"))
        #expect(paginationState.days.map(\.day) == ["2026-07-15"])
        #expect(paginationState.nextCursor == cursor)
        #expect(paginationState.hasMore)
        #expect(paginationState.inFlightRequest == nil)
    }

    @Test("next page requires pagination trigger cursor and more history")
    func nextPageGuards() {
        var state = HistoryPaginationState()
        let blockedID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000081")!
        let missingCursor = state.beginNextPage(
            trigger: .scroll, requestID: blockedID)
        #expect(missingCursor == nil)

        let initial = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000082")!)
        let initialInFlight = state.beginNextPage(
            trigger: .scroll, requestID: blockedID)
        #expect(initialInFlight == nil)
        let completedInitial = state.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: Date(timeIntervalSince1970: 1_000),
                hasMore: true),
            for: initial)
        #expect(completedInitial)
        let invalidTrigger = state.beginNextPage(
            trigger: .initial, requestID: blockedID)
        #expect(invalidTrigger == nil)

        let terminal = state.reset(requestID: UUID(
            uuidString: "00000000-0000-0000-0000-000000000083")!)
        let completedTerminal = state.complete(
            HistoryPage(
                days: [day("2026-07-15")],
                nextCursor: Date(timeIntervalSince1970: 1_000),
                hasMore: false),
            for: terminal)
        #expect(completedTerminal)
        let noMore = state.beginNextPage(
            trigger: .retry, requestID: blockedID)
        #expect(noMore == nil)
    }
}
