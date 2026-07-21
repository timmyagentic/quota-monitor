import AppKit
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Status item popover window", .serialized)
struct StatusItemControllerTests {

    @Test("Observation does not retain the status item controller without a mutation")
    func observationAllowsControllerTeardownWithoutMutation() throws {
        _ = NSApplication.shared
        let defaultsName = "StatusItemControllerTests.teardown.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        weak var weakController: StatusItemController?

        autoreleasepool {
            let availability = PersistentUpdateAvailability()
            let runtime = UpdaterController.RuntimeConfiguration(
                updateAvailability: availability,
                sparkleEnabled: false)
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

    @Test("Status item has no update marker, timer, or presentation side effects")
    func statusItemContainsNoUpdateReminderSurface() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        #expect(!source.contains("StatusItemUpdateMarker"))
        #expect(!source.contains("pulseUpdateMarker"))
        #expect(!source.contains("updateMarkerIsEmphasized"))
        #expect(!source.contains("pulseTask"))
        #expect(!source.contains("Task.sleep"))
        #expect(!source.contains("updateAvailability.version"))
    }

    @Test("Unchanged label inputs skip native status-item reassignment")
    func unchangedLabelInputsShortCircuitRendering() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        let render = try Self.sourceSlice(
            source,
            from: "private func renderLabel()",
            to: "private static let gaugeImage")

        let equalityGuard = try #require(render.range(of: "guard rows != lastRenderedRows"))
        let titleBuild = try #require(render.range(of: "MenuBarTitleBuilder.make"))
        let titleAssignment = try #require(render.range(of: "button.attributedTitle = baseTitle"))
        let cacheUpdate = try #require(render.range(of: "lastRenderedRows = rows"))

        #expect(equalityGuard.lowerBound < titleBuild.lowerBound)
        #expect(titleBuild.lowerBound < titleAssignment.lowerBound)
        #expect(titleAssignment.lowerBound < cacheUpdate.lowerBound)
        #expect(render.contains("style != lastRenderedStyle"))
        #expect(render.contains("localizationTick != lastRenderedLocalizationTick"))
    }

    @Test("Dashboard quota is observed only while live Codex limits are unavailable")
    func dashboardQuotaIsFallbackOnly() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        let render = try Self.sourceSlice(
            source,
            from: "private func renderLabel()",
            to: "private static let gaugeImage")

        #expect(render.contains("let rateLimits = env.latestRateLimits"))
        #expect(render.contains(
            "let codexQuota = rateLimits == nil ? env.dashboardSnapshot?.codexQuota : nil"))
        #expect(render.contains("rateLimits: rateLimits"))
        #expect(render.contains("codexQuota: codexQuota"))
        #expect(!render.contains("rateLimits: env.latestRateLimits"))
        #expect(!render.contains("codexQuota: env.dashboardSnapshot?.codexQuota"))
    }

    @Test("Teardown avoids experimental isolated deinit syntax")
    func teardownIsSwift61Compatible() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        #expect(!source.contains("\n    isolated deinit"))

        let teardown = try Self.sourceSlice(
            source,
            from: "func stop()",
            to: "// MARK: - label rendering")
        #expect(teardown.contains("guard !isStopped else { return }"))
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

    @Test("Controller tests bootstrap AppKit before creating status items")
    func controllerTestsBootstrapAppKitBeforeStatusItems() throws {
        let source = try Self.source(named: "Tests/QuotaMonitorTests/StatusItemControllerTests.swift")
        let controllerTests = [try Self.sourceSlice(
            source,
            from: "func observationAllowsControllerTeardownWithoutMutation()",
            to: "let controller = StatusItemController(")]

        for testBodyBeforeController in controllerTests {
            #expect(testBodyBeforeController.contains("_ = NSApplication.shared"))
        }
        #expect(source.contains("@Suite(\"Status item popover window\", .serialized)"))
    }

    @Test("Popover window can appear above full-screen Spaces")
    func popoverWindowCanJoinFullScreenSpaces() {
        _ = NSApplication.shared
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
