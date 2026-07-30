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

    @Test("only an explicit action may launch a stopped Codex")
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

    @Test("setup copy makes launch ownership explicit")
    func explicitLaunchCopy() {
        LocalizationTestSupport.withLanguage(.english) {
            #expect(L10n.codexCapsuleNeedsQuitStatus.contains("Quit Codex yourself"))
            #expect(L10n.codexCapsuleReadyToLaunchStatus.contains("Open it from here"))
            #expect(L10n.codexCapsuleLaunchButton.contains("Open Codex"))
        }
        LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            #expect(L10n.codexCapsuleNeedsQuitStatus.contains("手动退出 Codex"))
            #expect(L10n.codexCapsuleReadyToLaunchStatus.contains("从这里打开"))
            #expect(L10n.codexCapsuleLaunchButton.contains("打开 Codex"))
        }
    }

    @Test("controller source has no modal or automatic relaunch path")
    func noAutomaticRelaunchSource() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("QuotaMonitor/App/OpsailCodexRefitController.swift"),
            encoding: .utf8)

        #expect(!source.contains("runModal"))
        #expect(!source.contains("awaitingInitialCodexRestart"))
        #expect(!source.contains("relaunchTask"))
        #expect(source.contains(
            "if self.pendingManagerAllowLaunch {\n"
                + "                self.startManagedSession(allowLaunch: true)"))
    }

    @Test("helper retries back off and cap at one minute")
    func retryBackoff() {
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 0) == 2_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 1) == 4_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 4) == 32_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 5) == 60_000_000_000)
        #expect(OpsailRetryPolicy.delayNanoseconds(attempt: 50) == 60_000_000_000)
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
    @Test("new Opsail integration remains off even when the legacy overlay was enabled")
    func isolatedOptInKey() throws {
        let suite = "OpsailCodexRefitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "settings.codexAttachedCapsuleEnabled")
        let initial = SettingsStore(defaults: defaults)
        #expect(initial.codexSidebarQuotaEnabled == false)

        initial.codexSidebarQuotaEnabled = true
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaEnabled == true)
    }
}
