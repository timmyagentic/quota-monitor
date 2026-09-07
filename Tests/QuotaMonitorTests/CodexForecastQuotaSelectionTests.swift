import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex forecast quota selection")
struct CodexForecastQuotaSelectionTests {
    @Test("weekly-only accounts offer only the weekly period and normalize a stale selection")
    func weeklyOnlyPickerDoesNotOfferFiveHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selection = CodexForecastQuotaSelection(primary: nil,
            secondary: .init(usedPercent: 69, resetsAt: now.addingTimeInterval(500_000)))
        let available = ForecastCycleSelection.availableBuckets(codex: selection, claude: nil,
            blockResetAt: nil, visibleProviders: ["codex"], now: now)
        #expect(available == ["secondary"])
        #expect(ForecastCycleSelection.resolve("primary", available: available) == "secondary")
        #expect(ForecastCycleSelection.resolve("secondary", available: []) == nil)
        let claude = ClaudeUsageSnapshot(capturedAt: now, tier: nil, fiveHour: nil,
            sevenDay: .init(usedPercent: 69, resetAt: now.addingTimeInterval(500_000), windowDuration: 604_800),
            sevenDayOpus: nil, sevenDaySonnet: nil)
        #expect(ForecastCycleSelection.availableBuckets(codex: selection, claude: claude,
            blockResetAt: now.addingTimeInterval(100), visibleProviders: ["claude"], now: now) == ["secondary"])
    }

    @Test("selected period controls quota and pace together")
    func selectedPeriodMasksOtherQuotaAndPace() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let both = CodexForecastQuotaSelection(
            primary: .init(usedPercent: 20, resetsAt: now.addingTimeInterval(100)),
            secondary: .init(usedPercent: 69, resetsAt: now.addingTimeInterval(500_000)))
        let primaryBurn = CodexBurnRate(percentPerMinute: 1, sampleCount: 5)
        let weeklyBurn = CodexBurnRate(percentPerMinute: 0.1, sampleCount: 3)
        for bucket in ["primary", "secondary"] {
            let selected = both.selecting(bucket: bucket, now: now)
            #expect((selected.primary != nil) == (bucket == "primary"))
            #expect((selected.secondary != nil) == (bucket == "secondary"))
            #expect(selected.paceBurn(burn: ["primary": primaryBurn, "secondary": weeklyBurn],
                cycles: [], now: now) == (bucket == "primary" ? primaryBurn : weeklyBurn))
        }
    }

    @Test("trend cycle choices omit missing and hidden windows")
    func trendChoicesTrackAvailableCycles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = cycle("secondary", reset: now.addingTimeInterval(100), basis: .estimated)
        #expect(TrendRange.available(cycles: [weekly], visibleProviders: ["codex"], now: now)
            == [.current7d, .last7d, .last30d, .last90d, .lastYear])
        #expect(TrendRange.available(cycles: [weekly], visibleProviders: ["claude"], now: now)
            == [.last7d, .last30d, .last90d, .lastYear])
        #expect(TrendRange.available(cycles: [weekly], visibleProviders: ["codex"],
            now: now.addingTimeInterval(101)) == [.last7d, .last30d, .last90d, .lastYear])
    }

    @Test("hidden providers and expired windows cannot add period choices")
    func availablePeriodsFollowVisibleProviders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = CodexForecastQuotaSelection(
            primary: .init(usedPercent: 20, resetsAt: now.addingTimeInterval(-1)),
            secondary: .init(usedPercent: 69, resetsAt: now.addingTimeInterval(500_000)))
        let claude = ClaudeUsageSnapshot(capturedAt: now, tier: nil,
            fiveHour: .init(usedPercent: 20, resetAt: now.addingTimeInterval(100), windowDuration: 18_000),
            sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil)
        #expect(ForecastCycleSelection.availableBuckets(codex: codex, claude: claude,
            blockResetAt: nil, visibleProviders: ["codex"], now: now) == ["secondary"])
        #expect(ForecastCycleSelection.availableBuckets(codex: codex, claude: claude,
            blockResetAt: nil, visibleProviders: ["codex", "claude"], now: now) == ["primary", "secondary"])
        #expect(ForecastCycleSelection.availableBuckets(codex: codex, claude: claude,
            blockResetAt: nil, visibleProviders: ["claude"], now: now) == ["primary"])
        #expect(ForecastCycleSelection.availableBuckets(codex: codex, claude: claude,
            blockResetAt: nil, visibleProviders: [], now: now).isEmpty)
    }

    @Test("weekly-only live snapshot does not revive stored five-hour data")
    func liveSnapshotWinsAsAWhole() {
        let now = Date(timeIntervalSince1970: 1_784_050_000)
        let weekly = RateLimitSnapshot.Window(
            usedPercent: 64,
            windowDuration: 604_800,
            resetAt: now.addingTimeInterval(5 * 86_400))
        let live = RateLimitSnapshot(
            capturedAt: now,
            planType: "pro",
            primary: nil,
            secondary: weekly,
            additional: [],
            resetCreditsAvailable: nil)
        let stored = CodexQuotaSnapshot(
            primary: storedWindow("primary", usedPercent: 11, now: now),
            secondary: storedWindow("secondary", usedPercent: 3, now: now),
            burn: [:])

        let selection = CodexForecastQuotaSelection.make(
            live: live,
            stored: stored)

        #expect(selection.primary == nil)
        #expect(selection.secondary?.usedPercent == 64)
    }

    @Test("stored snapshot is used only when the live snapshot is absent")
    func storedSnapshotIsWholeFallback() {
        let now = Date(timeIntervalSince1970: 1_784_050_000)
        let stored = CodexQuotaSnapshot(
            primary: storedWindow("primary", usedPercent: 11, now: now),
            secondary: storedWindow("secondary", usedPercent: 3, now: now),
            burn: [:])

        let selection = CodexForecastQuotaSelection.make(
            live: nil,
            stored: stored)

        #expect(selection.primary?.usedPercent == 11)
        #expect(selection.secondary?.usedPercent == 3)
    }

    @Test("weekly pace uses weekly reset evidence even when five-hour quota is visible")
    func weeklyPaceUsesItsOwnEvidence() {
        let now = Date(timeIntervalSince1970: 1_784_050_000)
        let selection = CodexForecastQuotaSelection(
            primary: .init(usedPercent: 20, resetsAt: now.addingTimeInterval(100)),
            secondary: .init(usedPercent: 30, resetsAt: now.addingTimeInterval(200)))
        let burn = CodexBurnRate(percentPerMinute: 0.1, sampleCount: 3)
        for uncertain: QuotaCycle.Basis in [.unresolved, .observedChange] {
            #expect(selection.paceBurn(burn: ["secondary": burn], cycles: [
                cycle("primary", reset: now.addingTimeInterval(100), basis: .estimated),
                cycle("secondary", reset: now.addingTimeInterval(200), basis: uncertain)
            ], now: now) == nil)
            #expect(selection.paceBurn(burn: ["secondary": burn], cycles: [
                cycle("primary", reset: now.addingTimeInterval(100), basis: uncertain),
                cycle("secondary", reset: now.addingTimeInterval(200), basis: .estimated)
            ], now: now) == burn)
        }
    }

    @Test("weekly pace checks its own deadline and requires a visible weekly window")
    func paceDeadlineFollowsBurnBucket() {
        let now = Date(timeIntervalSince1970: 1_784_050_000)
        let primary = CodexForecastQuotaSelection.Window(usedPercent: 20,
                                                        resetsAt: now.addingTimeInterval(-1))
        let secondary = CodexForecastQuotaSelection.Window(usedPercent: 30,
                                                          resetsAt: now.addingTimeInterval(200))
        let burn = CodexBurnRate(percentPerMinute: 0.1, sampleCount: 3)
        #expect(CodexForecastQuotaSelection(primary: primary, secondary: secondary)
            .paceBurn(burn: ["secondary": burn], cycles: [], now: now) == burn)
        #expect(CodexForecastQuotaSelection(primary: primary, secondary: nil)
            .paceBurn(burn: ["secondary": burn], cycles: [], now: now) == nil)
    }

    private func cycle(_ bucket: String, reset: Date, basis: QuotaCycle.Basis) -> QuotaCycle {
        QuotaCycle(observation: .init(provider: "codex", bucket: bucket, scope: "fixture",
            plan: "pro", capturedAt: reset.addingTimeInterval(-100), resetAt: reset,
            duration: bucket == "primary" ? 18_000 : 604_800, usedPercent: 20),
            start: nil, possibleStart: nil, basis: basis)
    }

    private func storedWindow(
        _ bucket: String,
        usedPercent: Double,
        now: Date
    ) -> CodexQuotaWindow {
        CodexQuotaWindow(
            bucket: bucket,
            sourceKind: "live",
            planType: "pro",
            sampleAt: now,
            windowStart: nil,
            resetsAt: now.addingTimeInterval(bucket == "primary" ? 18_000 : 604_800),
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent)
    }
}
