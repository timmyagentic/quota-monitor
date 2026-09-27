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

    static func invalidatesAnchor(previousBounds: CGRect?, currentBounds: CGRect) -> Bool {
        // Anchors are window-relative. A translation does not change the slot.
        previousBounds?.size != currentBounds.size
    }

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
    static func isHeaderControl(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        windowFrame.contains(frame) && frame.width >= 10 && frame.height >= 10
            && frame.height <= 48 && frame.minY - windowFrame.minY <= 100
            && frame.maxX - windowFrame.minX <= min(560, windowFrame.width)
    }

    static func anchor(
        in windowFrame: CGRect,
        candidates: [CodexSidebarHeaderCandidate]
    ) -> CodexSidebarHeaderAnchor? {
        guard let measured = measuredAnchor(in: windowFrame, candidates: candidates),
              measured.availableWidth >= CodexQuotaOverlayLayout.compactWidth else { return nil }
        return measured
    }

    static func measuredAnchor(
        in windowFrame: CGRect,
        candidates: [CodexSidebarHeaderCandidate]
    ) -> CodexSidebarHeaderAnchor? {
        let header = candidates.filter {
            isHeaderControl($0.frame, in: windowFrame)
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
        var narrowAnchor: CodexSidebarHeaderAnchor?
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
            narrowAnchor = narrowAnchor ?? anchor
        }
        return narrowAnchor
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
    static func mainWindow(for processIdentifier: pid_t) -> CodexMainWindowReadResult {
        CodexMainWindowReader.read(application: Element(AXUIElementCreateApplication(processIdentifier)),
            access: CodexMainWindowAccess(
                isTrusted: AXIsProcessTrusted(),
                role: { stringAttribute($0.value, kAXRoleAttribute as CFString) },
                subrole: { stringAttribute($0.value, kAXSubroleAttribute as CFString) },
                frame: { frame(of: $0.value) },
                mainWindow: { element($0.value, kAXMainWindowAttribute as CFString) },
                isCancelled: { currentTaskIsCancelled }))
    }

    /// Read only, bounded, and never prompts for permission: an unrecognized header yields
    /// no automatic placement instead of guessing over the host's content.
    static func read(
        for processIdentifier: pid_t,
        in quartzWindowFrame: CGRect
    ) -> CodexSidebarHeaderReadResult {
        let application = Element(AXUIElementCreateApplication(processIdentifier))
        return CodexSidebarHeaderReader.read(application: application,
            windowFrame: quartzWindowFrame,
            access: CodexSidebarHeaderAccess(
                isTrusted: AXIsProcessTrusted(),
                role: { stringAttribute($0.value, kAXRoleAttribute as CFString) },
                frame: { frame(of: $0.value) },
                windows: { elements($0.value, kAXWindowsAttribute as CFString) },
                children: { elements($0.value, kAXChildrenAttribute as CFString) },
                descriptors: { element in
                    [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                     kAXIdentifierAttribute, kAXValueAttribute].compactMap {
                        stringAttribute(element.value, $0 as CFString)
                    }
                },
                mainWindow: { element($0.value, kAXMainWindowAttribute as CFString) },
                isCancelled: { currentTaskIsCancelled }))
    }

    private static func element(_ element: AXUIElement, _ name: CFString) -> Element? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Element(unsafeDowncast(value, to: AXUIElement.self))
    }

    private struct Element: Hashable {
        let value: AXUIElement
        init(_ value: AXUIElement) {
            self.value = value
            AXUIElementSetMessagingTimeout(value, 0.2)
        }
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(value)) }
    }

    private static func elements(_ element: AXUIElement, _ name: CFString) -> [Element] {
        (attribute(element, name) as? [AXUIElement] ?? []).map(Element.init)
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
}
