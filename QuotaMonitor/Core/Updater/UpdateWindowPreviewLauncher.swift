import AppKit
import Foundation

/// QA-only launch hook for previewing the real update window with generated
/// release-note HTML. This does not contact Sparkle or install anything; it
/// only exercises the same NSWindow, SwiftUI view, and WKWebView used by the
/// updater.
@MainActor
final class UpdateWindowPreviewLauncher {
    struct Configuration: Equatable {
        let htmlPath: String
        let newVersion: String
        let currentVersion: String?
        let locale: String
    }

    static let htmlArgument = "--quotamonitor-preview-update-window-html"
    static let newVersionArgument = "--quotamonitor-preview-update-window-version"
    static let currentVersionArgument = "--quotamonitor-preview-current-version"
    static let localeArgument = "--quotamonitor-preview-locale"

    private let configuration: Configuration
    private let state = UpdateWindowState()
    private lazy var windowController = UpdateWindowController(state: state)

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Configuration? {
        guard arguments.contains(where: {
            $0 == htmlArgument || $0.hasPrefix("\(htmlArgument)=")
        }) else {
            return nil
        }

        let localQAIsActive = LocalQAEnvironment.isActive(
            environment: environment,
            arguments: arguments)
        guard localQAIsActive else {
            Log.discover.error(
                "Ignoring update-window preview outside Local QA")
            return nil
        }

        guard let htmlPath = value(after: htmlArgument, in: arguments) else {
            Log.discover.error(
                "Ignoring update-window preview without an HTML path")
            return nil
        }

        Log.discover.info(
            "Preparing Local QA update-window preview")

        return Configuration(
            htmlPath: htmlPath,
            newVersion: value(after: newVersionArgument, in: arguments)
                ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? "Preview",
            currentVersion: value(after: currentVersionArgument, in: arguments),
            locale: value(after: localeArgument, in: arguments) ?? "zh-Hans")
    }

    func show() {
        let rawHTML: String
        do {
            rawHTML = try String(
                contentsOfFile: (configuration.htmlPath as NSString).expandingTildeInPath,
                encoding: .utf8)
        } catch {
            showError(error.localizedDescription)
            return
        }

        state.reset()
        state.newVersion = configuration.newVersion
        state.currentVersion = configuration.currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "?"
        state.isCritical = false
        state.hasReleaseNotes = ReleaseNotesCSS.hasContent(rawHTML)
        state.releaseNotesHTML = state.hasReleaseNotes
            ? ReleaseNotesCSS.wrapHTML(
                rawHTML,
                isDark: isDarkMode,
                locale: configuration.locale)
            : ""
        state.phase = .updateAvailable

        state.onInstall = { [weak self] in self?.windowController.close() }
        state.onSkip = { [weak self] in self?.windowController.close() }
        state.onDismiss = { [weak self] in self?.windowController.close() }

        windowController.show()
        Log.discover.info("Presented Local QA update-window preview")
    }

    private func showError(_ message: String) {
        state.reset()
        state.phase = .error(message)
        state.onAcknowledge = { [weak self] in self?.windowController.close() }
        windowController.show()
    }

    private var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(
            from: [NSAppearance.Name.darkAqua, .aqua]) == .darkAqua
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == flag {
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else { return nil }
                let value = arguments[valueIndex]
                return value.hasPrefix("--") ? nil : value
            }
            if argument.hasPrefix("\(flag)=") {
                let value = argument.dropFirst(flag.count + 1)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }
}
