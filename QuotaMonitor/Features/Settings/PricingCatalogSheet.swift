import SwiftUI

/// Read-only pricing catalog viewer, presented as a sheet from
/// Advanced → Pricing → View Catalog. Replaces the old top-level
/// Pricing tab (removed in commit 15b7e65) so users can still
/// inspect the per-model rates without opening the sqlite file by
/// hand. Sync / Restore actions stay in the parent Advanced tab —
/// this sheet is strictly viewing.
struct PricingCatalogSheet: View {
    let rows: [PricingCatalogRow]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(rows) {
                TableColumn(L10n.colModel) { row in
                    HStack(spacing: 6) {
                        sourceBadge(row.priceSource)
                        Text(row.displayName)
                        if !row.isOfficial && row.priceSource == "local" {
                            Image(systemName: "pencil.circle.fill")
                                .foregroundStyle(.orange)
                                .help(row.note ?? L10n.helpLocallyEdited)
                        }
                    }
                }
                TableColumn(L10n.colInputPerM) { row in
                    Text(row.inputPrice.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                }
                TableColumn(L10n.colCachedPerM) { row in
                    Text(row.cachedInputPrice.formatted(.number.precision(.fractionLength(3))))
                        .monospacedDigit()
                }
                TableColumn(L10n.colOutputPerM) { row in
                    Text(row.outputPrice.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                }
                TableColumn(L10n.colCacheCreatePerM) { row in
                    if row.cacheCreationPrice > 0 {
                        Text(row.cacheCreationPrice.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.pricingSheetTitle)
                    .font(.headline)
                Text(L10n.pricingSheetUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.done) { onDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func sourceBadge(_ source: String) -> some View {
        let (label, color): (String, Color) = {
            switch source {
            case "litellm": return (L10n.badgeLive,  .green)
            case "local":   return (L10n.badgeLocal, .orange)
            default:        return (L10n.badgeSeed,  .gray)
            }
        }()
        Text(label)
            .font(.caption2.weight(.medium).monospaced())
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.15))
            )
    }
}
