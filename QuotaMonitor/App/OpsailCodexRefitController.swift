import AppKit
import Darwin
import Foundation
import Observation

enum OpsailCodexRefitCommand {
    private static let managedEnableLaunching = [
        "refit", "codex", "enable", "usage", "--launch"
    ]
    private static let managedEnableAttachOnly = [
        "refit", "codex", "enable", "usage"
    ]
    static let disable = [
        "refit", "codex", "disable", "usage"
    ]

    static func managedEnable(allowLaunch: Bool) -> [String] {
        allowLaunch ? managedEnableLaunching : managedEnableAttachOnly
    }
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

enum OpsailCodexApplicationPolicy {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex"
    ]

    static func isSupported(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(supportedBundleIdentifiers.contains) ?? false
    }
}

enum OpsailCodexActivationPolicy {
    private static let attachUnavailableMarkers = [
        "[opsail-refit-codex:session-unavailable]",
        "[opsail-refit-codex:restart-required]"
    ]

    static func allowLaunchForExplicitRequest(
        codexIsRunning: Bool
    ) -> Bool {
        !codexIsRunning
    }

    static func actionableStatus(
        status: Int32,
        diagnostic: String,
        codexIsRunning: Bool
    ) -> CodexSidebarQuotaStatus? {
        guard status != 0,
              attachUnavailableMarkers.contains(where: diagnostic.contains)
        else { return nil }
        return codexIsRunning ? .needsCodexQuit : .readyToLaunch
    }

    static func preserveLaunchIntent(
        pendingAllowLaunch: Bool,
        requestedAllowLaunch: Bool
    ) -> Bool {
        pendingAllowLaunch || requestedAllowLaunch
    }

}

struct OpsailCodexAutomaticRestoreState: Equatable {
    private(set) var awaitingTerminationProcessIdentifier: pid_t?

    mutating func beginPrelaunchHandoff(
        processIdentifier: pid_t,
        enabled: Bool,
        isManagedLaunch: Bool,
        runningProcessIdentifiers: [pid_t]
    ) -> Bool {
        guard awaitingTerminationProcessIdentifier == nil,
              enabled,
              !isManagedLaunch,
              runningProcessIdentifiers.count == 1,
              runningProcessIdentifiers[0] == processIdentifier
        else { return false }
        awaitingTerminationProcessIdentifier = processIdentifier
        return true
    }

    func isAwaitingTermination(processIdentifier: pid_t) -> Bool {
        awaitingTerminationProcessIdentifier == processIdentifier
    }

    mutating func didTerminate(processIdentifier: pid_t) -> Bool {
        guard awaitingTerminationProcessIdentifier == processIdentifier else {
            return false
        }
        awaitingTerminationProcessIdentifier = nil
        return true
    }

    mutating func cancelAwaitingTermination(
        processIdentifier: pid_t
    ) -> Bool {
        guard awaitingTerminationProcessIdentifier == processIdentifier else {
            return false
        }
        awaitingTerminationProcessIdentifier = nil
        return true
    }

    mutating func reset() {
        awaitingTerminationProcessIdentifier = nil
    }
}

enum OpsailCodexLaunchArgumentPolicy {
    private static let remoteDebuggingMarker = Data(
        "--remote-debugging-port".utf8)

    static func alreadyHasDebuggingPort(processIdentifier: pid_t) -> Bool? {
        guard let processArguments = processArguments(
            processIdentifier: processIdentifier)
        else { return nil }
        return processArguments.range(of: remoteDebuggingMarker) != nil
    }

    static func containsDebuggingPort(in processArguments: Data) -> Bool {
        processArguments.range(of: remoteDebuggingMarker) != nil
    }

    private static func processArguments(
        processIdentifier: pid_t
    ) -> Data? {
        var query = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var requiredSize = 0
        let sizeStatus = query.withUnsafeMutableBufferPointer { pointer in
            sysctl(
                pointer.baseAddress,
                u_int(pointer.count),
                nil,
                &requiredSize,
                nil,
                0)
        }
        guard sizeStatus == 0, requiredSize > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: requiredSize)
        let readStatus = query.withUnsafeMutableBufferPointer { queryPointer in
            bytes.withUnsafeMutableBytes { bytePointer in
                sysctl(
                    queryPointer.baseAddress,
                    u_int(queryPointer.count),
                    bytePointer.baseAddress,
                    &requiredSize,
                    nil,
                    0)
            }
        }
        guard readStatus == 0, requiredSize > 0 else { return nil }
        return Data(bytes.prefix(requiredSize))
    }
}

enum OpsailCodexTerminationSignal {
    static func requestGracefulTermination(
        processIdentifier: pid_t
    ) -> Bool {
        Darwin.kill(processIdentifier, SIGTERM) == 0
    }
}

extension Notification.Name {
    static let quotaMonitorCodexSidebarLaunchRequested =
        Notification.Name("dev.tjzhou.QuotaMonitor.codexSidebarLaunchRequested")
}

@MainActor
enum OpsailCodexRefitActions {
    static func requestExplicitLaunch() {
        NotificationCenter.default.post(
            name: .quotaMonitorCodexSidebarLaunchRequested,
            object: nil)
    }
}

enum OpsailRetryPolicy {
    static func delayNanoseconds(attempt: Int) -> UInt64 {
        guard attempt < 5 else { return 60_000_000_000 }
        return UInt64(2 << max(0, attempt)) * 1_000_000_000
    }
}

enum OpsailCleanupPolicy {
    static func didComplete(status: Int32) -> Bool {
        status == 0
    }

    static func canStartManager(
        disableInvocationPending: Bool,
        disableProcessPresent: Bool
    ) -> Bool {
        !disableInvocationPending && !disableProcessPresent
    }
}

/// Owns only the QuotaMonitor-to-Opsail process boundary.
///
/// Opsail owns application validation, CDP discovery, renderer lifecycle,
/// bridge reads, DOM placement, health checks, reconnection, and cleanup.
@MainActor
final class OpsailCodexRefitController: NSObject {
    private static let shutdownTimeout: TimeInterval = 5
    private static let automaticHandoffTimeoutNanoseconds: UInt64 =
        5_000_000_000
    private static let managedLaunchExpectationTimeoutNanoseconds: UInt64 =
        30_000_000_000

    private let settings: SettingsStore
    private let workspace: NSWorkspace
    private let helperURL: URL
    private let fileManager: FileManager
    private let rendererAssetInstaller: OpsailRendererAssetInstaller

    private var enableProcess: Process?
    private var disableProcess: Process?
    private var enableInvocationID: UUID?
    private var disableInvocationID: UUID?
    private var managerRetryTask: Task<Void, Never>?
    private var cleanupRetryTask: Task<Void, Never>?
    private var automaticHandoffTimeoutTask: Task<Void, Never>?
    private var managedLaunchExpectationTask: Task<Void, Never>?
    private var managerRetryAttempt = 0
    private var cleanupRetryAttempt = 0
    private var enabled = false
    private var automaticRestoreEnabled = false
    private var automaticRestoreState = OpsailCodexAutomaticRestoreState()
    private var expectingManagedCodexLaunch = false
    private var managedSessionRequested = false
    private var pendingManagerAllowLaunch = false
    private var observingWorkspace = false
    private var observingLaunchRequests = false
    private var stopping = false

    init(
        settings: SettingsStore = .shared,
        workspace: NSWorkspace = .shared,
        helperURL: URL = OpsailHelperLocator.bundledHelperURL(),
        rendererAssetInstaller: OpsailRendererAssetInstaller =
            OpsailRendererAssetInstaller(),
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.workspace = workspace
        self.helperURL = helperURL
        self.rendererAssetInstaller = rendererAssetInstaller
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
            workspace.notificationCenter.addObserver(
                self,
                selector: #selector(codexWillLaunch),
                name: NSWorkspace.willLaunchApplicationNotification,
                object: nil)
            workspace.notificationCenter.addObserver(
                self,
                selector: #selector(codexDidLaunch),
                name: NSWorkspace.didLaunchApplicationNotification,
                object: nil)
            observingWorkspace = true
        }
        if !observingLaunchRequests {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(explicitLaunchRequested),
                name: .quotaMonitorCodexSidebarLaunchRequested,
                object: nil)
            observingLaunchRequests = true
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
        managerRetryTask?.cancel()
        managerRetryTask = nil
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil
        resetAutomaticRestoreState()
        clearManagedLaunchExpectation()
        if observingWorkspace {
            workspace.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil)
            workspace.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.willLaunchApplicationNotification,
                object: nil)
            workspace.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.didLaunchApplicationNotification,
                object: nil)
            observingWorkspace = false
        }
        if observingLaunchRequests {
            NotificationCenter.default.removeObserver(
                self,
                name: .quotaMonitorCodexSidebarLaunchRequested,
                object: nil)
            observingLaunchRequests = false
        }

        guard shouldCleanup else { return }
        let manager = enableProcess
        enableInvocationID = nil
        enableProcess = nil
        if manager?.isRunning == true {
            manager?.terminate()
        }
        waitForExit(manager, timeout: 1)

        let cleanup = disableProcess ?? launchProcess(
            arguments: OpsailCodexRefitCommand.disable,
            termination: nil)
        disableProcess = cleanup
        waitForExit(cleanup, timeout: Self.shutdownTimeout)
        disableProcess = nil

        disableInvocationID = nil
        managedSessionRequested = false
        settings.codexSidebarQuotaStatus = .disabled
    }

    private func observeSetting() {
        withObservationTracking {
            apply(
                enabled: settings.codexSidebarQuotaEnabled,
                automaticRestoreEnabled:
                    settings.codexSidebarQuotaAutoRestoreEnabled)
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observeSetting()
            }
        }
    }

    private func apply(
        enabled nextEnabled: Bool,
        automaticRestoreEnabled nextAutomaticRestoreEnabled: Bool
    ) {
        let enabledChanged = nextEnabled != enabled
        let automaticRestoreChanged =
            nextAutomaticRestoreEnabled != automaticRestoreEnabled
        guard enabledChanged || automaticRestoreChanged else { return }

        automaticRestoreEnabled = nextAutomaticRestoreEnabled
        if !nextAutomaticRestoreEnabled {
            resetAutomaticRestoreState()
        }
        guard enabledChanged else { return }

        enabled = nextEnabled
        managerRetryTask?.cancel()
        managerRetryTask = nil
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil

        if nextEnabled {
            managerRetryAttempt = 0
            settings.codexSidebarQuotaStatus = .attaching
            startManagedSession(allowLaunch: false)
        } else {
            cleanupRetryAttempt = 0
            pendingManagerAllowLaunch = false
            resetAutomaticRestoreState()
            clearManagedLaunchExpectation()
            settings.codexSidebarQuotaStatus = .disabled
            disableManagedSession()
        }
    }

    private func startManagedSession(allowLaunch: Bool) {
        guard enabled, !stopping else { return }
        guard enableProcess?.isRunning != true else {
            pendingManagerAllowLaunch =
                OpsailCodexActivationPolicy.preserveLaunchIntent(
                    pendingAllowLaunch: pendingManagerAllowLaunch,
                    requestedAllowLaunch: allowLaunch)
            return
        }
        guard OpsailCleanupPolicy.canStartManager(
            disableInvocationPending: disableInvocationID != nil,
            disableProcessPresent: disableProcess != nil)
        else {
            pendingManagerAllowLaunch =
                OpsailCodexActivationPolicy.preserveLaunchIntent(
                    pendingAllowLaunch: pendingManagerAllowLaunch,
                    requestedAllowLaunch: allowLaunch)
            return
        }
        let effectiveAllowLaunch =
            OpsailCodexActivationPolicy.preserveLaunchIntent(
                pendingAllowLaunch: pendingManagerAllowLaunch,
                requestedAllowLaunch: allowLaunch)
        pendingManagerAllowLaunch = false
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            settings.codexSidebarQuotaStatus = .unavailable
            Log.ui.error(
                "Opsail helper unavailable at \(self.helperURL.path, privacy: .public)")
            return
        }
        do {
            let outcome = try rendererAssetInstaller.installIfNeeded()
            Log.ui.info(
                "Opsail renderer assets prepared: \(String(describing: outcome), privacy: .public)")
        } catch {
            pendingManagerAllowLaunch =
                OpsailCodexActivationPolicy.preserveLaunchIntent(
                    pendingAllowLaunch: pendingManagerAllowLaunch,
                    requestedAllowLaunch: effectiveAllowLaunch)
            settings.codexSidebarQuotaStatus = .unavailable
            Log.ui.error(
                "Opsail renderer assets unavailable: \(error.localizedDescription, privacy: .public)")
            scheduleManagerRetry()
            return
        }

        managerRetryTask?.cancel()
        managerRetryTask = nil
        managedSessionRequested = true
        let invocationID = UUID()
        enableInvocationID = invocationID
        if effectiveAllowLaunch {
            armManagedLaunchExpectation()
        }
        let process = launchProcess(
            arguments: OpsailCodexRefitCommand.managedEnable(
                allowLaunch: effectiveAllowLaunch)
        ) { [weak self] status, diagnostic in
            guard let self else { return }
            guard self.enableInvocationID == invocationID else { return }
            self.enableInvocationID = nil
            self.enableProcess = nil
            guard self.enabled, !self.stopping else { return }
            if effectiveAllowLaunch, status != 0 {
                self.clearManagedLaunchExpectation()
            }
            if self.pendingManagerAllowLaunch {
                self.startManagedSession(allowLaunch: true)
                return
            }
            Log.ui.info(
                "Opsail Codex manager exited with status \(status, privacy: .public)")
            if status == 0 {
                self.managerRetryAttempt = 0
                self.settings.codexSidebarQuotaStatus = .active
                return
            }
            if let actionableStatus = OpsailCodexActivationPolicy.actionableStatus(
                status: status,
                diagnostic: diagnostic,
                codexIsRunning: self.codexIsRunning())
            {
                self.settings.codexSidebarQuotaStatus = actionableStatus
                return
            }
            self.settings.codexSidebarQuotaStatus = .unavailable
            self.scheduleManagerRetry()
        }
        enableProcess = process
        if process == nil, enableInvocationID == invocationID {
            enableInvocationID = nil
            managedSessionRequested = false
            if effectiveAllowLaunch {
                clearManagedLaunchExpectation()
            }
            pendingManagerAllowLaunch =
                OpsailCodexActivationPolicy.preserveLaunchIntent(
                    pendingAllowLaunch: pendingManagerAllowLaunch,
                    requestedAllowLaunch: effectiveAllowLaunch)
            settings.codexSidebarQuotaStatus = .unavailable
            scheduleManagerRetry()
        }
    }

    private func scheduleManagerRetry() {
        guard enabled, !stopping, managerRetryTask == nil else { return }
        let delay = OpsailRetryPolicy.delayNanoseconds(
            attempt: managerRetryAttempt)
        managerRetryAttempt = min(managerRetryAttempt + 1, 5)
        managerRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, self.enabled, !self.stopping else { return }
            self.managerRetryTask = nil
            self.settings.codexSidebarQuotaStatus = .attaching
            self.startManagedSession(allowLaunch: false)
        }
    }

    private func disableManagedSession() {
        guard managedSessionRequested || enableProcess != nil else { return }
        guard disableProcess?.isRunning != true else { return }
        cleanupRetryTask?.cancel()
        cleanupRetryTask = nil
        if enableProcess?.isRunning == true {
            enableProcess?.terminate()
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            scheduleCleanupRetry()
            return
        }

        let invocationID = UUID()
        disableInvocationID = invocationID
        let process = launchProcess(
            arguments: OpsailCodexRefitCommand.disable
        ) { [weak self] status, _ in
            guard let self else { return }
            guard self.disableInvocationID == invocationID else { return }
            self.disableInvocationID = nil
            self.disableProcess = nil
            guard OpsailCleanupPolicy.didComplete(status: status) else {
                Log.ui.error(
                    "Opsail Codex cleanup failed with status \(status, privacy: .public)")
                if self.enabled, !self.stopping {
                    self.startManagedSession(allowLaunch: false)
                } else {
                    self.scheduleCleanupRetry()
                }
                return
            }
            self.cleanupRetryAttempt = 0
            self.enableProcess = nil
            self.managedSessionRequested = false
            Log.ui.info("Opsail Codex cleanup completed")
            if self.enabled, !self.stopping {
                self.startManagedSession(allowLaunch: false)
            }
        }
        disableProcess = process
        if process == nil, disableInvocationID == invocationID {
            disableInvocationID = nil
            scheduleCleanupRetry()
        }
    }

    private func scheduleCleanupRetry() {
        guard !enabled, !stopping, managedSessionRequested,
              cleanupRetryTask == nil
        else { return }
        let delay = OpsailRetryPolicy.delayNanoseconds(
            attempt: cleanupRetryAttempt)
        cleanupRetryAttempt = min(cleanupRetryAttempt + 1, 5)
        cleanupRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !self.enabled, !self.stopping else { return }
            self.cleanupRetryTask = nil
            self.disableManagedSession()
        }
    }

    private func launchProcess(
        arguments: [String],
        termination: (@MainActor @Sendable (Int32, String) -> Void)?
    ) -> Process? {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let diagnosticURL = termination.map { _ in
            fileManager.temporaryDirectory
                .appendingPathComponent(
                    "quota-monitor-opsail-\(UUID().uuidString).log")
        }
        let diagnosticHandle: FileHandle?
        if let diagnosticURL {
            fileManager.createFile(
                atPath: diagnosticURL.path,
                contents: nil)
            diagnosticHandle = try? FileHandle(forWritingTo: diagnosticURL)
            process.standardError =
                diagnosticHandle ?? FileHandle.nullDevice
        } else {
            diagnosticHandle = nil
            process.standardError = FileHandle.nullDevice
        }
        if let termination {
            process.terminationHandler = { finished in
                try? diagnosticHandle?.close()
                let diagnostic = diagnosticURL
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    ?? ""
                if let diagnosticURL {
                    try? FileManager.default.removeItem(at: diagnosticURL)
                }
                Task { @MainActor in
                    termination(finished.terminationStatus, diagnostic)
                }
            }
        }
        do {
            try process.run()
            return process
        } catch {
            try? diagnosticHandle?.close()
            if let diagnosticURL {
                try? fileManager.removeItem(at: diagnosticURL)
            }
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

    private func codexIsRunning() -> Bool {
        !supportedCodexApplications().isEmpty
    }

    private func supportedCodexApplications() -> [NSRunningApplication] {
        workspace.runningApplications.filter {
            OpsailCodexApplicationPolicy.isSupported(
                bundleIdentifier: $0.bundleIdentifier)
        }
    }

    private func armAutomaticHandoffTimeout(processIdentifier: pid_t) {
        automaticHandoffTimeoutTask?.cancel()
        automaticHandoffTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.automaticHandoffTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.automaticRestoreState.cancelAwaitingTermination(
                      processIdentifier: processIdentifier)
            else { return }
            self.automaticHandoffTimeoutTask = nil
            Log.ui.info(
                "Codex declined the graceful handoff; leaving the session untouched")
            if self.codexIsRunning() {
                self.settings.codexSidebarQuotaStatus = .attaching
                self.startManagedSession(allowLaunch: false)
            } else {
                self.settings.codexSidebarQuotaStatus = .readyToLaunch
            }
        }
    }

    private func resetAutomaticRestoreState() {
        automaticHandoffTimeoutTask?.cancel()
        automaticHandoffTimeoutTask = nil
        automaticRestoreState.reset()
    }

    private func armManagedLaunchExpectation() {
        expectingManagedCodexLaunch = true
        managedLaunchExpectationTask?.cancel()
        managedLaunchExpectationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds:
                        Self.managedLaunchExpectationTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.managedLaunchExpectationTask = nil
            self.expectingManagedCodexLaunch = false
        }
    }

    private func consumeManagedLaunchExpectation() -> Bool {
        guard expectingManagedCodexLaunch else { return false }
        clearManagedLaunchExpectation()
        return true
    }

    private func clearManagedLaunchExpectation() {
        expectingManagedCodexLaunch = false
        managedLaunchExpectationTask?.cancel()
        managedLaunchExpectationTask = nil
    }

    @objc private func explicitLaunchRequested() {
        guard !stopping else { return }
        resetAutomaticRestoreState()
        let codexIsRunning = codexIsRunning()
        let allowLaunch =
            OpsailCodexActivationPolicy.allowLaunchForExplicitRequest(
                codexIsRunning: codexIsRunning)
        if !enabled {
            enabled = true
            settings.codexSidebarQuotaEnabled = true
        }
        managerRetryTask?.cancel()
        managerRetryTask = nil
        managerRetryAttempt = 0
        settings.codexSidebarQuotaStatus =
            allowLaunch ? .launching : .attaching
        startManagedSession(allowLaunch: allowLaunch)
    }

    @objc private func codexWillLaunch(_ notification: Notification) {
        guard let application =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              enabled,
              automaticRestoreEnabled,
              !stopping,
              OpsailCodexApplicationPolicy.isSupported(
                bundleIdentifier: application.bundleIdentifier)
        else { return }

        if expectingManagedCodexLaunch {
            settings.codexSidebarQuotaStatus = .launching
            return
        }

        let processIdentifier = application.processIdentifier
        guard let alreadyHasDebuggingPort =
                OpsailCodexLaunchArgumentPolicy.alreadyHasDebuggingPort(
                    processIdentifier: processIdentifier)
        else {
            Log.ui.info(
                "Could not inspect newly launched Codex process \(processIdentifier, privacy: .public); skipping automatic handoff")
            return
        }
        guard !alreadyHasDebuggingPort else {
            Log.ui.info(
                "Newly launched Codex process \(processIdentifier, privacy: .public) already has a debugging port")
            return
        }

        let runningProcessIdentifiers =
            supportedCodexApplications().map(\.processIdentifier)
        guard automaticRestoreState.beginPrelaunchHandoff(
            processIdentifier: processIdentifier,
            enabled: automaticRestoreEnabled,
            isManagedLaunch: false,
            runningProcessIdentifiers: runningProcessIdentifiers)
        else {
            Log.ui.info(
                "Skipped automatic handoff because Codex launch ownership was ambiguous")
            return
        }

        guard OpsailCodexTerminationSignal.requestGracefulTermination(
            processIdentifier: processIdentifier)
        else {
            _ = automaticRestoreState.cancelAwaitingTermination(
                processIdentifier: processIdentifier)
            Log.ui.info(
                "Could not send SIGTERM to newly launched Codex process \(processIdentifier, privacy: .public); leaving it untouched")
            return
        }

        managerRetryTask?.cancel()
        managerRetryTask = nil
        settings.codexSidebarQuotaStatus = .launching
        armAutomaticHandoffTimeout(processIdentifier: processIdentifier)
        Log.ui.info(
            "Intercepted newly launched Codex process \(processIdentifier, privacy: .public) before activation")
    }

    @objc private func codexDidTerminate(_ notification: Notification) {
        guard let application =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              enabled,
              !stopping,
              OpsailCodexApplicationPolicy.isSupported(
                bundleIdentifier: application.bundleIdentifier)
        else { return }

        let processIdentifier = application.processIdentifier
        if automaticRestoreState.didTerminate(
            processIdentifier: processIdentifier)
        {
            automaticHandoffTimeoutTask?.cancel()
            automaticHandoffTimeoutTask = nil
            managerRetryTask?.cancel()
            managerRetryTask = nil
            managerRetryAttempt = 0
            settings.codexSidebarQuotaStatus = .launching
            startManagedSession(allowLaunch: true)
            return
        }

        managerRetryTask?.cancel()
        managerRetryTask = nil
        clearManagedLaunchExpectation()
        settings.codexSidebarQuotaStatus = .readyToLaunch
    }

    @objc private func codexDidLaunch(_ notification: Notification) {
        guard let application =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              enabled,
              !stopping,
              OpsailCodexApplicationPolicy.isSupported(
                bundleIdentifier: application.bundleIdentifier)
        else { return }

        let processIdentifier = application.processIdentifier
        if automaticRestoreState.isAwaitingTermination(
            processIdentifier: processIdentifier)
        {
            settings.codexSidebarQuotaStatus = .launching
            return
        }

        let isManagedLaunch = consumeManagedLaunchExpectation()
        if isManagedLaunch {
            settings.codexSidebarQuotaStatus = .launching
            return
        }

        managerRetryTask?.cancel()
        managerRetryTask = nil
        managerRetryAttempt = 0
        settings.codexSidebarQuotaStatus = .attaching
        startManagedSession(allowLaunch: false)
    }
}
