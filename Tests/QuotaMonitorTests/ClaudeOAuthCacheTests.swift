import Foundation
import Testing
@testable import QuotaMonitor

/// `ClaudeOAuthCache` is QuotaMonitor's *private* store for tokens it
/// refreshed itself. It deliberately lives outside `~/.claude` so a refresh
/// can never corrupt the user's real Claude Code login. These tests pin the
/// round-trip and the security posture (owner-only file mode), all against
/// an injected temp path so they never touch a real cache.
@Suite("ClaudeOAuthCache")
struct ClaudeOAuthCacheTests {

    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qm-oauth-\(UUID().uuidString)")
            .appendingPathComponent("claude-oauth.json")
    }

    @Test("Saved credentials round-trip through load")
    func saveLoadRoundTrip() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let refreshed = RefreshedClaudeCredentials(
            accessToken: "at-1", refreshToken: "rt-1", expiresAtMs: 1_800_000_000_000)
        ClaudeOAuthCache.save(refreshed, scopes: ["user:profile"], fileURL: url)

        let loaded = try #require(ClaudeOAuthCache.load(fileURL: url))
        #expect(loaded.accessToken == "at-1")
        #expect(loaded.refreshToken == "rt-1")
        #expect(loaded.expiresAtMs == 1_800_000_000_000)
        #expect(loaded.scopes == ["user:profile"])
    }

    @Test("Loading a missing cache returns nil")
    func loadMissingReturnsNil() {
        #expect(ClaudeOAuthCache.load(fileURL: tempFile()) == nil)
    }

    @Test("Cache file is written owner-only (0600)")
    func cacheFileIsOwnerOnly() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        ClaudeOAuthCache.save(
            RefreshedClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAtMs: 1),
            scopes: nil, fileURL: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect(perms.int16Value == 0o600)
    }
}
