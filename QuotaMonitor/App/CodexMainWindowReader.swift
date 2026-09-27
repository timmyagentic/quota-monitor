import CoreGraphics

struct CodexMainWindowReadResult: Equatable, Sendable {
    var frame: CGRect?
    var failure: CodexSidebarHeaderReadFailure?
}

struct CodexMainWindowAccess<Element> {
    var isTrusted: Bool
    var role: (Element) -> String?
    var subrole: (Element) -> String?
    var frame: (Element) -> CGRect?
    var mainWindow: (Element) -> Element?
    var isCancelled: () -> Bool = { false }
}

enum CodexMainWindowReader {
    static func read<Element>(application: Element, access: CodexMainWindowAccess<Element>) -> CodexMainWindowReadResult {
        guard access.isTrusted else { return .init(failure: .permissionRequired) }
        guard !access.isCancelled() else { return .init(failure: .cancelled) }
        // AXMainWindow is the document, unlike AXFocusedWindow or CG front order
        // which can refer to a temporary preview, sheet, or utility window.
        guard access.role(application) != nil,
              let window = access.mainWindow(application),
              access.role(window) == "AXWindow",
              access.subrole(window) == "AXStandardWindow",
              let frame = access.frame(window), !frame.isEmpty, !frame.isInfinite else {
            return .init(failure: .windowUnavailable)
        }
        guard !access.isCancelled() else { return .init(failure: .cancelled) }
        return .init(frame: frame)
    }
}
