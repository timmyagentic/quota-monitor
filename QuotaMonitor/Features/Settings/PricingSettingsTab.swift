import SwiftUI

/// Pricing tab — read-only catalog viewer.
///
/// Earlier versions exposed an inline editor (pick a row → edit
/// input/cached/output → Save) so users could fix prices LiteLLM didn't
/// have. In practice nobody used it: the failure mode for "wrong price"
/// is always "everything is way off" not "this one model is off by
/// $0.50", and the LiteLLM Sync button + Restore Defaults already cover
/// both. The editor was 80 lines of state for ~zero clicks. Removed.
///
/// Kept here:
///   - LiteLLM "Sync" header (the one button users actually click)
///   - Read-only price table with Live/Local/Seed source badges
///   - "Restore Defaults" escape hatch for when LiteLLM goes weird
struct PricingSettingsTab: View {
    @Environment(AppEnvironment.self) private var env

    @State private var rows: [PricingCatalogRow] = []
    @State private var refreshing = false
    @State private var restoring = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            litellmHeader

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
            .frame(minHeight: 240)

            HStack {
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L10n.pricingRestoreDefaults) {
                    Task { await restore() }
                }
                .disabled(restoring || refreshing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .task {
            if !loaded {
                loaded = true
                await reload()
            }
        }
    }

    private var litellmHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.livePricesViaLiteLLM)
                    .font(.subheadline.weight(.medium))
                Text(lastRefreshedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if refreshing { ProgressView().controlSize(.small) }
            Button(L10n.pricingFetchLiteLLM) {
                Task { await refreshFromLiteLLM() }
            }
            .disabled(restoring || refreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    private var lastRefreshedLabel: String {
        let latest = rows.compactMap { $0.fetchedAt }.max()
        guard let latest, let date = ISO8601.parse(latest) else {
            return L10n.neverRefreshed
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.unitsStyle = .short
        return L10n.lastRefreshed(formatter.localizedString(for: date, relativeTo: Date()))
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

    private func reload() async {
        do {
            rows = try await env.loadPricingCatalog()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        do {
            try await env.restorePricingDefaults()
            await reload()
            errorMessage = nil
            statusMessage = L10n.restoredSeedPrices
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func refreshFromLiteLLM() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let updated = try await env.refreshPricingFromLiteLLM()
            await reload()
            errorMessage = nil
            statusMessage = updated == 0
                ? L10n.litellmNoMatch
                : L10n.litellmUpdated(updated)
        } catch {
            errorMessage = L10n.litellmRefreshFailed(error.localizedDescription)
        }
    }
}
