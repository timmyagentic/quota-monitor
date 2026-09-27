import AppKit
import SwiftUI
import Observation

/// An opt-in native gallery of the unmodified shipping SwiftUI views. Synthetic data and
/// controls stay in the existing isolated QA environment; no Codex interaction.
@MainActor @Observable
final class LocalQAOverlayPreview {
    let window: NSWindow
    fileprivate let environment: AppEnvironment
    fileprivate let settings: SettingsStore
    let state = CodexQuotaOverlayViewState()
    var narrow = false
    var dark = false
    var scenario = "Weekly"

    var sidebarWidth: CGFloat { narrow ? 320 : 438 }
    var header: CodexSidebarHeaderAnchor {
        .init(leadingInset: 152, trailingXInset: sidebarWidth - 70, centerYInset: 62)
    }

    init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment
        self.settings = settings
        window = NSWindow(contentRect: CGRect(x: 200, y: 160, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "QuotaMonitor · Native widget QA"
        window.identifier = NSUserInterfaceItemIdentifier("codex-overlay-qa-host")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LocalQAOverlayPreviewView(preview: self))
        window.appearance = NSAppearance(named: .aqua)
        settings.codexSidebarQuotaPosition = nil
        settings.quotaDisplayMode = .remaining
        select("Weekly")
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func select(_ scenario: String) {
        self.scenario = scenario
        state.isExpanded = true
        let now = Date()
        environment.latestRateLimits = scenario == "Unavailable" ? nil : RateLimitSnapshot(
            capturedAt: now.addingTimeInterval(scenario == "Stale" ? -1200 : 0), planType: "pro",
            primary: scenario == "Dual" ? .init(usedPercent: 42, windowDuration: 18000,
                resetAt: now.addingTimeInterval(7200)) : nil,
            secondary: .init(usedPercent: 8, windowDuration: 604800, resetAt: now.addingTimeInterval(345600)),
            additional: [], resetCreditsAvailable: nil)
        environment.latestCodexResetCredits = nil
        updateLayout()
    }

    func toggleWidth() { narrow.toggle(); updateLayout() }
    func toggleMode() { settings.quotaDisplayMode = settings.quotaDisplayMode == .used ? .remaining : .used; updateLayout() }
    private func updateLayout() {
        let presentation = CodexQuotaOverlayPresentation.make(snapshot: environment.latestRateLimits,
            displayMode: settings.quotaDisplayMode)
        let placement = CodexQuotaOverlayLayout.summaryPlacement(in: window.frame,
            presentation: presentation, header: header)
        state.width = placement?.frame.width ?? 0
        state.compact = placement?.compact ?? false
    }

    func toggleAppearance() {
        dark.toggle()
        // Appearance changes belong only to this isolated QA process.
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = NSApp.appearance
    }
}

private struct LocalQAOverlayPreviewView: View {
    let preview: LocalQAOverlayPreview

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                VStack(spacing: 28) {
                    Image(systemName: "house.fill").padding(.top, 25)
                    Image(systemName: "clock")
                    Image(systemName: "books.vertical")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .frame(width: 48)
                .background(.primary.opacity(0.03))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(verbatim: "Codex").font(.system(size: 18, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "bell").padding(.trailing, 14)
                        Image(systemName: "magnifyingglass")
                    }
                    .frame(height: 80).padding(.horizontal, 22)
                    Label("New chat", systemImage: "square.and.pencil").padding(22)
                    Text(verbatim: "Pinned").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 14)
                    Label("quota-monitor", systemImage: "folder").padding(.horizontal, 22)
                    Text(verbatim: "额度挂件设计")
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12).padding(.top, 14)
                    Spacer()
                }
                .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
                .frame(width: preview.sidebarWidth - 48)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                VStack(alignment: .leading, spacing: 20) {
                    Spacer()
                    Text(verbatim: "原生额度挂件").font(.system(size: 28, weight: .semibold))
                    Text(verbatim: "点击挂件查看详情\n用下方按钮检查不同状态")
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(8)
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "QA · 合成数据 / 实际 SwiftUI 组件")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            ForEach(["Weekly", "Dual", "Stale", "Unavailable"], id: \.self) { scenario in
                                Button(scenario) { preview.select(scenario) }
                            }
                        }
                        HStack {
                            Button("Compact") { preview.toggleWidth() }
                            Button("Used / Remaining") { preview.toggleMode() }
                            Button("Light / Dark") { preview.toggleAppearance() }
                            Button("EN / 中文") {
                                let locale = LocalizationStore.shared
                                locale.set(locale.currentLanguage == .english ? .simplifiedChinese : .english)
                            }
                        }
                    }
                }
                .padding(44).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onTapGesture { preview.state.isExpanded = false }

            if preview.state.width > 0 {
                CodexQuotaOverlayView(state: preview.state,
                    onResetPosition: {}, onActivate: { preview.state.isExpanded.toggle() },
                    onPressBegan: {}, onDragBegan: {}, onDragChanged: {}, onDragEnded: {})
                    .offset(x: preview.header.leadingInset, y: 26)
                if preview.state.isExpanded {
                    let presentation = CodexQuotaOverlayPresentation.make(snapshot: preview.environment.latestRateLimits,
                        displayMode: preview.settings.quotaDisplayMode)
                    CodexQuotaOverlayDetailsView(onRefresh: { preview.select("Weekly") },
                        onOpenDashboard: { WindowManager.shared.show("dashboard") })
                        .frame(width: CodexQuotaOverlayLayout.detailsWidth,
                            height: CodexQuotaOverlayLayout.detailsContentHeight(presentation: presentation, resetCredits: nil))
                        .offset(x: preview.header.leadingInset, y: 60)
                }
            }
        }
        .environment(preview.environment)
        .environment(preview.settings)
        .environment(LocalizationStore.shared)
        .onExitCommand { preview.state.isExpanded = false }
    }
}
