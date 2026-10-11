import AppKit
import Charts
import SwiftUI
import Testing
@testable import QuotaMonitor

@Suite("Trend tooltip hosted layout", .serialized)
@MainActor
struct TrendTooltipLayoutTests {
    @Test("Side tooltip leaves the selected date clear at both edges and the center",
          arguments: [CGFloat(340), CGFloat(600), CGFloat(1200)], [CGFloat(0), CGFloat(0.5), CGFloat(1)])
    func sidePlacement(width: CGFloat, fraction: CGFloat) {
        let plot = CGRect(x: 40, y: 20, width: width, height: 245)
        let x = plot.minX + width * fraction
        for halfWidth: CGFloat in [0, 80] {
            let placement = TrendTooltipPlacement(plotFrame: plot, selectedX: x,
                                                  selectedHalfWidth: halfWidth)
            #expect(placement.origin.x >= plot.minX)
            #expect(placement.origin.x + placement.totalWidth <= plot.maxX)
            #expect(placement.origin.x + placement.totalWidth <= x - halfWidth - 24
                    || placement.origin.x >= x + halfWidth + 24)
            #expect(placement.contentWidth + 18 == placement.totalWidth)
        }
    }

    @Test("Hosted side tooltip keeps pointer access and compact sizing", arguments: [CGFloat(50), CGFloat(600), CGFloat(1150)])
    func hostedSideTooltip(selectedX: CGFloat) async throws {
        let rows = (0..<24).map { index in
            TrendSelection.Row(id: "row-\(index)", label: "GPT-6 Astra",
                color: .green, tokens: Int64(index + 1) * 100, speedTier: .ultrafast)
        }
        let selection = TrendSelection(date: Date(), rows: rows,
            totalTokens: rows.reduce(0) { $0 + $1.tokens }, cacheUsage: .zero)
        let probe = PointerProbe()
        let content = ProbeSurface(probe: probe)
            .overlay(alignment: .topLeading) {
                TrendTooltipOverlay(selection: selection, tokenLocale: Locale(identifier: "en_US"),
                    localization: LocalizationStore.shared,
                    plotFrame: CGRect(x: 0, y: 0, width: 1200, height: 245), selectedX: selectedX)
            }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 245),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 245)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(host.hitTest(CGPoint(x: selectedX, y: 100)) === probe)
        if let directory = ProcessInfo.processInfo.environment["QM_TEST_TREND_TOOLTIP_IMAGE_DIRECTORY"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("side-tooltip-\(Int(selectedX)).png"))
        }
    }

    @Test("Chart annotation renders with its own localization environment")
    func chartAnnotationRendering() throws {
        let date = Date()
        let selection = TrendSelection(date: date, rows: [
            .init(id: "model", label: "GPT-6 Astra", color: .green,
                  tokens: 100, speedTier: .ultrafast)
        ], totalTokens: 100, cacheUsage: .zero)
        // Charts rasterizes annotations in a separate render tree, unlike
        // the ordinary overlay exercised by the layout test below.
        let chart = Chart {
            BarMark(x: .value("Day", date), y: .value("Tokens", 100))
            RuleMark(x: .value("Day", date))
                .annotation(position: .top) {
                    TrendTooltip(selection: selection, tokenLocale: Locale(identifier: "en_US"))
                        .environment(LocalizationStore.shared)
                }
        }
        .environment(LocalizationStore.shared)
        .frame(width: 600, height: 300)
        let renderer = ImageRenderer(content: chart)
        #expect(try #require(renderer.nsImage).size.width == 600)
    }

    @Test("Tooltip stays compact and leaves the chart pointer target intact", arguments: [3, 24])
    func compactNonInteractiveTooltip(rowCount: Int) async throws {
        let rows = (0..<rowCount).map { index in
            TrendSelection.Row(id: "row-\(index)", label: "GPT-6 Astra",
                color: .green, tokens: Int64(index + 1) * 100, speedTier: .ultrafast)
        }
        let selection = TrendSelection(date: Date(), rows: rows,
            totalTokens: rows.reduce(0) { $0 + $1.tokens }, cacheUsage: .zero)
        let probe = PointerProbe()
        let size = LayoutSize()
        let content = ProbeSurface(probe: probe)
            .overlay(alignment: .topTrailing) {
                TrendTooltip(selection: selection, tokenLocale: Locale(identifier: "en_US"))
                    .environment(LocalizationStore.shared)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { size.value = geometry.size }
                            .onChange(of: geometry.size) { _, value in size.value = value }
                    })
            }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 245),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 245)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(size.value.width > 0)
        #expect(size.value.width < 330, "Tooltip stretched to \(size.value.width)")
        #expect(size.value.height <= 245, "Tooltip escaped the plot height")
        for location in [CGPoint(x: 1_100, y: 20), CGPoint(x: 1_100, y: 120),
                         CGPoint(x: 1_100, y: 200), CGPoint(x: 300, y: 100)] {
            #expect(host.hitTest(location) === probe, "Tooltip intercepted the chart pointer target")
        }
        if let directory = ProcessInfo.processInfo.environment["QM_TEST_TREND_TOOLTIP_IMAGE_DIRECTORY"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("tooltip-\(rowCount)-rows.png"))
        }
    }
}

@MainActor
private final class LayoutSize {
    var value = CGSize.zero
}

private final class PointerProbe: NSView {}

private struct ProbeSurface: NSViewRepresentable {
    let probe: PointerProbe
    func makeNSView(context: Context) -> PointerProbe { probe }
    func updateNSView(_ view: PointerProbe, context: Context) {}
}
