import Foundation
import Testing
@testable import QuotaMonitor

@Suite("ClaudeUsageSnapshot stale 5h preservation")
struct ClaudeUsageSnapshotTests {

    @Test("7d-only refresh preserves an expired previous 5h as stale")
    func sevenDayOnlyRefreshPreservesExpiredPreviousFiveHour() {
        let oldFiveHour = ClaudeUsageSnapshot.Window(
            usedPercent: 3,
            resetAt: Date(timeIntervalSince1970: 3_600),
            windowDuration: 18_000)
        let previous = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 3_500),
            tier: "pro",
            fiveHour: oldFiveHour,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)
        let refreshed = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 7_200),
            tier: "pro",
            fiveHour: nil,
            sevenDay: ClaudeUsageSnapshot.Window(
                usedPercent: 27,
                resetAt: Date(timeIntervalSince1970: 604_800),
                windowDuration: 604_800),
            sevenDayOpus: nil,
            sevenDaySonnet: nil)

        let merged = refreshed.preservingStaleFiveHour(from: previous)

        #expect(merged.fiveHour == nil)
        #expect(merged.staleFiveHour == oldFiveHour)
        #expect(merged.fiveHourForDisplay == oldFiveHour)
    }

    @Test("previous 5h is not marked stale before its reset time")
    func previousFiveHourBeforeResetIsNotMarkedStale() {
        let activeFiveHour = ClaudeUsageSnapshot.Window(
            usedPercent: 3,
            resetAt: Date(timeIntervalSince1970: 7_200),
            windowDuration: 18_000)
        let previous = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 3_500),
            tier: "pro",
            fiveHour: activeFiveHour,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)
        let refreshed = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 3_600),
            tier: "pro",
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)

        let merged = refreshed.preservingStaleFiveHour(from: previous)

        #expect(merged.staleFiveHour == nil)
    }

    @Test("current 5h takes display precedence over stale 5h")
    func currentFiveHourTakesDisplayPrecedence() {
        let current = ClaudeUsageSnapshot.Window(
            usedPercent: 19,
            resetAt: Date(timeIntervalSince1970: 18_000),
            windowDuration: 18_000)
        let stale = ClaudeUsageSnapshot.Window(
            usedPercent: 3,
            resetAt: Date(timeIntervalSince1970: 3_600),
            windowDuration: 18_000)
        let snapshot = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 7_200),
            tier: "pro",
            fiveHour: current,
            staleFiveHour: stale,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)

        #expect(snapshot.fiveHourForDisplay == current)
    }

    @Test("empty refresh does not preserve stale 5h by itself")
    func emptyRefreshDoesNotPreserveStaleFiveHour() {
        let oldFiveHour = ClaudeUsageSnapshot.Window(
            usedPercent: 3,
            resetAt: Date(timeIntervalSince1970: 3_600),
            windowDuration: 18_000)
        let previous = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 3_500),
            tier: "pro",
            fiveHour: oldFiveHour,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)
        let refreshed = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 7_200),
            tier: "pro",
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)

        let merged = refreshed.preservingStaleFiveHour(from: previous)

        #expect(merged.staleFiveHour == nil)
    }

    @Test("Fable-only refresh preserves an expired previous 5h as stale")
    func fableOnlyRefreshPreservesExpiredPreviousFiveHour() {
        let oldFiveHour = ClaudeUsageSnapshot.Window(
            usedPercent: 3,
            resetAt: Date(timeIntervalSince1970: 3_600),
            windowDuration: 18_000)
        let previous = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 3_500),
            tier: "max20x",
            fiveHour: oldFiveHour,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil)
        let fable = ClaudeUsageSnapshot.Window(
            usedPercent: 25,
            resetAt: Date(timeIntervalSince1970: 604_800),
            windowDuration: 604_800)
        let refreshed = ClaudeUsageSnapshot(
            capturedAt: Date(timeIntervalSince1970: 7_200),
            tier: "max20x",
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            weeklyScoped: [.init(key: "fable", window: fable)])

        let merged = refreshed.preservingStaleFiveHour(from: previous)

        #expect(merged.fiveHour == nil)
        #expect(merged.staleFiveHour == oldFiveHour)
        #expect(merged.sevenDayFable == fable)
    }
}
