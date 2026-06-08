import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Local QA state report")
struct LocalQAReportTests {
    @Test("Writes app-state JSON into the requested artifact directory")
    func writesStateJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaMonitorQAReportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = LocalQAReport(
            generatedAt: "2026-06-01T00:00:00Z",
            pid: 123,
            bundleIdentifier: "dev.tjzhou.QuotaMonitor",
            qaSteps: ["open-dashboard", "snapshot"],
            databasePath: "/tmp/qa/quotamonitor.sqlite",
            developerLogPath: "/tmp/qa/quotamonitor-dev.log",
            statusItemVisibility: "visible",
            lastError: nil,
            settings: LocalQASettingsReport(
                language: "en",
                enabledProviders: ["claude"],
                menuBarIconProviders: ["claude"],
                menuBarLabelStyle: "native",
                quotaDisplayMode: "remaining",
                showDockIconForWindows: false,
                developerModeEnabled: true,
                pollIntervalSeconds: 900),
            windows: [
                LocalQAWindowReport(
                    title: "Quota Monitor",
                    identifier: "dashboard",
                    isVisible: true,
                    isKeyWindow: false)
            ],
            menuBar: LocalQAMenuBarReport(
                codexEvents: 2,
                codexSessions: 1,
                codexTokens: 290,
                claudeEvents: 1,
                claudeSessions: 1,
                claudeTokens: 42))

        let url = try report.write(to: root)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(LocalQAReport.self, from: data)

        #expect(url.lastPathComponent == "app-state.json")
        #expect(decoded == report)
    }
}
