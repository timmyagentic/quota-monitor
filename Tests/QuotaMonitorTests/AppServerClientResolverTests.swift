import Darwin
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("AppServerClient binary resolver")
struct AppServerClientResolverTests {

    @Test("explicit override wins when executable")
    func explicitOverrideWins() throws {
        let executable: Set<String> = [
            "/custom/codex",
            "/Users/test/.nvm/versions/node/v1/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: "/custom/codex",
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/codex",
            isExecutable: executable.contains)

        #expect(resolved == "/custom/codex")
    }

    @Test("login-shell codex wins over CLI fallbacks when no app bundle exists")
    func loginShellCodexWinsOverCLIFallbacks() throws {
        let executable: Set<String> = [
            "/Users/test/.nvm/versions/node/v1/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/codex",
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.nvm/versions/node/v1/bin/codex")
    }

    @Test("desktop app bundle avoids login-shell discovery")
    func desktopAppBundleAvoidsLoginShellDiscovery() throws {
        let executable: Set<String> = [
            "/Users/test/.nvm/versions/node/v1/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        var evaluatedLoginShell = false

        func loginShellCodex() -> String? {
            evaluatedLoginShell = true
            return "/Users/test/.nvm/versions/node/v1/bin/codex"
        }

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: loginShellCodex(),
            isExecutable: executable.contains)

        #expect(resolved == "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(!evaluatedLoginShell)
    }

    @Test("desktop app binary skips login-shell PATH augmentation")
    func desktopAppBinarySkipsLoginShellPATHAugmentation() throws {
        var evaluatedLoginShell = false

        func loginShellPATH() -> String? {
            evaluatedLoginShell = true
            return "/Users/test/.nvm/bin"
        }

        let resolved = AppServerClient.loginShellPathForEnvironment(
            binaryPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
            discoveredPath: loginShellPATH())

        #expect(resolved == nil)
        #expect(!evaluatedLoginShell)
    }

    @Test("a custom binary with an app-like suffix still receives login-shell PATH")
    func customAppLikeBinaryReceivesLoginShellPATH() throws {
        var evaluatedLoginShell = false

        func loginShellPATH() -> String? {
            evaluatedLoginShell = true
            return "/Users/test/.nvm/bin"
        }

        let resolved = AppServerClient.loginShellPathForEnvironment(
            binaryPath: "/tmp/Custom/ChatGPT.app/Contents/Resources/codex",
            home: "/Users/test",
            discoveredPath: loginShellPATH())

        #expect(resolved == "/Users/test/.nvm/bin")
        #expect(evaluatedLoginShell)
    }

    @Test("login-shell PATH resolution keeps the first executable")
    func loginShellPATHResolutionKeepsFirstExecutable() throws {
        let executable: Set<String> = [
            "/first/bin/codex",
            "/second/bin/codex",
        ]

        let resolved = AppServerClient.executable(
            named: "codex",
            inPath: "/missing:/first/bin:/second/bin",
            isExecutable: executable.contains)

        #expect(resolved == "/first/bin/codex")
    }

    @Test("login-shell probe kills a foreground process after timeout")
    func loginShellProbeKillsForegroundProcessAfterTimeout() throws {
        let pidFile = Self.temporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let startedAt = Date()
        let result = AppServerClient.runLoginShellLine(
            shell: "/bin/sh",
            command: "printf %s $$ > \(Self.shellQuote(pidFile.path)); trap '' TERM; exec sleep 3",
            timeout: 0.5)

        #expect(result == nil)
        #expect(Date().timeIntervalSince(startedAt) < 1)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(pid != nil)
        if let pid {
            #expect(Self.waitForProcessToExit(pid, timeout: 0.5))
        }
    }

    @Test("login-shell timeout kills an observed background child")
    func loginShellTimeoutKillsObservedBackgroundChild() throws {
        let pidFile = Self.temporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let result = AppServerClient.runLoginShellLine(
            shell: "/bin/sh",
            command: "(trap '' HUP TERM; exec sleep 3) & child=$!; printf %s \"$child\" > \(Self.shellQuote(pidFile.path)); wait",
            timeout: 0.5)

        #expect(result == nil)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(pid != nil)
        if let pid {
            #expect(Self.waitForProcessToExit(pid, timeout: 0.5))
        }
    }

    @Test("successful login-shell probe does not wait for or terminate a background child")
    func successfulLoginShellProbeLeavesBackgroundChildRunning() throws {
        let pidFile = Self.temporaryPIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let startedAt = Date()
        let result = AppServerClient.runLoginShellLine(
            shell: "/bin/sh",
            command: "(trap '' HUP TERM; exec sleep 3) & child=$!; printf %s \"$child\" > \(Self.shellQuote(pidFile.path)); printf /tmp/codex",
            timeout: 1)

        #expect(result == "/tmp/codex")
        #expect(Date().timeIntervalSince(startedAt) < 1)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(pid != nil)
        if let pid {
            #expect(Self.processIsRunning(pid))
            _ = kill(pid, SIGKILL)
            #expect(Self.waitForProcessToExit(pid, timeout: 0.5))
        }
    }

    @Test("login-shell probe rejects oversized command output")
    func loginShellProbeRejectsOversizedOutput() throws {
        let result = AppServerClient.runLoginShellLine(
            shell: "/bin/sh",
            command: "/usr/bin/yes x | /usr/bin/head -c 70000",
            timeout: 1)

        #expect(result == nil)
    }

    @Test("login-shell probe supports a non-POSIX csh command parser")
    func loginShellProbeSupportsCsh() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/csh") else { return }

        let result = AppServerClient.runLoginShellLine(
            shell: "/bin/csh",
            command: "printf /tmp/codex",
            timeout: 1)

        #expect(result == "/tmp/codex")
    }

    @Test("home npm-global bin is used before Homebrew install")
    func homeNpmGlobalBinUsedBeforeHomebrewInstall() throws {
        let executable: Set<String> = [
            "/Users/test/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.npm-global/bin/codex")
    }

    @Test("home bun bin is used before Homebrew install")
    func homeBunBinUsedBeforeHomebrewInstall() throws {
        let executable: Set<String> = [
            "/Users/test/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.bun/bin/codex")
    }

    @Test("Codex desktop bundle supports app-only installs")
    func codexDesktopBundleSupportsAppOnlyInstalls() throws {
        let executable: Set<String> = [
            "/Applications/Codex.app/Contents/Resources/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Applications/Codex.app/Contents/Resources/codex")
    }

    @Test("unified ChatGPT desktop bundle supports app-only installs")
    func chatGPTDesktopBundleSupportsAppOnlyInstalls() throws {
        let executable: Set<String> = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    @Test("system ChatGPT bundle wins over user legacy Codex and Homebrew fallbacks")
    func chatGPTDesktopBundleWinsOverLegacyFallbacks() throws {
        let executable: Set<String> = [
            "/Users/test/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    @Test("Codex desktop bundle wins over hardcoded Homebrew fallback")
    func codexDesktopBundleWinsOverHardcodedHomebrewFallback() throws {
        let executable: Set<String> = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Applications/Codex.app/Contents/Resources/codex")
    }

    @Test("user Applications Codex bundle is checked before system Applications")
    func userApplicationsCodexBundleCheckedBeforeSystemApplications() throws {
        let executable: Set<String> = [
            "/Users/test/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/Applications/Codex.app/Contents/Resources/codex")
    }

    @Test("user Applications ChatGPT bundle is checked before system Applications")
    func userApplicationsChatGPTBundleCheckedBeforeSystemApplications() throws {
        let executable: Set<String> = [
            "/Users/test/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Users/test/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    @Test("hardcoded installs are fallback when login shell has no codex")
    func hardcodedInstallsFallback() throws {
        let executable: Set<String> = ["/opt/homebrew/bin/codex"]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: nil,
            isExecutable: executable.contains)

        #expect(resolved == "/opt/homebrew/bin/codex")
    }

    private static func temporaryPIDFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-monitor-shell-pid-\(UUID().uuidString)")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func waitForProcessToExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            errno = 0
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return false
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
