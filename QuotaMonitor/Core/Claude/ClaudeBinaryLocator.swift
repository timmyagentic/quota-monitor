import Foundation

/// Locates the user's `claude` executable so QuotaMonitor can read the
/// installed Claude Code version (see `ClaudeCodeVersionDetector`).
///
/// **History.** This was previously `ClaudeCLIRefreshTrigger`, which spawned
/// `claude --version` to force the CLI to refresh expired Claude Code OAuth
/// credentials and then watched the Keychain for the change. QuotaMonitor now
/// refreshes the token itself via a direct OAuth refresh-token grant
/// (`ClaudeTokenRefresher` → `ClaudeOAuthCache`), so that spawn-to-refresh path
/// — along with its cooldown/back-off state and Keychain-mdat polling — was
/// removed as dead code. Only the pure binary-resolution helpers remain, and
/// they are used purely for version detection now.
enum ClaudeBinaryLocator {

    /// Probe for an executable `claude`, matching the user's terminal
    /// before common hardcoded install directories.
    static func resolveClaudeBinary(
        explicitOverride: String?,
        home: String,
        loginShellPath: String?,
        path: String,
        desktopBundlePath: String? = nil,
        isExecutable: (String) -> Bool
    ) -> String? {
        if let override = explicitOverride, !override.isEmpty, isExecutable(override) {
            return override
        }
        if let shellPath = loginShellPath, !shellPath.isEmpty, isExecutable(shellPath) {
            return shellPath
        }
        let userCandidates = [
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.cargo/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        for candidate in userCandidates where isExecutable(candidate) {
            return candidate
        }
        if let desktopBundlePath, isExecutable(desktopBundlePath) {
            return desktopBundlePath
        }
        let packageManagerCandidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for candidate in packageManagerCandidates where isExecutable(candidate) {
            return candidate
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Claude Desktop can download a native Claude Code build into
    /// `~/Library/Application Support/Claude/claude-code/<version>/claude.app`.
    /// That covers users who installed the desktop app but never put a
    /// standalone `claude` binary on PATH. The VM copy next to it is an ELF
    /// Linux binary, so only the `.app/Contents/MacOS/claude` path is usable
    /// from QuotaMonitor on macOS.
    static func discoverClaudeDesktopBundle(
        home: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        let root = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Claude/claude-code",
                                    isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return nil }

        let candidates = versions
            .filter { $0.hasDirectoryPath }
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: [.numeric, .caseInsensitive]) == .orderedDescending
            }
            .map {
                $0.appendingPathComponent("claude.app/Contents/MacOS/claude",
                                          isDirectory: false).path
            }

        return candidates.first(where: isExecutable)
    }
}
