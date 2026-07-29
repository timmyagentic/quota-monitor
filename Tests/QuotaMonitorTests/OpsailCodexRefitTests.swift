import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Opsail Codex refit integration")
struct OpsailCodexRefitTests {
    @Test("managed mode delegates the complete lifecycle to Opsail")
    func managedCommand() {
        #expect(OpsailCodexRefitCommand.managedEnable(allowLaunch: true) == [
            "refit", "codex", "enable", "usage", "--launch", "--foreground"
        ])
        #expect(OpsailCodexRefitCommand.managedEnable(allowLaunch: false) == [
            "refit", "codex", "enable", "usage", "--foreground"
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

    @Test("only the initial opt-in quit relaunches Codex")
    func initialOptInRelaunchPolicy() {
        #expect(!OpsailCodexRelaunchPolicy.shouldArmInitialRestart(
            isInitialObservation: true,
            codexIsRunning: true))
        #expect(OpsailCodexRelaunchPolicy.shouldArmInitialRestart(
            isInitialObservation: false,
            codexIsRunning: true))
        #expect(!OpsailCodexRelaunchPolicy.shouldArmInitialRestart(
            isInitialObservation: false,
            codexIsRunning: false))
        #expect(OpsailCodexRelaunchPolicy.shouldRelaunch(
            enabled: true,
            stopping: false,
            awaitingInitialRestart: true,
            bundleIdentifier: "com.openai.chat"))
        #expect(!OpsailCodexRelaunchPolicy.shouldRelaunch(
            enabled: true,
            stopping: false,
            awaitingInitialRestart: false,
            bundleIdentifier: "com.openai.chat"))
        #expect(!OpsailCodexRelaunchPolicy.shouldRelaunch(
            enabled: false,
            stopping: false,
            awaitingInitialRestart: true,
            bundleIdentifier: "com.openai.chat"))
        #expect(!OpsailCodexRelaunchPolicy.shouldRelaunch(
            enabled: true,
            stopping: true,
            awaitingInitialRestart: true,
            bundleIdentifier: "com.openai.chat"))
        #expect(!OpsailCodexRelaunchPolicy.shouldRelaunch(
            enabled: true,
            stopping: false,
            awaitingInitialRestart: true,
            bundleIdentifier: "com.example.other"))
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
