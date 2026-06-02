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
}
