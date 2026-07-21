import Foundation
import Testing

@Suite("Sessions view wiring")
struct SessionsViewWiringTests {
    @Test("Session search cancels the pending debounce before scheduling another query")
    func searchUsesOneCancellableTrailingReload() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/Sessions/SessionsView.swift"),
            encoding: .utf8)

        #expect(source.contains("@State private var pendingSearchReload: Task<Void, Never>?"))
        #expect(source.contains(".onChange(of: search) { _, _ in\n            scheduleSearchReload()"))
        #expect(source.contains("private func scheduleSearchReload()"))
        #expect(source.contains("cancelPendingSearchReload()\n        pendingSearchReload = Task"))
        #expect(source.contains("try await Task.sleep(for: .milliseconds(200))"))
        #expect(source.contains("catch {\n                return\n            }\n            await reloadList()"))
        #expect(!source.contains("reloadList(debounceMs:"))
    }

    @Test("Sort changes and view teardown cancel a pending search reload")
    func otherLifecycleEventsCancelPendingSearch() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: "QuotaMonitor/Features/Sessions/SessionsView.swift"),
            encoding: .utf8)

        #expect(source.contains(".onChange(of: sort) { _, _ in\n            cancelPendingSearchReload()"))
        #expect(source.contains(".onDisappear {\n            cancelPendingSearchReload()"))
        #expect(source.contains("pendingSearchReload?.cancel()\n        pendingSearchReload = nil"))
    }
}
