import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Local QA isolation")
struct LocalQAIsolationTests {
    private let pendingUpdateStorageKey = "app.pendingUpdateSnapshot.v1"

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

    @Test("Any QA marker is requested regardless of its value or validity")
    func qaRequestDetectionFailsClosed() {
        #expect(LocalQAEnvironment.isQARequested(
            environment: ["QUOTAMONITOR_QA_MODE": "0"],
            arguments: ["QuotaMonitor"]))
        #expect(LocalQAEnvironment.isQARequested(
            environment: ["QUOTAMONITOR_QA_BROKEN": "anything"],
            arguments: ["QuotaMonitor"]))
        #expect(LocalQAEnvironment.isQARequested(
            environment: [:],
            arguments: ["QuotaMonitor", "--quotamonitor-qa-config"]))
        #expect(LocalQAEnvironment.isQARequested(
            environment: [:],
            arguments: ["QuotaMonitor", "--quotamonitor-qa-malformed=value"]))
        #expect(LocalQAEnvironment.isQARequested(
            environment: ["CODEX_HOME": "/tmp/codex"],
            arguments: ["QuotaMonitor"]) == false)
    }

    @Test("Malformed and explicitly false QA requests isolate defaults and external data")
    func malformedQARequestsFailClosed() throws {
        let cases: [([String: String], [String])] = [
            (["QUOTAMONITOR_QA_MODE": "false"], ["QuotaMonitor"]),
            ([:], ["QuotaMonitor", "--quotamonitor-qa-config"]),
            ([:], ["QuotaMonitor", "--quotamonitor-qa-config-base64=not-base64"]),
        ]

        for (index, testCase) in cases.enumerated() {
            let key = "malformed-qa.\(index).\(UUID().uuidString)"
            let defaults = try #require(LocalQAEnvironment.userDefaults(
                environment: testCase.0,
                arguments: testCase.1))
            let invalid = try #require(UserDefaults(
                suiteName: LocalQAEnvironment.invalidQADefaultsSuite))
            defer {
                defaults.removeObject(forKey: key)
                invalid.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: key)
            }

            defaults.set("isolated", forKey: key)

            #expect(UserDefaults.standard.string(forKey: key) == nil)
            #expect(invalid.string(forKey: key) == "isolated")
            #expect(LocalQAEnvironment.allowsExternalDataSources(
                environment: testCase.0,
                arguments: testCase.1) == false)
        }
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
            "QUOTAMONITOR_QA_MODE": "1",
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

    @MainActor
    @Test("Updater runtime restores only its supplied suite and disables external update UI in QA and App Store")
    func updaterRuntimeRespectsDistributionAndQABoundaries() throws {
        let productionName = "UpdaterRuntime.production.\(UUID().uuidString)"
        let qaName = "dev.tjzhou.QuotaMonitor.QATest.UpdaterRuntime.\(UUID().uuidString)"
        let productionDefaults = try #require(UserDefaults(suiteName: productionName))
        let qaDefaults = try #require(UserDefaults(suiteName: qaName))
        defer {
            productionDefaults.removePersistentDomain(forName: productionName)
            qaDefaults.removePersistentDomain(forName: qaName)
        }
        let productionSnapshot = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41",
            phase: .available,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            nextReminderAt: Date(timeIntervalSince1970: 200),
            deliveredReminderCount: 0)
        let qaSnapshot = PendingUpdateSnapshot(
            internalVersion: "42",
            displayVersion: "0.2.42-qa",
            phase: .readyToInstall,
            firstSeenAt: Date(timeIntervalSince1970: 300),
            nextReminderAt: Date(timeIntervalSince1970: 400),
            deliveredReminderCount: 1)
        productionDefaults.set(
            try JSONEncoder().encode(productionSnapshot),
            forKey: pendingUpdateStorageKey)
        let qaStoredData = try JSONEncoder().encode(qaSnapshot)
        qaDefaults.set(qaStoredData, forKey: pendingUpdateStorageKey)

        let production = UpdaterController.makeRuntimeConfiguration(
            distribution: .developerID,
            defaults: productionDefaults,
            currentInternalVersion: "40",
            localQARequested: false)
        #expect(production.updateAvailability.snapshot == productionSnapshot)
        #expect(production.sparkleEnabled)
        #expect(production.reminderPresentationEnabled)

        let qa = UpdaterController.makeRuntimeConfiguration(
            distribution: .developerID,
            defaults: qaDefaults,
            currentInternalVersion: "40",
            localQARequested: true)
        #expect(qa.updateAvailability.snapshot == qaSnapshot)
        #expect(qa.updateAvailability.snapshot != productionSnapshot)
        #expect(!qa.sparkleEnabled)
        #expect(!qa.reminderPresentationEnabled)

        let appStore = UpdaterController.makeRuntimeConfiguration(
            distribution: .appStore,
            defaults: qaDefaults,
            currentInternalVersion: "40",
            localQARequested: false)
        #expect(appStore.updateAvailability.snapshot == nil)
        #expect(!appStore.sparkleEnabled)
        #expect(!appStore.reminderPresentationEnabled)
        appStore.updateAvailability.recordDiscovery(
            internalVersion: "43",
            displayVersion: "0.2.43",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 500))
        appStore.updateAvailability.markLater(now: Date(timeIntervalSince1970: 500))
        #expect(qaDefaults.data(forKey: pendingUpdateStorageKey) == qaStoredData)
    }

    @MainActor
    @Test("Any requested QA marker disables the updater default runtime")
    func updaterDefaultRuntimeFailsClosedForEveryQARequest() throws {
        let standardName = "UpdaterRuntime.requestedQA.\(UUID().uuidString)"
        let standardDefaults = try #require(UserDefaults(suiteName: standardName))
        defer { standardDefaults.removePersistentDomain(forName: standardName) }
        let cases: [([String: String], [String])] = [
            (["QUOTAMONITOR_QA_MODE": "false"], ["QuotaMonitor"]),
            ([:], ["QuotaMonitor", "--quotamonitor-qa-config-base64=not-base64"]),
        ]

        for (environment, arguments) in cases {
            let requested = LocalQAEnvironment.isQARequested(
                environment: environment,
                arguments: arguments)
            #expect(requested)
            #expect(LocalQAEnvironment.isActive(
                environment: environment,
                arguments: arguments) == false)

            let runtime = UpdaterController.makeDefaultRuntimeConfiguration(
                distribution: .developerID,
                defaults: LocalQAEnvironment.userDefaults(
                    environment: environment,
                    arguments: arguments),
                standardDefaults: standardDefaults,
                currentInternalVersion: "40",
                localQARequested: requested)

            #expect(!runtime.sparkleEnabled)
            #expect(!runtime.reminderPresentationEnabled)
        }

        let source = try Self.source(
            named: "QuotaMonitor/Core/Updater/UpdaterController.swift")
        #expect(source.contains(
            "localQARequested: LocalQAEnvironment.isQARequested())"))
        #expect(!source.contains(
            "localQARequested: LocalQAEnvironment.isActive())"))
    }

    @MainActor
    @Test("QA without isolated defaults fails closed without reading or writing standard defaults")
    func updaterRuntimeFailsClosedWhenQADefaultsAreUnavailable() throws {
        let standardName = "UpdaterRuntime.standard.\(UUID().uuidString)"
        let standardDefaults = try #require(UserDefaults(suiteName: standardName))
        defer { standardDefaults.removePersistentDomain(forName: standardName) }
        let productionSnapshot = PendingUpdateSnapshot(
            internalVersion: "41",
            displayVersion: "0.2.41-production",
            phase: .available,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            nextReminderAt: Date(timeIntervalSince1970: 200),
            deliveredReminderCount: 0)
        let productionData = try JSONEncoder().encode(productionSnapshot)
        standardDefaults.set(productionData, forKey: pendingUpdateStorageKey)

        let qa = UpdaterController.makeDefaultRuntimeConfiguration(
            distribution: .developerID,
            defaults: nil,
            standardDefaults: standardDefaults,
            currentInternalVersion: "40",
            localQARequested: true)

        #expect(qa.updateAvailability.snapshot == nil)
        #expect(!qa.sparkleEnabled)
        #expect(!qa.reminderPresentationEnabled)
        qa.updateAvailability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42-qa",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 300))
        qa.updateAvailability.markLater(now: Date(timeIntervalSince1970: 300))
        #expect(standardDefaults.data(forKey: pendingUpdateStorageKey) == productionData)
    }

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
