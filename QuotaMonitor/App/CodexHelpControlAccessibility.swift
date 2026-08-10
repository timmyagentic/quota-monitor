import ApplicationServices
import CoreGraphics
import Foundation

struct CodexHelpControlAnchor: Equatable, Sendable {
    let leadingEdgeTrailingInset: CGFloat

    func leadingX(in windowFrame: CGRect) -> CGFloat {
        windowFrame.maxX - leadingEdgeTrailingInset
    }
}

struct CodexHelpControlCandidate: Equatable {
    let frame: CGRect
    let descriptors: [String]
}

enum CodexHelpControlDiscoveryPolicy {
    static let anchoredRefreshInterval: TimeInterval = 10
    static let preservedAnchorMissLimit = 2

    static func retryInterval(afterFailureCount failureCount: Int) -> TimeInterval {
        let exponent = min(max(0, failureCount - 1), 4)
        return min(8, 0.5 * pow(2, Double(exponent)))
    }

    static func shouldStart(
        now: Date,
        nextAttemptAt: Date?,
        isRunning: Bool,
        force: Bool
    ) -> Bool {
        guard !isRunning else { return false }
        guard !force, let nextAttemptAt else { return true }
        return now >= nextAttemptAt
    }
}

enum CodexHelpControlSelectionPolicy {
    private static let minimumControlSize: CGFloat = 12
    private static let maximumControlSize: CGFloat = 64
    private static let maximumEdgeInset: CGFloat = 96
    private static let helpTerms = [
        "help",
        "question",
        "questionmark",
        "support",
        "?",
        "帮助",
        "问号"
    ]

    static func anchor(
        in windowFrame: CGRect,
        candidates: [CodexHelpControlCandidate]
    ) -> CodexHelpControlAnchor? {
        candidates
            .filter { candidate in
                let frame = candidate.frame
                guard frame.width >= minimumControlSize,
                      frame.height >= minimumControlSize,
                      frame.width <= maximumControlSize,
                      frame.height <= maximumControlSize,
                      windowFrame.contains(frame),
                      matchesHelpDescriptor(candidate.descriptors) else {
                    return false
                }
                let trailingCenterInset = windowFrame.maxX - frame.midX
                let bottomCenterInset = windowFrame.maxY - frame.midY
                return (0...maximumEdgeInset).contains(trailingCenterInset)
                    && (0...maximumEdgeInset).contains(bottomCenterInset)
            }
            .min { lhs, rhs in
                score(lhs.frame, in: windowFrame)
                    < score(rhs.frame, in: windowFrame)
            }
            .map {
                CodexHelpControlAnchor(
                    leadingEdgeTrailingInset: windowFrame.maxX - $0.frame.minX)
            }
    }

    private static func matchesHelpDescriptor(_ descriptors: [String]) -> Bool {
        let normalized = descriptors
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return helpTerms.contains { normalized.contains($0) }
    }

    private static func score(_ frame: CGRect, in windowFrame: CGRect) -> CGFloat {
        abs((windowFrame.maxX - frame.midX) - 24)
            + abs((windowFrame.maxY - frame.midY) - 24)
    }
}

enum CodexHelpControlAccessibility {
    private static let maximumTraversalDepth = 14
    private static let maximumVisitedElements = 600

    /// Reads an already-authorized accessibility tree without prompting for
    /// permission. Missing permission, labels, or controls deliberately falls
    /// through to the layout's proportional fallback anchor.
    static func anchor(
        for processIdentifier: pid_t,
        in quartzWindowFrame: CGRect
    ) -> CodexHelpControlAnchor? {
        guard !currentTaskIsCancelled,
              AXIsProcessTrusted() else {
            return nil
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        guard let windows = attribute(
            application,
            kAXWindowsAttribute as CFString) as? [AXUIElement],
            let window = windows.max(by: {
                intersectionArea(frame(of: $0), quartzWindowFrame)
                    < intersectionArea(frame(of: $1), quartzWindowFrame)
            }),
            intersectionArea(frame(of: window), quartzWindowFrame) > 0 else {
            return nil
        }

        return CodexHelpControlSelectionPolicy.anchor(
            in: quartzWindowFrame,
            candidates: buttonCandidates(in: window))
    }

    private static func buttonCandidates(
        in window: AXUIElement
    ) -> [CodexHelpControlCandidate] {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var cursor = 0
        var visited: Set<CFHashCode> = []
        var candidates: [CodexHelpControlCandidate] = []

        while cursor < queue.count,
              visited.count < maximumVisitedElements,
              !currentTaskIsCancelled {
            let item = queue[cursor]
            cursor += 1

            let hash = CFHash(item.element)
            guard visited.insert(hash).inserted else { continue }

            if stringAttribute(item.element, kAXRoleAttribute as CFString)
                == (kAXButtonRole as String),
               let frame = frame(of: item.element) {
                let descriptors = [
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXHelpAttribute,
                    kAXIdentifierAttribute,
                    kAXValueAttribute
                ].compactMap {
                    stringAttribute(item.element, $0 as CFString)
                }
                candidates.append(CodexHelpControlCandidate(
                    frame: frame,
                    descriptors: descriptors))
            }

            guard item.depth < maximumTraversalDepth,
                  let children = attribute(
                    item.element,
                    kAXChildrenAttribute as CFString) as? [AXUIElement] else {
                continue
            }
            queue.append(contentsOf: children.map {
                (element: $0, depth: item.depth + 1)
            })
        }

        return candidates
    }

    private static var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String? {
        attribute(element, name) as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(
            element,
            kAXPositionAttribute as CFString),
            let size = sizeAttribute(
                element,
                kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CGPoint? {
        guard let value = axValueAttribute(element, name),
              AXValueGetType(value) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CGSize? {
        guard let value = axValueAttribute(element, name),
              AXValueGetType(value) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValueAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> AXValue? {
        guard let rawValue = attribute(element, name),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(rawValue, to: AXValue.self)
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private static func intersectionArea(
        _ lhs: CGRect?,
        _ rhs: CGRect
    ) -> CGFloat {
        guard let lhs else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
