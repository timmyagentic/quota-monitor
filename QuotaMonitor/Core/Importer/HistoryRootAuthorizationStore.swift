import Foundation

enum HistoryRootKind: String, CaseIterable, Sendable, Identifiable {
    case codexHome
    case claudeProjects
    case claudeConfigProjects

    var id: String { rawValue }
}

struct SecurityScopedResourceAccess: Sendable {
    let url: URL
    private let stopHandler: @Sendable () -> Void

    init(url: URL, stop: @escaping @Sendable () -> Void) {
        self.url = url
        self.stopHandler = stop
    }

    func stop() {
        stopHandler()
    }
}

protocol SecurityScopedResourceAccessing: Sendable {
    func access(_ url: URL) -> SecurityScopedResourceAccess
}

struct FoundationSecurityScopedResourceAccessing: SecurityScopedResourceAccessing {
    func access(_ url: URL) -> SecurityScopedResourceAccess {
        let didStart = url.startAccessingSecurityScopedResource()
        return SecurityScopedResourceAccess(url: url) {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

final class HistoryRootAuthorizationStore: @unchecked Sendable {
    static let shared = HistoryRootAuthorizationStore(
        defaults: LocalQAEnvironment.userDefaults() ?? .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults = LocalQAEnvironment.userDefaults() ?? .standard) {
        self.defaults = defaults
    }

    func authorize(kind: HistoryRootKind, url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        defaults.set(bookmark, forKey: bookmarkKey(for: kind))
        defaults.set(url.path, forKey: pathKey(for: kind))
    }

    func clear(kind: HistoryRootKind) {
        defaults.removeObject(forKey: bookmarkKey(for: kind))
        defaults.removeObject(forKey: pathKey(for: kind))
    }

    func displayPath(for kind: HistoryRootKind) -> String? {
        defaults.string(forKey: pathKey(for: kind))
    }

    func resolvedURL(for kind: HistoryRootKind) -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey(for: kind)) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        else { return nil }
        if isStale {
            defaults.set(url.path, forKey: pathKey(for: kind))
        }
        return url
    }

    func missingRequiredKinds(for providers: Set<String>) -> [HistoryRootKind] {
        requiredKinds(for: providers).filter { resolvedURL(for: $0) == nil }
    }

    func requiredKinds(for providers: Set<String>) -> [HistoryRootKind] {
        var kinds: [HistoryRootKind] = []
        if providers.contains("codex") {
            kinds.append(.codexHome)
        }
        if providers.contains("claude") {
            kinds.append(.claudeProjects)
        }
        return kinds
    }

    private func bookmarkKey(for kind: HistoryRootKind) -> String {
        "historyRoots.\(kind.rawValue).bookmark"
    }

    private func pathKey(for kind: HistoryRootKind) -> String {
        "historyRoots.\(kind.rawValue).path"
    }
}
