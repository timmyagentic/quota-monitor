import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuotaMonitor

@Suite("Activity heatmap model")
struct ActivityHeatmapModelTests {
    @Test("calendar alignment keeps every point and pads complete weeks")
    func calendarAlignment() throws {
        var calendar = Self.calendar(firstWeekday: 1)
        let start = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 5)))
        let daily = Self.daily(tokens: Array(1...8).map(Int64.init), start: start, calendar: calendar)

        let sundayFirst = HeatmapModel(
            daily: daily,
            calendar: calendar,
            language: .english)
        calendar.firstWeekday = 2
        let mondayFirst = HeatmapModel(
            daily: daily,
            calendar: calendar,
            language: .english)

        #expect(sundayFirst.weeks.count == 2)
        #expect(sundayFirst.weeks.allSatisfy { $0.count == 7 })
        #expect(sundayFirst.weeks[0][0].point == nil)
        #expect(sundayFirst.weeks[0][1].point?.date == start)
        #expect(mondayFirst.weeks[0][0].point?.date == start)
        #expect(Self.points(in: sundayFirst).map(\.date) == daily.map(\.date))
        #expect(Self.points(in: mondayFirst).map(\.date) == daily.map(\.date))
    }

    @Test("token quartiles keep the exact five heatmap levels")
    func exactLevels() throws {
        let calendar = Self.calendar()
        let start = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 4)))
        let tokens: [Int64] = [0, 10, 20, 30, 40, 50, 60, 70, 80]
        let model = HeatmapModel(
            daily: Self.daily(tokens: tokens, start: start, calendar: calendar),
            calendar: calendar,
            language: .english)

        #expect(HeatmapModel.thresholds(values: tokens.map(Double.init)) == [30, 50, 60])
        #expect(Self.levels(in: model) == [0, 1, 1, 1, 2, 2, 3, 4, 4])
    }

    @Test("daily changes refresh levels without changing dates")
    func dailyRefreshesLevels() throws {
        let calendar = Self.calendar()
        let start = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 4)))
        let empty = Self.daily(tokens: [0, 0, 0, 0], start: start, calendar: calendar)
        let active = Self.daily(tokens: [0, 0, 100, 0], start: start, calendar: calendar)

        let emptyModel = HeatmapModel(
            daily: empty,
            calendar: calendar,
            language: .english)
        let activeModel = HeatmapModel(
            daily: active,
            calendar: calendar,
            language: .english)

        #expect(Self.points(in: emptyModel).map(\.date) == Self.points(in: activeModel).map(\.date))
        #expect(Self.levels(in: emptyModel) == [0, 0, 0, 0])
        #expect(Self.levels(in: activeModel) == [0, 0, 1, 0])
    }

    @Test("language changes refresh exact month labels")
    func languageRefreshesMonthLabels() throws {
        let calendar = Self.calendar()
        let start = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 28)))
        let daily = Self.daily(
            tokens: Array(repeating: 1, count: 37),
            start: start,
            calendar: calendar)

        let english = HeatmapModel(
            daily: daily,
            calendar: calendar,
            language: .english)
        let chinese = HeatmapModel(
            daily: daily,
            calendar: calendar,
            language: .simplifiedChinese)

        #expect(english.monthMarkers.map { $0.column } == [0, 1, 5])
        #expect(chinese.monthMarkers.map { $0.column } == [0, 1, 5])
        #expect(english.monthMarkers.map { $0.label } == ["Jan", "Feb", "Mar"])
        #expect(chinese.monthMarkers.map { $0.label } == ["1月", "2月", "3月"])
    }

    private static func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func daily(
        tokens: [Int64],
        start: Date,
        calendar: Calendar
    ) -> [DailyPoint] {
        tokens.enumerated().map { offset, tokens in
            DailyPoint(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                valueUSD: 0,
                tokens: tokens)
        }
    }

    private static func points(in model: HeatmapModel) -> [DailyPoint] {
        model.weeks.flatMap { $0 }.compactMap(\.point)
    }

    private static func levels(in model: HeatmapModel) -> [Int] {
        model.weeks.flatMap { $0 }.compactMap { cell in
            cell.point == nil ? nil : cell.level
        }
    }
}

@MainActor
@Suite("Activity heatmap observation boundary")
struct ActivityHeatmapObservationBoundaryTests {
    @Test("hover changes do not rebuild the parent-derived model")
    func hoverChangesDoNotRebuildModel() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        let start = try #require(calendar.date(
            from: DateComponents(year: 2025, month: 8, day: 10)))
        let daily = (0..<365).map { offset in
            DailyPoint(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                valueUSD: 0,
                tokens: Int64(offset + 1))
        }
        let model = HeatmapModel(
            daily: daily,
            calendar: calendar,
            language: .english)
        let firstCell = try #require(model.weeks.first?.first { $0.point != nil })
        let hoverState = HeatmapHoverState()
        let buildCount = LockedCounter()
        let view = ActivityHeatmap(
            daily: daily,
            tokenLocale: Locale(identifier: "en_US"),
            calendar: calendar,
            language: .english,
            hoverState: hoverState,
            onModelBuild: { buildCount.increment() })
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 220)

        await Self.settle(hostingView)
        let buildsBeforeHover = buildCount.value
        #expect(buildsBeforeHover == 1)

        for _ in 0..<100 {
            hoverState.update(hovering: true, cell: firstCell, col: 0, row: 0)
            hoverState.update(hovering: false, cell: firstCell, col: 0, row: 0)
        }
        #expect(hoverState.hoveredCell == nil)

        await Self.settle(hostingView)
        #expect(buildCount.value == 1)
    }

    @Test("hover selection preserves tooltip enter and leave behavior")
    func hoverSelectionBehavior() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1)))
        let point = DailyPoint(date: date, valueUSD: 0, tokens: 42)
        let activeCell = HeatmapModel.Cell(point: point, level: 1)
        let paddingCell = HeatmapModel.Cell(point: nil, level: 0)
        let state = HeatmapHoverState()

        state.update(hovering: true, cell: paddingCell, col: 0, row: 0)
        #expect(state.hoveredCell == nil)

        state.update(hovering: true, cell: activeCell, col: 1, row: 2)
        #expect(state.hoveredCell?.col == 1)
        #expect(state.hoveredCell?.row == 2)
        #expect(state.hoveredCell?.cell.point == point)

        state.update(hovering: false, cell: activeCell, col: 2, row: 2)
        #expect(state.hoveredCell?.col == 1)
        state.update(hovering: false, cell: activeCell, col: 1, row: 2)
        #expect(state.hoveredCell == nil)
    }

    private static func settle<Content: View>(_ hostingView: NSHostingView<Content>) async {
        hostingView.layoutSubtreeIfNeeded()
        _ = hostingView.fittingSize
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        hostingView.layoutSubtreeIfNeeded()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
