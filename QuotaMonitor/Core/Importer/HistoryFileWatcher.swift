import CoreServices
import Foundation

/// Delivers changes under a provider's transcript directories. The importer
/// owns file discovery, checkpoints and de-duplication.
final class HistoryFileWatcher {
    enum Provider: String, CaseIterable, Sendable {
        case codex, claude
    }

    let id: UUID

    /// Preserve the Claude importer's legacy and current directory selection.
    static func claudeDirectories(
        home: URL,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ].filter { exists($0.path) }
    }

    private(set) var rolloutWrites: CodexRolloutWriteObserver?
    private let observesOpenRollouts: Bool
    private let directories: [URL]
    private let latency: TimeInterval
    // FSEvents needs an existing directory. When a history folder is first
    // created, its parent stream also reports unrelated writes. Only forward
    // paths under the selected history folders (or a dropped-event rescan).
    private struct Location {
        let directory: String
        let target: String

        init(_ url: URL) {
            var ancestor = url
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                missing.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
            // FSEvents uses the physical path (e.g. /private/var); Foundation's
            // resolvingSymlinksInPath can return /var for the same directory.
            directory = (try? ancestor.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
                ?? ancestor.resolvingSymlinksInPath().path
            let physical = URL(fileURLWithPath: directory, isDirectory: true)
            target = missing.reversed().reduce(physical) { $0.appendingPathComponent($1) }.path
        }
    }

    private final class Callback {
        let targets: [String]
        let onChange: @Sendable () -> Void

        init(locations: [Location], onChange: @escaping @Sendable () -> Void) {
            self.targets = locations.map(\.target)
            self.onChange = onChange
        }

        func notify(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>) {
            for (index, path) in paths.enumerated() {
                if flags[index] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || targets.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    onChange()
                    return
                }
            }
        }
    }

    private let onChange: @Sendable () -> Void
    private let scopeRoots: [URL]
    /// App Store: watching a security-scoped bookmark root requires the scope to
    /// be open for the FSEvents stream's whole lifetime. `nil` for Developer ID
    /// (real HOME paths need no scope).
    private let securityScopedAccess: (any SecurityScopedResourceAccessing)?
    private var scopedAccesses: [SecurityScopedResourceAccess] = []
    private let queue = DispatchQueue(
        label: "dev.tjzhou.QuotaMonitor.history-file-watch", qos: .utility)
    private var stream: FSEventStreamRef?

    init(
        id: UUID = UUID(),
        directories: [URL],
        scopeRoots: [URL]? = nil,
        observesOpenRollouts: Bool = false,
        latency: TimeInterval = 2.0,
        securityScopedAccess: (any SecurityScopedResourceAccessing)? = nil,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.directories = directories
        self.latency = latency
        self.securityScopedAccess = securityScopedAccess
        self.scopeRoots = scopeRoots ?? directories
        self.observesOpenRollouts = observesOpenRollouts
        self.onChange = onChange
    }

    /// Begin watching. Returns `true` only when a stream is actually active
    /// afterwards — `false` if there's nothing to watch or FSEvents stream
    /// creation/start fails (a transient resource failure, etc.). The caller
    /// must not retain the watcher on `false`, so a later retry can try again
    /// instead of being blocked by a non-nil-but-dead watcher. Already-started
    /// is treated as success.
    @discardableResult
    func start() -> Bool {
        if stream != nil { return true }
        guard !directories.isEmpty else { return false }
        // Open (and hold) security scope on the watched roots before creating
        // the stream, so FSEvents can watch App Store bookmark folders. No-op
        // when no accessor was injected (Developer ID).
        var watched = directories
        if let securityScopedAccess {
            scopedAccesses = scopeRoots.map { securityScopedAccess.access($0) }
            watched = directories.filter { directory in
                scopedAccesses.contains { scope in
                    scope.didStart && (directory == scope.url
                        || directory.path.hasPrefix(scope.url.path + "/"))
                }
            }
            guard !watched.isEmpty else {
                releaseScopes()
                return false
            }
        }
        let locations = watched.map(Location.init)
        let callback = Callback(locations: locations, onChange: onChange)
        defer { withExtendedLifetime(callback) {} }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(ptr).retain().toOpaque())
            },
            release: { ptr in
                if let ptr { Unmanaged<Callback>.fromOpaque(ptr).release() }
            },
            copyDescription: nil)
        // `kFSEventStreamEventIdSinceNow` → only future events (no history
        // replay). `NoDefer` → deliver the first event after `latency` from
        // the burst start rather than continually deferring.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, paths, flags, _ in
                guard let info,
                      let strings = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]
                else { return }
                Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().notify(paths: strings, flags: flags)
            },
            &context,
            Array(Set(locations.map(\.directory))) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            releaseScopes()
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            releaseScopes()
            return false
        }
        stream = created
        if observesOpenRollouts {
            let writes = CodexRolloutWriteObserver(directories: watched, onChange: onChange)
            rolloutWrites = writes
            writes.start()
        }
        return true
    }

    func stop() {
        rolloutWrites?.stop()
        rolloutWrites = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        releaseScopes()
    }

    private func releaseScopes() {
        scopedAccesses.reversed().forEach { $0.stop() }
        scopedAccesses = []
    }

    deinit { stop() }
}
