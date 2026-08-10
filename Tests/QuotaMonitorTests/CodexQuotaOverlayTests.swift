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

    @Test("Overlay follows the right-side help control slot")
    func accountRowLayout() {
        let minimumWindow = CGRect(x: 0, y: 0, width: 480, height: 700)
        #expect(CodexQuotaOverlayLayout.frame(
            in: minimumWindow)
            == CGRect(x: 274, y: 12, width: 132, height: 25))

        let referenceWindow = CGRect(x: 0, y: 0, width: 490, height: 700)
        #expect(CodexQuotaOverlayLayout.frame(
            in: referenceWindow)
            == CGRect(x: 284, y: 12, width: 132, height: 25))

        let widerWindow = CGRect(x: 0, y: 0, width: 720, height: 700)
        #expect(CodexQuotaOverlayLayout.frame(
            in: widerWindow)
            == CGRect(x: 514, y: 12, width: 132, height: 25))
        #expect(CodexQuotaOverlayLayout.frame(
            in: CGRect(x: -1_200, y: 200, width: 1_000, height: 700))
            == CGRect(x: -406, y: 212, width: 132, height: 25))

        let weeklyOnly = CodexQuotaOverlayPresentation.make(
            snapshot: snapshot(
                primary: nil,
                secondary: window(usedPercent: 20)),
            displayMode: .used,
            now: now)
        #expect(CodexQuotaOverlayLayout.frame(
            in: referenceWindow,
            presentation: weeklyOnly) == CGRect(
                x: 332,
                y: 12,
                width: 84,
                height: 25))
        #expect(CodexQuotaOverlayLayout.frame(
            in: widerWindow,
            presentation: weeklyOnly).maxX == CodexQuotaOverlayLayout.frame(
                in: widerWindow).maxX)
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(
            presentation: weeklyOnly,
            resetCredits: nil) == 97)
    }

    @Test("Hover details occupy the sidebar above the established account row")
    func hoverDetailsLayout() {
        let rateLimits = snapshot(
            primary: window(usedPercent: 37),
            secondary: window(usedPercent: 18))
        let presentation = CodexQuotaOverlayPresentation.make(
            snapshot: rateLimits,
            displayMode: .used,
            now: now)
        let resetCredits = CodexQuotaOverlayResetCreditsPresentation(
            availableCount: 3,
            expirations: [
                now.addingTimeInterval(86_400),
                now.addingTimeInterval(172_800),
                now.addingTimeInterval(259_200)
            ])

        #expect(CodexQuotaOverlayLayout.detailsContentHeight(
            presentation: presentation,
            resetCredits: nil) == 158)
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(
            presentation: presentation,
            resetCredits: resetCredits) == 238)
        #expect(CodexQuotaOverlayLayout.detailsFrame(
            in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            contentHeight: 222) == CGRect(
                x: 1_558,
                y: 43,
                width: 288,
                height: 222))

        let cached = CodexQuotaOverlayPresentation.make(
            snapshot: snapshot(
                capturedOffset: -(16 * 60),
                primary: window(usedPercent: 37),
                secondary: window(usedPercent: 18)),
            displayMode: .used,
            now: now)
        #expect(cached.isCached)
        #expect(CodexQuotaOverlayLayout.detailsContentHeight(
            presentation: cached,
            resetCredits: nil) == 158)
        #expect(CodexQuotaOverlayLayout.detailsFrame(
            in: CGRect(x: -1_200, y: 200, width: 600, height: 320),
            contentHeight: 300) == CGRect(
                x: -962,
                y: 243,
                width: 288,
                height: 265))
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

    @Test("The existing sidebar opt-in persists across the native migration")
    @MainActor
    func settingPersists() {
        let suite = "CodexQuotaOverlayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.codexSidebarQuotaEnabled)
        settings.codexSidebarQuotaEnabled = true
        #expect(SettingsStore(defaults: defaults).codexSidebarQuotaEnabled)
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
        #expect(source.contains(
            "panel.ignoresMouseEvents = !placement.allowsInteraction"))
        #expect(source.contains("ignoresMouseEvents: false"))
        #expect(source.contains(
            "panel.ignoresMouseEvents = ignoresMouseEvents"))
        #expect(source.contains("panel.level = .normal"))
        #expect(!source.contains("panel.level = .floating"))
        #expect(source.contains(
            "panel.order(.above, relativeTo: codexWindowNumber)"))
        #expect(source.contains("onHoverChanged"))
        #expect(source.contains("detailsPanel"))
        #expect(source.contains("addGlobalMonitorForEvents"))
        #expect(!source.contains("isDetailsPinned"))
        #expect(viewSource.contains("Text(Branding.appDisplayName)"))
        #expect(viewSource.contains("ViewThatFits(in: .vertical)"))
        #expect(viewSource.contains(
            ".fixedSize(horizontal: false, vertical: true)"))
        #expect(viewSource.contains("ScrollView(.vertical)"))
        #expect(viewSource.contains(".scrollIndicators(.hidden)"))
        #expect(viewSource.contains("QuotaWindowCompactLabel.fiveHour"))
        #expect(viewSource.contains("QuotaWindowCompactLabel.sevenDay"))
        #expect(viewSource.contains("Text(QuotaWindowCompactLabel.segment("))
        #expect(viewSource.contains("style: settings.menuBarLabelStyle"))
        #expect(!viewSource.contains("private func metricAccent"))
        #expect(!viewSource.contains(".fill(Material.ultraThin)"))
        #expect(!viewSource.contains(".fill(.regularMaterial)"))
        #expect(viewSource.contains(
            ".fill(Color.primary.opacity(isHovering ? 0.035 : 0.018))"))
        #expect(viewSource.contains(
            "color: .black.opacity(isHovering ? 0.13 : 0)"))
        #expect(viewSource.contains(
            ".fill(Color(nsColor: .windowBackgroundColor))"))
        #expect(viewSource.contains(
            ".primary.opacity(isHovering ? 0.12 : 0.055)"))
        #expect(viewSource.contains(
            "lineWidth: isHovering ? 0.75 : 0.5"))
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
