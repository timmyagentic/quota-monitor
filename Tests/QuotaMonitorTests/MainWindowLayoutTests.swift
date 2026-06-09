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

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "quota-monitor" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }
}
