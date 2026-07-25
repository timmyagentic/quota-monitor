import Foundation
import Testing
@testable import QuotaMonitor

@Suite("History view wiring")
struct HistoryViewWiringTests {
    @Test("Daily cache hit rate sits in summary above model usage")
    func dailyCacheHitRatePlacement() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift")
        let dayDetail = Self.normalized(try Self.sourceSlice(
            source,
            from: "private struct DayDetailView: View",
            to: "// MARK: - Expandable per-session row"))
        let header = Self.normalized(try Self.sourceSlice(
            source,
            from: "private var header: some View",
            to: "private func stat"))

        #expect(dayDetail.contains(
            "header Divider() breakdown Divider() sessionsSection"))
        #expect(!dayDetail.contains("cacheHitRateSection"))
        #expect(header.contains("L10n.cacheHitRateTitle"))
        #expect(header.contains("detail.cacheUsage.hitRate"))
    }

    @Test("History requests are reducer-driven cancellable page tasks")
    func requestsAreReducerDrivenPageTasks() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift")
        let body = try Self.sourceSlice(
            source,
            from: "var body: some View",
            to: "// MARK: - Sidebar")
        let normalizedBody = Self.normalized(body)
        let tasks = try Self.rootTaskSlices(in: body)
        let pageTask = Self.normalized(tasks[1])

        #expect(normalizedBody.contains("let pageRequest = pagination.inFlightRequest"))
        #expect(pageTask.contains(".task(id: pageRequest?.id)"))
        #expect(pageTask.contains("guard let request = pageRequest else { return }"))
        #expect(pageTask.contains("pageSize: request.pageSize"))
        #expect(pageTask.contains("calendar: selectedCalendar"))
        #expect(!pageTask.contains("pagination.inFlightRequest"))
        #expect(!pageTask.contains("calendar: historyCalendar"))

        let cancellationChecks = Self.ranges(
            of: "try Task.checkCancellation()", in: pageTask)
        let fetch = try #require(pageTask.range(
            of: "let page = try await env.fetchHistoryPage"))
        let completion = try #require(pageTask.range(
            of: "pagination.complete(page, for: request)"))
        #expect(cancellationChecks.count == 2)
        if cancellationChecks.count == 2 {
            #expect(cancellationChecks[0].lowerBound < fetch.lowerBound)
            #expect(fetch.lowerBound < cancellationChecks[1].lowerBound)
            #expect(cancellationChecks[1].lowerBound < completion.lowerBound)
        }
        #expect(pageTask.contains("if request.trigger == .initial"))
    }

    @Test("History detail task uses one render snapshot and checks cancellation first")
    func detailTaskUsesRenderSnapshot() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift")
        let body = try Self.sourceSlice(
            source,
            from: "var body: some View",
            to: "// MARK: - Sidebar")
        let normalizedBody = Self.normalized(body)
        let tasks = try Self.rootTaskSlices(in: body)
        let detailTask = Self.normalized(tasks[2])
        let loadDetail = Self.normalized(try Self.sourceSlice(
            source,
            from: "private func loadDetail(",
            to: "// MARK: - Sidebar row"))

        #expect(normalizedBody.contains("let selectedDay = selection"))
        #expect(normalizedBody.contains("let selectedCalendar = historyCalendar"))
        #expect(detailTask.contains(".task(id: selectedDay)"))
        #expect(detailTask.contains(
            "await loadDetail(for: selectedDay, calendar: selectedCalendar)"))
        #expect(!detailTask.contains("for: selection"))
        #expect(!detailTask.contains("calendar: historyCalendar"))

        let cancellation = try #require(loadDetail.range(
            of: "guard !Task.isCancelled else { return }"))
        let requestToken = try #require(loadDetail.range(
            of: "let requestID = UUID()"))
        #expect(cancellation.lowerBound < requestToken.lowerBound)
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
        #expect(footer.contains("canFillViewport: pagination.canFillViewport"))
        #expect(footer.contains(
            "pagination.beginNextPage(trigger: .viewportFill)"))
        #expect(footer.contains("pagination.beginNextPage(trigger: .scroll)"))
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
        #expect(source.contains("calendar: selectedCalendar, trigger: request.trigger"))
        #expect(source.contains("loadDetail(for: selectedDay, calendar: selectedCalendar)"))
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

    @Test("Cancelled ordinary detail failures cannot publish state")
    func cancelledOrdinaryDetailFailureCannotPublishState() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/History/HistoryView.swift")
        let loadDetail = try Self.sourceSlice(
            source,
            from: "private func loadDetail(",
            to: "// MARK: - Sidebar row")
        let catchStart = try #require(loadDetail.range(
            of: "} catch {")?.lowerBound)
        let ordinaryCatch = Self.normalized(String(loadDetail[catchStart...]))

        let cancellation = try #require(ordinaryCatch.range(
            of: "guard !Task.isCancelled else { return }"))
        let requestIdentity = try #require(ordinaryCatch.range(
            of: "guard detailRequestID == requestID else { return }"))
        #expect(cancellation.lowerBound < requestIdentity.lowerBound)

        let stateWrites = [
            "detail = nil",
            "detailErrorMessage = String(describing: error)",
            "loadingDetail = false",
            "detailRequestID = nil"
        ]
        for stateWrite in stateWrites {
            let mutation = try #require(ordinaryCatch.range(of: stateWrite))
            #expect(requestIdentity.lowerBound < mutation.lowerBound)
        }
    }

    @Test("History query facade exposes separate database and data-ready timings")
    func queryFacadeExposesSeparatePageTimings() throws {
        let rawSource = try Self.source(
            named: "QuotaMonitor/App/QueryFacade.swift")
        let source = Self.normalized(rawSource)
        let historyPage = Self.normalized(try Self.sourceSlice(
            rawSource,
            from: "func fetchHistoryPage(",
            to: "func fetchDayDetail("))

        #expect(source.contains("func fetchHistoryPage("))
        #expect(source.contains("\"query.days.page\""))
        #expect(source.contains("\"query.days.page.database.start\""))
        #expect(source.contains("\"query.days.page.database.finish\""))
        #expect(source.contains("\"query.days.page.database.fail\""))
        #expect(source.contains("Aggregator.fetchHistoryPage("))
        #expect(source.contains("func fetchDayDetail(day: String, calendar: Calendar)"))
        #expect(source.contains("func fetchSessionEventsOnDay(sessionId: String, day: String, calendar: Calendar"))
        #expect(!source.contains("query.days." + "list"))
        #expect(!source.contains("fetchDays" + "List"))

        let databaseCompleted = try #require(historyPage.range(
            of: "databaseFinishedAt: ContinuousClock.now"))
        let databaseFinishLog = try #require(historyPage.range(
            of: "DeveloperLog.eventRecord(\"query.days.page.database.finish\""))
        let facadeFinishLog = try #require(historyPage.range(
            of: "DeveloperLog.finishOperation(op"))
        #expect(databaseCompleted.lowerBound < databaseFinishLog.lowerBound)
        #expect(databaseFinishLog.lowerBound < facadeFinishLog.lowerBound)
        #expect(!historyPage.contains("databaseStartedAt.duration(to: .now)"))
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

    private static func rootTaskSlices(in body: String) throws -> [String] {
        let starts = ranges(of: ".task(id:", in: body).map(\.lowerBound)
        #expect(starts.count == 3)
        guard starts.count == 3,
              let end = body.range(of: ".onReceive(")?.lowerBound else {
            throw CocoaError(.formatting)
        }
        let boundaries = starts + [end]
        return (0..<3).map { index in
            String(body[boundaries[index]..<boundaries[index + 1]])
        }
    }

    private static func ranges(
        of needle: String,
        in source: String
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(
                  of: needle,
                  range: searchStart..<source.endIndex) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    private static func normalized(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }
}
