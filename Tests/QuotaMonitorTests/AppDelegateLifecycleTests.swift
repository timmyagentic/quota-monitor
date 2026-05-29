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
}
