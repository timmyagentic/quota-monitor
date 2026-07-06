import SwiftUI

/// Composition panel: where the last-30-day usage went. Mirrors Token
/// Monitor's overview breakdown with two compact horizontal lists:
/// by model and by tool/provider.
struct CompositionSection: View {
    @Environment(SettingsStore.self) private var settings

    let modelShares30d: [ModelShare]
    let modelSharesPrior30d: [ModelShare]
    let providerShares30d: [ProviderShare]
    let showProviderBreakdown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.compositionSectionTitle)
                    .font(.headline)
                Spacer()
            }

            if modelRows.isEmpty && providerRows.isEmpty {
                Text(L10n.compositionNoSpend)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if showProviderBreakdown {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 36) {
                        BreakdownBarColumn(title: L10n.compositionTopModels, rows: modelRows)
                        BreakdownBarColumn(title: L10n.compositionByProvider, rows: providerRows)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        BreakdownBarColumn(title: L10n.compositionTopModels, rows: modelRows)
                        BreakdownBarColumn(title: L10n.compositionByProvider, rows: providerRows)
                    }
                }
            } else {
                BreakdownBarColumn(title: L10n.compositionTopModels, rows: modelRows)
            }

            if let insight = insightText {
                Text(insight)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashboardPanel(cornerRadius: 12, padding: 14)
    }

    private var modelRows: [BreakdownBarRow] {
        let total = max(modelShares30d.reduce(Int64(0)) { $0 + $1.tokens }, 1)
        let maxTokens = max(modelShares30d.map(\.tokens).max() ?? 0, 1)
        return modelShares30d.prefix(5).map { share in
            let pct = Double(share.tokens) / Double(total)
            return BreakdownBarRow(
                id: share.modelId,
                label: share.displayName,
                color: DashboardTheme.modelColor(share.modelId),
                value: compactTokens(share.tokens),
                percent: pct,
                fractionOfMax: Double(share.tokens) / Double(maxTokens))
        }
    }

    private var providerRows: [BreakdownBarRow] {
        let visible = providerShares30d
            .filter { $0.tokens > 0 || $0.valueUSD > 0 }
            .sorted { $0.tokens > $1.tokens }
        let total = max(visible.reduce(Int64(0)) { $0 + $1.tokens }, 1)
        let maxTokens = max(visible.map(\.tokens).max() ?? 0, 1)
        return visible.map { share in
            let pct = Double(share.tokens) / Double(total)
            return BreakdownBarRow(
                id: share.provider,
                label: DashboardTheme.providerLabel(share.provider),
                color: DashboardTheme.providerColor(share.provider),
                value: compactTokens(share.tokens),
                percent: pct,
                fractionOfMax: Double(share.tokens) / Double(maxTokens))
        }
    }

    private func compactTokens(_ tokens: Int64) -> String {
        tokens.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(settings.tokenFormatLocale))
    }

    /// Auto-insight sentence — uses the dominant model's pp-delta vs the
    /// prior 30 days when available, otherwise falls back to the static
    /// share-of-spend phrasing.
    private var insightText: String? {
        guard total30d > 0, let top = modelShares30d.first, top.valueUSD > 0
        else { return nil }
        let pct = top.valueUSD / total30d * 100
        let prior = modelSharesPrior30d.first { $0.modelId == top.modelId }
        let priorTotal = modelSharesPrior30d.reduce(0) { $0 + $1.valueUSD }
        if let prior, priorTotal > 0 {
            let priorPct = prior.valueUSD / priorTotal * 100
            let pp = pct - priorPct
            return L10n.compositionInsightWithDelta(
                model: top.displayName, percent: pct, pp: pp)
        }
        return L10n.compositionInsightFlat(model: top.displayName, percent: pct)
    }

    private var total30d: Double {
        modelShares30d.reduce(0) { $0 + $1.valueUSD }
    }
}

private struct BreakdownBarRow: Identifiable {
    let id: String
    let label: String
    let color: Color
    let value: String
    let percent: Double
    let fractionOfMax: Double
}

private struct BreakdownBarColumn: View {
    let title: String
    let rows: [BreakdownBarRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(rows) { row in
                    BreakdownBarRowView(row: row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BreakdownBarRowView: View {
    let row: BreakdownBarRow

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(row.color)
                    .frame(width: 10, height: 10)
                Text(row.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 128, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(row.color)
                        .frame(width: max(2, proxy.size.width * row.fractionOfMax))
                }
            }
            .frame(height: 4)

            Text(row.value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(row.percent.formatted(
                .percent
                    .precision(.fractionLength(1))
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
        }
    }
}
