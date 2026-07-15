import AppKit
import SwiftUI
import Observation

/// Owns the AppKit `NSStatusItem` that replaced the SwiftUI `MenuBarExtra`.
/// AppKit is required for things `MenuBarExtra` cannot do: open the popover
/// programmatically (first-run auto-open) and read the status item's
/// on-screen geometry (clip detection).
///
/// **Label rendering.** The menu-bar text is drawn natively via
/// `statusItem.button.attributedTitle`, NOT a hosted SwiftUI view. The
/// status item uses `variableLength`, which measures the button's *title*
/// to size itself — a hosted subview can't drive that, which produced the
/// wrong insets/spacing. Native title rendering restores system spacing and
/// gives two selectable styles (see `SettingsStore.MenuBarLabelStyle`).
///
/// **Reactivity.** Not a SwiftUI view, so the label is re-rendered by
/// observing the `@Observable` state with `withObservationTracking` and
/// re-arming on every change. The popover, by contrast, stays SwiftUI via
/// `NSHostingController`.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    typealias PulseSleep = @Sendable (_ duration: Duration) async throws -> Void

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let env: AppEnvironment
    private let localization: LocalizationStore
    private let settings: SettingsStore
    private let updater: UpdaterController
    private let pulseSleep: PulseSleep
    private var pulseTask: Task<Void, Never>?
    private var pulseGeneration: UInt = 0
    private var emphasizedUpdateVersion: String?

    var updateMarkerIsEmphasized: Bool {
        guard let emphasizedUpdateVersion else { return false }
        return updater.updateAvailability.version == emphasizedUpdateVersion
    }

    /// Invoked when the display configuration changes (external monitor,
    /// resolution, notch) so the owner can re-run the clip check.
    var onScreenChange: (() -> Void)?

    init(env: AppEnvironment,
         localization: LocalizationStore,
         settings: SettingsStore,
         updater: UpdaterController,
         pulseSleep: @escaping PulseSleep = { duration in
             try await Task<Never, Never>.sleep(for: duration)
         }) {
        self.env = env
        self.localization = localization
        self.settings = settings
        self.updater = updater
        self.pulseSleep = pulseSleep
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        statusItem.autosaveName = "QuotaMonitor"   // nudge placement only

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: HostedContent()
                .environment(env)
                .environment(localization)
                .environment(settings)
                .environment(updater)
                .environment(\.locale, localization.locale))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        // Initial render + arm observation so the label tracks live state.
        renderAndObserve()
    }

    isolated deinit {
        pulseTask?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
        NotificationCenter.default.removeObserver(self)
    }

    func pulseUpdateMarker(version: String) {
        guard updater.updateAvailability.version == version else { return }
        pulseGeneration &+= 1
        let generation = pulseGeneration
        pulseTask?.cancel()
        emphasizedUpdateVersion = version
        renderLabel()

        let pulseSleep = self.pulseSleep
        pulseTask = Task { @MainActor [weak self, pulseSleep] in
            do {
                try await pulseSleep(.seconds(8))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.endUpdateMarkerPulse(generation: generation)
        }
    }

    private func endUpdateMarkerPulse(generation: UInt) {
        guard generation == pulseGeneration else { return }
        pulseTask = nil
        emphasizedUpdateVersion = nil
        renderLabel()
    }

    // MARK: - label rendering

    /// Render the label once and re-arm Observation. `renderLabel()` reads
    /// the `@Observable` properties inside the tracking closure, so any
    /// change to them fires `onChange`, where we re-render and re-arm.
    private func renderAndObserve() {
        withObservationTracking {
            renderLabel()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.renderAndObserve() }
        }
    }

    private func renderLabel() {
        guard let button = statusItem.button else { return }
        _ = localization.tickForceRedraw
        let updateVersion = StatusItemUpdateMarker.normalizedVersion(
            updater.updateAvailability.version)
        if let emphasizedUpdateVersion, emphasizedUpdateVersion != updateVersion {
            pulseGeneration &+= 1
            pulseTask?.cancel()
            pulseTask = nil
            self.emphasizedUpdateVersion = nil
        }
        let rows = MenuBarLabelModel.rows(
            iconProviders: settings.menuBarIconProviders,
            enabledProviders: settings.enabledProviders,
            rateLimits: env.latestRateLimits,
            claudeUsage: env.latestClaudeUsage,
            codexQuota: env.dashboardSnapshot?.codexQuota,
            displayMode: settings.quotaDisplayMode)
        let style = settings.menuBarLabelStyle
        let baseTitle: NSAttributedString

        // Reset version-specific tooltip copy on every pass. Accessibility is
        // assigned explicitly below because AppKit does not restore an inferred
        // title after an explicit accessibility label is cleared with nil.
        button.toolTip = nil

        if rows.isEmpty {
            // Same gauge fallback the app shipped with — as a template image
            // so it auto-adapts to the menu bar's light/dark appearance.
            baseTitle = NSAttributedString(string: "")
            button.image = Self.gaugeImage
            button.imagePosition = updateVersion == nil ? .imageOnly : .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
            baseTitle = MenuBarTitleBuilder.make(rows: rows, style: style)
        }

        button.attributedTitle = StatusItemUpdateMarker.title(
            base: baseTitle,
            version: updateVersion,
            emphasized: emphasizedUpdateVersion == updateVersion)
        let accessibilityLabel = StatusItemUpdateMarker.accessibilityLabel(
            base: baseTitle,
            fallback: Branding.appDisplayName,
            version: updateVersion)
        button.setAccessibilityLabel(accessibilityLabel)
        if let updateVersion {
            button.toolTip = L10n.statusItemUpdateTooltip(updateVersion)
        }
    }

    private static let gaugeImage: NSImage? = {
        let img = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                          accessibilityDescription: Branding.appDisplayName)
        img?.isTemplate = true
        return img
    }()

    // MARK: - popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// Open the popover anchored to the status button. Used both by the
    /// button click and by the first-run auto-open.
    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds,
                     of: button,
                     preferredEdge: .minY)
        preparePopoverWindowForMenuBarPresentation()
    }

    /// `NSPopoverDelegate` — the authoritative "popover opened" hook now
    /// that we own the popover. Mirrors the old
    /// `MenuBarContentView.onAppear` refresh-on-open.
    func popoverWillShow(_ notification: Notification) {
        guard !settings.needsProviderOnboarding else { return }
        env.refreshAll(throttle: true, trigger: "popover")
    }

    func popoverDidShow(_ notification: Notification) {
        preparePopoverWindowForMenuBarPresentation()
    }

    private func preparePopoverWindowForMenuBarPresentation() {
        guard let window = popover.contentViewController?.view.window,
              let button = statusItem.button else { return }
        Self.configurePopoverWindowForMenuBarPresentation(window)
        Self.positionPopoverWindowForMenuBarPresentation(window, relativeTo: button)
        window.makeKey()
        window.orderFrontRegardless()
    }

    static func configurePopoverWindowForMenuBarPresentation(_ window: NSWindow) {
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.hidesOnDeactivate = false
        window.level = .popUpMenu
    }

    static func positionPopoverWindowForMenuBarPresentation(_ window: NSWindow,
                                                            relativeTo button: NSStatusBarButton) {
        guard let anchorRect = menuBarAnchorRectOnScreen(for: button) else { return }
        let screenFrame = menuBarScreenFrame(
            containing: anchorRect,
            fallback: button.window?.screen)
        let origin = menuBarPopoverOrigin(
            windowSize: window.frame.size,
            anchorRect: anchorRect,
            screenFrame: screenFrame,
            statusBarThickness: NSStatusBar.system.thickness)
        window.setFrameOrigin(origin)
    }

    private static func menuBarAnchorRectOnScreen(for button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private static func menuBarScreenFrame(containing anchorRect: NSRect,
                                           fallback: NSScreen?) -> NSRect {
        let anchorMidX = anchorRect.midX
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) {
            return screen.frame
        }
        if let screen = NSScreen.screens.first(where: {
            anchorMidX >= $0.frame.minX && anchorMidX <= $0.frame.maxX
        }) {
            return screen.frame
        }
        return fallback?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 0, height: 0)
    }

    static func menuBarPopoverOrigin(windowSize: NSSize,
                                     anchorRect: NSRect,
                                     screenFrame: NSRect,
                                     statusBarThickness: CGFloat) -> NSPoint {
        let padding: CGFloat = 8
        let proposedX = anchorRect.midX - windowSize.width / 2
        let maxX = screenFrame.maxX - windowSize.width - padding
        let x = clamp(proposedX, min: screenFrame.minX + padding, max: maxX)

        let anchorIsOutsideScreen = anchorRect.maxY < screenFrame.minY
            || anchorRect.minY > screenFrame.maxY
        let anchorBottomY = anchorIsOutsideScreen
            ? screenFrame.maxY - statusBarThickness
            : anchorRect.minY
        let proposedY = anchorBottomY - windowSize.height
        let maxY = screenFrame.maxY - windowSize.height - padding
        let y = clamp(proposedY, min: screenFrame.minY + padding, max: maxY)

        return NSPoint(x: x, y: y)
    }

    private static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), Swift.max(minValue, maxValue))
    }

    // MARK: - visibility

    /// Live clip check. Wraps the pure `MenuBarVisibilityEvaluator` with the
    /// AppKit geometry: the status button's window frame and the frame of
    /// the screen hosting it (falling back to the main screen).
    func currentVisibility() -> StatusItemVisibility {
        guard statusItem.isVisible,
              let win = statusItem.button?.window else {
            Log.discover.info(
                "visibility=clipped reason=no-window isVisible=\(self.statusItem.isVisible, privacy: .public) hasButton=\(self.statusItem.button != nil, privacy: .public)")
            return .clipped
        }
        let screenFrame = (win.screen ?? NSScreen.main)?.frame
        let result = MenuBarVisibilityEvaluator.evaluate(
            buttonWindowFrame: win.frame, hostScreenFrame: screenFrame)
        Log.discover.info(
            "visibility=\(String(describing: result), privacy: .public) buttonFrame=\(NSStringFromRect(win.frame), privacy: .public) screenFrame=\(screenFrame.map(NSStringFromRect) ?? "nil", privacy: .public)")
        return result
    }

    @objc private func screenParamsChanged() { onScreenChange?() }
}

// MARK: - native title builder

/// Adds the compact update affordance without rewriting the quota title.
enum StatusItemUpdateMarker {
    static func normalizedVersion(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        return version
    }

    static func title(
        base: NSAttributedString,
        version: String?,
        emphasized: Bool = false
    ) -> NSAttributedString {
        guard normalizedVersion(version) != nil else { return base }
        let decorated = NSMutableAttributedString(attributedString: base)
        let attributes: [NSAttributedString.Key: Any] = emphasized
            ? [
                .foregroundColor: NSColor.selectedMenuItemTextColor,
                .backgroundColor: NSColor.systemOrange,
            ]
            : [.foregroundColor: NSColor.systemOrange]
        decorated.append(NSAttributedString(
            string: " ↓",
            attributes: attributes))
        return decorated
    }

    static func accessibilityLabel(
        base: NSAttributedString,
        fallback: String,
        version: String?
    ) -> String {
        let baseLabel = base.string.isEmpty ? fallback : base.string
        guard let version = normalizedVersion(version) else { return baseLabel }
        return "\(baseLabel). \(L10n.statusItemUpdateAccessibilityLabel(version))"
    }
}

/// Builds the `NSAttributedString` for the menu-bar label in the chosen
/// style. Kept separate from the controller so the typography is easy to
/// find and tweak.
enum MenuBarTitleBuilder {
    static func make(rows: [MenuBarLabelModel.Row],
                     style: SettingsStore.MenuBarLabelStyle) -> NSAttributedString {
        switch style {
        case .emphasis: return emphasis(rows)
        case .native:   return native(rows)
        }
    }

    private static let thinSpace = "\u{2009}"

    // MARK: emphasis — rounded design, mixed weights

    private static func emphasis(_ rows: [MenuBarLabelModel.Row]) -> NSAttributedString {
        let labelFont = rounded(9, .medium)
        let tagFont = rounded(9, .semibold)
        let valueFont = monospacedDigits(rounded(11, .heavy))
        let sepFont = rounded(9, .regular)
        let multi = rows.count > 1

        let out = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            if i > 0 { out.append(run("   ", sepFont)) }   // wide gap between providers
            if multi { out.append(run("\(r.tag) ", tagFont)) }
            for (segmentIndex, segment) in visibleSegments(for: r).enumerated() {
                if segmentIndex > 0 { out.append(run("  ·  ", sepFont)) }
                out.append(run("\(segment.label)\(thinSpace)", labelFont))
                out.append(run(segment.value, valueFont))
            }
        }
        return out
    }

    // MARK: native — system menu-bar font, single weight

    private static func native(_ rows: [MenuBarLabelModel.Row]) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let multi = rows.count > 1
        var parts: [String] = []
        for r in rows {
            let tag = multi ? "\(r.tag) " : ""
            let windows = visibleSegments(for: r)
                .map { "\($0.label) \($0.value)" }
                .joined(separator: " · ")
            parts.append("\(tag)\(windows)")
        }
        return run(parts.joined(separator: "   "), font)
    }

    // MARK: helpers

    private static func visibleSegments(
        for row: MenuBarLabelModel.Row
    ) -> [(label: String, value: String)] {
        let all = [
            (label: "5h", value: row.fiveHour),
            (label: "7d", value: row.sevenDay)
        ]
        let available = all.filter { $0.value != "--" }
        // Preserve the established two-placeholder readout while data is
        // entirely unavailable. Once one real window exists, omit only the
        // inactive window so the title describes the current Codex policy.
        return available.isEmpty ? all : available
    }

    private static func run(_ s: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    }

    /// Apply proportional→monospaced digit spacing so the label doesn't
    /// shift horizontally as percentages flip between 1 and 2 digits.
    private static func monospacedDigits(_ font: NSFont) -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector
        ]]
        let d = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }
}

// MARK: - hosted SwiftUI popover wrapper

/// Wraps `MenuBarContentView` so reading `loc.tickForceRedraw` in the body
/// re-renders the popover's `NSHostingController` on a language switch.
private struct HostedContent: View {
    @Environment(LocalizationStore.self) private var loc
    var body: some View {
        MenuBarContentView().id(loc.tickForceRedraw)
    }
}
