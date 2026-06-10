import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Local QA isolation")
struct LocalQAIsolationTests {
    private func writeConfig(_ json: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-qa-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("qa-config.json", isDirectory: false)
        try json.data(using: .utf8)?.write(to: url)
        return url
    }

    private func inlineConfigArguments(home: String, codexHome: String? = nil) -> [String] {
        let codexHomeEntry = codexHome.map { #","codexHome":"\#($0)""# } ?? ""
        let json = #"{"mode":true,"home":"\#(home)"\#(codexHomeEntry)}"#
        let encoded = Data(json.utf8).base64EncodedString()
        return ["QuotaMonitor", "--quotamonitor-qa-config-base64", encoded]
    }

    @Test("QA home redirects application support into the harness profile")
    func qaHomeRedirectsApplicationSupport() throws {
        let dir = LocalQAEnvironment.applicationSupportDirectory(environment: [
            "QUOTAMONITOR_QA_HOME": "/tmp/qm-qa-home"
        ])

        #expect(dir.path == "/tmp/qm-qa-home/Library/Application Support")
    }

    @Test("QA defaults suite uses a separate preferences domain")
    func qaDefaultsSuiteUsesSeparateDomain() throws {
        let suiteName = "dev.tjzhou.QuotaMonitor.QATest.\(UUID().uuidString)"
        let defaults = try #require(LocalQAEnvironment.userDefaults(environment: [
            "QUOTAMONITOR_QA_DEFAULTS_SUITE": suiteName
        ]))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "marker.\(UUID().uuidString)"
        defaults.set("qa", forKey: key)

        #expect(UserDefaults.standard.string(forKey: key) == nil)
        #expect(UserDefaults(suiteName: suiteName)?.string(forKey: key) == "qa")
    }

    @Test("QA defaults suite refuses the installed app preferences domain")
    func qaDefaultsSuiteRefusesInstalledAppDomain() throws {
        let key = "qa.production-guard.\(UUID().uuidString)"
        let json = #"{"mode":true,"home":"/tmp/qm-qa-prod-guard","defaultsSuite":"dev.tjzhou.QuotaMonitor"}"#
        let arguments = [
            "QuotaMonitor",
            "--quotamonitor-qa-config-base64",
            Data(json.utf8).base64EncodedString()
        ]
        let defaults = try #require(LocalQAEnvironment.userDefaults(
            environment: [:],
            arguments: arguments))
        let fallback = try #require(UserDefaults(
            suiteName: LocalQAEnvironment.invalidQADefaultsSuite))
        defer {
            defaults.removeObject(forKey: key)
            fallback.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }

        defaults.set("qa", forKey: key)

        #expect(UserDefaults.standard.string(forKey: key) == nil)
        #expect(UserDefaults(suiteName: "dev.tjzhou.QuotaMonitor")?.string(forKey: key) == nil)
        #expect(fallback.string(forKey: key) == "qa")
    }

    @Test("Launch config activates QA isolation without environment variables")
    func launchConfigActivatesIsolationWithoutEnvironmentVariables() throws {
        let configFile = try writeConfig("""
        {
          "mode": true,
          "home": "/tmp/qm-qa-config-home",
          "defaultsSuite": "dev.tjzhou.QuotaMonitor.QA.Config",
          "outputDirectory": "/tmp/qm-qa-config-artifacts"
        }
        """)
        let arguments = ["QuotaMonitor", "--quotamonitor-qa-config", configFile.path]

        #expect(LocalQAEnvironment.isActive(environment: [:], arguments: arguments))
        #expect(LocalQAEnvironment.homeDirectory(environment: [:], arguments: arguments).path == "/tmp/qm-qa-config-home")
        #expect(LocalQAEnvironment.applicationSupportDirectory(environment: [:], arguments: arguments).path == "/tmp/qm-qa-config-home/Library/Application Support")
        #expect(LocalQAEnvironment.codexHomeDirectory(environment: [:], arguments: arguments)?.path == "/tmp/qm-qa-config-home/.codex")
    }

    @Test("Launch config disables external data sources")
    func launchConfigDisablesExternalDataSources() {
        let arguments = inlineConfigArguments(home: "/tmp/qm-qa-data-sources")

        #expect(LocalQAEnvironment.allowsExternalDataSources(
            environment: [:],
            arguments: arguments) == false)
        #expect(LocalQAEnvironment.allowsExternalDataSources(
            environment: [:],
            arguments: ["QuotaMonitor"]) == true)
    }

    @Test("Launch config prepares process environment overrides")
    func launchConfigPreparesProcessEnvironmentOverrides() {
        let arguments = inlineConfigArguments(home: "/tmp/qm-qa-home")

        let overrides = LocalQAEnvironment.processEnvironmentOverrides(
            environment: ["HOME": "/Users/real-user"],
            arguments: arguments)

        #expect(overrides["HOME"] == "/tmp/qm-qa-home")
        #expect(overrides["CODEX_HOME"] == "/tmp/qm-qa-home/.codex")
    }

    @Test("QA settings snapshot reads the isolated defaults suite")
    func qaSettingsSnapshotReadsIsolatedDefaultsSuite() throws {
        let suiteName = "dev.tjzhou.QuotaMonitor.QATest.\(UUID().uuidString)"
        let json = #"{"mode":true,"home":"/tmp/qm-qa-settings","defaultsSuite":"\#(suiteName)"}"#
        let arguments = [
            "QuotaMonitor",
            "--quotamonitor-qa-config-base64",
            Data(json.utf8).base64EncodedString()
        ]
        let defaults = try #require(LocalQAEnvironment.userDefaults(
            environment: [:],
            arguments: arguments))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["claude"], forKey: "settings.enabledProviders")
        defaults.set(900, forKey: "settings.pollIntervalSeconds")
        defaults.set(true, forKey: "onboarding.providersDone")

        let snap = SettingsStore.snapshot(environment: [:], arguments: arguments)

        #expect(snap.enabledProviders == ["claude"])
        #expect(snap.pollIntervalSeconds == 900)
        #expect(snap.hasCompletedProviderOnboarding)
    }

    @Test("QA launch disables pricing refreshes")
    func qaLaunchDisablesPricingRefreshes() {
        let arguments = inlineConfigArguments(home: "/tmp/qm-qa-pricing")

        #expect(AppEnvironment.allowsPricingRefresh(
            environment: [:],
            arguments: arguments) == false)
        #expect(AppEnvironment.allowsPricingRefresh(
            environment: [:],
            arguments: ["QuotaMonitor"]) == true)
    }

    @Test("QA Claude credentials path stays under QA home")
    func qaClaudeCredentialsPathUsesQAHome() {
        let arguments = inlineConfigArguments(home: "/tmp/qm-qa-claude-home")

        let path = ClaudeUsageClient.credentialsFilePath(
            environment: ["HOME": "/Users/real-user"],
            arguments: arguments)

        #expect(path == "/tmp/qm-qa-claude-home/.claude/.credentials.json")
    }

    @Test("QA Codex child environment uses QA home and CODEX_HOME")
    func qaCodexChildEnvironmentUsesQAHome() {
        let arguments = inlineConfigArguments(
            home: "/tmp/qm-qa-codex-home",
            codexHome: "/tmp/qm-qa-codex-home/.codex")

        let env = AppServerClient.augmentedEnvironment(
            environment: [
                "HOME": "/Users/real-user",
                "PATH": "/usr/bin",
                "SHELL": "/bin/zsh",
            ],
            arguments: arguments,
            loginShellPath: nil)

        #expect(env["HOME"] == "/tmp/qm-qa-codex-home")
        #expect(env["CODEX_HOME"] == "/tmp/qm-qa-codex-home/.codex")
        #expect(env["PATH"]?.contains("/tmp/qm-qa-codex-home/.npm-global/bin") == true)
    }
}
