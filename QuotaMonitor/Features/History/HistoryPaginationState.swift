import Foundation

struct HistoryPaginationState {
    enum Failure: Equatable {
        case query(String)
        case nonAdvancingCursor
    }

    struct Request: Sendable, Equatable, Identifiable {
        let id: UUID
        let trigger: HistoryPageLoadTrigger
        let cursor: Date?
    }

    private(set) var days: [DaySummary] = []
    private(set) var nextCursor: Date?
    private(set) var hasMore = false
    private(set) var initialFailure: Failure?
    private(set) var paginationFailure: Failure?
    private(set) var inFlightRequest: Request?

    var isLoadingInitial: Bool { inFlightRequest?.trigger == .initial }
    var isLoadingNextPage: Bool {
        guard let trigger = inFlightRequest?.trigger else { return false }
        return trigger == .scroll || trigger == .retry
    }

    @discardableResult
    mutating func reset(requestID: UUID = UUID()) -> Request {
        let request = Request(id: requestID, trigger: .initial, cursor: nil)
        days = []
        nextCursor = nil
        hasMore = false
        initialFailure = nil
        paginationFailure = nil
        inFlightRequest = request
        return request
    }

    mutating func beginNextPage(
        trigger: HistoryPageLoadTrigger,
        requestID: UUID = UUID()
    ) -> Request? {
        guard trigger != .initial,
              inFlightRequest == nil,
              hasMore,
              let nextCursor else { return nil }
        paginationFailure = nil
        let request = Request(
            id: requestID,
            trigger: trigger,
            cursor: nextCursor)
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
