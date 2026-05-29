import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Menu-bar visibility enforcement")
struct MenuBarVisibilityEnforcementTests {

    @Test
    func firstClippedReadRetries() {
        #expect(MenuBarVisibilityEnforcement.decide(
            visibility: .clipped, attempt: 1) == .retry)
    }

    @Test
    func secondClippedReadAppliesFallback() {
        #expect(MenuBarVisibilityEnforcement.decide(
            visibility: .clipped, attempt: 2) == .applyUnreachable(clipped: true))
    }

    @Test
    func visibleReadAppliesReachableStateImmediately() {
        #expect(MenuBarVisibilityEnforcement.decide(
            visibility: .visible, attempt: 1) == .applyUnreachable(clipped: false))
    }
}
