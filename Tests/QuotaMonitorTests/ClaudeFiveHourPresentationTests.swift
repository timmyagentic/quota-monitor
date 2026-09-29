import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Claude five-hour presentation")
struct ClaudeFiveHourPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func block(active: Bool = true) -> BillingBlocks.Block {
        let start = now.addingTimeInterval(active ? -9_000 : -21_600)
        return .init(id: "local-claude", startTime: start,
              endTime: start.addingTimeInterval(18_000), firstEntryAt: start,
              lastEntryAt: start, isActive: active, isGap: false, entryCount: 1,
              tokenCounts: .init(input: 1_000, output: 200), costUSD: 0.02,
              models: ["claude-fable-5-1"])
    }

    private func window(_ percent: Double, duration: TimeInterval = 18_000)
        -> ClaudeUsageSnapshot.Window {
        .init(usedPercent: percent, resetAt: now.addingTimeInterval(duration / 2),
              windowDuration: duration)
    }

    private func usage(five: ClaudeUsageSnapshot.Window? = nil,
                       stale: ClaudeUsageSnapshot.Window? = nil,
                       scopedOnly: Bool = false) -> ClaudeUsageSnapshot {
        .init(capturedAt: now, tier: nil, fiveHour: five, staleFiveHour: stale,
              sevenDay: scopedOnly ? nil : window(46, duration: 604_800),
              sevenDayOpus: nil, sevenDaySonnet: nil,
              weeklyScoped: [.init(key: "fable", window: window(0, duration: 604_800))])
    }

    @Test("weekly-only quota keeps the local 5h block visible", arguments: [false, true])
    func weeklyQuotaDoesNotHideLocalBlock(scopedOnly: Bool) {
        let local = block()
        #expect(ClaudeFiveHourPresentation.make(usage: usage(scopedOnly: scopedOnly),
                                               block: local) == .localBlock(local))
    }

    @Test("current quota takes precedence over local time progress, even at zero", arguments: [0.0, 37.0])
    func currentQuotaWins(percent: Double) {
        let current = window(percent)
        #expect(ClaudeFiveHourPresentation.make(usage: usage(five: current, stale: window(90)),
                                               block: block()) == .quota(current))
    }

    @Test("preserved quota retains its stale treatment instead of becoming local progress")
    func staleQuotaWins() {
        let stale = ClaudeUsageSnapshot.Window(usedPercent: 81,
            resetAt: now.addingTimeInterval(-60), windowDuration: 18_000)
        #expect(ClaudeFiveHourPresentation.make(usage: usage(stale: stale),
                                               block: block()) == .quota(stale))
    }

    @Test("most recent local block remains visible after it ends")
    func completedLocalBlockIsStillAvailable() {
        let local = block(active: false)
        #expect(ClaudeFiveHourPresentation.make(usage: usage(), block: local) == .localBlock(local))
    }

    @Test("local usage works without Claude credentials")
    func localBlockWithoutOAuth() {
        let local = block()
        #expect(ClaudeFiveHourPresentation.make(usage: nil, block: local) == .localBlock(local))
    }

    @Test("weekly quota without any 5h source retains the idle placeholder", arguments: [false, true])
    func weeklyQuotaWithoutLocalDataIsIdle(scopedOnly: Bool) {
        #expect(ClaudeFiveHourPresentation.make(usage: usage(scopedOnly: scopedOnly),
                                               block: nil) == .idle)
    }

    @Test("no quota or local records remains unavailable")
    func noDataIsUnavailable() {
        #expect(ClaudeFiveHourPresentation.make(usage: nil, block: nil) == .unavailable)
    }
}
