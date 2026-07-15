import AppKit
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Status item popover window")
struct StatusItemControllerTests {

    @Test("Observation does not retain the status item controller without a mutation")
    func observationAllowsControllerTeardownWithoutMutation() throws {
        let defaultsName = "StatusItemControllerTests.teardown.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        weak var weakController: StatusItemController?

        autoreleasepool {
            let availability = PersistentUpdateAvailability()
            let runtime = UpdaterController.RuntimeConfiguration(
                updateAvailability: availability,
                sparkleEnabled: false,
                reminderPresentationEnabled: false)
            let updater = UpdaterController(runtimeConfiguration: runtime)
            let controller = StatusItemController(
                env: AppEnvironment(startBackgroundTasks: false),
                localization: .shared,
                settings: SettingsStore(defaults: defaults, hasExistingAppData: { false }),
                updater: updater)
            weakController = controller
            controller.stop()
            controller.stop()
        }

        #expect(weakController == nil)
    }

    @Test("Update marker pulses for eight seconds, repeat restarts it, and mismatch does nothing")
    func updateMarkerPulseIsVersionScopedAndRestartable() async throws {
        let availability = PersistentUpdateAvailability()
        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 100))
        let runtime = UpdaterController.RuntimeConfiguration(
            updateAvailability: availability,
            sparkleEnabled: false,
            reminderPresentationEnabled: false)
        let updater = UpdaterController(runtimeConfiguration: runtime)
        let defaultsName = "StatusItemControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sleeper = ControlledStatusItemSleeper()
        let controller = StatusItemController(
            env: AppEnvironment(startBackgroundTasks: false),
            localization: .shared,
            settings: SettingsStore(defaults: defaults, hasExistingAppData: { false }),
            updater: updater,
            pulseSleep: { duration in try await sleeper.sleep(duration) })
        defer { controller.stop() }

        controller.pulseUpdateMarker(version: "0.2.42")
        await Task.yield()
        #expect(!controller.updateMarkerIsEmphasized)
        #expect(await sleeper.requestedDurations().isEmpty)

        controller.pulseUpdateMarker(version: "0.2.41")
        #expect(controller.updateMarkerIsEmphasized)
        let firstDurations = await waitForRequests(1, from: sleeper)
        #expect(firstDurations == [.seconds(8)])

        availability.recordDiscovery(
            internalVersion: "42",
            displayVersion: "0.2.42",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 200))
        await Task.yield()
        #expect(!controller.updateMarkerIsEmphasized)

        availability.recordDiscovery(
            internalVersion: "41",
            displayVersion: "0.2.41",
            userInitiated: false,
            now: Date(timeIntervalSince1970: 300))

        controller.pulseUpdateMarker(version: "0.2.41")
        _ = await waitForRequests(2, from: sleeper)
        controller.pulseUpdateMarker(version: "0.2.41")
        let repeatedDurations = await waitForRequests(3, from: sleeper)
        #expect(repeatedDurations == [.seconds(8), .seconds(8), .seconds(8)])
        #expect(controller.updateMarkerIsEmphasized)

        await sleeper.resume(request: 0)
        await Task.yield()
        #expect(controller.updateMarkerIsEmphasized)

        await sleeper.resume(request: 1)
        await Task.yield()
        #expect(controller.updateMarkerIsEmphasized)

        await sleeper.resume(request: 2)
        await waitUntil { !controller.updateMarkerIsEmphasized }
        #expect(!controller.updateMarkerIsEmphasized)
    }

    @Test("Marker pulse never opens or activates application UI")
    func markerPulseContainsNoFocusOrWindowAPIs() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        let body = try Self.sourceSlice(
            source,
            from: "func pulseUpdateMarker",
            to: "// MARK: - label rendering")
        let forbidden = [
            "NSApp.activate",
            "showPopover",
            "WindowManager",
            "makeKey",
            "orderFront",
            "NSWindow",
            "UNUserNotificationCenter",
            "renderAndObserve()",
        ]

        for symbol in forbidden {
            #expect(!body.contains(symbol), "Pulse must not call \(symbol)")
        }
        #expect(body.contains("renderLabel()"))
    }

    @Test("Teardown avoids experimental isolated deinit syntax")
    func teardownIsSwift61Compatible() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        #expect(!source.contains("\n    isolated deinit"))

        let teardown = try Self.sourceSlice(
            source,
            from: "func stop()",
            to: "func pulseUpdateMarker")
        #expect(teardown.contains("guard !isStopped else { return }"))
        #expect(teardown.contains("pulseTask?.cancel()"))
        #expect(teardown.contains("NSStatusBar.system.removeStatusItem(statusItem)"))

        let observation = try Self.sourceSlice(
            source,
            from: "private func renderAndObserve()",
            to: "private func renderLabel()")
        #expect(observation.contains("guard !isStopped else { return }"))

        let render = try Self.sourceSlice(
            source,
            from: "private func renderLabel()",
            to: "private static let gaugeImage")
        #expect(render.contains("guard !isStopped else { return }"))
    }

    @Test("Popover window can appear above full-screen Spaces")
    func popoverWindowCanJoinFullScreenSpaces() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.collectionBehavior = []
        window.level = .normal

        StatusItemController.configurePopoverWindowForMenuBarPresentation(window)

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.hidesOnDeactivate == false)
        #expect(window.level == .popUpMenu)
    }

    @Test("Offscreen full-screen menu-bar anchors are normalized to the top edge")
    func offscreenFullscreenAnchorUsesTopEdge() {
        let origin = StatusItemController.menuBarPopoverOrigin(
            windowSize: NSSize(width: 400, height: 560),
            anchorRect: NSRect(x: 1_338, y: -59, width: 100, height: 24),
            screenFrame: NSRect(x: 0, y: 0, width: 2_048, height: 1_152),
            statusBarThickness: 24)

        #expect(origin.x == 1_188)
        #expect(origin.y == 568)
    }

    @Test("Popover origin stays inside the screen horizontally")
    func popoverOriginStaysInsideScreen() {
        let origin = StatusItemController.menuBarPopoverOrigin(
            windowSize: NSSize(width: 400, height: 560),
            anchorRect: NSRect(x: 2_000, y: 1_128, width: 100, height: 24),
            screenFrame: NSRect(x: 0, y: 0, width: 2_048, height: 1_152),
            statusBarThickness: 24)

        #expect(origin.x == 1_640)
        #expect(origin.y == 568)
    }

    private func waitForRequests(
        _ count: Int,
        from sleeper: ControlledStatusItemSleeper
    ) async -> [Duration] {
        for _ in 0..<500 {
            let durations = await sleeper.requestedDurations()
            if durations.count >= count { return durations }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) marker pulse sleeps")
        return await sleeper.requestedDurations()
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for marker pulse transition")
    }

    private static func sourceSlice(
        _ source: String,
        from startNeedle: String,
        to endNeedle: String
    ) throws -> String {
        guard let start = source.range(of: startNeedle),
              let end = source.range(of: endNeedle, range: start.upperBound..<source.endIndex) else {
            throw CocoaError(.formatting)
        }
        return String(source[start.lowerBound..<end.lowerBound])
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

private actor ControlledStatusItemSleeper {
    private var nextID = 0
    private var requests: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id = nextID
        nextID += 1
        durations.append(duration)
        try await withCheckedThrowingContinuation { continuation in
            requests[id] = continuation
        }
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    func resume(request id: Int) {
        requests.removeValue(forKey: id)?.resume()
    }
}
