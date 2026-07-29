import AppKit
import Foundation
import Observation

enum OpsailCodexRefitCommand {
    static let managedEnableLaunching = [
        "refit", "codex", "enable", "usage", "--launch", "--foreground"
    ]
    static let managedEnableAttachOnly = [
        "refit", "codex", "enable", "usage", "--foreground"
    ]
    static let disable = [
        "refit", "codex", "disable", "usage"
    ]
}

enum OpsailHelperLocator {
    static func bundledHelperURL(in bundle: Bundle = .main) -> URL {
        bundledHelperURL(bundleURL: bundle.bundleURL)
    }

    static func bundledHelperURL(bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("opsail", isDirectory: false)
    }
}

enum OpsailCodexRelaunchPolicy {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex"
    ]

    static func isSupported(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(supportedBundleIdentifiers.contains) ?? false
    }

    static func shouldRelaunch(
        enabled: Bool,
        stopping: Bool,
        awaitingInitialRestart: Bool,
        bundleIdentifier: String?
    ) -> Bool {
        enabled
            && !stopping
            && awaitingInitialRestart
            && isSupported(bundleIdentifier: bundleIdentifier)
    }

    static func shouldArmInitialRestart(
        isInitialObservation: Bool,
        codexIsRunning: Bool
    ) -> Bool {
        !isInitialObservation && codexIsRunning
    }
}

/// Owns only the QuotaMonitor-to-Opsail process boundary.
///
/// Opsail owns application validation, CDP discovery, renderer lifecycle,
/// bridge reads, DOM placement, health checks, reconnection, and cleanup.
@MainActor
final class OpsailCodexRefitController: NSObject {
    private static let relaunchDelayNanoseconds: UInt64 = 700_000_000
    private static let managerRetryDelayNanoseconds: UInt64 = 2_000_000_000
    private static let shutdownTimeout: TimeInterval = 5

    private let settings: SettingsStore
    private let workspace: NSWorkspace
    private let helperURL: URL
    private let fileManager: FileManager

    private var enableProcess: Process?
    private var disableProcess: Process?
    private var enableInvocationID: UUID?
    private var disableInvocationID: UUID?
    private var relaunchTask: Task<Void, Never>?
    private var managerRetryTask: Task<Void, Never>?
    private var enabled = false
    private var managedSessionRequested = false
    private var awaitingInitialCodexRestart = false
    private var hasObservedInitialSetting = false
    private var observingWorkspace = false
    private var stopping = false

    init(
        settings: SettingsStore = .shared,
        workspace: NSWorkspace = .shared,
        helperURL: URL = OpsailHelperLocator.bundledHelperURL(),
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.workspace = workspace
        self.helperURL = helperURL
        self.fileManager = fileManager
        super.init()
    }

    func start() {
        stopping = false
        if !observingWorkspace {
            workspace.notificationCenter.addObserver(
                self,
                selector: #selector(codexDidTerminate),
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil)
            observingWorkspace = true
        }
        observeSetting()
    }

    /// Performs bounded, synchronous cleanup while the app delegate and helper
    /// executable are still alive.
    func stop() {
        let shouldCleanup = managedSessionRequested
            || enableProcess != nil
            || disableProcess != nil
        stopping = true
        enabled = false
        awaitingInitialCodexRestart = false
        relaunchTask?.cancel()
        relaunchTask = nil
        managerRetryTask?.cancel()
        managerRetryTask = nil
        if observingWorkspace {
            workspace.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil)
            observingWorkspace = false
        }

        guard shouldCleanup else { return }
        let cleanup = disableProcess ?? launchProcess(
            arguments: OpsailCodexRefitCommand.disable,
            termination: nil)
        disableProcess = cleanup
        waitForExit(cleanup, timeout: Self.shutdownTimeout)
        disableProcess = nil

        if enableProcess?.isRunning == true {
            enableProcess?.terminate()
        }
        waitForExit(enableProcess, timeout: 1)
        enableProcess = nil
        enableInvocationID = nil
        disableInvocationID = nil
        managedSessionRequested = false
    }

    private func observeSetting() {
        withObservationTracking {
            apply(enabled: settings.codexSidebarQuotaEnabled)
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observeSetting()
            }
        }
    }

    private func apply(enabled nextEnabled: Bool) {
        let isInitialObservation = !hasObservedInitialSetting
        hasObservedInitialSetting = true
        guard nextEnabled != enabled else { return }
        enabled = nextEnabled
        relaunchTask?.cancel()
        relaunchTask = nil
        managerRetryTask?.cancel()
        managerRetryTask = nil

        if nextEnabled {
            let codexIsRunning = workspace.runningApplications.contains {
                OpsailCodexRelaunchPolicy.isSupported(
                    bundleIdentifier: $0.bundleIdentifier)
            }
            awaitingInitialCodexRestart =
                OpsailCodexRelaunchPolicy.shouldArmInitialRestart(
                    isInitialObservation: isInitialObservation,
                    codexIsRunning: codexIsRunning)
            startManagedSession(allowLaunch: !isInitialObservation)
        } else {
            awaitingInitialCodexRestart = false
            disableManagedSession()
        }
    }

    private func startManagedSession(allowLaunch: Bool) {
        guard enabled, !stopping else { return }
        guard enableProcess?.isRunning != true, disableProcess?.isRunning != true else {
            return
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            Log.ui.error(
                "Opsail helper unavailable at \(self.helperURL.path, privacy: .public)")
            return
        }

        managerRetryTask?.cancel()
        managerRetryTask = nil
        managedSessionRequested = true
        let invocationID = UUID()
        enableInvocationID = invocationID
        let process = launchProcess(
            arguments: allowLaunch
                ? OpsailCodexRefitCommand.managedEnableLaunching
                : OpsailCodexRefitCommand.managedEnableAttachOnly
        ) { [weak self] status in
            guard let self else { return }
            guard self.enableInvocationID == invocationID else { return }
            self.enableInvocationID = nil
            self.enableProcess = nil
            guard self.enabled, !self.stopping else { return }
            Log.ui.info(
                "Opsail Codex manager exited with status \(status, privacy: .public)")
            self.scheduleManagerRetry()
        }
        enableProcess = process
        if process == nil, enableInvocationID == invocationID {
            enableInvocationID = nil
            managedSessionRequested = false
            scheduleManagerRetry()
        }
    }

    private func scheduleManagerRetry() {
        guard enabled, !stopping, managerRetryTask == nil else { return }
        managerRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.managerRetryDelayNanoseconds)
            } catch {
                return
            }
            guard let self, self.enabled, !self.stopping else { return }
            self.managerRetryTask = nil
            self.startManagedSession(allowLaunch: false)
        }
    }

    private func disableManagedSession() {
        guard managedSessionRequested || enableProcess != nil else { return }
        guard disableProcess?.isRunning != true else { return }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            enableProcess?.terminate()
            enableProcess = nil
            managedSessionRequested = false
            return
        }

        let invocationID = UUID()
        disableInvocationID = invocationID
        let process = launchProcess(
            arguments: OpsailCodexRefitCommand.disable
        ) { [weak self] status in
            guard let self else { return }
            if self.disableInvocationID == invocationID {
                self.disableInvocationID = nil
                self.disableProcess = nil
            }
            if self.enableProcess?.isRunning == true {
                self.enableProcess?.terminate()
            }
            self.enableProcess = nil
            self.managedSessionRequested = false
            Log.ui.info(
                "Opsail Codex cleanup exited with status \(status, privacy: .public)")
            if self.enabled, !self.stopping {
                self.startManagedSession(allowLaunch: true)
            }
        }
        disableProcess = process
        if process == nil, disableInvocationID == invocationID {
            disableInvocationID = nil
        }
    }

    private func launchProcess(
        arguments: [String],
        termination: (@MainActor @Sendable (Int32) -> Void)?
    ) -> Process? {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let termination {
            process.terminationHandler = { finished in
                Task { @MainActor in
                    termination(finished.terminationStatus)
                }
            }
        }
        do {
            try process.run()
            return process
        } catch {
            Log.ui.error(
                "Could not launch Opsail helper: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func waitForExit(_ process: Process?, timeout: TimeInterval) {
        guard let process else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    @objc private func codexDidTerminate(_ notification: Notification) {
        guard let application =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              OpsailCodexRelaunchPolicy.shouldRelaunch(
                enabled: enabled,
                stopping: stopping,
                awaitingInitialRestart: awaitingInitialCodexRestart,
                bundleIdentifier: application.bundleIdentifier)
        else { return }

        awaitingInitialCodexRestart = false
        relaunchTask?.cancel()
        managerRetryTask?.cancel()
        managerRetryTask = nil
        relaunchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.relaunchDelayNanoseconds)
            } catch {
                return
            }
            guard let self, self.enabled, !self.stopping else { return }
            if self.enableProcess?.isRunning == true {
                self.enableProcess?.terminate()
                self.enableProcess = nil
            }
            self.startManagedSession(allowLaunch: true)
        }
    }
}
