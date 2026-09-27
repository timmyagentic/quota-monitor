import CoreGraphics
import Foundation

enum CodexSidebarHeaderReadFailure: String, Sendable {
    case permissionRequired
    case windowUnavailable
    case treeUnavailable
    case traversalLimit
    case headerNotFound
    case insufficientSpace
    case cancelled
}

struct CodexSidebarHeaderReadResult: Equatable, Sendable {
    var anchor: CodexSidebarHeaderAnchor?
    var failure: CodexSidebarHeaderReadFailure?
    var visitedCount = 0
    var candidateCount = 0
    var webAreaCount = 0

    func anchorForPlacement(previous: CodexSidebarHeaderAnchor?) -> CodexSidebarHeaderAnchor? {
        if let anchor { return anchor }
        switch failure {
        case .windowUnavailable, .treeUnavailable, .traversalLimit, .cancelled: return previous
        default: return nil
        }
    }

    var unavailableStatus: CodexSidebarQuotaStatus {
        if anchor != nil { return .headerSpaceUnavailable }
        switch failure {
        case .permissionRequired: return .accessibilityPermissionRequired
        case .headerNotFound: return .waitingForHeader
        case .insufficientSpace: return .headerSpaceUnavailable
        default: return .waitingForInterface
        }
    }
}

/// The same reader runs against macOS AX elements and deterministic lazy trees.
struct CodexSidebarHeaderAccess<Element: Hashable> {
    var isTrusted: Bool
    var role: (Element) -> String?
    var frame: (Element) -> CGRect?
    var windows: (Element) -> [Element]
    var children: (Element) -> [Element]
    var descriptors: (Element) -> [String]
    var mainWindow: (Element) -> Element? = { _ in nil }
    var isCancelled: () -> Bool = { false }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
}

enum CodexSidebarHeaderReader {
    static let maximumVisitedElements = 600
    static let maximumTraversalDepth = 48
    static let maximumDuration: TimeInterval = 0.75

    static func read<Element: Hashable>(
        application: Element,
        windowFrame: CGRect,
        access: CodexSidebarHeaderAccess<Element>
    ) -> CodexSidebarHeaderReadResult {
        guard access.isTrusted else { return .init(failure: .permissionRequired) }
        guard !access.isCancelled() else { return .init(failure: .cancelled) }
        let startedAt = access.uptime()
        // Chromium activates native accessibility on an application-role read.
        // Starting at AXWindows can leave a cold renderer tree uninitialized.
        guard access.role(application) != nil else { return .init(failure: .treeUnavailable) }
        let matches = access.windows(application).filter { element in
            access.frame(element).map { CodexWindowSelectionPolicy.framesMatch($0, windowFrame) } ?? false
        }
        let main = access.mainWindow(application)
        guard let window = matches.count == 1 ? matches.first : matches.first(where: { $0 == main }) else {
            return .init(failure: .windowUnavailable)
        }

        var pending: [(Element, Int)] = [(window, 0)]
        var visited: Set<Element> = []
        var candidates: [CodexSidebarHeaderCandidate] = []
        var depthLimited = false
        var webAreaCount = 0
        let headerRegion = CGRect(x: windowFrame.minX, y: windowFrame.minY,
            width: min(560, windowFrame.width), height: min(148, windowFrame.height))
        while !pending.isEmpty,
              visited.count < maximumVisitedElements,
              access.uptime() - startedAt < maximumDuration,
              !access.isCancelled() {
            let (element, depth) = pending.removeLast()
            guard visited.insert(element).inserted else { continue }
            let frame = access.frame(element)
            // Empty/unknown wrapper bounds are not evidence that its children
            // are outside the header. Real off-header subtrees need no text reads.
            if let frame, !frame.isEmpty, !frame.isInfinite,
               !frame.intersects(headerRegion) { continue }
            let role = access.role(element)
            if role == "AXWebArea" { webAreaCount += 1 }
            if let role,
               ["AXButton", "AXPopUpButton", "AXStaticText", "AXImage"].contains(role),
               let frame,
               CodexSidebarHeaderSelectionPolicy.isHeaderControl(frame, in: windowFrame) {
                candidates.append(.init(frame: frame,
                    descriptors: access.descriptors(element), role: role))
            }
            let children = access.children(element)
            if depth == maximumTraversalDepth {
                depthLimited = depthLimited || !children.isEmpty
            } else {
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        var result = CodexSidebarHeaderReadResult(
            visitedCount: visited.count, candidateCount: candidates.count, webAreaCount: webAreaCount)
        if access.isCancelled() { result.failure = .cancelled }
        else if !pending.isEmpty || depthLimited { result.failure = .traversalLimit }
        else if candidates.isEmpty && webAreaCount == 0 { result.failure = .treeUnavailable }
        else {
            if let anchor = CodexSidebarHeaderSelectionPolicy.measuredAnchor(
                in: windowFrame, candidates: candidates) {
                if anchor.availableWidth >= CodexQuotaOverlayLayout.compactWidth {
                    result.anchor = anchor
                } else {
                    result.failure = .insufficientSpace
                }
            } else {
                result.failure = .headerNotFound
            }
        }
        return result
    }
}
