import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Main window layout", .serialized)
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

    @Test("Native status item observes update version and localization redraws")
    func nativeStatusItemObservesUpdateAndLocalization() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        let renderLabel = try Self.sourceSlice(
            source,
            from: "private func renderLabel()",
            to: "private static let gaugeImage")

        #expect(source.contains("private let localization: LocalizationStore"))
        #expect(source.contains("self.localization = localization"))
        #expect(renderLabel.contains("updater.updateAvailability.version"))
        #expect(renderLabel.contains("localization.tickForceRedraw"))
        #expect(renderLabel.contains("button.toolTip = nil"))
        #expect(!renderLabel.contains("button.setAccessibilityLabel(nil)"))
        #expect(renderLabel.contains("StatusItemUpdateMarker.accessibilityLabel("))
        #expect(renderLabel.contains("button.setAccessibilityLabel(accessibilityLabel)"))
        #expect(renderLabel.contains("L10n.statusItemUpdateTooltip(updateVersion)"))
    }

    @Test("Gauge fallback remains visible beside an available update marker")
    func gaugeFallbackPreservesImageAndMarker() throws {
        let source = try Self.source(named: "QuotaMonitor/App/StatusItemController.swift")
        let renderLabel = try Self.sourceSlice(
            source,
            from: "private func renderLabel()",
            to: "private static let gaugeImage")
        let fallback = try Self.sourceSlice(
            renderLabel,
            from: "if rows.isEmpty",
            to: "} else {")

        #expect(fallback.contains("button.image = Self.gaugeImage"))
        #expect(fallback.contains("button.imagePosition = updateVersion == nil ? .imageOnly : .imageLeading"))
        #expect(fallback.contains("NSAttributedString(string: \"\")"))
        #expect(renderLabel.contains("StatusItemUpdateMarker.title("))
    }

    @Test("English and Chinese status-item update copy includes the version")
    func localizedStatusItemUpdateCopyIncludesVersion() {
        let version = "0.2.41"
        let english = LocalizationTestSupport.withLanguage(.english) {
            (
                L10n.statusItemUpdateTooltip(version),
                L10n.statusItemUpdateAccessibilityLabel(version)
            )
        }
        let chinese = LocalizationTestSupport.withLanguage(.simplifiedChinese) {
            (
                L10n.statusItemUpdateTooltip(version),
                L10n.statusItemUpdateAccessibilityLabel(version)
            )
        }

        #expect(english.0.contains(version))
        #expect(english.1.contains(version))
        #expect(english.0.localizedCaseInsensitiveContains("update"))
        #expect(english.1.localizedCaseInsensitiveContains("update"))
        #expect(chinese.0.contains(version))
        #expect(chinese.1.contains(version))
        #expect(chinese.0.contains("更新"))
        #expect(chinese.1.contains("更新"))
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

    @Test("Dashboard trend domain includes the complete final day")
    func dashboardTrendDomainIncludesCompleteFinalDay() throws {
        let source = try Self.source(named: "QuotaMonitor/Features/Dashboard/Sections/TrendsSection.swift")
        let domain = try Self.sourceSlice(
            source,
            from: "private var xDomain",
            to: "private var selectedTrendSelection")

        #expect(domain.contains("TrendChartDomain.domain"))
        #expect(domain.contains("for: windowedDaily.map(\\.date)"))
        #expect(!domain.contains("return first...last"))
    }

    @Test("Codex pace uses only visible quota windows")
    func codexPaceUsesOnlyVisibleQuotaWindows() throws {
        let source = try Self.source(
            named: "QuotaMonitor/Features/Dashboard/Sections/ForecastSection.swift")
        let card = try Self.sourceSlice(
            source,
            from: "private var codexCard",
            to: "private var claudeCard")

        #expect(card.contains("quota.primary.flatMap"))
        #expect(card.contains("dbQuota?.burn[\"primary\"]"))
        #expect(card.contains("quota.secondary.flatMap"))
        #expect(card.contains("dbQuota?.burn[\"secondary\"]"))
        #expect(card.contains("if let burn = paceBurn"))
        #expect(!card.contains(
            "dbQuota?.burn[\"primary\"] ?? dbQuota?.burn[\"secondary\"]"))
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
