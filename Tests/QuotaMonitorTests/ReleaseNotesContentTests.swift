import Foundation
import Testing
@testable import QuotaMonitor

/// `ReleaseNotesCSS.hasContent` is what lets the update window tell a real
/// set of release notes apart from an empty/missing appcast `<description>`.
/// It must judge emptiness on the *raw* body — the wrapped document is never
/// empty — so these lock that behaviour in.
@Suite("Release notes content detection")
struct ReleaseNotesContentTests {

    @Test
    func nilDescriptionHasNoContent() {
        #expect(!ReleaseNotesCSS.hasContent(nil))
    }

    @Test
    func emptyOrWhitespaceDescriptionHasNoContent() {
        #expect(!ReleaseNotesCSS.hasContent(""))
        #expect(!ReleaseNotesCSS.hasContent("   "))
        #expect(!ReleaseNotesCSS.hasContent("\n\t  \n"))
    }

    @Test
    func realDescriptionHasContent() {
        #expect(ReleaseNotesCSS.hasContent("<ul><li>Fixed a bug</li></ul>"))
    }

    @Test
    func wrappedEmptyBodyIsNeverEmpty() {
        // The reason hasContent exists: wrapHTML("") is still a full,
        // non-empty document, so the window can't gate on the wrapped string.
        let wrapped = ReleaseNotesCSS.wrapHTML("", isDark: false, locale: "en")
        #expect(!wrapped.isEmpty)
        #expect(!ReleaseNotesCSS.hasContent(""))
    }
}
