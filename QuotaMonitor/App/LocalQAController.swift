import AppKit
import Foundation

@MainActor
final class LocalQAController {
    private let configuration: LocalQAConfiguration
    private let environment: AppEnvironment
    private let statusItemController: StatusItemController

    init(configuration: LocalQAConfiguration,
         environment: AppEnvironment,
         statusItemController: StatusItemController) {
        self.configuration = configuration
        self.environment = environment
        self.statusItemController = statusItemController
    }

    func start() {
        Task { @MainActor in
            await run()
        }
    }

    private func run() async {
        try? FileManager.default.createDirectory(
            at: configuration.outputDirectory,
            withIntermediateDirectories: true)

        await pause(seconds: 0.8)
        for step in configuration.steps {
            switch step {
            case .openDashboard:
                // `WindowManager.show` activates the app then orders the window
                // front, so the old `activateForWindow()` + URL-scheme
                // `WindowRouter.request` two-step is no longer needed.
                WindowManager.shared.show("dashboard")
                await pause(seconds: 0.8)
            case .openSettings:
                WindowManager.shared.show("settings")
                await pause(seconds: 0.8)
            case .openMenuBarHelp:
                WindowManager.shared.show("menubar-help")
                await pause(seconds: 0.8)
            case .showPopover:
                statusItemController.showPopover()
                await pause(seconds: 0.6)
            case .refreshAll:
                environment.refreshAll(throttle: false, trigger: "qa")
                await pause(seconds: 2.0)
            case .exerciseSettings:
                exerciseSettings()
                await pause(seconds: 0.8)
            case .wait:
                await pause(seconds: 1.0)
            case .snapshot:
                writeSnapshot()
            case .quit:
                writeSnapshot()
                await pause(seconds: 0.2)
                NSApp.terminate(nil)
            }
        }
    }

    private func pause(seconds: Double) async {
        let nanos = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    private func exerciseSettings() {
        let settings = SettingsStore.shared

        settings.pollIntervalSeconds = 900
        settings.quotaDisplayMode = .remaining
        settings.showDockIconForWindows = false
        _ = settings.setMenuBarIconProviderEnabled("codex", enabled: false)
        _ = settings.setProviderEnabled("codex", enabled: false)

        environment.applySettings()
        environment.applyDockIconPolicy()
        environment.applyEnabledProviders()

        DeveloperLog.eventRecord(
            "qa.settings.exercise",
            category: "settings",
            trigger: "qa",
            result: "success",
            fields: [
                "enabled_providers": .string(settings.enabledProviders.sorted().joined(separator: ",")),
                "menu_bar_icon_providers": .string(settings.menuBarIconProviders.sorted().joined(separator: ",")),
                "quota_display_mode": .string(settings.quotaDisplayMode.rawValue),
                "show_dock_icon": .bool(settings.showDockIconForWindows),
                "poll_interval_seconds": .int(settings.pollIntervalSeconds)
            ])
    }

    private func writeSnapshot() {
        let visibility = statusItemController.currentVisibility()
        let settings = SettingsStore.shared
        let report = LocalQAReport(
            generatedAt: ISO8601.fractional.string(from: Date()),
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            qaSteps: configuration.steps.map(\.rawValue),
            databasePath: DatabaseManager.defaultURL().path,
            developerLogPath: DeveloperLog.logFileURL.path,
            statusItemVisibility: String(describing: visibility),
            lastError: environment.lastError,
            settings: LocalQASettingsReport(
                language: LocalizationStore.shared.currentLanguage.rawValue,
                enabledProviders: settings.enabledProviders.sorted(),
                menuBarIconProviders: settings.menuBarIconProviders.sorted(),
                menuBarLabelStyle: settings.menuBarLabelStyle.rawValue,
                quotaDisplayMode: settings.quotaDisplayMode.rawValue,
                showDockIconForWindows: settings.showDockIconForWindows,
                developerModeEnabled: settings.developerModeEnabled,
                pollIntervalSeconds: settings.pollIntervalSeconds),
            windows: NSApp.windows.map {
                LocalQAWindowReport(
                    title: $0.title,
                    identifier: $0.identifier?.rawValue,
                    isVisible: $0.isVisible,
                    isKeyWindow: $0.isKeyWindow)
            },
            menuBar: environment.menuBarSnapshot.map {
                LocalQAMenuBarReport(
                    codexEvents: $0.codex.eventCount,
                    codexSessions: $0.codex.sessionCount,
                    codexTokens: $0.codex.totalTokens,
                    claudeEvents: $0.claude.eventCount,
                    claudeSessions: $0.claude.sessionCount,
                    claudeTokens: $0.claude.totalTokens)
            })

        do {
            try report.write(to: configuration.outputDirectory)
            DeveloperLog.eventRecord(
                "qa.snapshot.write",
                category: "app",
                trigger: "qa",
                result: "success",
                fields: [
                    "path": .string(configuration.outputDirectory
                        .appendingPathComponent("app-state.json").path)
                ])
        } catch {
            DeveloperLog.eventRecord(
                "qa.snapshot.write",
                level: .error,
                category: "app",
                trigger: "qa",
                result: "failure",
                message: error.localizedDescription)
        }
    }
}
