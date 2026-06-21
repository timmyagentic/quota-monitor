import Foundation

struct CodexResetCredit: Equatable, Sendable {
    let grantedAt: Date?
    let expiresAt: Date
}

struct CodexResetCreditsSnapshot: Equatable, Sendable {
    enum DetailStatus: Equatable, Sendable {
        case complete
        case countOnly
    }

    let capturedAt: Date
    let availableCount: Int
    let credits: [CodexResetCredit]
    let detailStatus: DetailStatus

    init(
        capturedAt: Date,
        availableCount: Int,
        credits: [CodexResetCredit],
        detailStatus: DetailStatus
    ) {
        self.capturedAt = capturedAt
        self.availableCount = max(0, availableCount)
        self.credits = credits.sorted { $0.expiresAt < $1.expiresAt }
        self.detailStatus = detailStatus
    }

    static func countOnly(
        availableCount: Int,
        capturedAt: Date = Date()
    ) -> CodexResetCreditsSnapshot {
        CodexResetCreditsSnapshot(
            capturedAt: capturedAt,
            availableCount: availableCount,
            credits: [],
            detailStatus: .countOnly)
    }

    var nextExpiration: Date? {
        credits.first?.expiresAt
    }

    var hasDetailedExpirations: Bool {
        detailStatus == .complete && !credits.isEmpty
    }
}
