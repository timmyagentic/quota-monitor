import SwiftUI

enum DashboardTheme {
    static let codex = Color(red: 0.29, green: 0.66, blue: 0.72)
    static let claude = Color(red: 0.80, green: 0.48, blue: 0.35)
    static let accentBlue = Color(red: 0.55, green: 0.78, blue: 0.95)
    static let cache = Color(red: 0.55, green: 0.49, blue: 0.96)
    static let warning = Color(red: 0.94, green: 0.42, blue: 0.48)

    static func providerColor(_ provider: String) -> Color {
        switch provider.lowercased() {
        case "codex": return codex
        case "claude": return claude
        default: return accentBlue
        }
    }

    static func providerLabel(_ provider: String) -> String {
        switch provider.lowercased() {
        case "codex": return L10n.codex
        case "claude": return L10n.claude
        default: return provider
        }
    }

    static func modelColor(_ model: String) -> Color {
        let lower = model.lowercased()
        if lower == TrendSeriesBuilder.otherKey {
            return Color.secondary.opacity(0.62)
        }
        let bucket = lower.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let hue = Double((bucket & Int.max) % 360) / 360.0
        return Color(hue: hue, saturation: 0.58, brightness: 0.78)
    }
}

struct DashboardPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.82)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            )
    }
}

extension View {
    func dashboardPanel(
        cornerRadius: CGFloat = 10,
        padding: CGFloat = 14
    ) -> some View {
        modifier(DashboardPanelModifier(cornerRadius: cornerRadius, padding: padding))
    }
}
