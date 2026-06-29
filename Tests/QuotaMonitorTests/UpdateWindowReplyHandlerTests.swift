import Testing
@testable import QuotaMonitor

/// Sparkle expects exactly one reply per update interaction. The persistent
/// update badge can fire `onInstall` while the update window is still open and
/// still in `.updateAvailable`, so a subsequent user title-bar close must NOT
/// send a second, conflicting `.dismiss` reply. These tests lock the
/// "consume the reply once" contract on `UpdateWindowState`.
@MainActor
@Suite("Update window reply handlers")
struct UpdateWindowReplyHandlerTests {

    @Test("Firing install consumes the other handlers so a later window close can't double-reply")
    func firingInstallPreventsDoubleReplyOnClose() {
        let state = UpdateWindowState()
        var installCount = 0
        var dismissCount = 0
        state.phase = .updateAvailable
        state.onInstall = { installCount += 1 }
        state.onDismiss = { dismissCount += 1 }

        // Badge-triggered install while the window is still on screen…
        state.fireInstall()
        // …then the user closes the still-open window before Sparkle advances.
        state.handleWindowClose()

        #expect(installCount == 1)
        #expect(dismissCount == 0)
    }

    @Test("A fired reply runs once even if the same handler path is invoked again")
    func fireDismissRepliesExactlyOnce() {
        let state = UpdateWindowState()
        var dismissCount = 0
        state.phase = .updateAvailable
        state.onDismiss = { dismissCount += 1 }

        state.fireDismiss()
        // A second close after the reply was already sent must be a no-op.
        state.handleWindowClose()

        #expect(dismissCount == 1)
    }
}
