import SwiftUI

struct SessionsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var rows: [SessionRow] = []
    @State private var search: String = ""
    @State private var sort: SessionSort = .recent
    @State private var selection: SessionRow.ID?
    @State private var detail: SessionDetail?
    @State private var loadingList = false
    @State private var loadingDetail = false
    @State private var errorMessage: String?

    var body: some View {
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
        .task { await reloadList() }
        .onChange(of: search) { _, _ in
            Task { await reloadList(debounceMs: 200) }
        }
        .onChange(of: sort) { _, _ in
            Task { await reloadList() }
        }
        .onChange(of: selection) { _, newValue in
            Task { await loadDetail(for: newValue) }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if loadingList && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding()
            } else if rows.isEmpty {
                Text(L10n.noMatchingSessions)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows, selection: $selection) { row in
                    SessionRowView(row: row).tag(row.id)
                }
                .listStyle(.inset)
            }
        }
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

    private func reloadList(debounceMs: UInt64 = 0) async {
        if debounceMs > 0 {
            try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
        }
        let snapshotSearch = search
        let snapshotSort = sort
        loadingList = true
        defer { loadingList = false }
        do {
            let result = try await env.fetchSessionsList(
                sort: snapshotSort, search: snapshotSearch)
            // Drop stale results if user kept typing.
            if snapshotSearch == search && snapshotSort == sort {
                rows = result
                if let sel = selection, !rows.contains(where: { $0.id == sel }) {
                    selection = nil
                    detail = nil
                }
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func loadDetail(for id: SessionRow.ID?) async {
        guard let id else { detail = nil; return }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            detail = try await env.fetchSessionDetail(sessionId: id)
        } catch {
            errorMessage = String(describing: error)
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
