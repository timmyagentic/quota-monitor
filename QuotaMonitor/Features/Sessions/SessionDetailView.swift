import SwiftUI

struct SessionDetailView: View {
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
                     detail.header.totalTokens.formatted(.number.notation(.compactName)),
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
                LazyVStack(spacing: 4) {
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

struct EventRow: View {
    let event: SessionDetail.Event

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestampShort)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            Text(event.modelId)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Spacer(minLength: 4)

            tokenChip(L10n.chipIn, event.inputTokens, .blue)
            tokenChip(L10n.chipCache, event.cachedInputTokens, .teal)
            tokenChip(L10n.chipOut, event.outputTokens, .purple)
            if event.reasoningOutputTokens > 0 {
                tokenChip(L10n.chipReason, event.reasoningOutputTokens, .pink)
            }

            Text(event.valueUSD.formatted(.currency(code: "USD")))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private var timestampShort: String {
        guard let d = ISO8601.parse(event.timestamp) else { return event.timestamp }
        return d.formatted(.dateTime.hour().minute().second())
    }

    private func tokenChip(_ label: String, _ count: Int64, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(count.formatted(.number.notation(.compactName)))
                .foregroundStyle(color)
        }
        .font(.caption2.monospacedDigit())
    }
}
