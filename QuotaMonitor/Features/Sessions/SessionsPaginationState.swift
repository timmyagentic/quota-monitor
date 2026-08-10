import Foundation

struct SessionsPaginationState {
    static let pageSize = 50

    struct Query: Sendable, Equatable {
        let sort: SessionSort
        let search: String
    }

    enum Failure: Equatable {
        case query(String)
    }

    struct Request: Sendable, Equatable, Identifiable {
        let id: UUID
        let trigger: SessionPageLoadTrigger
        let query: Query
        let cursor: SessionPageCursor?
        let pageSize: Int
    }

    private(set) var rows: [SessionRow] = []
    private(set) var nextCursor: SessionPageCursor?
    private(set) var initialFailure: Failure?
    private(set) var paginationFailure: Failure?
    private(set) var inFlightRequest: Request?
    private(set) var currentQuery: Query?

    var hasMore: Bool { nextCursor != nil }
    var loadedCount: Int { rows.count }
    var isLoadingInitial: Bool { inFlightRequest?.trigger == .initial }
    var isLoadingNextPage: Bool {
        guard let trigger = inFlightRequest?.trigger else { return false }
        return trigger != .initial
    }

    @discardableResult
    mutating func reset(
        query: Query,
        requestID: UUID = UUID()
    ) -> Request {
        let request = Request(
            id: requestID,
            trigger: .initial,
            query: query,
            cursor: nil,
            pageSize: Self.pageSize)
        rows = []
        nextCursor = nil
        initialFailure = nil
        paginationFailure = nil
        currentQuery = query
        inFlightRequest = request
        return request
    }

    mutating func beginNextPage(
        trigger: SessionPageLoadTrigger,
        requestID: UUID = UUID()
    ) -> Request? {
        guard trigger != .initial,
              inFlightRequest == nil,
              paginationFailure == nil || trigger == .retry,
              hasMore,
              let currentQuery else { return nil }
        if trigger == .retry {
            paginationFailure = nil
        }
        let request = Request(
            id: requestID,
            trigger: trigger,
            query: currentQuery,
            cursor: nextCursor,
            pageSize: Self.pageSize)
        inFlightRequest = request
        return request
    }

    @discardableResult
    mutating func complete(_ page: SessionPage, for request: Request) -> Bool {
        guard inFlightRequest == request, currentQuery == request.query else {
            return false
        }
        if request.trigger == .initial {
            rows = page.rows
        } else {
            let loadedIDs = Set(rows.map(\.sessionId))
            rows.append(contentsOf: page.rows.filter {
                !loadedIDs.contains($0.sessionId)
            })
        }
        nextCursor = page.nextCursor
        if request.trigger == .initial {
            initialFailure = nil
        } else {
            paginationFailure = nil
        }
        inFlightRequest = nil
        return true
    }

    @discardableResult
    mutating func fail(_ message: String, for request: Request) -> Bool {
        guard inFlightRequest == request, currentQuery == request.query else {
            return false
        }
        inFlightRequest = nil
        if request.trigger == .initial {
            initialFailure = .query(message)
        } else {
            paginationFailure = .query(message)
        }
        return true
    }

    mutating func cancel(_ request: Request) {
        guard inFlightRequest == request else { return }
        inFlightRequest = nil
    }
}
