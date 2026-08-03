import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Opsail Codex refit integration")
struct OpsailCodexRefitTests {
    @Test("managed mode delegates the complete lifecycle to Opsail")
    func managedCommand() {
        #expect(OpsailCodexRefitCommand.managedEnable(allowLaunch: true) == [
            "refit", "codex", "enable", "usage", "--launch"
        ])
        #expect(OpsailCodexRefitCommand.managedEnable(allowLaunch: false) == [
            "refit", "codex", "enable", "usage"
        ])
        #expect(OpsailCodexRefitCommand.disable == [
            "refit", "codex", "disable", "usage"
        ])
    }

    @Test("helper lives in the signed app Helpers directory")
    func helperLocation() {
        let app = URL(fileURLWithPath: "/Applications/QuotaMonitor.app")
        let helper = OpsailHelperLocator.bundledHelperURL(bundleURL: app)
        let renderer = OpsailRendererAssetLocator.bundledAssetsURL(bundleURL: app)

        #expect(helper.path == "/Applications/QuotaMonitor.app/Contents/Helpers/opsail")
        #expect(renderer.path
            == "/Applications/QuotaMonitor.app/Contents/Resources/OpsailRenderer")
    }

    @Test("QuotaMonitor installs its verified renderer bundle atomically")
    func rendererAssetInstall() throws {
        let root = try Self.repositoryRoot()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let installer = OpsailRendererAssetInstaller(
            sourceURL: root.appendingPathComponent("Vendor/Opsail/Renderer"),
            stateRoot: temporary.appendingPathComponent("state"))

        #expect(try installer.installIfNeeded() == .installed)
        #expect(try installer.installIfNeeded() == .unchanged)

        let pointerURL = temporary
            .appendingPathComponent("state/renderer-assets/current.json")
        let pointer = try String(contentsOf: pointerURL, encoding: .utf8)
        #expect(pointer.contains(#""version" : "1.0.1""#))
        #expect(pointer.contains(#""directory" : "quota-monitor-1.0.1-"#))
        #expect(!pointer.contains(".install-"))
        let versions = temporary
            .appendingPathComponent("state/renderer-assets/versions")
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: versions.path).count == 1)
    }

    @Test("a newer Opsail renderer is never downgraded")
    func rendererAssetPreservesNewerVersion() throws {
        let root = try Self.repositoryRoot()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stateRoot = temporary.appendingPathComponent("state")
        let installer = OpsailRendererAssetInstaller(
            sourceURL: root.appendingPathComponent("Vendor/Opsail/Renderer"),
            stateRoot: stateRoot)
        #expect(try installer.installIfNeeded() == .installed)

        let assetRoot = stateRoot
            .appendingPathComponent("renderer-assets", isDirectory: true)
        let pointerURL = assetRoot.appendingPathComponent("current.json")
        let pointerData = try Data(contentsOf: pointerURL)
        let pointerObject = try #require(
            try JSONSerialization.jsonObject(with: pointerData)
                as? [String: Any])
        let directory = try #require(pointerObject["directory"] as? String)
        let selected = assetRoot.appendingPathComponent(
            "versions/\(directory)",
            isDirectory: true)
        let manifestURL = selected.appendingPathComponent("manifest.json")
        var manifest = try String(
            contentsOf: manifestURL,
            encoding: .utf8)
        manifest = manifest.replacingOccurrences(
            of: #""assetVersion": "1.0.1""#,
            with: #""assetVersion": "1.1.0""#)
        manifest = manifest.replacingOccurrences(
            of: #""schemaVersion": 1"#,
            with: #""schemaVersion": 2"#)
        manifest = manifest.replacingOccurrences(
            of: #""apiVersion": 1"#,
            with: #""apiVersion": 2"#)
        try Data(manifest.utf8).write(to: manifestURL)
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "version": "1.1.0",
                "directory": directory,
            ],
            options: [.sortedKeys]
        ).write(to: pointerURL)

        #expect(try installer.installIfNeeded()
            == .preservedNewer(version: "1.1.0"))
    }

    @Test("a corrupted newer renderer is repaired with the verified bundle")
    func rendererAssetRepairsCorruptedNewerVersion() throws {
        let root = try Self.repositoryRoot()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stateRoot = temporary.appendingPathComponent("state")
        let installer = OpsailRendererAssetInstaller(
            sourceURL: root.appendingPathComponent("Vendor/Opsail/Renderer"),
            stateRoot: stateRoot)
        #expect(try installer.installIfNeeded() == .installed)

        let assetRoot = stateRoot
            .appendingPathComponent("renderer-assets", isDirectory: true)
        let pointerURL = assetRoot.appendingPathComponent("current.json")
        let pointerData = try Data(contentsOf: pointerURL)
        let pointerObject = try #require(
            try JSONSerialization.jsonObject(with: pointerData)
                as? [String: Any])
        let installedDirectory = try #require(
            pointerObject["directory"] as? String)
        let versionsRoot = assetRoot
            .appendingPathComponent("versions", isDirectory: true)
        let selected = versionsRoot.appendingPathComponent(
            "opsail-9.0.0",
            isDirectory: true)
        try FileManager.default.copyItem(
            at: versionsRoot.appendingPathComponent(
                installedDirectory,
                isDirectory: true),
            to: selected)

        let manifestURL = selected.appendingPathComponent("manifest.json")
        var manifest = try String(
            contentsOf: manifestURL,
            encoding: .utf8)
        manifest = manifest.replacingOccurrences(
            of: #""assetVersion": "1.0.1""#,
            with: #""assetVersion": "9.0.0""#)
        manifest = manifest.replacingOccurrences(
            of: #""schemaVersion": 1"#,
            with: #""schemaVersion": 9"#)
        try Data(manifest.utf8).write(to: manifestURL)
        let corruptedFile = selected.appendingPathComponent(
            "opsail-refit-codex-usage-runtime.js")
        var corruptedData = try Data(contentsOf: corruptedFile)
        corruptedData.append(Data("\n// corrupt".utf8))
        try corruptedData.write(to: corruptedFile)
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "version": "9.0.0",
                "directory": "opsail-9.0.0",
            ],
            options: [.sortedKeys]
        ).write(to: pointerURL)

        #expect(try installer.installIfNeeded() == .installed)
        let repairedPointer = try String(
            contentsOf: pointerURL,
            encoding: .utf8)
        #expect(repairedPointer.contains(#""version" : "1.0.1""#))
        #expect(repairedPointer.contains(
            #""directory" : "\#(installedDirectory)""#))
    }

    @Test("a broken newer pointer is repaired instead of blocking the widget")
    func rendererAssetRepairsBrokenNewerPointer() throws {
        let root = try Self.repositoryRoot()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let assetRoot = temporary
            .appendingPathComponent("state/renderer-assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetRoot,
            withIntermediateDirectories: true)
        try Data(
            #"{"schemaVersion":1,"version":"9.0.0","directory":"missing"}"#
                .utf8
        ).write(to: assetRoot.appendingPathComponent("current.json"))
        let installer = OpsailRendererAssetInstaller(
            sourceURL: root.appendingPathComponent("Vendor/Opsail/Renderer"),
            stateRoot: temporary.appendingPathComponent("state"))

        #expect(try installer.installIfNeeded() == .installed)
        let pointer = try String(
            contentsOf: assetRoot.appendingPathComponent("current.json"),
            encoding: .utf8)
        #expect(pointer.contains(#""version" : "1.0.1""#))
    }

    @Test("a symlinked renderer store is rejected")
    func rendererAssetRejectsSymlinkedStore() throws {
        let root = try Self.repositoryRoot()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: temporary.appendingPathComponent("state"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: temporary.appendingPathComponent("state/renderer-assets"),
            withDestinationURL: outside)
        let installer = OpsailRendererAssetInstaller(
            sourceURL: root.appendingPathComponent("Vendor/Opsail/Renderer"),
            stateRoot: temporary.appendingPathComponent("state"))

        #expect(throws: OpsailRendererAssetInstallError.self) {
            try installer.installIfNeeded()
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: outside.path).isEmpty)
    }

    @Test("automatic local QA never starts or relaunches an external Codex app")
    func localQAIsolation() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("QuotaMonitor/App/AppDelegate.swift"),
            encoding: .utf8)

        #expect(source.contains(
            "if DistributionChannel.current != .appStore,\n"
                + "           !LocalQAEnvironment.isQARequested()"))
    }

    @Test("an explicit action launches Codex only when it is stopped")
    func activationLaunchPolicy() {
        #expect(!OpsailCodexActivationPolicy.allowLaunchForExplicitRequest(
            codexIsRunning: true))
        #expect(OpsailCodexActivationPolicy.allowLaunchForExplicitRequest(
            codexIsRunning: false))
        #expect(OpsailCodexApplicationPolicy.isSupported(
            bundleIdentifier: "com.openai.chat"))
        #expect(OpsailCodexApplicationPolicy.isSupported(
            bundleIdentifier: "com.openai.codex"))
        #expect(!OpsailCodexApplicationPolicy.isSupported(
            bundleIdentifier: "com.example.other"))
    }

    @Test("automatic restore records only opted-in normal launches")
    func automaticRestoreLaunchRecording() {
        let now = Date()
        var state = OpsailCodexAutomaticRestoreState()

        state.recordLaunch(
            processIdentifier: 41,
            observedAt: now,
            enabled: false,
            isManagedLaunch: false,
            runningProcessIdentifiers: [41])
        #expect(state.freshLaunch == nil)

        state.recordLaunch(
            processIdentifier: 42,
            observedAt: now,
            enabled: true,
            isManagedLaunch: true,
            runningProcessIdentifiers: [42])
        #expect(state.freshLaunch == nil)

        state.recordLaunch(
            processIdentifier: 43,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [42, 43])
        #expect(state.freshLaunch == nil)

        state.recordLaunch(
            processIdentifier: 44,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [44])
        #expect(state.freshLaunch == OpsailCodexLaunchObservation(
            processIdentifier: 44,
            observedAt: now))
    }

    @Test("automatic restore accepts one matching fresh Codex process")
    func automaticRestoreEligibility() {
        let now = Date()
        var state = OpsailCodexAutomaticRestoreState()
        state.recordLaunch(
            processIdentifier: 51,
            observedAt: now.addingTimeInterval(-1),
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [51])

        #expect(state.beginHandoffIfEligible(
            actionableStatus: .needsCodexQuit,
            runningProcessIdentifiers: [51],
            now: now) == 51)
        #expect(state.freshLaunch == nil)
        #expect(state.awaitingTerminationProcessIdentifier == 51)
    }

    @Test("automatic restore rejects stale, mismatched, or multiple processes")
    func automaticRestoreRejectsUnsafeCandidates() {
        let now = Date()
        var state = OpsailCodexAutomaticRestoreState()

        state.recordLaunch(
            processIdentifier: 61,
            observedAt: now.addingTimeInterval(
                -OpsailCodexAutomaticRestoreState.maximumFreshLaunchAge - 0.1),
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [61])
        #expect(state.beginHandoffIfEligible(
            actionableStatus: .needsCodexQuit,
            runningProcessIdentifiers: [61],
            now: now) == nil)

        state.recordLaunch(
            processIdentifier: 62,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [62])
        #expect(state.beginHandoffIfEligible(
            actionableStatus: .needsCodexQuit,
            runningProcessIdentifiers: [99],
            now: now) == nil)

        state.recordLaunch(
            processIdentifier: 63,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [63])
        #expect(state.beginHandoffIfEligible(
            actionableStatus: .needsCodexQuit,
            runningProcessIdentifiers: [63, 64],
            now: now) == nil)

        state.recordLaunch(
            processIdentifier: 65,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [65])
        #expect(state.beginHandoffIfEligible(
            actionableStatus: .readyToLaunch,
            runningProcessIdentifiers: [65],
            now: now) == nil)
    }

    @Test("only the exact graceful termination launches once")
    func automaticRestoreTerminationMatching() {
        let now = Date()
        var state = OpsailCodexAutomaticRestoreState()
        state.recordLaunch(
            processIdentifier: 71,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [71])
        #expect(state.beginHandoffIfEligible(
            actionableStatus: .needsCodexQuit,
            runningProcessIdentifiers: [71],
            now: now) == 71)

        let wrongTermination = state.didTerminate(processIdentifier: 72)
        let matchingTermination = state.didTerminate(processIdentifier: 71)
        let repeatedTermination = state.didTerminate(processIdentifier: 71)
        #expect(!wrongTermination)
        #expect(matchingTermination)
        #expect(!repeatedTermination)
    }

    @Test("a timed-out graceful handoff cannot relaunch Codex later")
    func automaticRestoreCancellation() {
        let now = Date()
        var state = OpsailCodexAutomaticRestoreState()
        state.recordLaunch(
            processIdentifier: 81,
            observedAt: now,
            enabled: true,
            isManagedLaunch: false,
            runningProcessIdentifiers: [81])
        #expect(state.beginHandoffIfEligible(
            actionableStatus: .needsCodexQuit,
            runningProcessIdentifiers: [81],
            now: now) == 81)

        let wrongCancellation = state.cancelAwaitingTermination(
            processIdentifier: 82)
        let matchingCancellation = state.cancelAwaitingTermination(
            processIdentifier: 81)
        let lateTermination = state.didTerminate(processIdentifier: 81)
        #expect(!wrongCancellation)
        #expect(matchingCancellation)
        #expect(!lateTermination)
    }

    @Test("attach failure maps to a user-owned next action")
    func attachFailureStatus() {
        #expect(OpsailCodexActivationPolicy.actionableStatus(
            status: 1,
            diagnostic: "[opsail-refit-codex:session-unavailable] no loopback listener",
            codexIsRunning: true) == .needsCodexQuit)
        #expect(OpsailCodexActivationPolicy.actionableStatus(
            status: 1,
            diagnostic: "[opsail-refit-codex:session-unavailable] no loopback listener",
            codexIsRunning: false) == .readyToLaunch)
        #expect(OpsailCodexActivationPolicy.actionableStatus(
            status: 1,
            diagnostic: "[opsail-refit-codex:restart-required] relaunch with CDP",
            codexIsRunning: false) == .readyToLaunch)
        #expect(OpsailCodexActivationPolicy.actionableStatus(
            status: 1,
            diagnostic: "validation failed",
            codexIsRunning: true) == nil)
        #expect(OpsailCodexActivationPolicy.actionableStatus(
            status: 0,
            diagnostic: "[opsail-refit-codex:session-unavailable] no loopback listener",
            codexIsRunning: true) == nil)
    }

    @Test("cleanup preserves a pending one-shot launch request")
    func pendingLaunchIntent() {
        #expect(OpsailCodexActivationPolicy.preserveLaunchIntent(
            pendingAllowLaunch: false,
            requestedAllowLaunch: true))
        #expect(OpsailCodexActivationPolicy.preserveLaunchIntent(
            pendingAllowLaunch: true,
            requestedAllowLaunch: false))
        #expect(!OpsailCodexActivationPolicy.preserveLaunchIntent(
            pendingAllowLaunch: false,
            requestedAllowLaunch: false))
    }

    @Test("setup copy explains the bounded automatic handoff")
    func automaticRestoreCopy() {
        LocalizationTestSupport.withLanguage(.english) {
            #expect(L10n.codexCapsuleSettingsHelp.contains("normal icon"))
            #expect(L10n.codexCapsuleAutoRestoreHelp.contains("newly launched"))
            #expect(L10n.codexCapsuleAutoRestoreHelp.contains("never force-quit"))
            #expect(L10n.codexCapsuleNeedsQuitStatus.contains(
                "Automatic restore was not available"))
            #expect(L10n.codexCapsuleReadyToLaunchStatus.contains("Open it from here"))
            #expect(L10n.codexCapsuleLaunchButton.contains("Open Codex"))
        }
        LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            #expect(L10n.codexCapsuleSettingsHelp.contains("原来的图标"))
            #expect(L10n.codexCapsuleAutoRestoreHelp.contains("刚启动"))
            #expect(L10n.codexCapsuleAutoRestoreHelp.contains("绝不会强制退出"))
            #expect(L10n.codexCapsuleNeedsQuitStatus.contains("无法自动恢复"))
            #expect(L10n.codexCapsuleReadyToLaunchStatus.contains("从这里打开"))
            #expect(L10n.codexCapsuleLaunchButton.contains("打开 Codex"))
        }
    }

    @Test("controller uses a graceful handoff and never force-quits Codex")
    func gracefulAutomaticRestoreSource() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("QuotaMonitor/App/OpsailCodexRefitController.swift"),
            encoding: .utf8)

        #expect(!source.contains("runModal"))
        #expect(source.contains("guard application.terminate() else"))
        #expect(source.contains("beginAutomaticRestoreIfEligible"))
        #expect(!source.contains("forceTerminate"))
    }

    @Test("helper retries back off and cap at one minute")
    func retryBackoff() {
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 0) == 2_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 1) == 4_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 4) == 32_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 5) == 60_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 50) == 60_000_000_000)
    }

    @Test("renderer preparation failures retain launch intent and retry")
    func rendererFailureRetrySource() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("QuotaMonitor/App/OpsailCodexRefitController.swift"),
            encoding: .utf8)
        let installStart = try #require(source.range(
            of: "let outcome = try rendererAssetInstaller.installIfNeeded()"))
        let installEnd = try #require(source.range(
            of: "managerRetryTask?.cancel()",
            range: installStart.lowerBound..<source.endIndex))
        let failureBranch = source[
            installStart.lowerBound..<installEnd.lowerBound]

        #expect(failureBranch.contains(
            "requestedAllowLaunch: effectiveAllowLaunch)"))
        #expect(failureBranch.contains(
            "Opsail renderer assets unavailable:"))
        #expect(failureBranch.contains("scheduleManagerRetry()"))
    }

    @Test("cleanup finalizes only after a successful disable")
    func cleanupCompletionPolicy() {
        #expect(OpsailCleanupPolicy.didComplete(status: 0))
        #expect(!OpsailCleanupPolicy.didComplete(status: 1))
        #expect(!OpsailCleanupPolicy.didComplete(status: -1))
        #expect(OpsailCleanupPolicy.canStartManager(
            disableInvocationPending: false,
            disableProcessPresent: false))
        #expect(!OpsailCleanupPolicy.canStartManager(
            disableInvocationPending: true,
            disableProcessPresent: false))
        #expect(!OpsailCleanupPolicy.canStartManager(
            disableInvocationPending: false,
            disableProcessPresent: true))
    }

    @Test("Codex sidebar help follows the configured brand")
    func brandedHelp() {
        LocalizationTestSupport.withLanguage(.english) {
            #expect(L10n.codexCapsuleSettingsHelp.contains(Branding.appDisplayName))
        }
        LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            #expect(L10n.codexCapsuleSettingsHelp.contains(Branding.appDisplayName))
        }
    }

    private static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

@MainActor
@Suite("Codex sidebar quota setting")
struct CodexSidebarQuotaSettingTests {
    @Test("widget and automatic restore require independent opt-ins")
    func isolatedOptInKey() throws {
        let suite = "OpsailCodexRefitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "settings.codexAttachedCapsuleEnabled")
        let initial = SettingsStore(defaults: defaults)
        #expect(initial.codexSidebarQuotaEnabled == false)
        #expect(initial.codexSidebarQuotaAutoRestoreEnabled == false)

        initial.codexSidebarQuotaEnabled = true
        initial.codexSidebarQuotaAutoRestoreEnabled = true
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaEnabled == true)
        #expect(SettingsStore(defaults: defaults)
            .codexSidebarQuotaAutoRestoreEnabled == true)
    }
}
