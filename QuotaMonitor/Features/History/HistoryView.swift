import Combine
import SwiftUI

// Day-by-day call history. Sidebar lists every local-calendar day that had
// any usage_event; selecting one shows per-model breakdown plus the sessions
// that ran that day, with each session expandable into its event timeline.

struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var pagination = HistoryPaginationState()
    @State private var selection: DaySummary.ID?
    @State private var detail: DayDetail?
    @State private var loadingDetail = false
    @State private var detailErrorMessage: String?
    @State private var historyCalendar = Calendar.current
    @State private var calendarRevision = 0
    @State private var detailRequestID: UUID?

    var body: some View {
        let pageRequest = pagination.inFlightRequest
        let selectedDay = selection
        let selectedCalendar = historyCalendar

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detailPane
        }
        // Allow click-and-drag selection on day labels, USD figures,
        // model names — handy for pasting a number elsewhere.
        .textSelection(.enabled)
        .task(id: calendarRevision) {
            historyCalendar = Calendar.current
            selection = nil
            detail = nil
            detailErrorMessage = nil
            detailRequestID = nil
            loadingDetail = false
            pagination.reset()
        }
        .task(id: pageRequest?.id) {
            guard let request = pageRequest else { return }
            do {
                try Task.checkCancellation()
                let page = try await env.fetchHistoryPage(
                    before: request.cursor,
                    now: Date(),
                    calendar: selectedCalendar,
                    trigger: request.trigger)
                try Task.checkCancellation()
                guard pagination.complete(page, for: request) else { return }
                if request.trigger == .initial {
                    let selectedStillExists = selection.map { selectedID in
                        pagination.days.contains { $0.id == selectedID }
                    } ?? false
                    if !selectedStillExists {
                        selection = pagination.days.first?.id
                    }
                }
            } catch is CancellationError {
                pagination.cancel(request)
            } catch {
                pagination.fail(String(describing: error), for: request)
            }
        }
        .task(id: selectedDay) {
            await loadDetail(for: selectedDay, calendar: selectedCalendar)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSSystemTimeZoneDidChange)) { _ in
                calendarRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                calendarRevision &+= 1
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.daysHeader).font(.headline)
                Spacer()
                Text("\(pagination.days.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if pagination.isLoadingInitial && pagination.days.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = initialErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pagination.days.isEmpty && !pagination.hasMore {
                Text(L10n.noUsageHistory)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if pagination.days.isEmpty {
                        Text(L10n.historyNoUsageLatestSevenDays)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(pagination.days) { day in
                        DayRowView(day: day).tag(day.id)
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
        return L10n.historyLoadOlderFailed
    }

    private var paginationFooter: some View {
        HStack(spacing: 8) {
            if pagination.isLoadingNextPage {
                ProgressView().controlSize(.small)
                Text(L10n.historyLoadingOlder)
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
            HistoryPaginationScrollBridge(
                isEnabled: pagination.hasMore && pagination.paginationFailure == nil,
                isLoading: pagination.isLoadingNextPage,
                canFillViewport: pagination.canFillViewport,
                onViewportFill: {
                    _ = pagination.beginNextPage(trigger: .viewportFill)
                },
                onLoadMore: {
                    _ = pagination.beginNextPage(trigger: .scroll)
                })
        )
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if loadingDetail {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            DayDetailView(detail: detail, calendar: historyCalendar)
        } else if let detailErrorMessage {
            Text(detailErrorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func loadDetail(
        for id: DaySummary.ID?,
        calendar: Calendar
    ) async {
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
            let loaded = try await env.fetchDayDetail(
                day: id,
                calendar: calendar)
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
    let calendar: Calendar

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
        let cacheHitRate = detail.cacheUsage.hitRate
        let cacheHitRateText = cacheHitRate?.formatted(
            .percent.precision(.fractionLength(1))) ?? "—"

        return VStack(alignment: .leading, spacing: 6) {
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
                stat(L10n.cacheHitRateTitle, cacheHitRateText, .teal)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.cacheHitRateTitle)
                    .accessibilityValue(
                        cacheHitRate == nil
                            ? L10n.cacheHitRateUnavailable
                            : cacheHitRateText)
                stat(L10n.kpiSessions, "\(detail.summary.sessionCount)", .orange)
                stat(L10n.kpiEvents, "\(detail.summary.eventCount)", .purple)
            }
            .padding(.top, 4)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                        ExpandableSessionRow(
                            day: detail.summary.day,
                            session: session,
                            calendar: calendar)
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
    let calendar: Calendar

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
                        Text(session.displayTitle)
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
                sessionId: session.sessionId,
                day: day,
                calendar: calendar)
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
