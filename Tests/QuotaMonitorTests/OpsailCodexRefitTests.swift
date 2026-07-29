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

        #expect(helper.path == "/Applications/QuotaMonitor.app/Contents/Helpers/opsail")
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
