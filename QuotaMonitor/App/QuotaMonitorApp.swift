import SwiftUI

@main
struct QuotaMonitorApp: App {
    // The AppDelegate owns the whole AppKit shell: the NSStatusItem (which
    // replaced MenuBarExtra), the four app windows (via WindowManager), and the
    // launch-time discoverability orchestration. Shared state is reached through
    // the `.shared` singletons directly (AppEnvironment / LocalizationStore /
    // SettingsStore) — WindowManager injects them into each window's
    // NSHostingController. This App struct exists only to run the UserDefaults
    // migration first and host the one required (inert) Scene.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Migrate UserDefaults from the legacy `dev.tjzhou.CodexMonitor` bundle
        // id BEFORE anything reads the singletons' persisted values. This init
        // body runs before `applicationDidFinishLaunching` and before the
        // `SettingsStore.snapshot()` read below, so the migration always
        // precedes the first `.shared` access.
        UserDefaultsMigration.runIfNeeded()
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
        // The whole shell is AppKit-owned: the menu-bar presence is an
        // `NSStatusItem` (`StatusItemController`), and the four real app
        // windows — onboarding / dashboard / settings / menubar-help — are
        // `NSWindowController`s managed by `WindowManager`, hosting these same
        // SwiftUI views via `NSHostingController`. AppKit code and SwiftUI
        // views all open windows through `WindowManager.show(_:)`; there is no
        // longer a `quotamonitor://` URL scheme or `openWindow` split.
        //
        // A SwiftUI `App` must still declare at least one `Scene`. This inert,
        // hidden placeholder satisfies that requirement and nothing else;
        // macOS auto-opens it at launch and `AppDelegate.closeStrayWindows()`
        // immediately closes it.
        Window("", id: "__inert__") {
            EmptyView().frame(width: 0, height: 0)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
    }
}
