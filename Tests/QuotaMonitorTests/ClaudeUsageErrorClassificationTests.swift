import Foundation
import Testing
@testable import QuotaMonitor

/// The menu bar must show an actionable hint (instead of silently keeping
/// stale numbers) when the Claude fetch fails for a *persistent* reason —
/// an expired/revoked token that direct refresh couldn't recover, missing
/// credentials, or an insufficient scope. Transient failures (429, network)
/// must NOT trip this, so a momentary blip doesn't blank a healthy block.
@Suite("ClaudeUsageClient auth-class error classification")
struct ClaudeUsageErrorClassificationTests {
    typealias FetchError = ClaudeUsageClient.FetchError

    @Test("Persistent auth failures are auth-class")
    func authClassErrors() {
        let authErrors: [FetchError] = [.unauthorized, .noCredentials, .insufficientScope]
        for err in authErrors {
            #expect(ClaudeUsageClient.isAuthClassErrorDescription(String(describing: err)),
                    "\(err) should be auth-class")
        }
    }

    @Test("Transient failures are not auth-class")
    func transientErrors() {
        let transient: [FetchError] = [
            .rateLimited(retryAfter: 60),
            .http(500, "server error"),
            .malformed("bad json"),
        ]
        for err in transient {
            #expect(!ClaudeUsageClient.isAuthClassErrorDescription(String(describing: err)),
                    "\(err) should NOT be auth-class")
        }
    }
}
