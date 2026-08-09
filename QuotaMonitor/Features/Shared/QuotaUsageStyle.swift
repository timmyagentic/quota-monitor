import SwiftUI

enum QuotaUsageStyle {
    static func tintColor(forUsedPercent usedPercent: Double) -> Color {
        switch usedPercent {
        case ..<60: .green
        case ..<85: .orange
        default: .red
        }
    }
}

struct QuotaUsageProgressBar: View {
    let value: Double
    let usedPercent: Double
    let accessibilityText: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.10))
                Capsule()
                    .fill(QuotaUsageStyle.tintColor(
                        forUsedPercent: usedPercent))
                    .frame(width: geometry.size.width * clampedValue)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityText))
    }

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }
}
