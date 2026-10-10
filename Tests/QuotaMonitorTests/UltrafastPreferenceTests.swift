import Testing
@testable import QuotaMonitor

@Suite("Ultrafast normalization")
struct UltrafastPreferenceTests {
    @Test(arguments: ["ultrafast", "ULTRAFAST", "  Ultrafast\n"])
    func normalizes(value: String) {
        #expect(CodexServiceTierPreference(rolloutValue: value) == .ultrafast)
    }
    @Test func unknownIsNotUltrafast() {
        #expect(CodexServiceTierPreference(rolloutValue: "ultra-fast") == nil)
        #expect(CodexServiceTierPreference(rolloutValue: nil) == nil)
        #expect(CodexServiceTierPreference(rolloutValue: "fast") == .priority)
    }
}
