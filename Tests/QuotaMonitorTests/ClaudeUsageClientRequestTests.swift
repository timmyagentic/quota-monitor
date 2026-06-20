import Foundation
import Testing
@testable import QuotaMonitor

@Suite("ClaudeUsageClient request construction")
struct ClaudeUsageClientRequestTests {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    @Test("Claude OAuth usage request uses Claude Code user-agent")
    func usageRequestUsesClaudeCodeUserAgent() {
        let userAgent = ClaudeUsageClient.claudeCodeUserAgent(versionString: "2.1.149")
        let request = ClaudeUsageClient.makeUsageRequest(
            url: usageURL,
            token: "token-123",
            userAgent: userAgent)

        #expect(userAgent == "claude-code/2.1.149")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.149")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Claude Code user-agent falls back to known safe version")
    func userAgentFallsBackToSafeClaudeCodeVersion() {
        #expect(ClaudeUsageClient.claudeCodeUserAgent(versionString: nil) == "claude-code/2.1.0")
        #expect(ClaudeUsageClient.claudeCodeUserAgent(versionString: "   ") == "claude-code/2.1.0")
    }

    @Test("Retry-After seconds parse, but zero is ignored")
    func retryAfterSecondsParseAndZeroIsIgnored() throws {
        let retry120 = try #require(HTTPURLResponse(
            url: usageURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"]))
        let retryZero = try #require(HTTPURLResponse(
            url: usageURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "0"]))

        #expect(ClaudeUsageClient.retryAfterSeconds(from: retry120, now: Date(timeIntervalSince1970: 0)) == 120)
        #expect(ClaudeUsageClient.retryAfterSeconds(from: retryZero, now: Date(timeIntervalSince1970: 0)) == nil)
    }

    @Test("Retry-After HTTP-date parses to remaining seconds")
    func retryAfterHTTPDateParses() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let now = try #require(formatter.date(from: "Sat, 20 Jun 2026 03:22:00 GMT"))
        let response = try #require(HTTPURLResponse(
            url: usageURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Sat, 20 Jun 2026 03:27:00 GMT"]))

        #expect(ClaudeUsageClient.retryAfterSeconds(from: response, now: now) == 300)
    }
}
