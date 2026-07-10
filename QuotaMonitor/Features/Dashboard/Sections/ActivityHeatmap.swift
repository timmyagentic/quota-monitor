import SwiftUI

/// Mode selector for the activity chart. Only `.daily` is used currently
/// (the classic GitHub-style contribution heatmap). The enum is kept for
/// potential future use (weekly bar chart, cumulative area chart).
enum HeatmapMode: String, CaseIterable, Identifiable, Hashable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }
}

/// Five-step blue scale, shared by the grid and the legend so they can't
/// drift. Level 0 is the empty / no-activity tint; 1…4 brighten with volume.
enum HeatmapPalette {
    static func color(level: Int) -> Color {
        switch level {
        case ..<1:  return Color.primary.opacity(0.045)
        case 1:     return DashboardTheme.accentBlue.opacity(0.22)
        case 2:     return DashboardTheme.accentBlue.opacity(0.45)
        case 3:     return DashboardTheme.accentBlue.opacity(0.75)
        default:    return Color(red: 0.72, green: 0.90, blue: 1.0)
        }
    }
}

/// Pure geometry shared by the heatmap grid, its hover hit-areas, and the
/// tooltip overlay. Each cell's hover area is the full `cell + gap` pitch
/// square (the visible square sits inset by `gap / 2`), so hit areas tile
/// the grid with no dead zones between squares. The tooltip hangs its
/// bottom edge `tooltipMargin` above the hovered square so it never covers
/// the square — or the cursor, which would steal the hover and flicker.
enum HeatmapGeometry {
    static let tooltipMargin: CGFloat = 4

    /// Full hover-sensitive area of a cell, in grid coordinates.
    static func hitFrame(col: Int, row: Int, cell: CGFloat, gap: CGFloat) -> CGRect {
        let pitch = cell + gap
        return CGRect(
            x: CGFloat(col) * pitch, y: CGFloat(row) * pitch,
            width: pitch, height: pitch)
    }

    /// The visible coloured square, centred inside its hit area.
    static func squareFrame(col: Int, row: Int, cell: CGFloat, gap: CGFloat) -> CGRect {
        hitFrame(col: col, row: row, cell: cell, gap: gap)
            .insetBy(dx: gap / 2, dy: gap / 2)
    }

    /// Point the tooltip's bottom-centre is pinned to: horizontally centred
    /// on the square, `tooltipMargin` above its top edge.
    static func tooltipAnchor(col: Int, row: Int, cell: CGFloat, gap: CGFloat) -> CGPoint {
        let square = squareFrame(col: col, row: row, cell: cell, gap: gap)
        return CGPoint(x: square.midX, y: square.minY - tooltipMargin)
    }
}

/// GitHub-style contribution heatmap: weeks as columns, weekday as rows,
/// month labels along the top. Cells are bucketed into five intensity levels.
/// Horizontally scrollable so a full year never clips inside the dashboard.
/// Only used in `.daily` mode.
struct ActivityHeatmap: View {
    /// Trailing daily series, oldest first, zero-filled (one entry per day).
    let daily: [DailyPoint]
    let tokenLocale: Locale

    @State private var hoveredCell: (col: Int, row: Int, cell: HeatmapModel.Cell)?

    private let cell: CGFloat = 13
    private let gap: CGFloat = 4

    var body: some View {
        let model = HeatmapModel(daily: daily, calendar: .current)
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        grid(model)
                        monthLabels(model)
                    }
                    if let (col, row, cell) = hoveredCell, let point = cell.point {
                        tooltipOverlay(for: point, col: col, row: row)
                    }
                }
                // Give the tooltip room to appear above the first row
                // without being clipped by the parent card.
                .padding(.top, 44)
            }
            .padding(.top, -44)
            legend
        }
    }

    // MARK: - tooltip overlay

    private func tooltipOverlay(for point: DailyPoint, col: Int, row: Int) -> some View {
        let date = point.date.formatted(.dateTime.year().month(.abbreviated).day())
        let tokens = point.tokens.formatted(
            .number.notation(.compactName).locale(tokenLocale))
        let anchor = HeatmapGeometry.tooltipAnchor(col: col, row: row, cell: cell, gap: gap)

        return VStack(alignment: .leading, spacing: 2) {
            Text(date)
                .font(.caption.weight(.medium))
            Text(L10n.tokensCount(tokens))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        )
        .fixedSize()
        // Zero-sized bottom-aligned frame turns `.position` (which pins the
        // view's centre) into a bottom-centre pin, so the whole tooltip sits
        // above the anchor no matter how tall its content renders.
        .frame(width: 0, height: 0, alignment: .bottom)
        .position(x: anchor.x, y: anchor.y)
        // The tooltip must never intercept the cursor: if it did, the cell
        // below would see the hover end, dismiss the tooltip, and flicker.
        .allowsHitTesting(false)
    }

    // MARK: - grid

    private func grid(_ model: HeatmapModel) -> some View {
        // Spacing lives INSIDE each cell (gap/2 padding around the visible
        // square) rather than between stack elements, so the hover-sensitive
        // areas tile the grid edge-to-edge — pointing at the gap between two
        // squares still keeps the tooltip up instead of hitting a dead zone.
        HStack(alignment: .top, spacing: 0) {
            ForEach(model.weeks.indices, id: \.self) { col in
                VStack(spacing: 0) {
                    ForEach(model.weeks[col].indices, id: \.self) { row in
                        cellView(model.weeks[col][row], col: col, row: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ entry: HeatmapModel.Cell, col: Int, row: Int) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(HeatmapPalette.color(level: entry.level))
            .frame(width: cell, height: cell)
            .padding(gap / 2)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering && entry.point != nil {
                    hoveredCell = (col, row, entry)
                } else if !hovering {
                    if hoveredCell?.col == col && hoveredCell?.row == row {
                        hoveredCell = nil
                    }
                }
            }
    }

    // MARK: - month labels

    private func monthLabels(_ model: HeatmapModel) -> some View {
        let width = CGFloat(model.weeks.count) * (cell + gap)
        return ZStack(alignment: .topLeading) {
            ForEach(model.monthMarkers, id: \.column) { marker in
                Text(marker.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // gap/2 keeps the label flush with its column's visible
                    // square now that squares sit inset inside their cells.
                    .offset(x: gap / 2 + CGFloat(marker.column) * (cell + gap))
            }
        }
        .frame(width: max(width, 1), height: 12, alignment: .topLeading)
    }

    // MARK: - legend

    private var legend: some View {
        HStack(spacing: 4) {
            Text(L10n.activityHeatmapLess)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(HeatmapPalette.color(level: level))
                    .frame(width: cell, height: cell)
            }
            Text(L10n.activityHeatmapMore)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Pure layout model for the daily heatmap: turns the flat daily series into
/// calendar-aligned week columns, assigns each day an intensity level based
/// on its token count, and works out where month labels go.
struct HeatmapModel {
    struct Cell {
        let point: DailyPoint?   // nil = calendar padding outside the range
        let level: Int           // 0…4
    }

    /// Each inner array is one week (7 entries, top → bottom by weekday).
    let weeks: [[Cell]]
    /// `(column index, abbreviated month label)` for the first column of
    /// each month present in the range.
    let monthMarkers: [(column: Int, label: String)]

    init(daily: [DailyPoint], calendar: Calendar) {
        // 1. Bucket each day's token count into intensity levels.
        let values = daily.map { Double($0.tokens) }
        let thresholds = HeatmapModel.thresholds(values: values)
        func level(_ v: Double) -> Int {
            guard v > 0 else { return 0 }
            var lvl = 1
            for t in thresholds where v > t { lvl += 1 }
            return min(lvl, 4)
        }

        // 2. Pad the leading days so column 0 starts on the calendar's
        //    first weekday, then chunk into 7-day columns.
        guard let first = daily.first?.date else {
            weeks = []
            monthMarkers = []
            return
        }
        let weekdayOfFirst = calendar.component(.weekday, from: first)
        let lead = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        var cells: [Cell] = []
        cells.reserveCapacity(daily.count + lead + 7)
        for _ in 0..<lead { cells.append(Cell(point: nil, level: 0)) }
        for (i, point) in daily.enumerated() {
            cells.append(Cell(point: point, level: level(values[i])))
        }
        while cells.count % 7 != 0 { cells.append(Cell(point: nil, level: 0)) }

        var builtWeeks: [[Cell]] = []
        var c = 0
        while c < cells.count {
            builtWeeks.append(Array(cells[c..<min(c + 7, cells.count)]))
            c += 7
        }
        weeks = builtWeeks

        // 3. Month markers: first column whose representative day starts a
        //    new month.
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = LocalizationStore.activeLanguage == .simplifiedChinese
            ? Locale(identifier: "zh_Hans")
            : Locale(identifier: "en_US")
        monthFormatter.setLocalizedDateFormatFromTemplate("MMM")

        var markers: [(column: Int, label: String)] = []
        var lastMonth = -1
        for (col, week) in builtWeeks.enumerated() {
            guard let date = week.compactMap({ $0.point?.date }).first else { continue }
            let month = calendar.component(.month, from: date)
            if month != lastMonth {
                markers.append((col, monthFormatter.string(from: date)))
                lastMonth = month
            }
        }
        monthMarkers = markers
    }

    /// Three cut points splitting levels 1/2, 2/3, 3/4. Quartiles of the
    /// non-zero values so one runaway day doesn't wash everything else pale.
    static func thresholds(values: [Double]) -> [Double] {
        let nonzero = values.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return [0, 0, 0] }
        func percentile(_ p: Double) -> Double {
            let idx = Int((Double(nonzero.count - 1) * p).rounded())
            return nonzero[min(max(idx, 0), nonzero.count - 1)]
        }
        return [percentile(0.25), percentile(0.5), percentile(0.75)]
    }
}
