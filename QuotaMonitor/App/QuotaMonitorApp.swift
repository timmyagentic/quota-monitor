import SwiftUI

@main
struct QuotaMonitorApp: App {
    // The AppDelegate owns the AppKit NSStatusItem (which replaced the
    // SwiftUI MenuBarExtra) and the launch-time discoverability
    // orchestration. It references the same `.shared` singletons the
    // scenes below use.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    // Single source of truth for language selection. Wired into the
    // SwiftUI environment so any view can switch language at runtime
    // via `@Environment(LocalizationStore.self)`. We pass the same
    // instance into all three Scenes so the menu bar, dashboard, and
    // Settings windows stay in sync — switching language in Settings
    // updates the menu bar popover instantly.
    @State private var localization: LocalizationStore
    // SettingsStore drives non-language preferences (menu bar headline
    // window, poll cadence, paths, keychain policy). Same lifetime as
    // localization — exposed in every Scene so any view can flip a
    // setting and have it reflected app-wide on the next render.
    @State private var settings: SettingsStore
    // Sparkle (auto-update). Single instance — passed via `.environment`
    // so the Settings tab can wire the "Check Now" button + automatic-
    // check toggle to the same SPUUpdater that the scheduled background
    // checks use. Lifetime is the app's; init is cheap (no network).
    @State private var updater: UpdaterController

    init() {
        // Migrate UserDefaults from the legacy `dev.tjzhou.CodexMonitor`
        // bundle id BEFORE the @Observable singletons below read their
        // persisted values. The State wrappers below are assigned in
        // this init body (NOT via `=` defaults at declaration), so we
        // can guarantee the migration runs first. If you switch back
        // to inline defaults like `@State private var foo = X.shared`,
        // those default expressions run before this init body and you
        // lose the migration on the first launch under the new id.
        UserDefaultsMigration.runIfNeeded()
        _environment = State(wrappedValue: AppEnvironment.shared)
        _localization = State(wrappedValue: LocalizationStore.shared)
        _settings = State(wrappedValue: SettingsStore.shared)
        _updater = State(wrappedValue: UpdaterController())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let snap = SettingsStore.snapshot()
        if snap.developerModeEnabled {
            DeveloperLog.eventRecord(
                "app.start",
                category: "app",
                trigger: "launch",
                fields: [
                    "version": .string(version),
                    "bundle_id": .string(bundleID),
                    "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
                    "log_path": .string(DeveloperLog.logFileURL.path),
                    "database_path": .string(DatabaseManager.defaultURL().path),
                    "enabled_providers": .string(snap.enabledProviders.sorted().joined(separator: ",")),
                    "poll_interval_seconds": .int(snap.pollIntervalSeconds),
                    "onboarding_done": .bool(snap.hasCompletedProviderOnboarding),
                    "codex_fast_mode_billing": .bool(snap.codexFastModeBilling)
                ])
        }
    }

    var body: some Scene {
        // The menu-bar presence is now an AppKit `NSStatusItem` owned by
        // `AppDelegate` / `StatusItemController` (SwiftUI's `MenuBarExtra`
        // can neither open its popover programmatically nor expose its
        // on-screen geometry — both of which the clip-detection feature
        // needs). The launch fan-out that used to live on the
        // `MenuBarExtra` content `.task` now runs in
        // `AppDelegate.applicationDidFinishLaunching`.

        // Standalone onboarding window, opened on launch by `AppDelegate`
        // (via `WindowRouter`) when the user hasn't yet picked a language
        // or a tracked-tools set. `OnboardingView` dismisses this window
        // on Continue; if the user closes it early via the red titlebar
        // button, OnboardingView re-opens it from onDisappear so they
        // can't slip past the gate.
        //
        // `.handlesExternalEvents(matching: ["onboarding"])` lets
        // `WindowRouter` open this window from AppKit via the
        // `quotamonitor://onboarding` URL (AppKit has no `openWindow`).
        Window(L10n.onboardingWindowTitle, id: "onboarding") {
            OnboardingView()
                .environment(localization)
                .environment(settings)
                .environment(environment)
                .environment(\.locale, localization.locale)
                .id(localization.tickForceRedraw)
        }
        .handlesExternalEvents(matching: ["onboarding"])
        // Pin the window size so the layout doesn't reflow when the
        // user resizes mid-onboarding (the design assumes ~340pt wide).
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(Branding.appDisplayName, id: "dashboard") {
            MainWindowView()
                .environment(environment)
                .environment(localization)
                .environment(settings)
                .environment(\.locale, localization.locale)
                .id(localization.tickForceRedraw)
        }
        .defaultSize(width: 980, height: 680)
        // Opened from AppKit (the clipped-icon fallback) via
        // `quotamonitor://dashboard`.
        .handlesExternalEvents(matching: ["dashboard"])

        // Recovery guide shown when the menu-bar icon is clipped. Opened
        // from AppKit via `quotamonitor://menubar-help`, and from the
        // Dashboard banner / Settings any time.
        Window(L10n.menuBarHelpWindowTitle, id: "menubar-help") {
            MenuBarHelpView()
                .environment(environment)
                .environment(localization)
                .environment(settings)
                .environment(\.locale, localization.locale)
                .id(localization.tickForceRedraw)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: ["menubar-help"])

        // Settings is a regular `Window` scene rather than SwiftUI's
        // special-purpose `Settings { }` scene. The latter closes
        // itself whenever the app deactivates (which is what
        // `setActivationPolicy(.accessory)` triggers), and that
        // collision made the "Show Dock icon when windows are open"
        // toggle untenable — flipping it OFF inside Settings would
        // yank the very window the user was interacting with. As a
        // regular Window the Settings scene stays open across
        // activation-policy flips, so `applyDockIconPolicy()` can
        // demote immediately on toggle OFF.
        Window(L10n.settingsWindowTitle, id: "settings") {
            SettingsView()
                .environment(environment)
                .environment(localization)
                .environment(settings)
                .environment(updater)
                .environment(\.locale, localization.locale)
                .id(localization.tickForceRedraw)
        }
        // Let the Settings window grow/shrink to whatever the inner
        // view's min/ideal frame allows. Without this the scene defaults
        // can clamp the window to its first measurement and ignore drag.
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        // Opened from the popover / AppKit via `quotamonitor://settings`.
        .handlesExternalEvents(matching: ["settings"])
    }
}
