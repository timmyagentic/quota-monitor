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

    @Test("Persisted update state renders before overdue reminder presentation starts")
    func reminderStartsOnlyAfterStatusControllerIsStored() throws {
        let source = try Self.source(named: "QuotaMonitor/App/AppDelegate.swift")
        let launch = String(try Self.sourceSlice(
            source,
            from: "func applicationDidFinishLaunching",
            to: "private func closeStrayWindows"))

        let updater = try Self.offset(of: "updater = UpdaterController(", in: launch)
        let controller = try Self.offset(of: "let controller = StatusItemController(", in: launch)
        let stored = try Self.offset(of: "self.statusItemController = controller", in: launch)
        let reminders = try Self.offset(of: "updater.startUpdateReminders", in: launch)
        #expect(updater < controller)
        #expect(controller < stored)
        #expect(stored < reminders)

        let reminderWiring = String(launch[reminders...])
        #expect(reminderWiring.contains("[weak controller]"))
        #expect(reminderWiring.contains("controller?.pulseUpdateMarker(version: version)"))
    }

    @Test("Application termination stops reminder scheduling")
    func terminationStopsUpdateReminders() throws {
        let source = try Self.source(named: "QuotaMonitor/App/AppDelegate.swift")
        let termination = String(try Self.sourceSlice(
            source,
            from: "func applicationWillTerminate",
            to: "func applicationShouldTerminateAfterLastWindowClosed"))

        let reminders = try Self.offset(of: "updater?.stopUpdateReminders()", in: termination)
        let statusItem = try Self.offset(of: "statusItemController?.stop()", in: termination)
        let release = try Self.offset(of: "statusItemController = nil", in: termination)
        #expect(reminders < statusItem)
        #expect(statusItem < release)
    }

    @Test("App delegate wires one token store through reporter, suppression, and termination")
    func anonymousReportingUsesOneStoreAndStopsAtTermination() throws {
        let source = try Self.source(named: "QuotaMonitor/App/AppDelegate.swift")
        let launch = String(try Self.sourceSlice(
            source,
            from: "func applicationDidFinishLaunching",
            to: "private func closeStrayWindows"))
        let termination = String(try Self.sourceSlice(
            source,
            from: "func applicationWillTerminate",
            to: "func applicationShouldTerminateAfterLastWindowClosed"))

        #expect(launch.contains("let dailyActiveTokenStore = DailyActiveTokenStore("))
        #expect(launch.contains("DailyActiveReporter(\n            store: dailyActiveTokenStore"))
        #expect(launch.contains("dailyActiveTokenStore.suppressUntilNextUTCDay"))
        #expect(launch.contains("anonymousVersionReportingCoordinator?.launch()"))
        #expect(termination.contains("anonymousVersionReportingCoordinator?.terminate()"))
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
