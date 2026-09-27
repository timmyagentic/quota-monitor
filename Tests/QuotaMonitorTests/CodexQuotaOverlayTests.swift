import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Codex native quota overlay")
struct CodexQuotaOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func window(
        usedPercent: Double,
        resetOffset: TimeInterval = 3_600
    ) -> RateLimitSnapshot.Window {
        RateLimitSnapshot.Window(
            usedPercent: usedPercent,
            windowDuration: 18_000,
            resetAt: now.addingTimeInterval(resetOffset))
    }

    private func snapshot(
        capturedOffset: TimeInterval = 0,
        primary: RateLimitSnapshot.Window?,
        secondary: RateLimitSnapshot.Window?
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            capturedAt: now.addingTimeInterval(capturedOffset),
            planType: "pro",
            primary: primary,
            secondary: secondary,
            additional: [],
            resetCreditsAvailable: nil)
    }

    @Test("Fresh quota follows the selected used or remaining display mode")
    func presentationFollowsDisplayMode() {
        let rateLimits = snapshot(
            primary: window(usedPercent: 37.4),
            secondary: window(usedPercent: 82.6))

        let used = CodexQuotaOverlayPresentation.make(
            snapshot: rateLimits,
            displayMode: .used,
            now: now)
        #expect(used.fiveHour?.percent == 37)
        #expect(used.fiveHour?.usedPercent == 37)
        #expect(used.fiveHour?.remainingPercent == 63)
        #expect(used.fiveHour?.displayMode == .used)
        #expect(used.fiveHour?.resetAt == now.addingTimeInterval(3_600))
        #expect(used.weekly?.percent == 83)
        #expect(used.fiveHour?.severity == .healthy)
        #expect(used.weekly?.severity == .warning)
        #expect(!used.isCached)

        let remaining = CodexQuotaOverlayPresentation.make(
            snapshot: rateLimits,
            displayMode: .remaining,
            now: now)
        #expect(remaining.fiveHour?.percent == 63)
        #expect(remaining.weekly?.percent == 17)
        #expect(remaining.fiveHour?.displayMode == .remaining)

        let usedLabel = LocalizationTestSupport.withLanguage(.english) {
            used.fiveHour?.localizedPercentLabel
        }
        let remainingLabel = LocalizationTestSupport.withLanguage(
            .simplifiedChinese
        ) {
            remaining.fiveHour?.localizedPercentLabel
        }
        #expect(usedLabel == "37% used")
        #expect(remainingLabel == "剩余 63%")
    }

    @Test("Last-good quota remains visible while it is stale")
    func stalePresentationKeepsValues() {
        let rateLimits = snapshot(
            capturedOffset: -(16 * 60),
            primary: window(usedPercent: 91),
            secondary: window(usedPercent: 42))

        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: rateLimits,
            displayMode: .used,
            now: now)

        #expect(presentation.hasQuota)
        #expect(presentation.isCached)
        #expect(presentation.fiveHour?.percent == 91)
        #expect(presentation.fiveHour?.severity == .critical)
    }

    @Test("An expired window marks an otherwise recent snapshot as cached")
    func expiredWindowMarksSnapshotCached() {
        let rateLimits = snapshot(
            primary: window(usedPercent: 55, resetOffset: -1),
            secondary: window(usedPercent: 44))

        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: rateLimits,
            displayMode: .used,
            now: now)

        #expect(presentation.isCached)
        #expect(presentation.hasQuota)
    }

    @Test("Missing quota produces a compact unavailable state")
    func unavailableWithoutQuota() {
        let emptySnapshot = snapshot(primary: nil, secondary: nil)

        #expect(!CodexQuotaOverlayPresentation.make(
            snapshot: nil,
            displayMode: .used,
            now: now).hasQuota)
        #expect(!CodexQuotaOverlayPresentation.make(
            snapshot: emptySnapshot,
            displayMode: .used,
            now: now).hasQuota)
    }

    @Test("Widget and menu bar share stable compact window labels")
    func compactWindowLabels() {
        let english = LocalizationTestSupport.withLanguage(.english) {
            [
                QuotaWindowCompactLabel.fiveHour,
                QuotaWindowCompactLabel.sevenDay
            ]
        }
        let chinese = LocalizationTestSupport.withLanguage(
            .simplifiedChinese
        ) {
            [
                QuotaWindowCompactLabel.fiveHour,
                QuotaWindowCompactLabel.sevenDay
            ]
        }

        #expect(english == ["5h", "7d"])
        #expect(chinese == english)
        #expect(QuotaWindowCompactLabel.segment(
            label: QuotaWindowCompactLabel.sevenDay,
            value: "51%",
            style: .native) == "7d 51%")
        #expect(QuotaWindowCompactLabel.segment(
            label: QuotaWindowCompactLabel.sevenDay,
            value: "51%",
            style: .emphasis) == "7d\u{2009}51%")
    }

    @Test("Window selection rejects helper surfaces and preserves front order")
    func selectsFrontCodexWindow() {
        let pid: pid_t = 120
        let candidates = [
            CodexWindowCandidate(
                windowNumber: 1,
                ownerPID: pid,
                layer: 2,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
            CodexWindowCandidate(
                windowNumber: 2,
                ownerPID: pid,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 1_200, height: 32)),
            CodexWindowCandidate(
                windowNumber: 3,
                ownerPID: 999,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 0, y: 0, width: 1_200, height: 800)),
            CodexWindowCandidate(
                windowNumber: 4,
                ownerPID: pid,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 100, y: 80, width: 1_200, height: 800)),
            CodexWindowCandidate(
                windowNumber: 5,
                ownerPID: pid,
                layer: 0,
                alpha: 1,
                bounds: CGRect(x: 200, y: 100, width: 1_000, height: 700))
        ]

        #expect(CodexWindowSelectionPolicy.frontWindow(
            for: pid,
            candidates: candidates)?.windowNumber == 4)
        #expect(CodexWindowSelectionPolicy.trackedWindow(
            for: pid,
            lastWindowNumber: 5,
            codexIsFrontmost: false,
            candidates: candidates)?.windowNumber == 5)
        #expect(CodexWindowSelectionPolicy.trackedWindow(
            for: pid,
            lastWindowNumber: 99,
            codexIsFrontmost: false,
            candidates: candidates) == nil)
        #expect(CodexWindowSelectionPolicy.trackedWindow(
            for: pid,
            lastWindowNumber: 5,
            codexIsFrontmost: true,
            candidates: candidates)?.windowNumber == 4)
        #expect(CodexWindowSelectionPolicy.isWindow(
            1,
            above: 4,
            candidates: candidates))
        #expect(!CodexWindowSelectionPolicy.isWindow(
            5,
            above: 4,
            candidates: candidates))
        #expect(!CodexWindowSelectionPolicy.isWindow(
            99,
            above: 4,
            candidates: candidates))
    }

    @Test("A visible widget stays with Codex in the background without reopening")
    func backgroundVisibilityPolicy() {
        #expect(CodexQuotaOverlayVisibilityPolicy.placement(
            codexIsFrontmost: true,
            trackedWindowIsOnScreen: true,
            overlayIsVisible: false) == .foreground)
        #expect(CodexQuotaOverlayVisibilityPolicy.placement(
            codexIsFrontmost: false,
            trackedWindowIsOnScreen: true,
            overlayIsVisible: true) == .background)
        #expect(!CodexQuotaOverlayPlacement.background.allowsDetails)
        #expect(!CodexQuotaOverlayPlacement.background.allowsInteraction)
    }

    @Test("Background tracking never summons a hidden or off-screen widget")
    func backgroundVisibilityRequiresExistingOnScreenWidget() {
        #expect(CodexQuotaOverlayVisibilityPolicy.placement(
            codexIsFrontmost: false,
            trackedWindowIsOnScreen: true,
            overlayIsVisible: false) == .hidden)
        #expect(CodexQuotaOverlayVisibilityPolicy.placement(
            codexIsFrontmost: false,
            trackedWindowIsOnScreen: false,
            overlayIsVisible: true) == .hidden)
        #expect(CodexQuotaOverlayPlacement.foreground.allowsDetails)
        #expect(CodexQuotaOverlayPlacement.foreground.allowsInteraction)
        #expect(!CodexQuotaOverlayPlacement.hidden.allowsInteraction)
    }

    @Test("Quartz window frames map onto primary and secondary AppKit screens")
    func convertsWindowCoordinates() {
        let displays = [
            CodexDisplayGeometry(
                quartzFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                appKitFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)),
            CodexDisplayGeometry(
                quartzFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
                appKitFrame: CGRect(x: -1_440, y: 180, width: 1_440, height: 900))
        ]

        #expect(CodexWindowFrameConverter.appKitFrame(
            for: CGRect(x: 100, y: 50, width: 900, height: 700),
            displays: displays) == CGRect(x: 100, y: 330, width: 900, height: 700))
        #expect(CodexWindowFrameConverter.appKitFrame(
            for: CGRect(x: -1_400, y: 100, width: 1_000, height: 700),
            displays: displays) == CGRect(x: -1_400, y: 280, width: 1_000, height: 700))
    }

    @Test("Header discovery requires a title, an aligned action, and an empty gap")
    func headerSelection() {
        let host = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let title = CodexSidebarHeaderCandidate(frame: CGRect(x: -1132, y: 146, width: 76, height: 28), descriptors: ["Codex"])
        let search = CodexSidebarHeaderCandidate(frame: CGRect(x: -794, y: 146, width: 24, height: 28), descriptors: ["Search"])
        let anchor = CodexSidebarHeaderSelectionPolicy.anchor(in: host, candidates: [title, search])
        #expect(anchor == .init(leadingInset: 152, trailingXInset: 398, centerYInset: 60))
        let narrowHost = CGRect(x: host.minX, y: host.minY, width: 480, height: 800)
        #expect(CodexSidebarHeaderSelectionPolicy.anchor(in: narrowHost, candidates: [title, search]) == anchor)
        #expect(CodexSidebarHeaderSelectionPolicy.anchor(in: host, candidates: [search]) == nil)
        #expect(CodexSidebarHeaderSelectionPolicy.anchor(in: host, candidates: [title]) == nil)
        let obstacle = CodexSidebarHeaderCandidate(frame: CGRect(x: -1020, y: 146, width: 28, height: 28), descriptors: ["Another action"])
        #expect(CodexSidebarHeaderSelectionPolicy.anchor(in: host, candidates: [title, obstacle, search]) == nil)
        let chatTitle = CodexSidebarHeaderCandidate(frame: CGRect(x: -500, y: 146, width: 76, height: 28), descriptors: ["Codex"])
        #expect(CodexSidebarHeaderSelectionPolicy.anchor(in: host, candidates: [chatTitle, search]) == nil)
    }

    @Test("Header discovery retries off transient misses with bounded backoff")
    func helpDiscoveryRetryPolicy() {
        #expect(CodexSidebarHeaderDiscoveryPolicy.retryInterval(
            afterFailureCount: 1) == 0.5)
        #expect(CodexSidebarHeaderDiscoveryPolicy.retryInterval(
            afterFailureCount: 2) == 1)
        #expect(CodexSidebarHeaderDiscoveryPolicy.retryInterval(
            afterFailureCount: 3) == 2)
        #expect(CodexSidebarHeaderDiscoveryPolicy.retryInterval(
            afterFailureCount: 4) == 4)
        #expect(CodexSidebarHeaderDiscoveryPolicy.retryInterval(
            afterFailureCount: 5) == 8)
        #expect(CodexSidebarHeaderDiscoveryPolicy.retryInterval(
            afterFailureCount: 50) == 8)

        let now = Date(timeIntervalSince1970: 10_000)
        let later = now.addingTimeInterval(4)
        #expect(CodexSidebarHeaderDiscoveryPolicy.shouldStart(
            now: now,
            nextAttemptAt: nil,
            isRunning: false,
            force: false))
        #expect(!CodexSidebarHeaderDiscoveryPolicy.shouldStart(
            now: now,
            nextAttemptAt: later,
            isRunning: true,
            force: true))
        #expect(!CodexSidebarHeaderDiscoveryPolicy.shouldStart(
            now: now,
            nextAttemptAt: later,
            isRunning: false,
            force: false))
        #expect(CodexSidebarHeaderDiscoveryPolicy.shouldStart(
            now: later,
            nextAttemptAt: later,
            isRunning: false,
            force: false))
        #expect(CodexSidebarHeaderDiscoveryPolicy.shouldStart(
            now: now,
            nextAttemptAt: later,
            isRunning: false,
            force: true))
    }

    @Test("Header layout adapts to measured space, never guesses, and preserves manual placement")
    func headerLayout() throws {
        let host = CGRect(x: -1200, y: 200, width: 1200, height: 800)
        let weekly = CodexQuotaOverlayPresentation.make(snapshot: snapshot(primary: nil, secondary: window(usedPercent: 8)), displayMode: .remaining, now: now)
        let wide = CodexSidebarHeaderAnchor(leadingInset: 152, trailingXInset: 400, centerYInset: 60)
        let placement = try #require(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: weekly, header: wide))
        #expect(placement.frame == CGRect(x: -1048, y: 926, width: 148, height: 28))
        #expect(!placement.compact)
        let narrow = CodexSidebarHeaderAnchor(leadingInset: 152, trailingXInset: 250, centerYInset: 60)
        let compact = try #require(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: weekly, header: narrow))
        #expect(compact.compact && compact.frame.width == 88)
        #expect(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: weekly, header: nil) == nil)
        let tooSmall = CodexSidebarHeaderAnchor(leadingInset: 152, trailingXInset: 239, centerYInset: 60)
        #expect(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: weekly, header: tooSmall) == nil)
        let dual = CodexQuotaOverlayPresentation.make(snapshot: snapshot(primary: window(usedPercent: 42), secondary: window(usedPercent: 8)), displayMode: .remaining, now: now)
        #expect(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: dual, header: wide)?.frame.width == 248)
        #expect(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: dual, header: narrow) == nil)
        let position = try #require(CodexSidebarQuotaPosition(horizontalFraction: 1, verticalFraction: 1))
        let manual = try #require(CodexQuotaOverlayLayout.summaryPlacement(in: host, presentation: weekly, header: nil, manualPosition: position))
        #expect(manual.frame.maxX == host.maxX - 12)
        #expect(manual.frame.maxY == host.maxY - 12)
        #expect(CodexQuotaOverlayLayout.manualPosition(for: manual.frame, in: host) == position)
    }

    @Test("Details open below the header, clamp on short screens, and retain all windows and credits")
    func detailsLayout() {
        let host = CGRect(x: -1200, y: 200, width: 1200, height: 800)
        let summary = CGRect(x: -1048, y: 926, width: 148, height: 28)
        let frame = CodexQuotaOverlayLayout.detailsFrame(in: host, summaryFrame: summary, contentHeight: 190)
        #expect(frame == CGRect(x: -1048, y: 730, width: 272, height: 190))
        let weekly = CodexQuotaOverlayPresentation.make(snapshot: snapshot(primary: nil, secondary: window(usedPercent: 8)), displayMode: .remaining, now: now)
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(presentation: weekly, resetCredits: nil) == 190)
        let dual = CodexQuotaOverlayPresentation.make(snapshot: snapshot(primary: window(usedPercent: 42), secondary: window(usedPercent: 8)), displayMode: .remaining, now: now)
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(presentation: dual, resetCredits: nil) == 303)
        let credits = CodexQuotaOverlayResetCreditsPresentation(availableCount: 1, expirations: [now.addingTimeInterval(3600)])
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(presentation: dual, resetCredits: credits) > 303)
        let shortHost = CGRect(x: 0, y: 0, width: 480, height: 320)
        let clamped = CodexQuotaOverlayLayout.detailsFrame(in: shortHost, summaryFrame: CGRect(x: 320, y: 250, width: 148, height: 28), contentHeight: 400)
        #expect(shortHost.contains(clamped))
        #expect(clamped.height < 400)
        let missing = CodexQuotaOverlayPresentation.make(snapshot: nil, displayMode: .remaining, now: now)
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(presentation: missing, resetCredits: nil) == 190)
    }

    @Test("A failed refresh marks even recent data stale without inventing missing windows")
    func failedRefresh() {
        let cached = CodexQuotaOverlayPresentation.make(snapshot: snapshot(primary: nil, secondary: window(usedPercent: 8)), displayMode: .remaining, now: now, refreshFailed: true)
        #expect(cached.isCached && cached.weekly?.percent == 92)
        #expect(cached.fiveHour == nil)
    }

    @Test("Mouse-down dismissal keeps only overlay-owned interactions open")
    func clickAwayDismissalPolicy() {
        #expect(!CodexQuotaOverlayInteractionPolicy.shouldDismissDetails(
            afterMouseDownIn: CodexQuotaOverlayLayout.windowIdentifier))
        #expect(!CodexQuotaOverlayInteractionPolicy.shouldDismissDetails(
            afterMouseDownIn: CodexQuotaOverlayLayout.detailsWindowIdentifier))
        #expect(CodexQuotaOverlayInteractionPolicy.shouldDismissDetails(
            afterMouseDownIn: "codex-document"))
        #expect(CodexQuotaOverlayInteractionPolicy.shouldDismissDetails(
            afterMouseDownIn: nil))
    }

    @Test("Moving requires a complete one-second hold while short clicks still open details")
    func longPressDragPolicy() {
        #expect(CodexQuotaOverlayDragInteractionPolicy.holdDuration == .seconds(1))
        #expect(!CodexQuotaOverlayDragPhase.pressing.isUnlocked)
        #expect(CodexQuotaOverlayDragPhase.ready.isUnlocked)
        #expect(CodexQuotaOverlayDragPhase.dragging.isUnlocked)
        #expect(CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: .pressing,
            translation: .zero) == .activateDetails)
        #expect(CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: .pressing,
            translation: CGSize(width: 4, height: 0)) == .cancel)
        #expect(CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: .ready,
            translation: .zero) == .finishDrag)
        #expect(CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: .dragging,
            translation: CGSize(width: 20, height: 12)) == .finishDrag)
        #expect(CodexQuotaOverlayDragInteractionPolicy.releaseAction(
            phase: .idle,
            translation: .zero) == .cancel)

        let english = LocalizationTestSupport.withLanguage(.english) {
            [L10n.codexOverlayHoldToMove, L10n.codexOverlayReadyToMove]
        }
        let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            [L10n.codexOverlayHoldToMove, L10n.codexOverlayReadyToMove]
        }
        #expect(english == ["Hold 1 sec, then drag", "Drag now"])
        #expect(chinese == ["按住 1 秒后拖动", "现在可拖动"])
    }

    @Test("Unlock applies pointer movement accumulated during the hold")
    func longPressUnlockAppliesAccumulatedMovement() {
        let startFrame = CGRect(x: 120, y: 40, width: 132, height: 25)
        let containerFrame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let unlockedFrame = CodexQuotaOverlayDragFramePolicy.frame(
            from: startFrame,
            pressLocation: CGPoint(x: 180, y: 52),
            currentLocation: CGPoint(x: 330, y: 172),
            in: containerFrame)

        #expect(unlockedFrame == CGRect(
            x: 270,
            y: 160,
            width: 132,
            height: 25))
    }

    @Test("Reset-card details prefer expirations and fall back to a live count")
    func resetCreditsPresentation() {
        let expirations = [
            now.addingTimeInterval(100),
            now.addingTimeInterval(200),
            now.addingTimeInterval(300),
            now.addingTimeInterval(400)
        ]
        let snapshot = CodexResetCreditsSnapshot(
            capturedAt: now,
            availableCount: 4,
            credits: expirations.map {
                CodexResetCredit(grantedAt: nil, expiresAt: $0)
            },
            detailStatus: .complete)

        let detailed = CodexQuotaOverlayResetCreditsPresentation.make(
            snapshot: snapshot,
            fallbackAvailableCount: nil,
            now: now)
        #expect(detailed?.availableCount == 4)
        #expect(detailed?.expirations == Array(expirations.prefix(3)))

        let countOnly = CodexQuotaOverlayResetCreditsPresentation.make(
            snapshot: nil,
            fallbackAvailableCount: 2,
            now: now)
        #expect(countOnly?.availableCount == 2)
        #expect(countOnly?.expirations.isEmpty == true)
        #expect(CodexQuotaOverlayResetCreditsPresentation.make(
            snapshot: nil,
            fallbackAvailableCount: 0,
            now: now) == nil)
    }

    @Test("Expired reset cards disappear and no longer inflate the count")
    func expiredResetCreditsAreFiltered() throws {
        let snapshot = CodexResetCreditsSnapshot(
            capturedAt: now.addingTimeInterval(-300),
            availableCount: 4,
            credits: [
                CodexResetCredit(
                    grantedAt: nil,
                    expiresAt: now.addingTimeInterval(-1)),
                CodexResetCredit(
                    grantedAt: nil,
                    expiresAt: now.addingTimeInterval(100)),
                CodexResetCredit(
                    grantedAt: nil,
                    expiresAt: now.addingTimeInterval(200)),
            ],
            detailStatus: .complete)

        let active = try #require(
            CodexQuotaOverlayResetCreditsPresentation.make(
                snapshot: snapshot,
                fallbackAvailableCount: 4,
                now: now))
        #expect(active.availableCount == 2)
        #expect(active.expirations == [
            now.addingTimeInterval(100),
            now.addingTimeInterval(200)
        ])

        #expect(CodexQuotaOverlayResetCreditsPresentation.make(
            snapshot: CodexResetCreditsSnapshot(
                capturedAt: now.addingTimeInterval(-300),
                availableCount: 1,
                credits: [CodexResetCredit(
                    grantedAt: nil,
                    expiresAt: now)],
                detailStatus: .complete),
            fallbackAvailableCount: 1,
            now: now) == nil)
    }

    @Test("Reset countdowns stay compact and stop at the refresh boundary")
    func compactResetCountdown() {
        #expect(CodexQuotaOverlayTimeFormatting.countdown(
            to: now.addingTimeInterval(60),
            now: now) != nil)
        #expect(CodexQuotaOverlayTimeFormatting.countdown(
            to: now,
            now: now) == nil)
        #expect(CodexQuotaOverlayTimeFormatting.countdown(
            to: now.addingTimeInterval(-1),
            now: now) == nil)
    }

    @Test("The native widget defaults on and persists an explicit opt-out")
    @MainActor
    func settingPersists() {
        let suite = "CodexQuotaOverlayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.codexSidebarQuotaEnabled)
        #expect(defaults.bool(forKey: "settings.codexSidebarQuotaEnabled"))

        settings.codexSidebarQuotaEnabled = false
        #expect(!SettingsStore(defaults: defaults).codexSidebarQuotaEnabled)
    }

    @Test("A manual widget position persists and can be reset")
    @MainActor
    func manualPositionPersistsAndResets() {
        let suite = "CodexQuotaOverlayPositionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.codexSidebarQuotaPosition == nil)
        settings.codexSidebarQuotaPosition = CodexSidebarQuotaPosition(
            horizontalFraction: 0.75,
            verticalFraction: 0.25)
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaPosition
            == CodexSidebarQuotaPosition(
                horizontalFraction: 0.75,
                verticalFraction: 0.25))

        settings.codexSidebarQuotaPosition = nil
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaPosition == nil)

        defaults.set(
            [0.5, "invalid"],
            forKey: "settings.codexSidebarQuotaPosition")
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaPosition == nil)
    }

    @Test("Overlay intent stays hidden until Codex tracking is enabled")
    @MainActor
    func overlayRequiresCodexProvider() {
        let suite = "CodexQuotaOverlayProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["claude"], forKey: "settings.enabledProviders")
        defaults.set(true, forKey: "settings.codexSidebarQuotaEnabled")

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.codexSidebarQuotaEnabled)
        #expect(!settings.shouldShowCodexSidebarQuota)
        #expect(settings.setProviderEnabled("codex", enabled: true))
        #expect(settings.shouldShowCodexSidebarQuota)
    }

    @Test("Native overlay contains no Codex process or debugging lifecycle")
    func nativeArchitectureHasNoRelaunchPath() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "QuotaMonitor/App/CodexQuotaOverlayController.swift"),
            encoding: .utf8)
        let helpControlSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "QuotaMonitor/App/CodexSidebarHeaderAccessibility.swift"),
            encoding: .utf8)
        let viewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "QuotaMonitor/App/CodexQuotaOverlayView.swift"),
            encoding: .utf8)
        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("build.sh"),
            encoding: .utf8)
        let appDelegate = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "QuotaMonitor/App/AppDelegate.swift"),
            encoding: .utf8)

        #expect(!source.contains("SIGTERM"))
        #expect(!source.contains("remote-debugging-port"))
        #expect(!source.contains("Process()"))
        #expect(helpControlSource.contains("AXIsProcessTrusted()"))
        #expect(!helpControlSource.contains("kAXTrustedCheckOptionPrompt"))
        #expect(helpControlSource.contains("maximumVisitedElements = 600"))
        #expect(source.contains("Task.detached(priority: .utility)"))
        #expect(source.contains("headerNextDiscoveryAt"))
        #expect(source.contains("workspace.runningApplications"))
        #expect(source.contains("updateTrackingInterval(nil)"))
        #expect(source.contains(
            "panel.ignoresMouseEvents = !placement.allowsInteraction"))
        #expect(source.contains("ignoresMouseEvents: false"))
        #expect(source.contains(
            "panel.ignoresMouseEvents = ignoresMouseEvents"))
        #expect(source.contains("panel.level = .normal"))
        #expect(!source.contains("panel.level = .floating"))
        #expect(source.contains(
            "panel.order(.above, relativeTo: codexWindowNumber)"))
        #expect(source.contains("summaryDragBegan"))
        #expect(source.contains("summaryDragChanged"))
        let pressHandler = try #require(source.range(
            of: "private func summaryPressBegan()"))
        let dragBeginHandler = try #require(source.range(
            of: "private func summaryDragBegan()"))
        let dragChangedHandler = try #require(source.range(
            of: "private func summaryDragChanged()"))
        let pressBody = source[
            pressHandler.lowerBound..<dragBeginHandler.lowerBound]
        let dragBeginBody = source[
            dragBeginHandler.lowerBound..<dragChangedHandler.lowerBound]
        #expect(pressBody.contains(
            "summaryDragStartMouseLocation = NSEvent.mouseLocation"))
        #expect(dragBeginBody.contains("summaryDragChanged()"))
        #expect(viewSource.contains("DragGesture(minimumDistance: 0"))
        #expect(viewSource.contains(
            "CodexQuotaOverlayDragInteractionPolicy.holdDuration"))
        #expect(viewSource.contains("repeatForever(autoreverses: true)"))
        #expect(viewSource.contains("accessibilityReduceMotion"))
        #expect(source.contains("detailsPanel"))
        #expect(source.contains("addGlobalMonitorForEvents"))
        #expect(!source.contains("isDetailsPinned"))
        #expect(viewSource.contains("ViewThatFits(in: .vertical)"))
        #expect(viewSource.contains(
            ".fixedSize(horizontal: false, vertical: true)"))
        #expect(viewSource.contains("ScrollView(.vertical)"))
        #expect(viewSource.contains(".scrollIndicators(.hidden)"))
        #expect(!viewSource.contains("private func metricAccent"))
        #expect(!viewSource.contains(".fill(Material.ultraThin)"))
        #expect(!viewSource.contains(".fill(.regularMaterial)"))
        #expect(viewSource.contains(
            ".fill(Color(nsColor: .windowBackgroundColor))"))
        let pollingStart = try #require(
            appDelegate.range(of: "env.startBackgroundPolling()"))
        let overlayStart = try #require(
            appDelegate.range(of: "overlayController.start()"))
        #expect(pollingStart.lowerBound < overlayStart.lowerBound)
        #expect(!buildScript.localizedCaseInsensitiveContains("opsail"))
        #expect(!FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent(
                "QuotaMonitor/App/OpsailCodexRefitController.swift").path))
    }
}
