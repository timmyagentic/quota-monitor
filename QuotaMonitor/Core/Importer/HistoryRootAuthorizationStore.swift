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
            // Apple's contract: when a security-scoped bookmark resolves stale
            // we must regenerate it from the resolved URL (while holding scope)
            // and persist the new bytes — otherwise the stale bookmark keeps
            // resolving on borrowed time and eventually fails on a later
            // launch, silently dropping this history root. Re-create it now.
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil) {
                defaults.set(refreshed, forKey: bookmarkKey(for: kind))
            }
            defaults.set(url.path, forKey: pathKey(for: kind))
        }
        return url
    }

    func missingRequiredKinds(for providers: Set<String>) -> [HistoryRootKind] {
        requiredKinds(for: providers).filter { resolvedURL(for: $0) == nil }
    }

    /// The subset of `providers` whose required history folders are all
    /// authorized. Used to scope a scan to what we can actually read instead
    /// of aborting the whole scan when only one provider is unauthorized — so
    /// an authorized Codex keeps importing while Claude awaits a folder grant.
    /// A provider with no folder requirement counts as authorized.
    func authorizedProviders(from providers: Set<String>) -> Set<String> {
        Set(providers.filter { missingRequiredKinds(for: [$0]).isEmpty })
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
