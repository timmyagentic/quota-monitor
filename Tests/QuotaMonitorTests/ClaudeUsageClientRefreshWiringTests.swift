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
        /// Counts how many times the stub actually served a request — used
        /// to prove the single-flight refresh coalesces concurrent callers.
        nonisolated(unsafe) static let requestCount = Counter()
        /// Per-request artificial delay so two concurrent callers genuinely
        /// overlap at the network point (then a missing single-flight guard
        /// would show as 2 requests).
        nonisolated(unsafe) static var delayMs: UInt32 = 0
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            func reset() { lock.lock(); n = 0; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requestCount.bump()
            if Self.delayMs > 0 { usleep(Self.delayMs * 1000) }
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
        StubURLProtocol.requestCount.reset()
        StubURLProtocol.delayMs = 0
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

    /// Routes each grant by the `refresh_token` in its form body, so one
    /// `loadAccessToken` pass can see the revoked token 400 and the valid one
    /// 200. Records every body it served to prove both tokens were tried.
    final class RoutingURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var routes: [(match: String, status: Int, body: String)] = []
        static let bodies = BodyLog()
        final class BodyLog: @unchecked Sendable {
            private let lock = NSLock(); private var all: [String] = []
            func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() }
            func reset() { lock.lock(); all.removeAll(); lock.unlock() }
            var values: [String] { lock.lock(); defer { lock.unlock() }; return all }
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        static func bodyString(_ request: URLRequest) -> String {
            if let b = request.httpBody { return String(data: b, encoding: .utf8) ?? "" }
            guard let stream = request.httpBodyStream else { return "" }
            stream.open(); defer { stream.close() }
            var data = Data()
            let size = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: size)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        override func startLoading() {
            let body = Self.bodyString(request)
            Self.bodies.add(body)
            let route = Self.routes.first { body.contains($0.match) }
            let status = route?.status ?? 400
            let payload = route?.body ?? #"{"error":"no_route"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test("A revoked cached refresh token is dropped and recovery uses the file token")
    func revokedCacheFallsThrough() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let pastMs = (Date().timeIntervalSince1970 - 3600) * 1000
        // Highest-priority source (our cache) carries a token the server will
        // reject; the lower-priority file source carries a valid one.
        ClaudeOAuthCache.save(
            RefreshedClaudeCredentials(
                accessToken: "at-cache-old", refreshToken: "rt-revoked", expiresAtMs: pastMs),
            scopes: ["user:profile"], fileURL: cacheURL)
        let fileCreds = ClaudeUsageClient.StoredCredentials(
            accessToken: "at-file-old", expiresAtMs: pastMs,
            scopes: ["user:profile"], refreshToken: "rt-file-good")

        RoutingURLProtocol.routes = [
            ("rt-revoked", 400, #"{"error":"invalid_grant"}"#),
            ("rt-file-good", 200,
             #"{"access_token":"at-new","refresh_token":"rt-rotated","expires_in":28800}"#),
        ]
        RoutingURLProtocol.bodies.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = ClaudeUsageClient(
            tokenRefresher: ClaudeTokenRefresher(session: session),
            oauthCacheURL: cacheURL,
            externalCredentialSources: { [fileCreds] })

        let token = try await client._loadAccessTokenForTest()
        #expect(token == "at-new")

        // The poisoned cache was replaced with the rotation of the file token.
        let cached = try #require(ClaudeOAuthCache.load(fileURL: cacheURL))
        #expect(cached.accessToken == "at-new")
        #expect(cached.refreshToken == "rt-rotated")

        // Both tokens were attempted — revoked first, then the valid fallback.
        let bodies = RoutingURLProtocol.bodies.values
        #expect(bodies.contains { $0.contains("rt-revoked") })
        #expect(bodies.contains { $0.contains("rt-file-good") })
    }

    @Test("A transient refresh failure keeps the cache and tries no other token")
    func transientFailureKeepsCache() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let pastMs = (Date().timeIntervalSince1970 - 3600) * 1000
        ClaudeOAuthCache.save(
            RefreshedClaudeCredentials(
                accessToken: "at-cache-old", refreshToken: "rt-cache", expiresAtMs: pastMs),
            scopes: ["user:profile"], fileURL: cacheURL)
        let fileCreds = ClaudeUsageClient.StoredCredentials(
            accessToken: "at-file-old", expiresAtMs: pastMs,
            scopes: ["user:profile"], refreshToken: "rt-file-good")

        // 503 is transient: the cached token isn't revoked, so we must NOT drop
        // the cache nor burn the file token chasing a server blip.
        RoutingURLProtocol.routes = [("rt-cache", 503, #"{"error":"upstream"}"#)]
        RoutingURLProtocol.bodies.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = ClaudeUsageClient(
            tokenRefresher: ClaudeTokenRefresher(session: session),
            oauthCacheURL: cacheURL,
            externalCredentialSources: { [fileCreds] })

        // Falls back to the best stale token; cache is untouched.
        _ = try await client._loadAccessTokenForTest()
        #expect(ClaudeOAuthCache.load(fileURL: cacheURL)?.refreshToken == "rt-cache")
        let bodies = RoutingURLProtocol.bodies.values
        #expect(bodies.allSatisfy { $0.contains("rt-cache") })
        #expect(!bodies.contains { $0.contains("rt-file-good") })
    }

    @Test("Concurrent loads coalesce into a single refresh grant")
    func singleFlightRefresh() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let pastMs = (Date().timeIntervalSince1970 - 3600) * 1000
        let expired = ClaudeUsageClient.StoredCredentials(
            accessToken: "at-old", expiresAtMs: pastMs,
            scopes: ["user:profile"], refreshToken: "rt-old")

        let session = stubbedSession(json: """
            {"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}
            """)
        // Delay so both callers reach the grant before either finishes —
        // without single-flight that would record 2 requests.
        StubURLProtocol.delayMs = 150
        defer { StubURLProtocol.delayMs = 0 }

        let client = ClaudeUsageClient(
            tokenRefresher: ClaudeTokenRefresher(session: session),
            oauthCacheURL: cacheURL,
            externalCredentialSources: { [expired] })

        async let a = client._loadAccessTokenForTest()
        async let b = client._loadAccessTokenForTest()
        let (ra, rb) = try await (a, b)

        #expect(ra == "at-new")
        #expect(rb == "at-new")
        #expect(StubURLProtocol.requestCount.value == 1,
                "two concurrent refreshes must collapse to one grant")
    }
}
