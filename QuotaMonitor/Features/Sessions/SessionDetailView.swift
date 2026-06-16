import SwiftUI

struct SessionDetailView: View {
    @Environment(SettingsStore.self) private var settings
    let detail: SessionDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                breakdown
                if !detail.subagents.isEmpty {
                    Divider()
                    subagentsSection
                }
                Divider()
                timeline
            }
            .padding(20)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.header.title?.isEmpty == false ? detail.header.title! : L10n.untitledSession)
                .font(.title2.bold())
                .lineLimit(2)

            if let project = detail.header.projectName, !project.isEmpty {
                Label(project, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(detail.header.cwd ?? project)
            }

            HStack(spacing: 12) {
                if let agent = detail.header.agentNickname, !agent.isEmpty {
                    Label(agent, systemImage: "person.crop.circle")
                        .font(.callout)
                }
                if let model = detail.header.lastModelId, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                        .font(.callout)
                }
                if detail.header.hasInferredModel {
                    Label(L10n.inferredModel, systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(L10n.helpInferredModel)
                }
            }
            .foregroundStyle(.secondary)

            Text(detail.header.sessionId)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(spacing: 18) {
                stat(L10n.statValue,
                     detail.header.totalValueUSD.formatted(.currency(code: "USD")),
                     .green)
                stat(L10n.kpiTokens,
                     detail.header.totalTokens.formatted(.number.notation(.compactName).locale(settings.tokenFormatLocale)),
                     .blue)
                stat(L10n.kpiEvents, "\(detail.header.eventCount)", .orange)
                if let started = detail.header.startedAt {
                    stat(L10n.statStarted, shortDate(started), .secondary)
                }
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

    // MARK: - Model breakdown

    @ViewBuilder
    private var breakdown: some View {
        if detail.modelBreakdown.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.modelsInSession).font(.headline)
                ForEach(detail.modelBreakdown) { share in
                    HStack {
                        Text(share.displayName)
                            .font(.callout)
                        Spacer()
                        Text(share.valueUSD.formatted(.currency(code: "USD")))
                            .font(.callout.monospacedDigit())
                        Text("(\(share.eventCount))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if let only = detail.modelBreakdown.first {
            HStack {
                Label(only.displayName, systemImage: "cpu")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(only.valueUSD.formatted(.currency(code: "USD")))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Subagents

    private var subagentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.subagentsCount(detail.subagents.count), systemImage: "person.2.fill")
                .font(.headline)
                .foregroundStyle(.purple)
            ForEach(detail.subagents) { sub in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(sub.title?.isEmpty == false ? sub.title! : L10n.untitledSubagent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let nickname = sub.agentNickname, !nickname.isEmpty {
                        Text(nickname)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if let model = sub.lastModelId, !model.isEmpty {
                        Text(model).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L10n.evShort(sub.eventCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(sub.totalValueUSD.formatted(.currency(code: "USD")))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.purple.opacity(0.05))
                )
            }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.eventsTimelineCount(detail.events.count)).font(.headline)
            if detail.events.isEmpty {
                Text(L10n.noEventsForSession)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 4, pinnedViews: []) {
                    EventRowHeader()
                    Divider()
                    ForEach(detail.events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }

    private func shortDate(_ iso: String) -> String {
        guard let d = ISO8601.parse(iso) else { return iso }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Column header for the EventRow timeline. Shared by HistoryView's
/// expand-session block and SessionDetailView so column widths and
/// alignment stay synchronized — if EventRow changes a frame width,
/// this header must change in lockstep (and vice versa). Kept on
/// purpose as a separate view rather than baked into a Table because
/// `Table` doesn't compose cleanly inside the existing `LazyVStack`
/// scroll setup and would force a bigger restructure.
struct EventRowHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.eventColTime)
                .frame(width: 76, alignment: .leading)
            Text(L10n.eventColModel)
                .frame(width: 150, alignment: .leading)
            Spacer(minLength: 4)
            Text(L10n.eventColTokens)
                .frame(width: 72, alignment: .trailing)
            Text(L10n.eventColCost)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// One row in the "events on this day" / "events in this session"
/// timelines. Used by both `HistoryView`'s expandable-session-row
/// section and `SessionDetailView`'s timeline. Same row → same UX in
/// both places.
///
/// Visual design: keep the inline row at 4 columns (time / model /
/// total tokens / cost) so a session with hundreds of events scans
/// vertically without the input/cache/output/reasoning chip clutter
/// drowning out the headline numbers. The token breakdown moves into
/// a click-revealed popover anchored to the trailing edge.
///
/// `modelInferred` rows get an inline orange warning triangle next to
/// the model name and a paragraph in the popover footer so the user
/// knows the cost is approximate. Previously this flag existed in the
/// schema (`AggregatorHistory:174`) but had no UI representation —
/// users would silently see a $-figure that's a fallback estimate.
///
/// Hover triggers the popover, but with two debounce timers to avoid
/// the two failure modes:
///   - Scroll / pass-through hovering 908 rows: 200 ms show delay
///     swallows transient hovers — cursor has to linger to trigger.
///   - Cursor moves from row into popover content: 120 ms hide delay
///     gives the cursor time to land inside the popover, where its
///     own `.onHover` re-arms the show state and cancels the pending
///     dismissal. Without this, the popover closes the instant the
///     source row's hover flips false.
struct EventRow: View {
    @Environment(SettingsStore.self) private var settings
    let event: SessionDetail.Event

    @State private var showingDetails = false
    @State private var isHovering = false
    @State private var showTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestampShort)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            HStack(spacing: 4) {
                Text(event.modelId)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if event.modelInferred {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 150, alignment: .leading)

            Spacer(minLength: 4)

            // Headline total tokens — compact notation (33.4 万) so
            // wide totals stay narrow. Exact integer breakdown lives
            // in the popover.
            Text(event.totalTokens.formatted(
                .number.notation(.compactName).locale(settings.tokenFormatLocale)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.blue)
                .frame(width: 72, alignment: .trailing)

            Text(event.valueUSD.formatted(.currency(code: "USD")))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(isHovering || showingDetails ? 0.12 : 0.05))
        )
        .onHover { hovering in
            isHovering = hovering
            scheduleVisibility(showing: hovering)
        }
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            detailsPopover
                // Mirror hover state from inside the popover so moving
                // the cursor from the row into the popover content
                // doesn't trigger the dismiss timer. Without this the
                // dismiss-after-120ms fires regardless of where the
                // cursor goes.
                .onHover { hovering in
                    scheduleVisibility(showing: hovering)
                }
        }
    }

    /// Show after 200 ms of sustained hover; hide after 120 ms of no
    /// hover (from either the row or the popover content). Tasks are
    /// cancelled and re-issued on every hover transition so a quick
    /// row→popover handoff doesn't dismiss anything.
    private func scheduleVisibility(showing: Bool) {
        showTask?.cancel()
        hideTask?.cancel()
        if showing {
            if showingDetails { return }
            showTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled {
                    showingDetails = true
                }
            }
        } else {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled {
                    showingDetails = false
                }
            }
        }
    }

    /// Tokens the model actually re-read this turn (uncached input),
    /// computed consistently across both providers:
    ///   - Claude: stored `input_tokens` is already the uncached
    ///     remainder, so return as-is.
    ///   - Codex: stored `input_tokens` is OpenAI's `prompt_tokens`
    ///     (full prompt including the cached subset), so subtract
    ///     `cached_input_tokens` to leave just the new bytes.
    /// `max(0, ...)` defends against any historical row where the
    /// cached count drifted higher than input due to a parser bug —
    /// we'd rather show 0 than a negative.
    private var uncachedInputTokens: Int64 {
        switch event.provider {
        case "claude":
            return event.inputTokens
        default:
            return max(0, event.inputTokens - event.cachedInputTokens)
        }
    }

    /// Total token volume that touched cache this turn. For Codex
    /// this is just the read count (writes aren't surfaced). For
    /// Claude this is reads + 5m writes + 1h writes — all the input
    /// bytes that interacted with cache in any direction.
    private var cacheTokens: Int64 {
        event.cachedInputTokens
            + event.cacheCreation5mTokens
            + event.cacheCreation1hTokens
    }

    /// Cached share of total input this turn, in [0, 1]. Computed
    /// against the right denominator per provider so the number
    /// means the same thing in both columns of the History view.
    /// Returns nil when there were no input tokens at all (avoid
    /// rendering a "0% hit rate" for events that aren't really
    /// model calls).
    private var hitRate: Double? {
        let denominator: Int64
        switch event.provider {
        case "claude":
            denominator = event.inputTokens
                + event.cachedInputTokens
                + event.cacheCreation5mTokens
                + event.cacheCreation1hTokens
        default:
            denominator = event.inputTokens
        }
        guard denominator > 0 else { return nil }
        return Double(event.cachedInputTokens) / Double(denominator)
    }

    @ViewBuilder
    private var detailsPopover: some View {
        // Cache → Hit Rate → Input → Output → (Reasoning if > 0) → Total.
        // Cache + Hit Rate sit together at the top because they're the
        // two cache-related numbers users compare across events; Total
        // sits below the divider as the headline.
        VStack(alignment: .leading, spacing: 6) {
            breakdownRow(label: L10n.chipCache, value: cacheTokens)
            if let rate = hitRate {
                hitRateRow(rate)
            }
            breakdownRow(label: L10n.chipIn, value: uncachedInputTokens)
            breakdownRow(label: L10n.chipOut, value: event.outputTokens)
            if event.reasoningOutputTokens > 0 {
                breakdownRow(label: L10n.chipReason, value: event.reasoningOutputTokens)
            }
            Divider()
            breakdownRow(label: L10n.tokenTotalLabel,
                         value: event.totalTokens,
                         emphasized: true)
            if event.modelInferred {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L10n.eventInferredCostNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .padding(12)
        .frame(minWidth: 200)
    }

    private func breakdownRow(label: String, value: Int64, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer(minLength: 16)
            Text(value.formatted(.number))
                .font(.caption.monospacedDigit().weight(emphasized ? .semibold : .regular))
        }
    }

    private func hitRateRow(_ rate: Double) -> some View {
        HStack {
            Text(L10n.chipHitRate)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(rate.formatted(.percent.precision(.fractionLength(1))))
                .font(.caption.monospacedDigit())
                // Tint by quality so the eye can scan a list of events
                // for "this one didn't cache well" without reading the
                // number. 90%+ is healthy for a long-context chat;
                // < 40% means either a fresh session or wasted prefix.
                .foregroundStyle(rate >= 0.9 ? .green
                                 : rate >= 0.4 ? .secondary
                                 : .orange)
        }
    }

    private var timestampShort: String {
        guard let d = ISO8601.parse(event.timestamp) else { return event.timestamp }
        return d.formatted(.dateTime.hour().minute().second())
    }
}
