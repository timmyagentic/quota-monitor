import Foundation
import Testing

@testable import QuotaMonitor

@Suite("Activity heatmap tooltip geometry")
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
}
