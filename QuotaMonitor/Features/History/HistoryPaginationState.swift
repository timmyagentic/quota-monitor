import Foundation

struct HistoryPaginationState {
    static let initialPageSize = 21
    static let incrementalPageSize = 7
    static let maximumViewportFillPageCount = 3

    enum Failure: Equatable {
        case query(String)
        case nonAdvancingCursor
    }

    struct Request: Sendable, Equatable, Identifiable {
        let id: UUID
        let trigger: HistoryPageLoadTrigger
        let cursor: Date?
        let pageSize: Int
    }

    private(set) var days: [DaySummary] = []
    private(set) var nextCursor: Date?
    private(set) var hasMore = false
    private(set) var initialFailure: Failure?
    private(set) var paginationFailure: Failure?
    private(set) var inFlightRequest: Request?
    private(set) var viewportFillPageCount = 0

    var isLoadingInitial: Bool { inFlightRequest?.trigger == .initial }
    var isLoadingNextPage: Bool {
        guard let trigger = inFlightRequest?.trigger else { return false }
        return trigger != .initial
    }
    var canFillViewport: Bool {
        inFlightRequest == nil &&
            hasMore &&
            nextCursor != nil &&
            paginationFailure == nil &&
            viewportFillPageCount < Self.maximumViewportFillPageCount
    }

    @discardableResult
    mutating func reset(requestID: UUID = UUID()) -> Request {
        let request = Request(
            id: requestID,
            trigger: .initial,
            cursor: nil,
            pageSize: Self.initialPageSize)
        days = []
        nextCursor = nil
        hasMore = false
        initialFailure = nil
        paginationFailure = nil
        inFlightRequest = request
        viewportFillPageCount = 0
        return request
    }

    mutating func beginNextPage(
        trigger: HistoryPageLoadTrigger,
        requestID: UUID = UUID()
    ) -> Request? {
        guard trigger != .initial else { return nil }
        if trigger == .viewportFill {
            guard canFillViewport else { return nil }
        }
        guard
              inFlightRequest == nil,
              hasMore,
              let nextCursor else { return nil }
        paginationFailure = nil
        let request = Request(
            id: requestID,
            trigger: trigger,
            cursor: nextCursor,
            pageSize: Self.incrementalPageSize)
        inFlightRequest = request
        return request
    }

    @discardableResult
    mutating func complete(_ page: HistoryPage, for request: Request) -> Bool {
        guard inFlightRequest == request else { return false }
        if let requestedCursor = request.cursor,
           page.nextCursor >= requestedCursor {
            inFlightRequest = nil
            paginationFailure = .nonAdvancingCursor
            return false
        }
        if request.trigger == .initial {
            days = page.days
            initialFailure = nil
        } else {
            var seen = Set(days.map(\.id))
            days.append(contentsOf: page.days.filter {
                seen.insert($0.id).inserted
            })
            paginationFailure = nil
            if request.trigger == .viewportFill {
                viewportFillPageCount += 1
            }
        }
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        inFlightRequest = nil
        return true
    }

    @discardableResult
    mutating func fail(_ message: String, for request: Request) -> Bool {
        guard inFlightRequest == request else { return false }
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
