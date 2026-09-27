import ApplicationServices
import CoreGraphics
import Foundation

/// The measured empty header slot, relative to the Quartz window's top left.
struct CodexSidebarHeaderAnchor: Equatable, Sendable {
    let leadingInset: CGFloat
    let trailingXInset: CGFloat
    let centerYInset: CGFloat

    var availableWidth: CGFloat { trailingXInset - leadingInset }
}

struct CodexSidebarHeaderCandidate: Equatable {
    let frame: CGRect
    let descriptors: [String]
    let role: String

    init(frame: CGRect, descriptors: [String], role: String = kAXButtonRole as String) {
        self.frame = frame
        self.descriptors = descriptors
        self.role = role
    }
}

enum CodexSidebarHeaderDiscoveryPolicy {
    static let anchoredRefreshInterval: TimeInterval = 10

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

enum CodexSidebarHeaderSelectionPolicy {
    static func anchor(
        in windowFrame: CGRect,
        candidates: [CodexSidebarHeaderCandidate]
    ) -> CodexSidebarHeaderAnchor? {
        let header = candidates.filter {
            let f = $0.frame
            return windowFrame.contains(f) && f.width >= 10 && f.height >= 10
                && f.height <= 48 && f.minY - windowFrame.minY <= 100
                && f.maxX - windowFrame.minX <= min(560, windowFrame.width)
        }
        let titles = header.filter {
            // A text child excludes its parent's chevron/padding. Only a full
            // interactive control can establish the occupied title boundary.
            ($0.role == kAXButtonRole as String || $0.role == kAXPopUpButtonRole as String)
                && $0.frame.width <= 160 && $0.frame.minX - windowFrame.minX <= 180
                && $0.descriptors.contains(where: isCodexTitle)
        }
        // A title AND a known sidebar action on the same row are required.
        // Chat text, the window title, and a collapsed navigation rail cannot anchor it.
        let orderedTitles = titles.sorted {
            $0.frame.minX == $1.frame.minX
                ? $0.frame.width > $1.frame.width
                : $0.frame.minX < $1.frame.minX
        }
        for title in orderedTitles {
            let actions = header.filter {
                $0.frame.minX >= title.frame.maxX && abs($0.frame.midY - title.frame.midY) <= 8
            }
            guard actions.contains(where: { candidate in
                candidate.descriptors.contains { text in
                    let text = text.lowercased()
                    return ["search", "notification", "搜索", "通知"].contains { text.contains($0) }
                }
            }), let next = actions.min(by: { $0.frame.minX < $1.frame.minX }) else { continue }
            let anchor = CodexSidebarHeaderAnchor(
                leadingInset: title.frame.maxX - windowFrame.minX + 8,
                trailingXInset: next.frame.minX - windowFrame.minX - 8,
                centerYInset: title.frame.midY - windowFrame.minY)
            if anchor.availableWidth >= CodexQuotaOverlayLayout.compactWidth { return anchor }
        }
        return nil
    }

    private static func isCodexTitle(_ descriptor: String) -> Bool {
        let normalized = descriptor.lowercased()
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "：", with: ":")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        // The new sidebar labels the full logo/dropdown button by its current
        // product mode. Matching only the visual wordmark misses this control.
        return ["codex", "switchmode,currentmode:codex",
                "切换模式,当前模式:codex", "切換模式,目前模式:codex"].contains(normalized)
    }
}

enum CodexSidebarHeaderAccessibility {
    private static let maximumTraversalDepth = 14
    private static let maximumVisitedElements = 600

    /// Read only, bounded, and never prompts for permission: an unrecognized header yields
    /// no automatic placement instead of guessing over the host's content.
    static func anchor(
        for processIdentifier: pid_t,
        in quartzWindowFrame: CGRect
    ) -> CodexSidebarHeaderAnchor? {
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

        return CodexSidebarHeaderSelectionPolicy.anchor(
            in: quartzWindowFrame,
            candidates: headerCandidates(in: window))
    }

    private static func headerCandidates(
        in window: AXUIElement
    ) -> [CodexSidebarHeaderCandidate] {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var cursor = 0
        var visited: Set<CFHashCode> = []
        var candidates: [CodexSidebarHeaderCandidate] = []

        while cursor < queue.count,
              visited.count < maximumVisitedElements,
              !currentTaskIsCancelled {
            let item = queue[cursor]
            cursor += 1

            let hash = CFHash(item.element)
            guard visited.insert(hash).inserted else { continue }

            if let role = stringAttribute(
                item.element,
                kAXRoleAttribute as CFString),
               [kAXButtonRole as String, kAXPopUpButtonRole as String, kAXStaticTextRole as String, kAXImageRole as String].contains(role),
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
                candidates.append(CodexSidebarHeaderCandidate(
                    frame: frame,
                    descriptors: descriptors,
                    role: role))
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
