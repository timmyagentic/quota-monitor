import Foundation
import Testing

@testable import QuotaMonitor

@Suite("Activity heatmap geometry and layout")
struct ActivityHeatmapGeometryTests {
    private let cell: CGFloat = 13
    private let gap: CGFloat = 4

    @Test("tooltip anchor is horizontally centred on the hovered square")
    func anchorCentredOnSquare() {
        for col in [0, 3, 25] {
            let anchor = HeatmapGeometry.tooltipAnchor(col: col, row: 2, cell: cell, gap: gap)
            let square = HeatmapGeometry.squareFrame(col: col, row: 2, cell: cell, gap: gap)
            #expect(anchor.x == square.midX)
        }
    }

    @Test("tooltip anchor sits above the hovered square, never over it")
    func anchorAboveSquare() {
        for row in 0..<7 {
            let anchor = HeatmapGeometry.tooltipAnchor(col: 4, row: row, cell: cell, gap: gap)
            let square = HeatmapGeometry.squareFrame(col: 4, row: row, cell: cell, gap: gap)
            #expect(anchor.y < square.minY)
        }
    }

    @Test("hover hit areas of adjacent cells tile the grid without dead zones")
    func hitAreasTile() {
        let origin = HeatmapGeometry.hitFrame(col: 0, row: 0, cell: cell, gap: gap)
        let right = HeatmapGeometry.hitFrame(col: 1, row: 0, cell: cell, gap: gap)
        let below = HeatmapGeometry.hitFrame(col: 0, row: 1, cell: cell, gap: gap)
        #expect(origin.maxX == right.minX)
        #expect(origin.maxY == below.minY)
    }

    @Test("visible square is centred inside its hit area")
    func squareCentredInHitArea() {
        let hit = HeatmapGeometry.hitFrame(col: 2, row: 3, cell: cell, gap: gap)
        let square = HeatmapGeometry.squareFrame(col: 2, row: 3, cell: cell, gap: gap)
        #expect(square.midX == hit.midX)
        #expect(square.midY == hit.midY)
        #expect(square.width == cell)
        #expect(square.height == cell)
    }

    @Test("default dashboard width selects the compact full-year layout")
    func defaultWidthUsesCompactLayout() {
        let defaultWindowWidth: CGFloat = 980
        let dashboardHorizontalPadding: CGFloat = 20 * 2
        let panelHorizontalPadding: CGFloat = 14 * 2
        let availableWidth = defaultWindowWidth
            - dashboardHorizontalPadding
            - panelHorizontalPadding
        let weekCount = 53

        #expect(!HeatmapLayout.regular.fits(
            availableWidth: availableWidth,
            weekCount: weekCount))
        #expect(HeatmapLayout.compact.fits(
            availableWidth: availableWidth,
            weekCount: weekCount))
    }

    @Test("compact layout scrolls only below its full-year width")
    func compactLayoutNarrowWindowThreshold() {
        let weekCount = 53
        let contentWidth = HeatmapLayout.compact.contentWidth(weekCount: weekCount)

        #expect(contentWidth == 819)
        #expect(HeatmapLayout.compact.fits(
            availableWidth: contentWidth,
            weekCount: weekCount))
        #expect(!HeatmapLayout.compact.fits(
            availableWidth: contentWidth - 1,
            weekCount: weekCount))
    }

    @Test("final month label stays inside the heatmap content width")
    func finalMonthLabelFits() {
        let layout = HeatmapLayout.compact
        let weekCount = 53
        let offset = layout.monthLabelOffset(column: weekCount - 1, weekCount: weekCount)

        #expect(offset >= 0)
        #expect(
            offset + HeatmapLayout.monthLabelWidth
                <= layout.contentWidth(weekCount: weekCount))
    }

    @Test("month label offsets clamp to the reserved trailing slot")
    func monthLabelOffsetClamps() {
        let layout = HeatmapLayout.compact
        let weekCount = 53
        let maximum = layout.contentWidth(weekCount: weekCount)
            - HeatmapLayout.monthLabelWidth

        #expect(layout.monthLabelOffset(column: weekCount + 10, weekCount: weekCount) == maximum)
    }
}
