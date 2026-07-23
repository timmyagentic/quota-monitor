import SwiftUI

struct SessionsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var pagination = SessionsPaginationState()
    @State private var search: String = ""
    @State private var sort: SessionSort = .recent
    @State private var selection: SessionRow.ID?
    @State private var detail: SessionDetail?
    @State private var loadingDetail = false
    @State private var detailErrorMessage: String?
    @State private var detailRequestID: UUID?

    var body: some View {
        let query = SessionsPaginationState.Query(sort: sort, search: search)
        let pageRequest = pagination.inFlightRequest
        let selectedSession = selection

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            detailPane
        }
        // Make session ids, model names and numbers copyable across both
        // panes. List-row selection still works — `.textSelection` only
        // affects standalone Text views, not Lists or Buttons.
        .textSelection(.enabled)
        .task(id: query) {
            if let request = pagination.inFlightRequest,
               request.query != query {
                pagination.cancel(request)
            }
            let shouldDebounce = pagination.currentQuery.map {
                $0.search != query.search
            } ?? false
            if shouldDebounce {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            // Search and sort reset the list prefix, but keep the inspected
            // session open. List filtering should not dismiss useful detail.
            pagination.reset(query: query)
        }
        .task(id: pageRequest?.id) {
            guard let request = pageRequest else { return }
            do {
                try Task.checkCancellation()
                let page = try await env.fetchSessionsPage(
                    sort: request.query.sort,
                    search: request.query.search,
                    limit: request.limit,
                    trigger: request.trigger)
                try Task.checkCancellation()
                let desiredQuery = SessionsPaginationState.Query(
                    sort: sort,
                    search: search)
                guard request.query == desiredQuery else {
                    pagination.cancel(request)
                    return
                }
                guard pagination.complete(page, for: request) else { return }
            } catch is CancellationError {
                pagination.cancel(request)
            } catch {
                let desiredQuery = SessionsPaginationState.Query(
                    sort: sort,
                    search: search)
                guard request.query == desiredQuery else {
                    pagination.cancel(request)
                    return
                }
                pagination.fail(String(describing: error), for: request)
            }
        }
        .task(id: selectedSession) {
            await loadDetail(for: selectedSession)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if pagination.isLoadingInitial && pagination.rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = initialErrorMessage {
                Text(message).font(.caption).foregroundStyle(.red).padding()
            } else if pagination.rows.isEmpty {
                Text(L10n.noMatchingSessions)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(pagination.rows) { row in
                        SessionRowView(row: row).tag(row.id)
                    }
                    if pagination.hasMore {
                        paginationFooter
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var initialErrorMessage: String? {
        guard let failure = pagination.initialFailure,
              case .query(let message) = failure else { return nil }
        return message
    }

    private var paginationErrorMessage: String? {
        guard pagination.paginationFailure != nil else { return nil }
        return L10n.sessionsLoadMoreFailed
    }

    private var paginationFooter: some View {
        HStack(spacing: 8) {
            if pagination.isLoadingNextPage {
                ProgressView().controlSize(.small)
                Text(L10n.sessionsLoadingMore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let message = paginationErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button(L10n.retry) {
                    _ = pagination.beginNextPage(trigger: .retry)
                }
                .controlSize(.small)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1)
        .listRowSeparator(.hidden)
        .background(
            PaginationScrollBridge(
                isEnabled: pagination.hasMore && pagination.paginationFailure == nil,
                isLoading: pagination.isLoadingNextPage,
                canFillViewport: false,
                onViewportFill: {},
                onLoadMore: {
                    _ = pagination.beginNextPage(trigger: .scroll)
                })
        )
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.searchSessionsPlaceholder, text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )

            Picker(L10n.sortBy, selection: $sort) {
                ForEach(SessionSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(10)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if loadingDetail {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            SessionDetailView(detail: detail)
        } else if let detailErrorMessage {
            Text(detailErrorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L10n.selectSessionToInspect)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading

    private func loadDetail(for id: SessionRow.ID?) async {
        guard !Task.isCancelled else { return }
        guard let id else {
            detailRequestID = nil
            loadingDetail = false
            detail = nil
            detailErrorMessage = nil
            return
        }
        let requestID = UUID()
        detailRequestID = requestID
        loadingDetail = true
        do {
            let loaded = try await env.fetchSessionDetail(sessionId: id)
            try Task.checkCancellation()
            guard detailRequestID == requestID else { return }
            detail = loaded
            detailErrorMessage = nil
            loadingDetail = false
            detailRequestID = nil
        } catch is CancellationError {
            guard detailRequestID == requestID else { return }
            loadingDetail = false
            detailRequestID = nil
        } catch {
            guard !Task.isCancelled else { return }
            guard detailRequestID == requestID else { return }
            detail = nil
            detailErrorMessage = String(describing: error)
            loadingDetail = false
            detailRequestID = nil
        }
    }
}

private struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(row.totalValueUSD.formatted(.currency(code: "USD"))
                     + (row.hasInferredModel ? "*" : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
                    .help(row.hasInferredModel
                        ? L10n.helpCostApproxInferred
                        : "")
            }
            SessionRowMetadataView(row: row, showsUpdatedRelativeTime: true)
        }
        .padding(.vertical, 3)
    }
}
