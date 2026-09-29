import SwiftUI

/// Compact 5h billing block widget — Anthropic-only, clearly labelled to
/// avoid being confused with Codex CLI's own "5-hour" quota row above.
/// Replaces the standalone `AnthropicBlockMini` rounded card (pre-Day-23).
struct Claude5hRow: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var localization
    let block: BillingBlocks.Block
    let burn: BillingBlocks.BurnRate?
    let projection: BillingBlocks.Projection?

    var body: some View {
        let elapsed = max(0, Date().timeIntervalSince(block.startTime))
        let pct = block.isActive
            ? min(1, elapsed / BillingBlocks.sessionDuration)
            : 1

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: block.isActive ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(block.isActive ? .green : .secondary)
                Text(L10n.fiveHBlockState(active: block.isActive))
                    .font(.caption.weight(.medium))
                Spacer()
                Text(L10n.cycleTimeProgress(String(format: "%.0f%%", pct * 100), estimated: true))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(progressTint(pct))
            }
            ProgressView(value: pct).tint(progressTint(pct))
            HStack(spacing: 4) {
                Text(block.costUSD.formatted(.currency(code: "USD")))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
                if let projection {
                    Text("→ \(projection.totalCost.formatted(.currency(code: "USD")))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(paceAccent(projection))
                    Text(L10n.minutesLeft(formatMinutes(projection.remainingMinutes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let burn {
                    Text(L10n.burnPerHour(burn.costPerHour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(block.tokenCounts.total.formatted(
                    .number.notation(.compactName).locale(settings.tokenFormatLocale)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func progressTint(_ pct: Double) -> Color {
        switch pct {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    private func paceAccent(_ p: BillingBlocks.Projection) -> Color {
        let ratio = block.costUSD > 0
            ? p.totalCost / max(block.costUSD, 0.0001)
            : 1
        switch ratio {
        case ..<1.5: return .green
        case ..<3:   return .orange
        default:     return .red
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }
}
