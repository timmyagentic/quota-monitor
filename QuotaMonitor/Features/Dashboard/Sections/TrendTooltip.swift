import SwiftUI

struct TrendTooltip: View {
    @Environment(LocalizationStore.self) private var localization
    let selection: TrendSelection
    let tokenLocale: Locale
    var contentWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedDateFormatting.string(
                from: selection.date,
                style: .monthDay))
                .font(.caption.weight(.semibold))
            Text(compactTokens(selection.totalTokens))
                .font(.callout.monospacedDigit().weight(.semibold))
            ForEach(selection.rows.prefix(6)) { row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.color)
                        .frame(width: 8, height: 8)
                    Text(row.label)
                        .lineLimit(1)
                    TrendSpeedBadge(tier: row.speedTier, color: row.color)
                    Spacer(minLength: 12)
                    Text(compactTokens(row.tokens))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if selection.rows.count > 6 {
                HStack {
                    Text(L10n.trendOtherEntries(selection.rows.count - 6))
                    Spacer(minLength: 12)
                    Text(compactTokens(selection.rows.dropFirst(6).reduce(0) { $0 + $1.tokens }))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(DashboardTheme.cache)
                    .frame(width: 7, height: 7)
                Text(L10n.cacheHitRateTitle)
                Spacer(minLength: 12)
                Text(formatCacheHitRate(selection.cacheUsage.hitRate))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
        )
        .allowsHitTesting(false)
    }

    private func compactTokens(_ tokens: Int64) -> String {
        tokens.formatted(.number.notation(.compactName)
            .precision(.fractionLength(0...1)).locale(tokenLocale))
    }

    private func formatCacheHitRate(_ rate: Double?) -> String {
        rate?.formatted(.percent.precision(.fractionLength(1))) ?? "—"
    }
}

struct TrendSpeedBadge: View {
    let tier: TrendSpeedTier?
    let color: Color

    var body: some View {
        if let tier {
            Text(tier.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.14), in: Capsule())
                .fixedSize()
        }
    }
}

/// Keep the selected column and its pointer corridor clear, including at
/// either plot edge. Narrow plots shrink the tip instead of covering it.
struct TrendTooltipPlacement {
    let origin: CGPoint
    let contentWidth: CGFloat
    let totalWidth: CGFloat

    init(plotFrame: CGRect, selectedX: CGFloat, selectedHalfWidth: CGFloat = 0) {
        let inset: CGFloat = 6
        let gap: CGFloat = 24 + selectedHalfWidth
        let horizontalPadding: CGFloat = 18
        let x = min(max(selectedX, plotFrame.minX), plotFrame.maxX)
        let leftSpace = max(0, x - gap - plotFrame.minX - inset)
        let rightSpace = max(0, plotFrame.maxX - inset - x - gap)
        let useLeft = leftSpace >= rightSpace
        totalWidth = min(298, max(leftSpace, rightSpace))
        contentWidth = max(0, totalWidth - horizontalPadding)
        origin = CGPoint(x: useLeft ? x - gap - totalWidth : x + gap,
                         y: plotFrame.minY + inset)
    }
}

struct TrendTooltipOverlay: View {
    let selection: TrendSelection
    let tokenLocale: Locale
    let localization: LocalizationStore
    let plotFrame: CGRect
    let selectedX: CGFloat
    var selectedHalfWidth: CGFloat = 0

    var body: some View {
        let placement = TrendTooltipPlacement(plotFrame: plotFrame, selectedX: selectedX,
                                              selectedHalfWidth: selectedHalfWidth)
        TrendTooltip(selection: selection, tokenLocale: tokenLocale,
                     contentWidth: placement.contentWidth)
            .environment(localization)
            .fixedSize()
            .offset(x: placement.origin.x, y: placement.origin.y)
            .allowsHitTesting(false)
    }
}
