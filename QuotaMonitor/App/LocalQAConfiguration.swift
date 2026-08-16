import Foundation

/// Launch-time configuration for the local QA harness.
///
/// The harness is intentionally opt-in through environment variables so
/// release builds and normal user launches never run automation code.
struct LocalQAConfiguration: Equatable {
    let outputDirectory: URL
    let steps: [LocalQAStep]
    let mockCodexResetCredits: Bool

    init?() {
        self.init(resolved: LocalQAEnvironment.resolvedConfiguration())
    }

    init?(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.init(resolved: LocalQAEnvironment.resolvedConfiguration(
            environment: environment,
            arguments: arguments))
    }

    private init?(resolved: LocalQAResolvedConfiguration?) {
        guard let resolved, resolved.isActive else { return nil }

        if let rawSteps = resolved.steps,
           !rawSteps.isEmpty {
            var parsed: [LocalQAStep] = []
            for name in rawSteps {
                guard let step = LocalQAStep(rawValue: name) else { return nil }
                parsed.append(step)
            }
            self.steps = parsed
        } else {
            self.steps = [
                .openDashboard,
                .openSettings,
                .openMenuBarHelp,
                .showPopover,
                .refreshAll,
                .exerciseSettings,
                .wait,
                .snapshot
            ]
        }

        let output = resolved.outputDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("QuotaMonitorQA", isDirectory: true)
        self.outputDirectory = output
        self.mockCodexResetCredits = resolved.mockCodexResetCredits
    }
}

enum LocalQAStep: String, Equatable {
    case openDashboard = "open-dashboard"
    case openSettings = "open-settings"
    case openMenuBarHelp = "open-menubar-help"
    case openWhatsNew = "open-whats-new"
    case showPopover = "show-popover"
    case showImportWarning = "show-import-warning"
    case showCodexOverlayDetails = "show-codex-overlay-details"
    case refreshAll = "refresh-all"
    case exerciseSettings = "exercise-settings"
    case wait
    case snapshot
    case quit
}
