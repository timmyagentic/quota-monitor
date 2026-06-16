import SwiftUI

// Day-by-day call history. Sidebar lists every local-calendar day that had
// any usage_event; selecting one shows per-model breakdown plus the sessions
// that ran that day, with each session expandable into its event timeline.

struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var days: [DaySummary] = []
    @State private var selection: DaySummary.ID?
    @State private var detail: DayDetail?
    @State private var loadingList = false
    @State private var loadingDetail = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detailPane
        }
        // Allow click-and-drag selection on day labels, USD figures,
        // model names — handy for pasting a number elsewhere.
        .textSelection(.enabled)
        .task { await reloadList() }
        .onChange(of: selection) { _, newValue in
            Task { await loadDetail(for: newValue) }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.daysHeader).font(.headline)
                Spacer()
                Text("\(days.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if loadingList && days.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding()
            } else if days.isEmpty {
                Text(L10n.noUsageHistory)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(days, selection: $selection) { day in
                    DayRowView(day: day).tag(day.id)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if loadingDetail {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            DayDetailView(detail: detail)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L10n.selectDayPrompt)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading

    private func reloadList() async {
        loadingList = true
        defer { loadingList = false }
        do {
            let result = try await env.fetchDaysList()
            days = result
            // Auto-select the most recent day on first load.
            if selection == nil, let first = result.first {
                selection = first.id
            } else if let sel = selection,
                      !result.contains(where: { $0.id == sel }) {
                selection = result.first?.id
                detail = nil
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func loadDetail(for id: DaySummary.ID?) async {
        guard let id else { detail = nil; return }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            detail = try await env.fetchDayDetail(day: id)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

// MARK: - Sidebar row

private struct DayRowView: View {
    @Environment(SettingsStore.self) private var settings
    let day: DaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.date.formatted(.dateTime.weekday(.short).month(.abbreviated).day()))
                    .font(.body.weight(.medium))
                Spacer()
                Text(day.valueUSD.formatted(.currency(code: "USD")))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            HStack(spacing: 10) {
                Label(day.tokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)),
                      systemImage: "number")
                Label("\(day.sessionCount)", systemImage: "list.bullet.rectangle")
                Label("\(day.eventCount)", systemImage: "circle.dotted")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail view

private struct DayDetailView: View {
    @Environment(SettingsStore.self) private var settings
    let detail: DayDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                breakdown
                Divider()
                sessionsSection
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.summary.date.formatted(
                .dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.title2.bold())

            HStack(spacing: 14) {
                stat(L10n.statValue,
                     detail.summary.valueUSD.formatted(.currency(code: "USD")),
                     .green)
                stat(L10n.kpiTokens,
                     detail.summary.tokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)),
                     .blue)
                stat(L10n.kpiSessions, "\(detail.summary.sessionCount)", .orange)
                stat(L10n.kpiEvents, "\(detail.summary.eventCount)", .purple)
            }
            .padding(.top, 4)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var breakdown: some View {
        let total = max(detail.modelBreakdown.map(\.valueUSD).reduce(0, +), 0.0001)
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.modelsUsedToday).font(.headline)
            ForEach(detail.modelBreakdown) { share in
                let pct = share.valueUSD / total
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(share.displayName).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(share.valueUSD.formatted(.currency(code: "USD")))
                            .font(.callout.monospacedDigit())
                        Text(String(format: "%.0f%%", pct * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    ProgressView(value: pct).tint(.accentColor)
                    HStack(spacing: 12) {
                        Label(share.tokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)),
                              systemImage: "number")
                        Label(L10n.eventsCount(share.eventCount), systemImage: "list.bullet")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.05))
                )
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.sessionsOnDay(detail.sessions.count))
                .font(.headline)
            if detail.sessions.isEmpty {
                Text(L10n.noSessions).font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(detail.sessions) { session in
                        ExpandableSessionRow(day: detail.summary.day, session: session)
                    }
                }
            }
        }
    }
}

// MARK: - Expandable per-session row

private struct ExpandableSessionRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    let day: String
    let session: SessionRow

    @State private var expanded = false
    @State private var events: [SessionDetail.Event] = []
    @State private var loadingEvents = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title?.isEmpty == false ? session.title! : L10n.untitledSession)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            SessionRowMetadataView(row: session)
                            if let started = session.startedAt {
                                Text(timeRange(started: started, ended: session.updatedAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    Text(session.totalValueUSD.formatted(.currency(code: "USD")))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.green)
                    Text(session.totalTokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                        .frame(width: 60, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if loadingEvents {
                    ProgressView().padding(.vertical, 6)
                } else if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else if events.isEmpty {
                    Text(L10n.noEvents).font(.caption).foregroundStyle(.secondary)
                } else {
                    // LazyVStack — sessions can have thousands of events
                    // (xhs-workspace day with 908 events was the report).
                    // A plain VStack here forces SwiftUI to materialize
                    // every EventRow + its ~5 token-chip subviews on the
                    // main thread the instant the user clicks the
                    // chevron, freezing the app for seconds. The outer
                    // DayDetailView already wraps the whole sessions
                    // section in a ScrollView (line 152) + LazyVStack
                    // (line 235), so this row inherits the same
                    // virtualization environment and renders only what's
                    // visible.
                    LazyVStack(spacing: 4) {
                        EventRowHeader()
                        Divider()
                        ForEach(events) { event in
                            EventRow(event: event)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 4)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func toggle() {
        expanded.toggle()
        if expanded && events.isEmpty {
            Task { await loadEvents() }
        }
    }

    private func loadEvents() async {
        loadingEvents = true
        defer { loadingEvents = false }
        do {
            events = try await env.fetchSessionEventsOnDay(
                sessionId: session.sessionId, day: day)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func timeRange(started: String, ended: String?) -> String {
        let s = ISO8601.parse(started)
        let e = ended.flatMap { ISO8601.parse($0) }
        guard let s else { return "" }
        let sStr = s.formatted(.dateTime.hour().minute())
        if let e, e.timeIntervalSince(s) > 60 {
            return "\(sStr) – \(e.formatted(.dateTime.hour().minute()))"
        }
        return sStr
    }
}
