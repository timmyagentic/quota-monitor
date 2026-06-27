import Foundation
import Testing
@testable import QuotaMonitor

/// Integration of the direct-refresh path inside `ClaudeUsageClient`:
/// an expired credential carrying a refresh token must be refreshed via
/// `ClaudeTokenRefresher` and the result persisted to the private cache —
/// all against injected sources + a stubbed `URLSession`, so the test never
/// reads real `~/.claude` credentials nor hits the network.
///
/// `.serialized` because the URLProtocol stub uses shared static state.
@Suite("ClaudeUsageClient direct refresh wiring", .serialized)
struct ClaudeUsageClientRefreshWiringTests {

    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responseBody = Data()
        nonisolated(unsafe) static var statusCode = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.statusCode,
                httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubbedSession(json: String, status: Int = 200) -> URLSession {
        StubURLProtocol.responseBody = Data(json.utf8)
        StubURLProtocol.statusCode = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func tempCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qm-oauth-\(UUID().uuidString)")
            .appendingPathComponent("claude-oauth.json")
    }

    @Test("An expired source token is refreshed directly and cached")
    func refreshesAndCaches() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let pastMs = (Date().timeIntervalSince1970 - 3600) * 1000
        let expired = ClaudeUsageClient.StoredCredentials(
            accessToken: "at-old", expiresAtMs: pastMs,
            scopes: ["user:profile"], refreshToken: "rt-old")

        let client = ClaudeUsageClient(
            tokenRefresher: ClaudeTokenRefresher(session: stubbedSession(json: """
                {"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}
                """)),
            oauthCacheURL: cacheURL,
            externalCredentialSources: { [expired] })

        let token = try await client._loadAccessTokenForTest()
        #expect(token == "at-new")

        let cached = try #require(ClaudeOAuthCache.load(fileURL: cacheURL))
        #expect(cached.accessToken == "at-new")
        #expect(cached.refreshToken == "rt-new")
        #expect(cached.scopes == ["user:profile"])
    }

    @Test("A failed refresh surfaces the stale token and writes no cache")
    func refreshFailureReturnsStale() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let pastMs = (Date().timeIntervalSince1970 - 3600) * 1000
        let expired = ClaudeUsageClient.StoredCredentials(
            accessToken: "at-old", expiresAtMs: pastMs,
            scopes: nil, refreshToken: "rt-old")

        let client = ClaudeUsageClient(
            tokenRefresher: ClaudeTokenRefresher(
                session: stubbedSession(json: #"{"error":"invalid_grant"}"#, status: 400)),
            oauthCacheURL: cacheURL,
            externalCredentialSources: { [expired] })

        let token = try await client._loadAccessTokenForTest()
        #expect(token == "at-old")
        #expect(ClaudeOAuthCache.load(fileURL: cacheURL) == nil)
    }
}
