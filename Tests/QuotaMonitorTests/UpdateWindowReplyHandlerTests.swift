import Foundation
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

    @Test("Available and ready phases expose the correct update actions")
    func phaseSpecificActions() {
        let state = UpdateWindowState()

        state.phase = .updateAvailable
        #expect(state.availableActions == [.skip, .later, .install])

        state.phase = .readyToInstall
        #expect(state.availableActions == [.later, .install])

        state.phase = .downloading
        #expect(state.availableActions.isEmpty)
    }

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
        #expect(state.handleWindowClose())

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
        #expect(state.handleWindowClose())

        #expect(dismissCount == 1)
    }

    @Test("Downloading close cancels once and allows the window to close")
    func downloadingCloseCancelsAndAllowsClose() {
        let state = UpdateWindowState()
        var cancelCount = 0
        state.phase = .downloading
        state.onCancel = { cancelCount += 1 }

        #expect(state.handleWindowClose())
        #expect(cancelCount == 1)
        #expect(state.handleWindowClose())
        #expect(cancelCount == 1)
    }

    @Test("Extraction and installation reject close without firing download cancellation")
    func nonCancellablePhasesRejectClose() {
        for phase in [UpdateWindowState.Phase.extracting, .installing] {
            let state = UpdateWindowState()
            var cancelCount = 0
            state.phase = phase
            state.onCancel = { cancelCount += 1 }

            #expect(!state.handleWindowClose())
            #expect(cancelCount == 0)
        }
    }

    @Test("Every update choice consumes all sibling reply handlers", arguments: [
        UpdateWindowState.UpdateAction.install,
        .skip,
        .later,
    ])
    func everyChoiceConsumesSiblingHandlers(choice: UpdateWindowState.UpdateAction) {
        let state = UpdateWindowState()
        var installCount = 0
        var skipCount = 0
        var laterCount = 0
        state.onInstall = { installCount += 1 }
        state.onSkip = { skipCount += 1 }
        state.onDismiss = { laterCount += 1 }

        switch choice {
        case .install:
            state.fireInstall()
        case .skip:
            state.fireSkip()
        case .later:
            state.fireDismiss()
        }
        state.fireInstall()
        state.fireSkip()
        state.fireDismiss()

        #expect(installCount == (choice == .install ? 1 : 0))
        #expect(skipCount == (choice == .skip ? 1 : 0))
        #expect(laterCount == (choice == .later ? 1 : 0))
    }

    @Test("The update view renders Skip only when the action model exposes it")
    func viewUsesPhaseSpecificSkipAvailability() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Core/Updater/UpdateWindowView.swift")

        #expect(source.contains("if state.availableActions.contains(.skip)"))
    }

    @Test("Beginning extraction expires the download cancellation callback")
    func extractionExpiresDownloadCancellation() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Core/Updater/CustomUserDriver.swift")
        let extraction = try Self.methodBody(
            source, signature: "func showDownloadDidStartExtractingUpdate")

        #expect(extraction.contains("state.onCancel = nil"))
    }

    private static func methodBody(_ source: String, signature: String) throws -> String {
        guard let start = source.range(of: signature) else {
            throw CocoaError(.formatting)
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
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
