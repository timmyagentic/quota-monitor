import Foundation

enum HistoryRootKind: String, CaseIterable, Sendable, Identifiable {
    case codexHome
    case claudeProjects
    case claudeConfigProjects

    var id: String { rawValue }

    /// Validate that `url` (a folder the user picked in an NSOpenPanel) looks
    /// like the expected history root for this kind, returning the URL to
    /// actually bookmark — which may be a child of the pick (e.g. the user
    /// selected `~` but we want `~/.codex`, or a Claude parent that contains
    /// `projects`). Returns `nil` when the pick doesn't match, so the caller
    /// can reject it instead of silently authorizing a wrong folder that would
    /// import nothing. Pure (filesystem probe is injectable) → unit-testable.
    func resolveSelectedFolder(
        _ url: URL,
        directoryExists: (URL) -> Bool = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                && isDir.boolValue
        }
    ) -> URL? {
        func child(_ parent: URL, _ name: String) -> URL {
            parent.appendingPathComponent(name, isDirectory: true)
        }
        switch self {
        case .codexHome:
            // Accept the Codex home by NAME (a fresh `.codex` may not have
            // `sessions`/`archived_sessions` yet) or by content.
            if url.lastPathComponent == ".codex"
                || directoryExists(child(url, "sessions"))
                || directoryExists(child(url, "archived_sessions")) {
                return url
            }
            // Tolerate a parent pick: resolve to a `<pick>/.codex` child if it
            // exists (even when empty) or already holds session folders.
            let dotCodex = child(url, ".codex")
            if directoryExists(dotCodex)
                || directoryExists(child(dotCodex, "sessions"))
                || directoryExists(child(dotCodex, "archived_sessions")) {
                return dotCodex
            }
            return nil
        case .claudeProjects, .claudeConfigProjects:
            if url.lastPathComponent == "projects" { return url }
            // Tolerate a parent pick: accept `<pick>/projects` if present.
            let projects = child(url, "projects")
            if directoryExists(projects) { return projects }
            return nil
        }
    }
}

struct SecurityScopedResourceAccess: Sendable {
    let url: URL
    /// Whether `startAccessingSecurityScopedResource()` actually opened the
    /// scope. For a non-security-scoped URL (e.g. a Developer ID real path)
    /// this is `false` and harmless — the read succeeds without a scope. For a
    /// bookmark-backed App Store URL, `false` means the scope could NOT be
    /// opened (folder moved/revoked, TCC reset), so a read will find nothing:
    /// callers should treat that as "folder access unavailable", not empty.
    let didStart: Bool
    private let stopHandler: @Sendable () -> Void

    init(url: URL, didStart: Bool, stop: @escaping @Sendable () -> Void) {
        self.url = url
        self.didStart = didStart
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
        return SecurityScopedResourceAccess(url: url, didStart: didStart) {
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
            // The App Store entitlement is `…files.user-selected.read-only`, so
            // the persisted bookmark must be created read-only too — a plain
            // `.withSecurityScope` bookmark requests read-write scope the
            // entitlement can't grant and fails to persist in the sandbox.
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
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
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil) {
                defaults.set(refreshed, forKey: bookmarkKey(for: kind))
            }
            defaults.set(url.path, forKey: pathKey(for: kind))
        }
        return url
    }

    func missingRequiredKinds(for providers: Set<String>) -> [HistoryRootKind] {
        var missing: [HistoryRootKind] = []
        if providers.contains("codex"), resolvedURL(for: .codexHome) == nil {
            missing.append(.codexHome)
        }
        if providers.contains("claude") {
            // Claude imports from either the primary `~/.claude/projects` or the
            // alternate `~/.config/claude/projects` (`ClaudeImportEngine.defaultRoots`
            // scans whichever is bookmarked), so authorizing either one is enough.
            // Only report the primary kind as missing when neither is granted.
            let claudeAuthorized = resolvedURL(for: .claudeProjects) != nil
                || resolvedURL(for: .claudeConfigProjects) != nil
            if !claudeAuthorized {
                missing.append(.claudeProjects)
            }
        }
        return missing
    }

    /// The subset of `providers` whose required history folders are all
    /// authorized. Used to scope a scan to what we can actually read instead
    /// of aborting the whole scan when only one provider is unauthorized — so
    /// an authorized Codex keeps importing while Claude awaits a folder grant.
    /// A provider with no folder requirement counts as authorized.
    func authorizedProviders(from providers: Set<String>) -> Set<String> {
        Set(providers.filter { missingRequiredKinds(for: [$0]).isEmpty })
    }

    private func bookmarkKey(for kind: HistoryRootKind) -> String {
        "historyRoots.\(kind.rawValue).bookmark"
    }

    private func pathKey(for kind: HistoryRootKind) -> String {
        "historyRoots.\(kind.rawValue).path"
    }
}
