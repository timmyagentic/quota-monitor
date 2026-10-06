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

    @Test("Popover closes when the application loses activation, including after reopening")
    func appDeactivationDismissesReopenedPopover() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }

        for _ in 0..<2 {
            fixture.present()
            fixture.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
            #expect(!fixture.popover.isShown)
        }
        #expect(fixture.popover.closeCount == 2)
    }

    @Test("Activating another app closes a popover opened by an inactive menu-bar agent")
    func anotherAppActivationDismissesPopover() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }
        fixture.present()

        fixture.workspaceCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(fixture.popover.isShown)

        let otherApp = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        })
        fixture.workspaceCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: otherApp])
        #expect(!fixture.popover.isShown)
    }

    @Test("Opening another app-owned window dismisses the popover")
    func anotherKeyWindowDismissesPopover() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }
        fixture.present()
        let window = Self.makeWindow()

        fixture.appCenter.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!fixture.popover.isShown)
    }

    @Test("Internal clicks keep the popover open and outside mouse buttons dismiss without consuming the click")
    func localClicksDismissOnlyOutsidePopover() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }
        fixture.present()
        let popoverWindow = Self.makeWindow()
        popoverWindow.contentView = fixture.popover.contentViewController?.view
        let outsideWindow = Self.makeWindow()

        let inside = try Self.mouseDown(in: popoverWindow)
        #expect(fixture.controller.handleLocalPopoverEvent(inside) === inside)
        #expect(fixture.popover.isShown)

        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            fixture.popover.shownForTest = true
            let outside = try Self.mouseDown(in: outsideWindow, type: type)
            #expect(fixture.controller.handleLocalPopoverEvent(outside) === outside)
            #expect(!fixture.popover.isShown)
        }
        #expect(fixture.popover.closeCount == 3)
    }

    @Test("The status button and popover child windows remain interactive")
    func statusButtonAndChildWindowsAreInsidePopover() {
        _ = NSApplication.shared
        let popoverWindow = Self.makeWindow()
        let statusWindow = Self.makeWindow()
        let child = Self.makeWindow()
        let outside = Self.makeWindow()
        popoverWindow.addChildWindow(child, ordered: .above)
        defer { popoverWindow.removeChildWindow(child) }

        for inside in [popoverWindow, statusWindow, child] {
            #expect(StatusItemController.isPopoverInteractionWindow(
                inside, popoverWindow: popoverWindow, statusItemWindow: statusWindow))
        }
        for outside in [outside, nil] {
            #expect(!StatusItemController.isPopoverInteractionWindow(
                outside, popoverWindow: popoverWindow, statusItemWindow: statusWindow))
        }
    }

    @Test("Popover and child-window activation keep the popover open")
    func internalKeyWindowsDoNotDismissPopover() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }
        fixture.present()
        let popoverWindow = Self.makeWindow()
        popoverWindow.contentView = fixture.popover.contentViewController?.view
        let child = Self.makeWindow()
        popoverWindow.addChildWindow(child, ordered: .above)
        defer { popoverWindow.removeChildWindow(child) }

        for window in [popoverWindow, child] {
            fixture.appCenter.post(name: NSWindow.didBecomeKeyNotification, object: window)
            #expect(fixture.popover.isShown)
        }
    }

    @Test("Escape closes and is consumed; ordinary keys and closed-popover events pass through")
    func escapeDismissalPreservesOtherKeyEvents() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }
        fixture.present()
        let ordinary = try Self.keyDown(code: 0, characters: "a")
        #expect(fixture.controller.handleLocalPopoverEvent(ordinary) === ordinary)
        #expect(fixture.popover.isShown)

        let escape = try Self.keyDown(code: 53, characters: "\u{1b}")
        #expect(fixture.controller.handleLocalPopoverEvent(escape) == nil)
        #expect(!fixture.popover.isShown)
        #expect(fixture.controller.handleLocalPopoverEvent(escape) === escape)
    }

    @Test("Closing and stopping remove dismissal observers and stale presentation cannot reinstall them")
    func dismissalObserversHavePopoverLifetime() throws {
        let fixture = try DismissalFixture()
        defer { fixture.stop() }
        fixture.present()
        fixture.popover.performClose(nil)
        fixture.popover.shownForTest = true
        fixture.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        fixture.appCenter.post(name: NSWindow.didBecomeKeyNotification, object: Self.makeWindow())
        #expect(fixture.popover.closeCount == 1)

        fixture.present()
        fixture.controller.stop()
        #expect(fixture.popover.closeCount == 2)
        fixture.present()
        fixture.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(fixture.popover.closeCount == 2)
    }

    private static func mouseDown(in window: NSWindow,
                                  type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private static func keyDown(code: UInt16, characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private struct DismissalFixture {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let popover = DismissalTestPopover()
        let controller: StatusItemController
        let defaults: UserDefaults
        let defaultsName = "StatusItemControllerTests.dismissal.\(UUID().uuidString)"

        init() throws {
            _ = NSApplication.shared
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            let updater = UpdaterController(runtimeConfiguration: .init(
                updateAvailability: PersistentUpdateAvailability(), sparkleEnabled: false))
            controller = StatusItemController(
                env: AppEnvironment(startBackgroundTasks: false),
                localization: .shared,
                settings: SettingsStore(defaults: defaults, hasExistingAppData: { false }),
                updater: updater, popover: popover,
                appNotificationCenter: appCenter,
                workspaceNotificationCenter: workspaceCenter)
        }

        func present() {
            popover.shownForTest = true
            controller.popoverDidShow(Notification(name: NSPopover.didShowNotification, object: popover))
        }

        func stop() {
            controller.stop()
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    @MainActor
    private final class DismissalTestPopover: NSPopover {
        var shownForTest = false
        var closeCount = 0
        override var isShown: Bool { shownForTest }

        override func performClose(_ sender: Any?) {
            guard shownForTest else { return }
            closeCount += 1
            shownForTest = false
            delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
        }
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
