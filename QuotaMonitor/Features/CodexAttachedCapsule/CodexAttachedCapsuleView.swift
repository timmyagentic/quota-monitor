import SwiftUI

@Observable
@MainActor
final class CodexAttachedCapsuleViewModel {
    var presentation: CodexAttachedCapsulePresentation
    var isExpanded = false

    init(presentation: CodexAttachedCapsulePresentation) {
        self.presentation = presentation
    }
}

struct CodexAttachedCapsuleView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let model: CodexAttachedCapsuleViewModel
    let onHoverChange: @MainActor (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.isExpanded {
                detail
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            compact
        }
        .frame(
            width: model.isExpanded
                ? CodexAttachedCapsuleGeometry.expandedSize.width
                : CodexAttachedCapsuleGeometry.compactSize.width,
            height: model.isExpanded
                ? CodexAttachedCapsuleGeometry.expandedSize.height
                : CodexAttachedCapsuleGeometry.compactSize.height,
            alignment: .bottom)
        .background(materialBackground)
        .clipShape(containerShape)
        .overlay(containerShape.strokeBorder(borderColor, lineWidth: 0.75))
        .shadow(color: .black.opacity(reduceTransparency ? 0.12 : 0.22), radius: 12, y: 5)
        .contentShape(containerShape)
        .onHover { hovering in
            if reduceMotion {
                onHoverChange(hovering)
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    onHoverChange(hovering)
                }
            }
        }
        .environment(\.locale, loc.locale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var compact: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(L10n.codexCapsuleWeekly)
                .foregroundStyle(.secondary)
            Text(compactPercent)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.codexCapsuleTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(statusLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            if let remaining = model.presentation.remainingPercent,
               let used = model.presentation.usedPercent {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.codexCapsuleRemaining(remaining))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(L10n.codexCapsuleUsed(used))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(statusColor)
                            .frame(width: max(
                                4,
                                proxy.size.width * Double(remaining) / 100))
                    }
                }
                .frame(height: 6)

                if let resetAt = model.presentation.resetAt {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                        Text(L10n.codexCapsuleResets)
                        Text(resetAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.codexCapsuleUnavailableHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var materialBackground: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    private var containerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: model.isExpanded ? 14 : 15,
            style: .continuous)
    }

    private var borderColor: Color {
        Color.primary.opacity(reduceTransparency ? 0.22 : 0.13)
    }

    private var compactPercent: String {
        model.presentation.remainingPercent.map { "\($0)%" } ?? "--"
    }

    private var statusColor: Color {
        switch model.presentation.availability {
        case .fresh: .mint
        case .stale: .orange
        case .unavailable: .secondary
        }
    }

    private var statusLabel: String {
        switch model.presentation.availability {
        case .fresh: L10n.codexCapsuleLive
        case .stale: L10n.codexCapsuleStale
        case .unavailable: L10n.codexCapsuleUnavailable
        }
    }

    private var accessibilityLabel: String {
        guard let remaining = model.presentation.remainingPercent else {
            return "\(L10n.codexCapsuleTitle), \(L10n.codexCapsuleUnavailable)"
        }
        return "\(L10n.codexCapsuleTitle), \(L10n.codexCapsuleRemaining(remaining)), \(statusLabel)"
    }
}
