import Foundation
import Testing
import WebKit
@testable import QuotaMonitor

@Suite("Release notes navigation policy")
struct ReleaseNotesNavigationPolicyTests {

    @Test
    func allowsWebKitInitialHTMLLoad() {
        #expect(ReleaseNotesNavigationPolicy.shouldAllow(
            navigationType: .other,
            url: URL(string: "about:blank")))
    }

    @Test
    func stillAllowsNilURLInitialHTMLLoad() {
        #expect(ReleaseNotesNavigationPolicy.shouldAllow(
            navigationType: .other,
            url: nil))
    }

    @Test
    func blocksExternalLinks() {
        #expect(!ReleaseNotesNavigationPolicy.shouldAllow(
            navigationType: .linkActivated,
            url: URL(string: "https://example.com/release-notes")))
    }

    @Test("An unchanged document is loaded only once")
    func unchangedDocumentDoesNotReload() {
        var state = ReleaseNotesDocumentLoadState()

        let firstLoad = state.shouldLoad("<html>First</html>")
        let duplicateLoad = state.shouldLoad("<html>First</html>")
        let changedLoad = state.shouldLoad("<html>Second</html>")

        #expect(firstLoad)
        #expect(!duplicateLoad)
        #expect(changedLoad)
    }
}
