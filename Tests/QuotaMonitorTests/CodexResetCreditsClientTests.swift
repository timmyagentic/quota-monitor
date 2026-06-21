import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex reset credits client")
struct CodexResetCreditsClientTests {
    private func makeAuthFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qm-reset-credits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json")
        try """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "codex-access-token",
            "account_id": "codex-account-id"
          }
        }
        """.write(to: auth, atomically: true, encoding: .utf8)
        return auth
    }

    @Test("fetches available reset credits and sets Codex headers")
    func fetchesAvailableCredits() async throws {
        let authFile = try makeAuthFile()
        let endpoint = URL(string: "https://example.test/rate-limit-reset-credits")!
        final class RequestBox: @unchecked Sendable {
            var request: URLRequest?
        }
        let box = RequestBox()
        let client = CodexResetCreditsClient(
            authFileURL: authFile,
            endpoint: endpoint,
            loader: { request in
                box.request = request
                let response = HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
                let body = """
                {
                  "available_count": 2,
                  "credits": [
                    {
                      "status": "available",
                      "granted_at": "2026-06-12T00:16:55.107346Z",
                      "expires_at": "2026-07-12T00:16:55.107346Z"
                    },
                    {
                      "status": "redeemed",
                      "granted_at": "2026-06-13T00:16:55.107346Z",
                      "expires_at": "2026-07-13T00:16:55.107346Z"
                    },
                    {
                      "status": "available",
                      "granted_at": "2026-06-18T00:28:14.459108Z",
                      "expires_at": "2026-07-18T00:28:14.459108Z"
                    }
                  ]
                }
                """
                return (Data(body.utf8), response)
            })

        let snapshot = try await client.fetchResetCredits()

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.count == 2)
        #expect(snapshot.detailStatus == .complete)
        #expect(box.request?.httpMethod == "GET")
        #expect(box.request?.value(forHTTPHeaderField: "Authorization") == "Bearer codex-access-token")
        #expect(box.request?.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "codex-account-id")
        #expect(box.request?.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(box.request?.value(forHTTPHeaderField: "originator") == "Codex Desktop")
    }

    @Test("missing auth file surfaces noCredentials")
    func missingAuthFile() async throws {
        let client = CodexResetCreditsClient(
            authFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-auth.json"),
            endpoint: URL(string: "https://example.test/reset")!,
            loader: { _ in
                Issue.record("loader must not run without auth")
                throw URLError(.badURL)
            })

        do {
            _ = try await client.fetchResetCredits()
            Issue.record("expected noCredentials")
        } catch let error as CodexResetCreditsClient.FetchError {
            #expect(error == .noCredentials)
        }
    }
}
