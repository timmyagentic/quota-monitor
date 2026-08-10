import AppKit
import Testing

@testable import QuotaMonitor

@Suite("Dashboard window sizing policy")
struct DashboardWindowSizingPolicyTests {
    @Test("Compact workspaces get the compact full-year-friendly opening size")
    func compactWorkspace() {
        let size = DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 720))

        #expect(size == NSSize(width: 900, height: 600))
    }

    @Test("Short workspaces retain the outer-window safety margin")
    func shortWorkspace() {
        let size = DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 680))

        #expect(size == NSSize(width: 900, height: 564))
    }

    @Test("Laptop workspaces scale continuously between the preferred bounds")
    func laptopWorkspace() {
        let size = DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 900))

        #expect(size == NSSize(width: 1028, height: 648))
    }

    @Test("Desktop workspaces use a wider Dashboard without growing indefinitely")
    func desktopWorkspace() {
        let size = DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 956))
        let largeSize = DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1390))

        #expect(size == NSSize(width: 1180, height: 688))
        #expect(largeSize == NSSize(width: 1180, height: 760))
    }

    @Test("Very small workspaces retain the functional Dashboard minimum")
    func verySmallWorkspace() {
        let size = DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 850, height: 600))

        #expect(size == DashboardWindowSizingPolicy.minimumContentSize)
    }

    @Test("Missing or invalid screen geometry uses the stable legacy fallback")
    func missingScreenFallback() {
        #expect(DashboardWindowSizingPolicy.contentSize(forVisibleFrame: nil)
            == DashboardWindowSizingPolicy.fallbackContentSize)
        #expect(DashboardWindowSizingPolicy.contentSize(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 0, height: 900))
            == DashboardWindowSizingPolicy.fallbackContentSize)
    }

    @Test("The pointer display supplies the usable workspace on multi-screen setups")
    func pointerDisplayWins() {
        let primary = DashboardWindowSizingPolicy.ScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1050))
        let secondary = DashboardWindowSizingPolicy.ScreenGeometry(
            frame: NSRect(x: 1920, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 1920, y: 0, width: 1512, height: 952))

        let selected = DashboardWindowSizingPolicy.preferredVisibleFrame(
            pointerLocation: NSPoint(x: 2200, y: 500),
            screens: [primary, secondary],
            fallbackVisibleFrame: primary.visibleFrame)

        #expect(selected == secondary.visibleFrame)
    }

    @Test("The main display is the fallback when the pointer is outside every screen")
    func mainDisplayFallback() {
        let screen = DashboardWindowSizingPolicy.ScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1050))
        let fallback = NSRect(x: -1512, y: 0, width: 1512, height: 952)

        let selected = DashboardWindowSizingPolicy.preferredVisibleFrame(
            pointerLocation: NSPoint(x: 3000, y: 2000),
            screens: [screen],
            fallbackVisibleFrame: fallback)

        #expect(selected == fallback)
    }

    @Test("Opening is centered inside an offset display's usable workspace")
    func centeredOnOffsetDisplay() {
        let origin = DashboardWindowSizingPolicy.centeredOrigin(
            windowFrameSize: NSSize(width: 1028, height: 680),
            in: NSRect(x: 1920, y: 40, width: 1512, height: 900))

        #expect(origin == NSPoint(x: 2162, y: 150))
    }
}
