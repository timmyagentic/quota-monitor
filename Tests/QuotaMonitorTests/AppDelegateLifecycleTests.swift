import AppKit
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("App delegate lifecycle")
struct AppDelegateLifecycleTests {

    @Test
    func doesNotTerminateAfterClosingLastWindow() {
        let delegate = AppDelegate()

        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(
            NSApplication.shared) == false)
    }

    @Test("Update state is passed to popover content without native reminder wiring")
    func updateStateStaysOutOfNativeStatusItemLifecycle() throws {
        let source = try Self.source(named: "QuotaMonitor/App/AppDelegate.swift")
        let launch = String(try Self.sourceSlice(
            source,
            from: "func applicationDidFinishLaunching",
            to: "private func closeStrayWindows"))

        let updater = try Self.offset(of: "updater = UpdaterController(", in: launch)
        let controller = try Self.offset(of: "let controller = StatusItemController(", in: launch)
        let stored = try Self.offset(of: "self.statusItemController = controller", in: launch)
        #expect(updater < controller)
        #expect(controller < stored)
        #expect(launch.contains("updater: updater"))
        #expect(!source.contains("startUpdateReminders"))
        #expect(!source.contains("stopUpdateReminders"))
        #expect(!source.contains("pulseUpdateMarker"))
    }

    @Test("App delegate starts anonymous reporting without consent coordination")
    func anonymousReportingStartsAutomatically() throws {
        let source = try Self.source(named: "QuotaMonitor/App/AppDelegate.swift")
        let launch = String(try Self.sourceSlice(
            source,
            from: "func applicationDidFinishLaunching",
            to: "private func closeStrayWindows"))

        #expect(launch.contains("let dailyActiveTokenStore = DailyActiveTokenStore("))
        #expect(launch.contains("DailyActiveReporter(\n            store: dailyActiveTokenStore"))
        #expect(launch.contains("Task { await reporter.start() }"))
        #expect(launch.contains("LocalQAEnvironment.isQARequested()"))
        #expect(!source.contains("AnonymousVersionReportingCoordinator"))
        #expect(!source.contains("AnonymousVersionReportingDisclosure"))
    }

    private static func offset(of needle: String, in source: String) throws -> String.Index {
        guard let range = source.range(of: needle) else {
            throw CocoaError(.formatting)
        }
        return range.lowerBound
    }

    private static func sourceSlice(
        _ source: String,
        from startNeedle: String,
        to endNeedle: String
    ) throws -> Substring {
        guard let start = source.range(of: startNeedle),
              let end = source.range(of: endNeedle, range: start.upperBound..<source.endIndex) else {
            throw CocoaError(.formatting)
        }
        return source[start.lowerBound..<end.lowerBound]
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
