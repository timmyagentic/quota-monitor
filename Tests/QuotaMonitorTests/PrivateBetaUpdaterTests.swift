import Foundation
import Sparkle
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Private Beta updater")
struct PrivateBetaUpdaterTests {
    @Test("The update channel defaults to stable and persists Private Beta")
    func channelPersistence() throws {
        let suite = "PrivateBetaUpdaterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UpdateChannel(defaults: defaults) == .stable)
        UpdateChannel.privateBeta.persist(to: defaults)
        #expect(UpdateChannel(defaults: defaults) == .privateBeta)
    }

    @Test("The Sparkle delegate switches feeds and allowed channels together")
    func delegateSwitchesFeedAndChannel() {
        var channel = UpdateChannel.stable
        let delegate = SparkleUpdateDelegate(
            stableFeedURL: "https://example.test/stable.xml",
            privateBetaFeedURL: "https://example.test/private/appcast.xml",
            channel: channel)

        #expect(delegate.currentFeedURL == "https://example.test/stable.xml")
        #expect(delegate.currentAllowedChannels.isEmpty)

        channel = .privateBeta
        delegate.channel = channel
        #expect(delegate.currentFeedURL == "https://example.test/private/appcast.xml")
        #expect(delegate.currentAllowedChannels == ["private-beta"])
    }

    @Test("Only a 32-byte base64url device credential is accepted")
    func tokenValidation() {
        #expect(PrivateBetaEnrollmentClient.isValidToken(String(repeating: "A", count: 43)))
        #expect(!PrivateBetaEnrollmentClient.isValidToken(String(repeating: "A", count: 42)))
        #expect(!PrivateBetaEnrollmentClient.isValidToken(
            String(repeating: "A", count: 42) + "="))
    }
}
