import Foundation
import Testing
@testable import QuotaMonitor

/// Pure-function tests for the direct OAuth refresh-token grant that lets
/// QuotaMonitor mint a fresh Claude access token without spawning the
/// `claude` CLI. Mirrors CodexBar's flow: POST the refresh token to
/// Anthropic's OAuth token endpoint, form-encoded, with the public Claude
/// Code client_id.
@Suite("ClaudeTokenRefresher")
struct ClaudeTokenRefresherTests {

    @Test("Refresh request is a form-encoded POST to the OAuth token endpoint")
    func refreshRequestShape() throws {
        let request = ClaudeTokenRefresher.makeRefreshRequest(refreshToken: "rt-123")

        #expect(request.httpMethod == "POST")
        #expect(request.url == ClaudeTokenRefresher.defaultEndpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=rt-123"))
        #expect(body.contains("client_id=\(ClaudeTokenRefresher.defaultClientID)"))
    }

    @Test("A successful refresh response parses tokens and computes expiry")
    func parseRefreshSuccess() throws {
        let json = Data("""
        {"access_token":"at-new","refresh_token":"rt-new","expires_in":28800,"token_type":"Bearer"}
        """.utf8)
        let now = Date(timeIntervalSince1970: 1000)

        let creds = try ClaudeTokenRefresher.parseRefreshResponse(data: json, now: now)

        #expect(creds.accessToken == "at-new")
        #expect(creds.refreshToken == "rt-new")
        // expiresAt = (now + expires_in) in ms
        #expect(creds.expiresAtMs == (1000 + 28800) * 1000)
    }

    @Test("A refresh response missing access_token is rejected")
    func parseRefreshMissingAccessToken() {
        let json = Data(#"{"refresh_token":"rt-new","expires_in":28800}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try ClaudeTokenRefresher.parseRefreshResponse(data: json, now: Date())
        }
    }

    @Test("Stored credentials expose the refresh token")
    func storedCredentialsParseRefreshToken() throws {
        let json = Data("""
        {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":123,"scopes":["user:profile"]}}
        """.utf8)

        let creds = try #require(ClaudeUsageClient.parseCredentials(jsonData: json))
        #expect(creds.accessToken == "a")
        #expect(creds.refreshToken == "r")
    }
}
