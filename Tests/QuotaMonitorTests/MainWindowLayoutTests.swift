import Foundation
import Testing

@Suite("Main window layout")
struct MainWindowLayoutTests {

    @Test("Provider filter stays in the titlebar with a stable explicit label")
    func providerFilterKeepsStableTitlebarPlacement() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/MainWindow/MainWindowView.swift")

        #expect(source.contains("ToolbarItem(placement: .navigation)"))
        #expect(source.contains("providerToolbarFilter(selection: $env.providerFilter)"))
        #expect(!source.contains("Picker(\"\", selection: $env.providerFilter)"))
        #expect(!source.contains("line.3.horizontal.decrease.circle"))
    }

    @Test("Available updates stay visible from main and menu surfaces via the shared badge")
    func persistentUpdateBadgeIsExposedOnPrimarySurfaces() throws {
        let mainWindow = try Self.source(named: "QuotaMonitor/Features/MainWindow/MainWindowView.swift")
        let menuBar = try Self.source(named: "QuotaMonitor/Features/MenuBar/MenuBarContentView.swift")
        let badge = try Self.source(named: "QuotaMonitor/Features/Shared/PersistentUpdateBadge.swift")
        let windowManager = try Self.source(named: "QuotaMonitor/App/WindowManager.swift")
        let statusItemController = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")

        // Both primary surfaces render the one shared component…
        #expect(mainWindow.contains("PersistentUpdateBadge("))
        #expect(menuBar.contains("PersistentUpdateBadge("))
        // …and the install action lives in that single shared place.
        #expect(badge.contains("updater.installAvailableUpdate()"))
        #expect(windowManager.contains(".environment(updater)"))
        #expect(statusItemController.contains(".environment(updater)"))
    }

    @Test("Dashboard overview keeps the original single-stack section order")
    func dashboardOverviewKeepsOriginalSingleStackSectionOrder() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/Dashboard/DashboardView.swift")
        let overview = try Self.sourceSlice(
            source,
            from: "private func overview",
            to: "private var visibleProviderCount")

        let statline = try Self.offset(of: "statline", in: overview)
        let forecast = try Self.offset(of: "ForecastSection(", in: overview)
        let trends = try Self.offset(of: "TrendsSection(", in: overview)
        let activity = try Self.offset(of: "ActivitySection(", in: overview)
        let composition = try Self.offset(of: "CompositionSection(", in: overview)

        #expect(!source.contains("@State private var page"))
        #expect(!source.contains("private var pageTabs"))
        #expect(!source.contains("private enum DashboardPage"))
        #expect(!overview.contains("private func trends"))
        #expect(!overview.contains("DashboardMetricStrip("))
        #expect(!overview.contains("showsStatStrip: false"))
        #expect(overview.contains("metrics: activityMetrics(for: snapshot)"))
        #expect(statline < forecast)
        #expect(forecast < trends)
        #expect(trends < activity)
        #expect(activity < composition)
    }

    @Test("Dashboard trends only exposes stacked bar mode")
    func dashboardTrendsOnlyExposesStackedBarMode() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/Dashboard/Sections/TrendsSection.swift")

        #expect(source.contains("private var stackedBars: some View"))
        #expect(!source.contains("K-line"))
        #expect(!source.contains("kline"))
        #expect(!source.contains("TrendMode"))
        #expect(!source.contains("UsageCandle"))
        #expect(!source.contains("candleTooltip"))
    }

    @Test("Dashboard trends preserve selected range and token totals")
    func dashboardTrendsPreserveRangeAndTotals() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/Dashboard/Sections/TrendsSection.swift")

        #expect(source.contains(".chartXScale(domain: xDomain)"))
        #expect(source.contains("TrendSeriesBuilder.collapsedModelSeries(raw)"))
        #expect(source.contains("static let otherKey = \"__other__\""))
    }

    @Test("Dashboard composition selects model rows by tokens")
    func dashboardCompositionSelectsModelRowsByTokens() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/Dashboard/Sections/CompositionSection.swift")
        let modelRows = try Self.sourceSlice(
            source,
            from: "private var modelRows",
            to: "private var providerRows")

        #expect(modelRows.contains(".sorted { $0.tokens > $1.tokens }"))
        #expect(modelRows.contains(".prefix(5)"))
    }

    @Test("Dashboard model colors are model-specific")
    func dashboardModelColorsAreModelSpecific() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/Dashboard/DashboardTheme.swift")
        let modelColor = try Self.sourceSlice(
            source,
            from: "static func modelColor",
            to: "struct DashboardPanelModifier")

        #expect(modelColor.contains("Color(hue: hue"))
        #expect(!modelColor.contains("return claude"))
        #expect(!modelColor.contains("return codex"))
    }

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func sourceSlice(
        _ source: String,
        from startSignature: String,
        to endSignature: String
    ) throws -> String {
        let start = try #require(source.range(of: startSignature)?.lowerBound)
        let rest = source[start...]
        let end = try #require(rest.range(of: endSignature)?.lowerBound)
        return String(rest[..<end])
    }

    private static func offset(of needle: String, in source: String) throws -> String.Index {
        try #require(source.range(of: needle)?.lowerBound)
    }
}
