import CoreServices
import Foundation

/// Watches the Claude transcript directories (`~/.claude/projects`,
/// `~/.config/claude/projects`) and fires `onChange` — coalesced by the
/// FSEvents `latency` — whenever anything under them is written.
///
/// Used to refresh local Claude usage/cost the moment Claude Code appends to
/// a transcript, instead of only when the popover opens. The caller funnels
/// `onChange` into a **Claude-scoped** `runScan` (see
/// `AppEnvironment.resolveScanProviders`) so reacting to a `~/.claude` write
/// never triggers Codex's expensive whole-file re-parse, and through the
/// existing `runScan` throttle/`isScanning` guard so a chatty session can't
/// cause a scan storm.
final class ClaudeFileWatcher {

    /// The Claude transcript roots under `home` that currently exist —
    /// mirrors `ClaudeImportEngine`'s legacy + new layout. FSEvents can't
    /// watch a path that doesn't exist yet, so non-existent roots are
    /// dropped (a fresh install with no Claude history simply isn't watched).
    static func watchedDirectories(
        home: URL,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ].filter { exists($0.path) }
    }

    private let directories: [URL]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(
        label: "dev.tjzhou.QuotaMonitor.claude-file-watch", qos: .utility)
    private var stream: FSEventStreamRef?

    init(
        directories: [URL],
        latency: TimeInterval = 2.0,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.directories = directories
        self.latency = latency
        self.onChange = onChange
    }

    /// Begin watching. No-op if already started or if there's nothing to
    /// watch. The FSEvents callback only ever reads the immutable
    /// `onChange` closure (bridged via the stream context), so it is safe
    /// to fire on the watcher's background queue.
    func start() {
        guard stream == nil, !directories.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // `kFSEventStreamEventIdSinceNow` → only future events (no history
        // replay). `NoDefer` → deliver the first event after `latency` from
        // the burst start rather than continually deferring.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<ClaudeFileWatcher>
                    .fromOpaque(info).takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            directories.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
