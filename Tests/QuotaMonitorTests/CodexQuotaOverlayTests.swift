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

    @Test("Overlay stays inside the Codex account row")
    func accountRowLayout() {
        #expect(CodexQuotaOverlayLayout.frame(
            in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
            == CGRect(x: 100, y: 12, width: 132, height: 25))
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
        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("build.sh"),
            encoding: .utf8)

        #expect(!source.contains("SIGTERM"))
        #expect(!source.contains("remote-debugging-port"))
        #expect(!source.contains("Process()"))
        #expect(!buildScript.localizedCaseInsensitiveContains("opsail"))
        #expect(!FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent(
                "QuotaMonitor/App/OpsailCodexRefitController.swift").path))
    }
}
