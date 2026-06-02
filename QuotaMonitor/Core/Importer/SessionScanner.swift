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

    /// Resolve $CODEX_HOME (env var → ~/.codex).
    static func defaultCodexHome() -> URL {
        if let qaCodexHome = LocalQAEnvironment.codexHomeDirectory() {
            return qaCodexHome
        }
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"],
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
    static func scan(codexHome: URL = defaultCodexHome()) -> [SessionFile] {
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

            let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let size = Int64(values?.fileSize ?? 0)
            let mtimeMs = Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)

            results.append(SessionFile(
                url: fileURL,
                path: fileURL.path,
                fileSize: size,
                fileMtimeMs: mtimeMs,
                bucket: bucket))
        }
        return results
    }
}
