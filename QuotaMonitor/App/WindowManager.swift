import AppKit
import Observation
import SwiftUI

/// AppKit-owned window management. Replaces the SwiftUI `Window(id:)` scenes +
/// the `quotamonitor://` URL-scheme router (`WindowRouter`). AppKit now
/// authoritatively owns the whole shell — the status item, the popover, and
/// these four windows — while the SwiftUI feature views are hosted unchanged
/// via `NSHostingController`.
///
/// Why this exists: the old design split window-opening across two worlds
/// (AppKit code went through the custom URL scheme; SwiftUI views went through
/// `@Environment(\.openWindow)`), and a pile of defensive code reconciled them
/// (`closeStrayWindows`, `hasVisibleAppWindow` classname heuristics, per-view
/// `onAppear` focus grabs, the `Settings {}`-avoidance dance). Owning the
/// windows here collapses all of that into one place.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    /// Set once at launch by `AppDelegate`. Only the Settings window needs it
    /// (its "Check Now" button + automatic-check toggle wire to this exact
    /// `SPUUpdater`). Implicitly-unwrapped: Settings can't open before launch
    /// has finished configuring us.
    private var updater: UpdaterController!

    /// Controllers keyed by window id. A controller is recreated on reopen when
    /// its window is not currently visible, so the hosted SwiftUI view remounts
    /// and its `.task` re-fires — matching the old `Window(id:)` scene
    /// behaviour. The stale (closed) controller is replaced inside `show(_:)`,
    /// never inside a delegate callback, so we never deallocate a controller
    /// while it is running `windowWillClose`.
    private var controllers: [String: AppWindowController] = [:]

    func configure(updater: UpdaterController) {
        self.updater = updater
        // Arm the language-switch title refresh. Called exactly once at launch
        // (AppDelegate), before any window opens, so every later `set(_:)` is
        // observed (see `applyTitlesAndObserve`).
        applyTitlesAndObserve()
    }

    /// Open — or bring forward — the window for `id`.
    func show(_ id: String) {
        // policy → activate, BEFORE makeKeyAndOrderFront (correct order for an
        // `.accessory` app). `activateForWindow` already does policy+activate.
        AppEnvironment.shared.activateForWindow()
        // Reuse the existing window when it's on screen OR just miniaturized in
        // the Dock. `isVisible` is false while miniaturized, so without the
        // `isMiniaturized` check a minimized window would be orphaned and a
        // duplicate built in its place.
        if let existing = controllers[id], let win = existing.window,
           win.isVisible || win.isMiniaturized {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
            return
        }
        // Truly closed (or never created). Drop any stale closed controller
        // first so its window releases its frame-autosave name before the
        // replacement claims it — otherwise AppKit logs a duplicate-name
        // warning and ignores the new window's autosave name.
        controllers[id] = nil
        let controller = makeController(id: id)
        controllers[id] = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Programmatically close the window for `id`. Bypasses `windowShouldClose`
    /// (that gate only guards the user's red-button close), so this always
    /// closes — used by the onboarding finish path and the help "Dismiss".
    func close(_ id: String) {
        controllers[id]?.window?.close()
    }

    /// Whether any app-owned window is currently on screen, excluding `ids`.
    /// Covers the four `WindowManager` windows via this registry (replacing
    /// `hasVisibleAppWindow`'s old `NSPanel`/classname heuristics) **plus** the
    /// Sparkle update window, which is app-owned but lives outside the registry
    /// (in `UpdateWindowController`). That window is a real titled window that
    /// needs Dock / Cmd-Tab presence, so it must count too — otherwise closing
    /// the last registry window while an update is showing demotes the app to
    /// `.accessory` out from under the updater. Miniaturized managed windows
    /// also count: `isVisible` is false while minimized, but the window still
    /// exists and needs the Dock/Cmd-Tab entry to be restorable.
    func hasVisibleWindow(excluding ids: Set<String> = []) -> Bool {
        let managedVisible = controllers.contains { id, controller in
            !ids.contains(id)
                && Self.shouldCountManagedWindow(
                    isVisible: controller.window?.isVisible ?? false,
                    isMiniaturized: controller.window?.isMiniaturized ?? false)
        }
        return managedVisible || (updater?.isUpdateWindowVisible ?? false)
    }

    static func shouldCountManagedWindow(isVisible: Bool,
                                         isMiniaturized: Bool) -> Bool {
        isVisible || isMiniaturized
    }

    /// Called from `AppWindowController.windowWillClose`. Demote back to
    /// menu-bar-only once the last app window goes away. Deliberately does NOT
    /// mutate `controllers` — doing so here would deallocate the controller
    /// mid-callback. The stale controller is replaced on the next `show(_:)`.
    func handleWillClose(_ id: String) {
        AppEnvironment.shared.demoteToAccessory(excludingWindowIDs: [id])
    }

    /// Pure decision for the onboarding hard-gate, extracted for unit testing.
    /// The window may close only once onboarding is fully complete.
    static func shouldAllowOnboardingClose(needsOnboarding: Bool,
                                           needsProvider: Bool) -> Bool {
        !(needsOnboarding || needsProvider)
    }

    // MARK: - localized titles

    /// The window-chrome title for `id`, in the *current* language. The single
    /// source for both initial construction (`makeController`) and the
    /// language-switch refresh (`applyTitlesAndObserve`). The dashboard title is
    /// the product name (not localized); the other three read `L10n`.
    static func windowTitle(for id: String) -> String {
        switch id {
        case "dashboard": return Branding.appDisplayName
        case "settings": return L10n.settingsWindowTitle
        case "onboarding": return L10n.onboardingWindowTitle
        case "menubar-help": return L10n.menuBarHelpWindowTitle
        default: return ""
        }
    }

    /// Re-apply every open window's title and re-arm Observation. `HostedWindow`
    /// remounts the SwiftUI *content* on a language switch via
    /// `.id(loc.tickForceRedraw)`, but `NSWindow.title` is AppKit chrome outside
    /// that hosted tree — nothing else refreshes it, so the title bar would keep
    /// the old language until the window is closed and rebuilt. Reading
    /// `tickForceRedraw` inside the tracking closure makes `set(_:)` fire
    /// `onChange`; the work is deferred to the next runloop tick so it runs after
    /// `L10n`'s language byte has been updated. Mirrors
    /// `StatusItemController.renderAndObserve`. Observation is one-shot, so we
    /// re-arm on every change.
    private func applyTitlesAndObserve() {
        withObservationTracking {
            _ = LocalizationStore.shared.tickForceRedraw
            for (id, controller) in controllers {
                guard let window = controller.window else { continue }
                window.title = Self.windowTitle(for: id)
                controller.refreshLocalizedChrome()
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.applyTitlesAndObserve() }
        }
    }

    // MARK: - construction

    private func makeController(id: String) -> AppWindowController {
        let env = AppEnvironment.shared
        let loc = LocalizationStore.shared
        let settings = SettingsStore.shared

        let root: AnyView
        let config: WindowConfig
        let settingsTabSelection: SettingsTabSelection?
        switch id {
        case "dashboard":
            settingsTabSelection = nil
            root = AnyView(HostedWindow(content: MainWindowView())
                .environment(env).environment(loc).environment(settings))
            config = WindowConfig(
                resizable: true,
                initialContentSize: NSSize(width: 980, height: 680),
                minContentSize: NSSize(width: 820, height: 560),
                autosaveName: Self.frameAutosaveName(for: id),
                centerOnOpen: false)
        case "settings":
            let tabSelection = SettingsTabSelection()
            settingsTabSelection = tabSelection
            root = AnyView(HostedWindow(content: SettingsView(tabSelection: tabSelection))
                .environment(env).environment(loc).environment(settings)
                .environment(updater))
            config = WindowConfig(
                resizable: true,
                initialContentSize: NSSize(width: 620, height: 520),
                minContentSize: NSSize(width: 480, height: 380),
                // Keep the old SwiftUI Window(id:) autosave key so upgrading to
                // AppKit-hosted windows preserves the user's existing frame.
                autosaveName: Self.frameAutosaveName(for: id),
                centerOnOpen: true)
        case "onboarding":
            settingsTabSelection = nil
            root = AnyView(HostedWindow(content: OnboardingView())
                .environment(env).environment(loc).environment(settings))
            config = WindowConfig(
                resizable: false,
                initialContentSize: nil, minContentSize: nil,
                autosaveName: nil, centerOnOpen: true)
        case "menubar-help":
            settingsTabSelection = nil
            root = AnyView(HostedWindow(content: MenuBarHelpView())
                .environment(env).environment(loc).environment(settings))
            config = WindowConfig(
                resizable: false,
                initialContentSize: nil, minContentSize: nil,
                autosaveName: nil, centerOnOpen: true)
        default:
            settingsTabSelection = nil
            // Unknown id — should never happen. Build an empty window so a
            // routing bug surfaces visibly rather than crashing.
            root = AnyView(EmptyView())
            config = WindowConfig(resizable: false,
                                  initialContentSize: nil, minContentSize: nil,
                                  autosaveName: nil, centerOnOpen: true)
        }

        let hosting = NSHostingController(rootView: root)
        // Pinned windows size to content; resizable windows are sized by us
        // (initial size + contentMinSize) so SwiftUI's auto-sizing can't fight
        // the explicit constraints.
        hosting.sizingOptions = config.resizable ? [] : [.preferredContentSize]

        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if config.resizable { style.insert(.resizable) }

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = style
        window.title = Self.windowTitle(for: id)
        if id == "settings" {
            window.titleVisibility = .visible
            window.toolbarStyle = .automatic
        }
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.isReleasedWhenClosed = false   // the controller owns the window
        if let minSize = config.minContentSize { window.contentMinSize = minSize }
        if let size = config.initialContentSize { window.setContentSize(size) }
        if config.centerOnOpen { window.center() }
        // Assigning the autosave name restores a saved frame if one exists
        // (overriding the size/center above); otherwise the centered/default
        // frame stands and is what gets saved. MUST come after setContentSize.
        if let autosave = config.autosaveName { window.setFrameAutosaveName(autosave) }

        let controller = AppWindowController(window: window, id: id)
        if let settingsTabSelection {
            controller.configureSettingsToolbar(selection: settingsTabSelection)
        }
        window.delegate = controller   // weak ref; `controllers` retains the controller
        return controller
    }

    private struct WindowConfig {
        let resizable: Bool
        let initialContentSize: NSSize?
        let minContentSize: NSSize?
        let autosaveName: String?
        let centerOnOpen: Bool
    }

    static func frameAutosaveName(for id: String) -> String? {
        switch id {
        case "dashboard", "settings":
            // Matches the previous SwiftUI `Window(id:)` frame keys
            // (`NSWindow Frame dashboard/settings`) so AppKit migration does
            // not reset window size and layout style for existing users.
            return id
        default:
            return nil
        }
    }
}

/// Hosts a feature view and re-mounts it on a language switch, mirroring the
/// popover's `StatusItemController.HostedContent`. `L10n` reads are static, so
/// SwiftUI can't track them; reading `loc.tickForceRedraw` in `.id(...)` forces
/// the remount.
private struct HostedWindow<Content: View>: View {
    @Environment(LocalizationStore.self) private var loc
    let content: Content
    var body: some View {
        content
            .environment(\.locale, loc.locale)
            .id(loc.tickForceRedraw)
    }
}

/// Owns one window and acts as its delegate. `NSWindow.delegate` is `weak` and
/// `WindowManager.controllers` retains this controller, so there is no cycle.
@MainActor
final class AppWindowController: NSWindowController, NSWindowDelegate {
    private let id: String
    private var settingsToolbarCoordinator: SettingsToolbarCoordinator?

    init(window: NSWindow, id: String) {
        self.id = id
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hard-gate the onboarding window: the red-button close is allowed only
    /// once onboarding is complete. Other windows always allow it. The
    /// programmatic `WindowManager.close(_:)` does NOT route through here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard id == "onboarding" else { return true }
        return WindowManager.shouldAllowOnboardingClose(
            needsOnboarding: LocalizationStore.shared.needsOnboarding,
            needsProvider: SettingsStore.shared.needsProviderOnboarding)
    }

    func windowWillClose(_ notification: Notification) {
        WindowManager.shared.handleWillClose(id)
    }

    func configureSettingsToolbar(selection: SettingsTabSelection) {
        guard let window else { return }
        let coordinator = SettingsToolbarCoordinator(selection: selection) {
            WindowCrossLinkActions.scene(
                env: AppEnvironment.shared,
                openWindow: { WindowManager.shared.show($0) }
            ).openDashboardFromSettings()
        }
        let toolbar = NSToolbar(identifier: "QuotaMonitorSettingsToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.delegate = coordinator
        toolbar.centeredItemIdentifier = .settingsTabs
        window.toolbar = toolbar
        window.toolbarStyle = .automatic
        settingsToolbarCoordinator = coordinator
        coordinator.refreshLabels()
    }

    func refreshLocalizedChrome() {
        settingsToolbarCoordinator?.refreshLabels()
    }
}

private extension NSToolbarItem.Identifier {
    static let settingsTabs = NSToolbarItem.Identifier(
        "QuotaMonitor.SettingsToolbar.tabs")
    static let settingsDashboard = NSToolbarItem.Identifier(
        "QuotaMonitor.SettingsToolbar.dashboard")
}

@MainActor
private final class SettingsToolbarCoordinator: NSObject, NSToolbarDelegate {
    private let selection: SettingsTabSelection
    private let openDashboard: @MainActor () -> Void
    private weak var segmentedControl: NSSegmentedControl?
    private weak var dashboardItem: NSToolbarItem?

    init(selection: SettingsTabSelection,
         openDashboard: @escaping @MainActor () -> Void) {
        self.selection = selection
        self.openDashboard = openDashboard
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .settingsTabs, .settingsDashboard]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .settingsTabs, .flexibleSpace, .settingsDashboard]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .settingsTabs:
            let control = NSSegmentedControl(
                labels: [L10n.settingsTabGeneral, L10n.settingsTabAdvanced],
                trackingMode: .selectOne,
                target: self,
                action: #selector(tabChanged(_:)))
            control.segmentStyle = .automatic
            control.selectedSegment = selection.tab.rawValue
            control.sizeToFit()

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = control
            item.label = L10n.settingsWindowTitle
            item.paletteLabel = L10n.settingsWindowTitle
            segmentedControl = control
            return item

        case .settingsDashboard:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(
                systemSymbolName: "chart.bar.xaxis",
                accessibilityDescription: L10n.openDashboard)
            item.label = L10n.openDashboard
            item.paletteLabel = L10n.openDashboard
            item.toolTip = L10n.openDashboardTooltip
            item.target = self
            item.action = #selector(openDashboardClicked(_:))
            dashboardItem = item
            return item

        default:
            return nil
        }
    }

    func refreshLabels() {
        if let segmentedControl {
            segmentedControl.setLabel(
                L10n.settingsTabGeneral,
                forSegment: SettingsTab.general.rawValue)
            segmentedControl.setLabel(
                L10n.settingsTabAdvanced,
                forSegment: SettingsTab.advanced.rawValue)
            segmentedControl.selectedSegment = selection.tab.rawValue
            segmentedControl.sizeToFit()
        }
        if let dashboardItem {
            dashboardItem.label = L10n.openDashboard
            dashboardItem.paletteLabel = L10n.openDashboard
            dashboardItem.toolTip = L10n.openDashboardTooltip
        }
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = SettingsTab(rawValue: sender.selectedSegment) else {
            sender.selectedSegment = selection.tab.rawValue
            return
        }
        selection.tab = tab
    }

    @objc private func openDashboardClicked(_ sender: Any?) {
        openDashboard()
    }
}
