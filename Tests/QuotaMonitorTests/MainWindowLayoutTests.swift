import Foundation
import Testing

@Suite("Main window layout")
struct MainWindowLayoutTests {

    @Test("Provider filter stays in the titlebar with a stable explicit label")
    func providerFilterKeepsStableTitlebarPlacement() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/MainWindow/MainWindowView.swift")

        #expect(source.contains("ToolbarItem(placement: .navigation)"))
        #expect(source.contains("providerToolbarFilter(selection: $env.providerFilter)"))
        #expect(!source.contains("Picker(\"\", selection: $env.providerFilter)"))
        #expect(!source.contains("line.3.horizontal.decrease.circle"))
    }

    @Test("Available updates stay visible from main and menu surfaces")
    func persistentUpdateBadgeIsExposedOnPrimarySurfaces() throws {
        let mainWindow = try Self.source(named: "QuotaMonitor/Features/MainWindow/MainWindowView.swift")
        let menuBar = try Self.source(named: "QuotaMonitor/Features/MenuBar/MenuBarContentView.swift")
        let windowManager = try Self.source(named: "QuotaMonitor/App/WindowManager.swift")
        let statusItemController = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")

        #expect(mainWindow.contains("persistentUpdateBadge"))
        #expect(mainWindow.contains("updater.installAvailableUpdate()"))
        #expect(menuBar.contains("persistentUpdateBadge"))
        #expect(menuBar.contains("updater.installAvailableUpdate()"))
        #expect(windowManager.contains(".environment(updater)"))
        #expect(statusItemController.contains(".environment(updater)"))
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
