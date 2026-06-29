import Foundation
import Testing
@testable import QuotaMonitor

/// Tests for `ClaudeBinaryLocator` — the pure `claude` binary-resolution
/// helpers used for Claude Code version detection. (These were previously on
/// `ClaudeCLIRefreshTrigger`, whose spawn-to-refresh machinery was removed once
/// QuotaMonitor began refreshing tokens itself via a direct OAuth grant.)
///
/// The probe order is exercised with an injected `isExecutable` predicate, so
/// no real binary or filesystem (except the dedicated temp-dir bundle test) is
/// touched.
@Suite("ClaudeBinaryLocator")
struct ClaudeBinaryLocatorTests {

    @Test("Explicit CLAUDE_BINARY wins when executable")
    func explicitClaudeBinaryWins() {
        let executable: Set<String> = [
            "/custom/claude",
            "/Users/test/.nvm/versions/node/v1/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        let resolved = ClaudeBinaryLocator.resolveClaudeBinary(
            explicitOverride: "/custom/claude",
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/claude",
            path: "/opt/homebrew/bin",
            isExecutable: executable.contains)

        #expect(resolved == "/custom/claude")
    }

    @Test("Login-shell claude wins over hardcoded installs")
    func loginShellClaudeWinsOverHardcodedInstalls() {
        let executable: Set<String> = [
            "/Users/test/.nvm/versions/node/v1/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        let resolved = ClaudeBinaryLocator.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/claude",
            path: "/opt/homebrew/bin",
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.nvm/versions/node/v1/bin/claude")
    }

    @Test("Hardcoded claude installs are fallback when login shell has no claude")
    func hardcodedClaudeInstallsFallback() {
        let executable: Set<String> = ["/opt/homebrew/bin/claude"]

        let resolved = ClaudeBinaryLocator.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            path: "",
            isExecutable: executable.contains)

        #expect(resolved == "/opt/homebrew/bin/claude")
    }

    @Test("Claude Desktop bundled CLI supports app-only installs")
    func claudeDesktopBundledCLISupportsAppOnlyInstalls() {
        let desktop = "/Users/test/Library/Application Support/Claude/claude-code/2.1.149/claude.app/Contents/MacOS/claude"
        let executable: Set<String> = [
            desktop,
            "/opt/homebrew/bin/claude",
        ]

        let resolved = ClaudeBinaryLocator.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            path: "",
            desktopBundlePath: desktop,
            isExecutable: executable.contains)

        #expect(resolved == desktop)
    }

    @Test("User-installed claude wins over Claude Desktop bundle")
    func userInstalledClaudeWinsOverClaudeDesktopBundle() {
        let desktop = "/Users/test/Library/Application Support/Claude/claude-code/2.1.149/claude.app/Contents/MacOS/claude"
        let executable: Set<String> = [
            "/Users/test/.local/bin/claude",
            desktop,
        ]

        let resolved = ClaudeBinaryLocator.resolveClaudeBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            path: "",
            desktopBundlePath: desktop,
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.local/bin/claude")
    }

    @Test("Discovers newest Claude Desktop native CLI bundle")
    func discoversNewestClaudeDesktopNativeCLIBundle() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qm-claude-desktop-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let oldDir = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code/2.1.9/claude.app/Contents/MacOS",
            isDirectory: true)
        let newDir = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code/2.1.149/claude.app/Contents/MacOS",
            isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let oldBinary = oldDir.appendingPathComponent("claude", isDirectory: false)
        let newBinary = newDir.appendingPathComponent("claude", isDirectory: false)
        fm.createFile(atPath: oldBinary.path, contents: Data())
        fm.createFile(atPath: newBinary.path, contents: Data())
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldBinary.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)

        let resolved = ClaudeBinaryLocator.discoverClaudeDesktopBundle(
            home: home.path,
            isExecutable: fm.isExecutableFile(atPath:))

        #expect(resolved.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                == newBinary.standardizedFileURL.path)
    }
}
