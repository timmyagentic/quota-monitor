import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Sessions view wiring")
struct SessionsViewWiringTests {
    @Test("Sessions pages are request-driven and keep query snapshots")
    func pagesUseRequestSnapshots() throws {
        let rawSource = try Self.source(
            named: "QuotaMonitor/Features/Sessions/SessionsView.swift")
        let source = Self.normalized(rawSource)
        let queryTask = Self.normalized(try Self.sourceSlice(
            rawSource,
            from: ".task(id: query)",
            to: ".task(id: pageRequest?.id)"))
        let pageTask = Self.normalized(try Self.sourceSlice(
            rawSource,
            from: ".task(id: pageRequest?.id)",
            to: ".task(id: selectedSession)"))

        #expect(source.contains("let query = SessionsPaginationState.Query(sort: sort, search: search)"))
        #expect(source.contains("let pageRequest = pagination.inFlightRequest"))
        #expect(source.contains(".task(id: query)"))
        #expect(source.contains("pagination.reset(query: query)"))
        #expect(source.contains(".task(id: pageRequest?.id)"))
        #expect(source.contains("guard let request = pageRequest else { return }"))
        #expect(source.contains("sort: request.query.sort"))
        #expect(source.contains("search: request.query.search"))
        #expect(source.contains("limit: request.limit"))
        #expect(source.contains("trigger: request.trigger"))
        #expect(source.contains("pagination.complete(page, for: request)"))
        #expect(source.contains("pagination.cancel(request)"))

        let invalidate = try #require(queryTask.range(
            of: "pagination.cancel(request)"))
        let debounce = try #require(queryTask.range(
            of: "Task.sleep(for: .milliseconds(200))"))
        #expect(invalidate.lowerBound < debounce.lowerBound)
        #expect(!source.contains("pendingSearchReload"))

        let cancellationChecks = Self.ranges(
            of: "try Task.checkCancellation()",
            in: pageTask)
        let fetch = try #require(pageTask.range(
            of: "let page = try await env.fetchSessionsPage"))
        let desiredQuery = try #require(pageTask.range(
            of: "let desiredQuery = SessionsPaginationState.Query"))
        let completion = try #require(pageTask.range(
            of: "pagination.complete(page, for: request)"))
        #expect(cancellationChecks.count == 2)
        if cancellationChecks.count == 2 {
            #expect(cancellationChecks[0].lowerBound < fetch.lowerBound)
            #expect(fetch.lowerBound < cancellationChecks[1].lowerBound)
            #expect(cancellationChecks[1].lowerBound < desiredQuery.lowerBound)
        }
        #expect(desiredQuery.lowerBound < completion.lowerBound)
        #expect(!queryTask.contains("selection = nil"))
        #expect(!pageTask.contains("selection = nil"))

        let ordinaryCatchStart = try #require(pageTask.range(
            of: "} catch {")?.lowerBound)
        let ordinaryCatch = String(pageTask[ordinaryCatchStart...])
        let staleGuard = try #require(ordinaryCatch.range(
            of: "guard request.query == desiredQuery else"))
        let failure = try #require(ordinaryCatch.range(
            of: "pagination.fail(String(describing: error), for: request)"))
        #expect(staleGuard.lowerBound < failure.lowerBound)
    }

    @Test("Sessions footer loads only from the shared gesture bridge")
    func footerUsesGestureBridge() throws {
        let rawSource = try Self.source(
            named: "QuotaMonitor/Features/Sessions/SessionsView.swift")
        let footer = Self.normalized(try Self.sourceSlice(
            rawSource,
            from: "private var paginationFooter: some View",
            to: "private var controls: some View"))

        #expect(footer.contains("PaginationScrollBridge("))
        #expect(footer.contains("isEnabled: pagination.hasMore && pagination.paginationFailure == nil"))
        #expect(footer.contains("isLoading: pagination.isLoadingNextPage"))
        #expect(footer.contains("canFillViewport: false"))
        #expect(footer.contains("pagination.beginNextPage(trigger: .scroll)"))
        #expect(footer.contains("pagination.beginNextPage(trigger: .retry)"))
        #expect(!footer.contains(".onAppear"))
        #expect(!footer.contains(".task"))
    }

    @Test("Sessions query facade fetches bounded pages")
    func queryFacadeFetchesPages() throws {
        let source = Self.normalized(try Self.source(
            named: "QuotaMonitor/App/QueryFacade.swift"))

        #expect(source.contains("func fetchSessionsPage("))
        #expect(source.contains("trigger: SessionPageLoadTrigger"))
        #expect(source.contains("\"query.sessions.page\""))
        #expect(source.contains("Aggregator.fetchSessionsPage("))
        #expect(source.contains("\"has_more\": .bool(page.hasMore)"))
        #expect(!source.contains("query.sessions." + "list"))
        #expect(!source.contains("fetchSessions" + "List"))
    }

    @Test("Session detail publication is request-identity guarded")
    func detailUsesRequestIdentity() throws {
        let rawSource = try Self.source(
            named: "QuotaMonitor/Features/Sessions/SessionsView.swift")
        let source = Self.normalized(rawSource)
        let loadDetail = Self.normalized(try Self.sourceSlice(
            rawSource,
            from: "private func loadDetail(",
            to: "\n}\n\nprivate struct SessionRowView"))

        #expect(source.contains("@State private var detailRequestID: UUID?"))
        #expect(source.contains(".task(id: selectedSession)"))
        #expect(loadDetail.contains("guard detailRequestID == requestID else { return }"))
        #expect(loadDetail.contains("guard !Task.isCancelled else { return }"))

        let ordinaryCatchStart = try #require(loadDetail.range(
            of: "} catch {")?.lowerBound)
        let ordinaryCatch = String(loadDetail[ordinaryCatchStart...])
        let cancellation = try #require(ordinaryCatch.range(
            of: "guard !Task.isCancelled else { return }"))
        let identity = try #require(ordinaryCatch.range(
            of: "guard detailRequestID == requestID else { return }"))
        #expect(cancellation.lowerBound < identity.lowerBound)
        for mutation in [
            "detail = nil",
            "detailErrorMessage = String(describing: error)",
            "loadingDetail = false",
            "detailRequestID = nil",
        ] {
            let stateWrite = try #require(ordinaryCatch.range(of: mutation))
            #expect(identity.lowerBound < stateWrite.lowerBound)
        }
    }

    @Test("Provider and reload changes remount Sessions pagination")
    func providerChangesRemountPagination() throws {
        let source = Self.normalized(try Self.source(
            named: "QuotaMonitor/Features/MainWindow/MainWindowView.swift"))

        #expect(source.contains(
            ".id(\"\\(env.providerFilter.rawValue)-\\(reloadToken)\")"))
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
}
