import AppKit
import CoreGraphics

@MainActor
final class CodexWindowLocator {
    nonisolated static let supportedBundleIdentifiers: Set<String> = ["com.openai.codex"]

    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    var isCodexFrontmost: Bool {
        guard let identifier = workspace.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.supportedBundleIdentifiers.contains(identifier)
    }

    func frontmostWindowFrame() -> CGRect? {
        guard let app = workspace.frontmostApplication,
              let identifier = app.bundleIdentifier,
              Self.supportedBundleIdentifiers.contains(identifier),
              let rawWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let windows = rawWindows.compactMap {
            Self.windowInfo(from: $0, ownerPID: app.processIdentifier)
        }
        guard let selected = CodexWindowSelector.bestWindow(in: windows),
              let primaryScreenMaxY = Self.primaryScreenMaxY()
        else { return nil }

        return CodexAttachedCapsuleGeometry.appKitFrame(
            quartzBounds: selected.bounds,
            primaryScreenMaxY: primaryScreenMaxY)
    }

    private static func windowInfo(
        from dictionary: [String: Any],
        ownerPID: pid_t
    ) -> CodexWindowInfo? {
        guard (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
              let id = (dictionary[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let boundsValue = dictionary[kCGWindowBounds as String]
        else { return nil }
        let boundsDictionary = boundsValue as! CFDictionary
        guard let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
            return nil
        }

        return CodexWindowInfo(
            id: id,
            bounds: bounds,
            layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
            alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
            isOnscreen: (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }

    private static func primaryScreenMaxY() -> CGFloat? {
        let primary = NSScreen.screens.first {
            $0.frame.minX == 0 && $0.frame.minY == 0
        }
        return (primary ?? NSScreen.main)?.frame.maxY
    }
}
