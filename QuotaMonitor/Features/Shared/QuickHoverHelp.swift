import SwiftUI

/// Small app-owned hover help for icon-only controls where macOS' native
/// `.help(...)` delay feels too slow. The 200 ms show delay matches the
/// existing event-row hover popover pattern: quick enough to explain an icon,
/// slow enough to ignore pass-through cursor movement.
struct QuickHoverHelpTiming: Equatable, Sendable {
    let showDelayMilliseconds: Int
    let hideDelayMilliseconds: Int

    static let toolbar = QuickHoverHelpTiming(
        showDelayMilliseconds: 200,
        hideDelayMilliseconds: 120)
}

private struct QuickHoverHelp: ViewModifier {
    let text: String
    let timing: QuickHoverHelpTiming

    @State private var showing = false
    @State private var showTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .accessibilityHint(Text(text))
            .onHover { hovering in
                schedule(showing: hovering)
            }
            .popover(isPresented: $showing, arrowEdge: Edge.bottom) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 260, alignment: .leading)
            }
    }

    private func schedule(showing shouldShow: Bool) {
        showTask?.cancel()
        hideTask?.cancel()

        if shouldShow {
            if showing { return }
            showTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(timing.showDelayMilliseconds))
                if !Task.isCancelled {
                    showing = true
                }
            }
        } else {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(timing.hideDelayMilliseconds))
                if !Task.isCancelled {
                    showing = false
                }
            }
        }
    }
}

extension View {
    func quickHoverHelp(
        _ text: String,
        timing: QuickHoverHelpTiming = .toolbar
    ) -> some View {
        modifier(QuickHoverHelp(text: text, timing: timing))
    }
}
