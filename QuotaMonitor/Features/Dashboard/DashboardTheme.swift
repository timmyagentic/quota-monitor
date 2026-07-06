import SwiftUI

enum DashboardTheme {
    static let codex = Color(red: 0.29, green: 0.66, blue: 0.72)
    static let claude = Color(red: 0.80, green: 0.48, blue: 0.35)
    static let accentBlue = Color(red: 0.55, green: 0.78, blue: 0.95)
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
        if lower.contains("claude") || lower.contains("opus") || lower.contains("sonnet") {
            return claude
        }
        if lower.contains("gpt") || lower.contains("codex") || lower.hasPrefix("o1")
            || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            return codex
        }
        let palette = [
            accentBlue,
            Color(red: 0.62, green: 0.50, blue: 0.88),
            Color(red: 0.86, green: 0.74, blue: 0.34),
            Color(red: 0.35, green: 0.70, blue: 0.56),
            warning
        ]
        let bucket = lower.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[(bucket & Int.max) % palette.count]
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
