import Foundation
import LocalAuthentication
import Security
import Testing
@testable import QuotaMonitor

@Suite("ClaudeUsageClient Keychain query construction")
struct ClaudeUsageClientKeychainTests {
    @Test("Keychain reads are non-interactive")
    func keychainQueriesDisableAuthenticationUI() {
        let list = ClaudeUsageClient.keychainListQuery()
        let data = ClaudeUsageClient.keychainDataQuery(
            persistentRef: Data([0x01, 0x02]))

        let key = kSecUseAuthenticationContext as String
        #expect((list[key] as? LAContext)?.interactionNotAllowed == true)
        #expect((data[key] as? LAContext)?.interactionNotAllowed == true)

        let legacyKey = ClaudeUsageClient.keychainAuthenticationUIKey
        let legacyFail = ClaudeUsageClient.keychainAuthenticationUIFailValue
        #expect(list[legacyKey] as? String == legacyFail)
        #expect(data[legacyKey] as? String == legacyFail)
    }

    @Test("security tool password JSON decodes as Claude credentials")
    func securityToolPasswordJSONDecodesAsCredentials() {
        let json = """
        {"claudeAiOauth":{"accessToken":"token-123","expiresAt":1779539381811,"scopes":["user:profile"]}}
        """

        let outcome = ClaudeUsageClient.decodeKeychainPasswordData(Data(json.utf8))

        if case .ok(let token, let raw) = outcome {
            #expect(token == "token-123")
            #expect(String(data: raw, encoding: .utf8)?.contains("token-123") == true)
        } else {
            Issue.record("expected ok credentials, got \(outcome)")
        }
    }
}
