import Darwin
import Foundation

// Enumerates rollout-*.jsonl files under $CODEX_HOME/sessions/ and
// $CODEX_HOME/archived_sessions/.
// Returns lightweight metadata so the ImportEngine can decide which files
// have changed since the last scan.

struct SessionFile: Equatable {
    let url: URL
    let path: String
    let fileSize: Int64
    let fileMtimeMs: Int64
    let sourceIdentity: RolloutSourceIdentity
    /// Either "active" (under sessions/) or "archived" (under archived_sessions/).
    /// Mirrors codex-pacer's bucket label. Currently informational only.
    let bucket: String

    var sessionIdHint: String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }
}

enum SessionScanner {

    /// Resolve the Codex history root. Developer ID builds keep the legacy
    /// `$CODEX_HOME` → `~/.codex` fallback; App Store builds must use a
    /// directory the user selected and the app persisted as a security-scoped
    /// bookmark.
    static func defaultCodexHome(
        distribution: DistributionChannel = .current,
        authorizations: HistoryRootAuthorizationStore = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        if let qaCodexHome = LocalQAEnvironment.codexHomeDirectory(
            environment: environment,
            arguments: arguments) {
            return qaCodexHome
        }

        if distribution == .appStore {
            return authorizations.resolvedURL(for: .codexHome)
        }

        if let override = environment["CODEX_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Walk both `<codexHome>/sessions/` and `<codexHome>/archived_sessions/`
    /// and return rollout-*.jsonl entries from each. Codex moves rollouts to
    /// archived_sessions/ when the user uses the CLI's archive command;
    /// without this branch their data silently drops out of the dashboard
    /// (verified locally: 14 archived files were invisible before this fix).
    static func scan(codexHome: URL) -> [SessionFile] {
        var results: [SessionFile] = []
        for (folder, bucket) in [("sessions", "active"), ("archived_sessions", "archived")] {
            let root = codexHome.appendingPathComponent(folder, isDirectory: true)
            results.append(contentsOf: walk(root: root, bucket: bucket))
        }
        return results
    }

    private static func walk(root: URL, bucket: String) -> [SessionFile] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var results: [SessionFile] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            var value = Darwin.stat()
            let status = fileURL.path.withCString { path in
                Darwin.lstat(path, &value)
            }
            guard status == 0 else { continue }
            let size = Int64(value.st_size)
            let mtimeMs = RolloutFileSnapshot.modificationTimeMilliseconds(
                seconds: Int64(value.st_mtimespec.tv_sec),
                nanoseconds: Int64(value.st_mtimespec.tv_nsec))
            let birthtimeNs = Int64(value.st_birthtimespec.tv_sec) * 1_000_000_000
                + Int64(value.st_birthtimespec.tv_nsec)

            results.append(SessionFile(
                url: fileURL,
                path: fileURL.path,
                fileSize: size,
                fileMtimeMs: mtimeMs,
                sourceIdentity: RolloutSourceIdentity(
                    device: Int64(value.st_dev),
                    inode: Int64(bitPattern: UInt64(value.st_ino)),
                    birthtimeNs: birthtimeNs),
                bucket: bucket))
        }
        return results
    }
}
