import CoreGraphics
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import QuotaMonitor

@Suite("Codex attached quota capsule")
struct CodexAttachedCapsuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("weekly quota maps to compact remaining and expanded used values")
    func mapsWeeklyQuota() {
        let snapshot = makeSnapshot(
            capturedAt: now.addingTimeInterval(-60),
            weeklyUsedPercent: 96.2,
            resetAt: now.addingTimeInterval(3_600))

        let presentation = CodexAttachedCapsulePresentation(
            snapshot: snapshot,
            now: now)

        #expect(presentation.availability == .fresh)
        #expect(presentation.usedPercent == 96)
        #expect(presentation.remainingPercent == 4)
        #expect(presentation.resetAt == now.addingTimeInterval(3_600))
    }

    @Test("missing weekly quota is unavailable")
    func missingWeeklyQuotaIsUnavailable() {
        let snapshot = RateLimitSnapshot(
            capturedAt: now,
            planType: "pro",
            primary: .init(
                usedPercent: 20,
                windowDuration: 18_000,
                resetAt: now.addingTimeInterval(1_000)),
            secondary: nil,
            additional: [],
            resetCreditsAvailable: nil)

        let presentation = CodexAttachedCapsulePresentation(
            snapshot: snapshot,
            now: now)

        #expect(presentation.availability == .unavailable)
        #expect(presentation.usedPercent == nil)
        #expect(presentation.remainingPercent == nil)
        #expect(presentation.resetAt == nil)
    }

    @Test("old or expired snapshots are marked stale")
    func staleSnapshot() {
        let old = CodexAttachedCapsulePresentation(
            snapshot: makeSnapshot(
                capturedAt: now.addingTimeInterval(-601),
                weeklyUsedPercent: 40,
                resetAt: now.addingTimeInterval(600)),
            now: now)
        let expired = CodexAttachedCapsulePresentation(
            snapshot: makeSnapshot(
                capturedAt: now,
                weeklyUsedPercent: 40,
                resetAt: now.addingTimeInterval(-1)),
            now: now)

        #expect(old.availability == .stale)
        #expect(expired.availability == .stale)
    }

    @Test("freshness threshold can follow a slower configured poll interval")
    func configurableFreshnessThreshold() {
        let presentation = CodexAttachedCapsulePresentation(
            snapshot: makeSnapshot(
                capturedAt: now.addingTimeInterval(-1_200),
                weeklyUsedPercent: 40,
                resetAt: now.addingTimeInterval(600)),
            now: now,
            maximumFreshAge: 1_800)

        #expect(presentation.availability == .fresh)
    }

    @Test("Quartz window coordinates convert to AppKit coordinates")
    func convertsQuartzCoordinates() {
        let frame = CodexAttachedCapsuleGeometry.appKitFrame(
            quartzBounds: CGRect(x: 20, y: 100, width: 1_200, height: 800),
            primaryScreenMaxY: 1_117)

        #expect(frame == CGRect(x: 20, y: 217, width: 1_200, height: 800))
    }

    @Test("compact and expanded panels retain the same bottom anchor")
    func panelFramesShareAnchor() {
        let target = CGRect(x: 30, y: 40, width: 1_200, height: 800)
        let compact = CodexAttachedCapsuleGeometry.panelFrame(
            targetWindow: target,
            panelSize: CodexAttachedCapsuleGeometry.compactSize)
        let expanded = CodexAttachedCapsuleGeometry.panelFrame(
            targetWindow: target,
            panelSize: CodexAttachedCapsuleGeometry.expandedSize)

        #expect(compact.minY == expanded.minY)
        #expect(compact.midX == expanded.midX)
        #expect(compact.minY == target.minY + 14)
        #expect(compact.minX >= target.minX + 8)
        #expect(expanded.maxX <= target.maxX - 8)
    }

    @Test("window selection ignores overlays and chooses the largest usable window")
    func choosesLargestUsableWindow() {
        let windows = [
            CodexWindowInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                            layer: 0, alpha: 1, isOnscreen: true),
            CodexWindowInfo(id: 2, bounds: CGRect(x: 0, y: 0, width: 1_400, height: 900),
                            layer: 3, alpha: 1, isOnscreen: true),
            CodexWindowInfo(id: 3, bounds: CGRect(x: 10, y: 10, width: 900, height: 700),
                            layer: 0, alpha: 1, isOnscreen: true),
            CodexWindowInfo(id: 4, bounds: CGRect(x: 20, y: 20, width: 1_200, height: 800),
                            layer: 0, alpha: 1, isOnscreen: true)
        ]

        #expect(CodexWindowSelector.bestWindow(in: windows)?.id == 4)
    }

    @Test("unified ChatGPT desktop bundle is recognized as Codex")
    func recognizesUnifiedDesktopBundle() {
        #expect(CodexWindowLocator.supportedBundleIdentifiers == ["com.openai.codex"])
    }

    @MainActor
    @Test("expanded capsule can render a QA artifact")
    func rendersExpandedQAArtifactWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "QUOTAMONITOR_CAPSULE_SCREENSHOT"] else { return }

        let renderNow = Date()
        let presentation = CodexAttachedCapsulePresentation(
            snapshot: makeSnapshot(
                capturedAt: renderNow,
                weeklyUsedPercent: 96.2,
                resetAt: renderNow.addingTimeInterval(7_200)),
            now: renderNow)
        let model = CodexAttachedCapsuleViewModel(presentation: presentation)
        model.isExpanded = true
        let content = CodexAttachedCapsuleView(
            model: model,
            onHoverChange: { _ in })
            .environment(LocalizationStore.shared)
            .padding(26)
            .frame(width: 300, height: 250)
            .background(Color(nsColor: .controlBackgroundColor))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let representation = NSBitmapImageRep(cgImage: image)
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private func makeSnapshot(
        capturedAt: Date,
        weeklyUsedPercent: Double,
        resetAt: Date
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            capturedAt: capturedAt,
            planType: "pro",
            primary: nil,
            secondary: .init(
                usedPercent: weeklyUsedPercent,
                windowDuration: 604_800,
                resetAt: resetAt),
            additional: [],
            resetCreditsAvailable: nil)
    }
}

@MainActor
@Suite("Codex attached quota capsule setting")
struct CodexAttachedCapsuleSettingTests {
    @Test("setting defaults off and persists explicit opt in")
    func defaultAndPersistence() {
        let suite = "test.codex-capsule.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let initial = SettingsStore(defaults: defaults)
        #expect(initial.codexAttachedCapsuleEnabled == false)

        initial.codexAttachedCapsuleEnabled = true
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.codexAttachedCapsuleEnabled == true)
    }
}
