import Foundation
import AppKit
import Testing
@testable import QuotaMonitor

/// The pure predicate behind `AppEnvironment.demoteToAccessory()`. When
/// the menu-bar icon is unreachable we must NEVER demote back to
/// `.accessory` — that would drop the only visible entry (the Dock icon)
/// once the last window closes.
@Suite("Demote-to-accessory predicate")
struct DemoteToAccessoryPredicateTests {

    @Test
    func demotesWhenRegularAndReachable() {
        #expect(AppEnvironment.shouldDemoteToAccessory(
            currentlyRegular: true, menuBarUnreachable: false) == true)
    }

    @Test
    func doesNotDemoteWhenUnreachable() {
        #expect(AppEnvironment.shouldDemoteToAccessory(
            currentlyRegular: true, menuBarUnreachable: true) == false)
    }

    @Test
    func doesNotDemoteWhenAlreadyAccessory() {
        #expect(AppEnvironment.shouldDemoteToAccessory(
            currentlyRegular: false, menuBarUnreachable: false) == false)
    }

    @Test
    func clippedMenuBarRequiresRegularActivationPolicy() {
        #expect(AppEnvironment.activationPolicyForMenuBarReachability(
            clipped: true,
            showDockIconForWindows: false,
            hasVisibleAppWindow: false) == .regular)
    }

    @Test
    func recoveredMenuBarWithoutVisibleWindowsDemotesAccessory() {
        #expect(AppEnvironment.activationPolicyForMenuBarReachability(
            clipped: false,
            showDockIconForWindows: false,
            hasVisibleAppWindow: false) == .accessory)
    }

    @Test
    func recoveredMenuBarKeepsRegularWhenWindowSettingRequiresDockIcon() {
        #expect(AppEnvironment.activationPolicyForMenuBarReachability(
            clipped: false,
            showDockIconForWindows: true,
            hasVisibleAppWindow: true) == .regular)
    }

    @Test
    func recoveredMenuBarDemotesWhenVisibleWindowDoesNotNeedDockIcon() {
        #expect(AppEnvironment.activationPolicyForMenuBarReachability(
            clipped: false,
            showDockIconForWindows: false,
            hasVisibleAppWindow: true) == .accessory)
    }
}
