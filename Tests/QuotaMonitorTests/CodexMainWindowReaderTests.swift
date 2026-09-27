import CoreGraphics
import Testing
@testable import QuotaMonitor

@Suite("Codex document window identity")
struct CodexMainWindowReaderTests {
    private let document = CodexWindowCandidate(windowNumber: 70, ownerPID: 120, layer: 0,
        alpha: 1, bounds: CGRect(x: 100, y: 80, width: 1200, height: 800))
    private let preview = CodexWindowCandidate(windowNumber: 71, ownerPID: 120, layer: 0,
        alpha: 1, bounds: CGRect(x: 700, y: 380, width: 600, height: 400))

    @Test("A preview in front cannot take the main document's identity")
    func mainDocument() throws {
        var primed = false
        let access = CodexMainWindowAccess<Int>(isTrusted: true,
            role: { if $0 == 0 { primed = true; return "AXApplication" }; return "AXWindow" },
            subrole: { _ in "AXStandardWindow" }, frame: { _ in document.bounds },
            mainWindow: { _ in primed ? 70 : nil })
        let result = CodexMainWindowReader.read(application: 0, access: access)
        let frame = try #require(result.frame)
        for windows in [[preview, document], [document], [preview, document]] {
            #expect(CodexWindowSelectionPolicy.windowMatchingMainFrame(frame, for: 120,
                previousWindowNumber: nil, candidates: windows)?.windowNumber == 70)
        }
    }

    @Test("Dialog and utility roles do not establish a document", arguments: ["AXDialog", "AXSystemDialog", "AXFloatingWindow", ""])
    func rejectsNonDocuments(subrole: String) {
        let access = CodexMainWindowAccess<Int>(isTrusted: true,
            role: { $0 == 0 ? "AXApplication" : "AXWindow" },
            subrole: { _ in subrole }, frame: { _ in preview.bounds }, mainWindow: { _ in 71 })
        #expect(CodexMainWindowReader.read(application: 0, access: access).frame == nil)
    }

    @Test("Permission and cancellation do not read another application")
    func readGuards() {
        var reads = 0
        var access = CodexMainWindowAccess<Int>(isTrusted: false,
            role: { _ in reads += 1; return "AXApplication" }, subrole: { _ in nil },
            frame: { _ in nil }, mainWindow: { _ in nil })
        #expect(CodexMainWindowReader.read(application: 0, access: access).failure == .permissionRequired)
        access.isTrusted = true
        access.isCancelled = { true }
        #expect(CodexMainWindowReader.read(application: 0, access: access).failure == .cancelled)
        #expect(reads == 0)
    }

    @Test("A confirmed second document can replace the first, independently of popup order")
    func switchesDocuments() {
        let second = CodexWindowCandidate(windowNumber: 72, ownerPID: 120, layer: 0,
            alpha: 1, bounds: CGRect(x: -1000, y: 80, width: 800, height: 600))
        let windows = [preview, second, document]
        let confirmed = CodexWindowSelectionPolicy.windowMatchingMainFrame(second.bounds, for: 120,
            previousWindowNumber: 70, candidates: windows)
        #expect(confirmed?.windowNumber == 72)
        #expect(CodexWindowSelectionPolicy.trackedWindow(for: 120, lastWindowNumber: 70,
            codexIsFrontmost: true, mainWindowNumber: confirmed?.windowNumber,
            candidates: windows)?.windowNumber == 72)
    }

    @Test("Overlapping and coincident geometry cannot invent a document identity")
    func ambiguousGeometry() {
        #expect(CodexWindowSelectionPolicy.windowMatchingMainFrame(document.bounds, for: 120,
            previousWindowNumber: 70, candidates: [preview]) == nil)
        let duplicate = CodexWindowCandidate(windowNumber: 73, ownerPID: 120, layer: 0,
            alpha: 1, bounds: document.bounds)
        #expect(CodexWindowSelectionPolicy.windowMatchingMainFrame(document.bounds, for: 120,
            previousWindowNumber: nil, candidates: [duplicate, document]) == nil)
        #expect(CodexWindowSelectionPolicy.windowMatchingMainFrame(document.bounds, for: 120,
            previousWindowNumber: 70, candidates: [duplicate, document])?.windowNumber == 70)
    }

    @Test("Closing or minimizing the document never transfers a manual widget to its preview")
    func missingDocument() {
        for foreground in [true, false] {
            #expect(CodexWindowSelectionPolicy.trackedWindow(for: 120, lastWindowNumber: 70,
                codexIsFrontmost: foreground, mainWindowNumber: 70, candidates: [preview]) == nil)
        }
        #expect(CodexWindowSelectionPolicy.trackedWindow(for: 120, lastWindowNumber: nil,
            codexIsFrontmost: true, candidates: [preview, document]) == nil)
    }
}
