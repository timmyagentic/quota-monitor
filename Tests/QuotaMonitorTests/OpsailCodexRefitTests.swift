import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Opsail Codex refit integration")
struct OpsailCodexRefitTests {
    @Test("managed mode delegates the complete lifecycle to Opsail")
    func managedCommand() {
        #expect(OpsailCodexRefitCommand.managedEnable == [
            "refit", "codex", "enable", "usage", "--launch", "--foreground"
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
