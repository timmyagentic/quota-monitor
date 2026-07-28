import Foundation
import Sparkle

@MainActor
final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
    private let stableFeedURL: String
    private let privateBetaFeedURL: String
    var channel: UpdateChannel

    init(
        stableFeedURL: String,
        privateBetaFeedURL: String,
        channel: UpdateChannel
    ) {
        self.stableFeedURL = stableFeedURL
        self.privateBetaFeedURL = privateBetaFeedURL
        self.channel = channel
    }

    var currentFeedURL: String {
        switch channel {
        case .stable:
            stableFeedURL
        case .privateBeta:
            privateBetaFeedURL
        }
    }

    var currentAllowedChannels: Set<String> {
        channel == .privateBeta ? [UpdateChannel.privateBeta.rawValue] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        currentFeedURL
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        currentAllowedChannels
    }
}
