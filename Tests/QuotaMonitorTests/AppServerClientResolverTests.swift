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
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: "/custom/codex",
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/codex",
            isExecutable: executable.contains)

        #expect(resolved == "/custom/codex")
    }

    @Test("login-shell codex wins over hardcoded installs")
    func loginShellCodexWinsOverHardcodedInstalls() throws {
        let executable: Set<String> = [
            "/Users/test/.nvm/versions/node/v1/bin/codex",
            "/opt/homebrew/bin/codex",
        ]

        let resolved = AppServerClient.resolveBinary(
            explicitOverride: nil,
            home: "/Users/test",
            loginShellPath: "/Users/test/.nvm/versions/node/v1/bin/codex",
            isExecutable: executable.contains)

        #expect(resolved == "/Users/test/.nvm/versions/node/v1/bin/codex")
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
}
