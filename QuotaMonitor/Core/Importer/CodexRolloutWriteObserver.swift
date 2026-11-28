import Darwin
import Foundation

/// Directory FSEvents discover rollouts and moves, but can delay modifications
/// until the writer closes. EVFILT_VNODE also signals writes on an open file.
final class CodexRolloutWriteObserver: @unchecked Sendable {
    // launchd's default soft limit is 256. Leave descriptors available to
    // SQLite, the app server and the importer even with years of transcripts.
    static let defaultLimit: Int = {
        var budget = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &budget) == 0 else { return 64 }
        return Int(min(128, budget.rlim_cur / 2))
    }()

    private struct Watch {
        let identity: RolloutSourceIdentity
        let source: DispatchSourceFileSystemObject
    }

    private let directories: [URL]
    private let allowedPrefixes: [String]
    private let limit: Int
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.tjzhou.QuotaMonitor.rollout-writes", qos: .utility)
    // The queue owns the inventory and the dispatch sources.
    private var watches: [String: Watch] = [:]
    private var writeNotifications = 0
    private var stopped = false
    private let queueKey = DispatchSpecificKey<Bool>()

    init(directories: [URL], limit: Int = defaultLimit, onChange: @escaping @Sendable () -> Void) {
        self.directories = directories
        allowedPrefixes = directories.flatMap { root in
            [root.path, root.standardizedFileURL.path,
             (try? root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? root.path]
        }.map { $0 + "/" }
        self.limit = limit
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() {
        let started = Int64(Date().timeIntervalSince1970 * 1000)
        queue.async {
            guard !self.stopped else { return }
            let files = self.directories.flatMap(SessionScanner.files(in:))
            self.reconcile(files)
            if files.contains(where: { $0.fileMtimeMs >= started }) { self.onChange() }
        }
    }

    /// Reuse the importer's discovery pass. Install before it reads the
    /// selected files so subsequent appends get a trailing scan.
    func observe(_ files: [SessionFile]) {
        synchronized {
            guard !stopped else { return }
            reconcile(files)
        }
    }

    func stop() {
        synchronized {
            stopped = true
            for watch in watches.values { watch.source.cancel() }
            watches.removeAll()
        }
    }

    private func synchronized(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private func reconcile(_ files: [SessionFile]) {
        let recent = files.filter { file in
            allowedPrefixes.contains { file.path.hasPrefix($0) }
        }.sorted {
            if $0.fileMtimeMs != $1.fileMtimeMs { return $0.fileMtimeMs > $1.fileMtimeMs }
            return $0.path < $1.path
        }.prefix(limit)
        let previousCount = watches.count
        let identities = Dictionary(recent.map { ($0.path, $0.sourceIdentity) },
                                    uniquingKeysWith: { first, _ in first })
        for (path, watch) in watches where identities[path] != watch.identity {
            watch.source.cancel()
            watches.removeValue(forKey: path)
        }
        for file in recent where watches[file.path] == nil { attach(file) }
        if previousCount != watches.count || writeNotifications > 0 {
            DeveloperLog.eventRecord(
                "codex_file_watch.rollouts", category: "scan", provider: "codex",
                fields: ["watched_files": .int(watches.count), "discovered_files": .int(files.count),
                         "write_notifications": .int(writeNotifications)])
        }
        writeNotifications = 0
    }

    private func attach(_ file: SessionFile) {
        let fd = open(file.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Int64(info.st_dev) == file.sourceIdentity.device,
              UInt64(info.st_ino) == UInt64(bitPattern: file.sourceIdentity.inode),
              Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec)
                == file.sourceIdentity.birthtimeNs else {
            close(fd)
            onChange()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped, let watch = self.watches[file.path],
                  watch.identity == file.sourceIdentity else { return }
            if !watch.source.data.intersection([.write, .extend]).isEmpty { self.writeNotifications += 1 }
            self.onChange()
        }
        source.setCancelHandler { close(fd) }
        // A write can land between the directory stat and kqueue registration.
        source.setRegistrationHandler { [onChange] in
            var current = stat()
            if fstat(fd, &current) == 0,
               current.st_nlink == 0 || current.st_size != file.fileSize || RolloutFileSnapshot.modificationTimeMilliseconds(
                    seconds: Int64(current.st_mtimespec.tv_sec),
                    nanoseconds: Int64(current.st_mtimespec.tv_nsec)) != file.fileMtimeMs {
                onChange()
            }
        }
        watches[file.path] = Watch(identity: file.sourceIdentity, source: source)
        source.activate()
    }
}
