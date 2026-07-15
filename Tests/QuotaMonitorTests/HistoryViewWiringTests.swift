import Foundation
import Testing
@testable import QuotaMonitor

@Suite("History view wiring")
struct HistoryViewWiringTests {
    @Test("History requests are reducer-driven cancellable page tasks")
    func requestsAreReducerDrivenPageTasks() throws {
        let source = Self.normalized(try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift"))

        #expect(source.contains("@State private var pagination = HistoryPaginationState()"))
        #expect(source.contains(".task(id: pagination.inFlightRequest?.id)"))
        #expect(source.contains("guard let request = pagination.inFlightRequest else { return }"))
        #expect(source.contains("pagination.complete(page, for: request)"))
        #expect(source.contains("if request.trigger == .initial"))
    }

    @Test("History footer keeps one stable scroll bridge row")
    func footerKeepsStableScrollBridgeRow() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift")
        let footer = Self.normalized(try Self.sourceSlice(
            source,
            from: "private var paginationFooter: some View",
            to: "// MARK: - Detail pane"))

        #expect(footer.contains("HistoryPaginationScrollBridge("))
        #expect(footer.contains("isEnabled: pagination.hasMore && pagination.paginationFailure == nil"))
        #expect(footer.contains("isLoading: pagination.isLoadingNextPage"))
        #expect(!footer.contains(".onAppear"))
        #expect(!footer.contains(".task"))
    }

    @Test("History captures and propagates one calendar snapshot")
    func capturesAndPropagatesCalendarSnapshot() throws {
        let source = Self.normalized(try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift"))

        #expect(source.contains("@State private var historyCalendar = Calendar.current"))
        #expect(source.contains("Notification.Name.NSSystemTimeZoneDidChange"))
        #expect(source.contains("NSLocale.currentLocaleDidChangeNotification"))
        #expect(source.contains("calendar: historyCalendar, trigger: request.trigger"))
        #expect(source.contains("loadDetail(for: selection, calendar: historyCalendar)"))
        #expect(source.contains("fetchDayDetail(day: id, calendar: calendar)"))
        #expect(source.contains("DayDetailView(detail: detail, calendar: historyCalendar)"))
        #expect(source.contains("ExpandableSessionRow(day: detail.summary.day, session: session, calendar: calendar)"))
        #expect(source.contains("sessionId: session.sessionId, day: day, calendar: calendar"))
    }

    @Test("History detail publication is guarded by request identity")
    func detailPublicationIsGuardedByRequestIdentity() throws {
        let source = Self.normalized(try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift"))

        #expect(source.contains("@State private var detailRequestID"))
        #expect(source.contains("guard detailRequestID == requestID else { return }"))
        #expect(source.contains("detailRequestID = nil"))
    }

    @Test("History query facade exposes only logged page reads")
    func queryFacadeExposesOnlyLoggedPageReads() throws {
        let source = Self.normalized(try Self.source(
            named: "QuotaMonitor/App/QueryFacade.swift"))

        #expect(source.contains("func fetchHistoryPage("))
        #expect(source.contains("\"query.days.page\""))
        #expect(source.contains("Aggregator.fetchHistoryPage("))
        #expect(source.contains("func fetchDayDetail(day: String, calendar: Calendar)"))
        #expect(source.contains("func fetchSessionEventsOnDay(sessionId: String, day: String, calendar: Calendar"))
        #expect(!source.contains("query.days." + "list"))
        #expect(!source.contains("fetchDays" + "List"))
    }

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func sourceSlice(
        _ source: String,
        from startSignature: String,
        to endSignature: String
    ) throws -> String {
        let start = try #require(source.range(of: startSignature)?.lowerBound)
        let rest = source[start...]
        let end = try #require(rest.range(of: endSignature)?.lowerBound)
        return String(rest[..<end])
    }

    private static func normalized(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }
}
