import Foundation
import Testing
@testable import QuotaMonitor

/// Pins the pure decision at the heart of the direct-refresh fix: given the
/// candidate credential sources (QM cache → file → Keychain, in priority
/// order) plus the set of server-rejected tokens, decide whether we already
/// hold a usable access token, must refresh (and with which refresh token),
/// or have nothing to work with.
@Suite("ClaudeUsageClient token resolution")
struct ClaudeAccessTokenResolutionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var freshMs: Double { (1_000_000 + 3600) * 1000 }   // 1h out
    private var expiredMs: Double { (1_000_000 - 10) * 1000 }   // already past

    private func creds(
        _ token: String, expiresAtMs: Double?, refreshToken: String? = nil
    ) -> ClaudeUsageClient.StoredCredentials {
        .init(accessToken: token, expiresAtMs: expiresAtMs,
              scopes: nil, refreshToken: refreshToken)
    }

    @Test("Returns the first usable token")
    func firstUsable() {
        let fresh = creds("at-fresh", expiresAtMs: freshMs)
        #expect(ClaudeUsageClient.resolveToken(
            candidates: [fresh], rejected: [], now: now) == .ready("at-fresh"))
    }

    @Test("Skips an expired source to the next usable one")
    func skipsExpired() {
        let result = ClaudeUsageClient.resolveToken(
            candidates: [creds("at-old", expiresAtMs: expiredMs),
                         creds("at-fresh", expiresAtMs: freshMs)],
            rejected: [], now: now)
        #expect(result == .ready("at-fresh"))
    }

    @Test("Skips a server-rejected token even when locally fresh")
    func skipsRejected() {
        let result = ClaudeUsageClient.resolveToken(
            candidates: [creds("at-bad", expiresAtMs: freshMs),
                         creds("at-good", expiresAtMs: freshMs)],
            rejected: ["at-bad"], now: now)
        #expect(result == .ready("at-good"))
    }

    @Test("Asks to refresh, using the highest-priority refresh token, when all are unusable")
    func mustRefreshPrefersPriority() {
        let result = ClaudeUsageClient.resolveToken(
            candidates: [creds("at-cache", expiresAtMs: expiredMs, refreshToken: "rt-cache"),
                         creds("at-file", expiresAtMs: expiredMs, refreshToken: "rt-file")],
            rejected: [], now: now)
        #expect(result == .mustRefresh("rt-cache"))
    }

    @Test("A rejected-but-refreshable token resolves to a refresh")
    func rejectedWithRefreshToken() {
        let result = ClaudeUsageClient.resolveToken(
            candidates: [creds("at-bad", expiresAtMs: freshMs, refreshToken: "rt-1")],
            rejected: ["at-bad"], now: now)
        #expect(result == .mustRefresh("rt-1"))
    }

    @Test("Unavailable when nothing is usable and no refresh token exists")
    func unavailable() {
        let result = ClaudeUsageClient.resolveToken(
            candidates: [creds("at-old", expiresAtMs: expiredMs)],
            rejected: [], now: now)
        #expect(result == .unavailable)
    }
}
