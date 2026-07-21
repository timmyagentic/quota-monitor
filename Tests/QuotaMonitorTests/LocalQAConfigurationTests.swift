import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Local QA launch configuration")
struct LocalQAConfigurationTests {
    private func writeConfig(_ json: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-qa-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("qa-config.json", isDirectory: false)
        try json.data(using: .utf8)?.write(to: url)
        return url
    }

    @Test("Disabled when QA mode flag is absent")
    func disabledWithoutModeFlag() {
        #expect(LocalQAConfiguration(environment: [:]) == nil)
    }

    @Test("Parses explicit QA steps and output directory")
    func parsesStepsAndOutputDirectory() throws {
        let config = try #require(LocalQAConfiguration(environment: [
            "QUOTAMONITOR_QA_MODE": "1",
            "QUOTAMONITOR_QA_OUTPUT_DIR": "/tmp/qm-qa",
            "QUOTAMONITOR_QA_STEPS": "open-dashboard,open-whats-new,exercise-settings,snapshot,quit"
        ]))

        #expect(config.outputDirectory.path == "/tmp/qm-qa")
        #expect(config.steps == [
            .openDashboard,
            .openWhatsNew,
            .exerciseSettings,
            .snapshot,
            .quit
        ])
    }

    @Test("Uses deterministic defaults when only QA mode is enabled")
    func defaultsForModeOnly() throws {
        let config = try #require(LocalQAConfiguration(environment: [
            "QUOTAMONITOR_QA_MODE": "1"
        ]))

        #expect(config.steps == [
            .openDashboard,
            .openSettings,
            .openMenuBarHelp,
            .showPopover,
            .refreshAll,
            .exerciseSettings,
            .wait,
            .snapshot
        ])
        #expect(config.outputDirectory.path.hasSuffix("/QuotaMonitorQA"))
    }

    @Test("Parses QA launch config passed through command line arguments")
    func parsesLaunchConfigArgument() throws {
        let configFile = try writeConfig("""
        {
          "mode": true,
          "home": "/tmp/qm-qa-home",
          "defaultsSuite": "dev.tjzhou.QuotaMonitor.QATest",
          "codexHome": "/tmp/qm-qa-home/.codex",
          "outputDirectory": "/tmp/qm-qa-artifacts",
          "mockCodexResetCredits": true,
          "steps": ["open-dashboard", "exercise-settings", "snapshot", "quit"]
        }
        """)

        let config = try #require(LocalQAConfiguration(
            environment: [:],
            arguments: ["QuotaMonitor", "--quotamonitor-qa-config", configFile.path]))

        #expect(config.outputDirectory.path == "/tmp/qm-qa-artifacts")
        #expect(config.steps == [.openDashboard, .exerciseSettings, .snapshot, .quit])
        #expect(config.mockCodexResetCredits)
    }

    @Test("Parses inline base64 QA launch config without file IO")
    func parsesInlineBase64LaunchConfigArgument() throws {
        let payload = """
        {
          "mode": true,
          "home": "/tmp/qm-qa-inline-home",
          "defaultsSuite": "dev.tjzhou.QuotaMonitor.QAInline",
          "codexHome": "/tmp/qm-qa-inline-home/.codex",
          "outputDirectory": "/tmp/qm-qa-inline-artifacts",
          "steps": ["exercise-settings", "snapshot"]
        }
        """
        let encoded = Data(payload.utf8).base64EncodedString()

        let config = try #require(LocalQAConfiguration(
            environment: [:],
            arguments: ["QuotaMonitor", "--quotamonitor-qa-config-base64", encoded]))

        #expect(config.outputDirectory.path == "/tmp/qm-qa-inline-artifacts")
        #expect(config.steps == [.exerciseSettings, .snapshot])
        #expect(config.mockCodexResetCredits == false)
    }

    @Test("Rejects unknown QA steps instead of silently skipping them")
    func rejectsUnknownStep() {
        #expect(LocalQAConfiguration(environment: [
            "QUOTAMONITOR_QA_MODE": "1",
            "QUOTAMONITOR_QA_STEPS": "snapshot,typo"
        ]) == nil)
    }

    @Test("Rejects unknown QA steps from launch config")
    func rejectsUnknownStepFromLaunchConfig() throws {
        let configFile = try writeConfig("""
        {
          "mode": true,
          "outputDirectory": "/tmp/qm-qa-artifacts",
          "steps": ["snapshot", "typo"]
        }
        """)

        #expect(LocalQAConfiguration(
            environment: [:],
            arguments: ["QuotaMonitor", "--quotamonitor-qa-config", configFile.path]) == nil)
    }
}
