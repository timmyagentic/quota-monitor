# Floating Quota Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional floating quota widget for QuotaMonitor that shows the same 5h and 7d quota state as the menu bar in a small AppKit-owned desktop HUD.

**Architecture:** `WindowManager` owns a new `FloatingQuotaWidgetController` that hosts `FloatingQuotaWidgetView` in an `NSPanel`. A pure `FloatingQuotaWidgetModel` converts the same `AppEnvironment` and `SettingsStore` inputs used by the menu-bar label into rows, headline text, and status. Settings add persistent show/pin/edge-auto-hide toggles; the controller owns free dragging, edge collapse, tab expansion, and explicit close semantics. LocalQA gains a widget step and artifact fields so GUI validation can prove the widget belongs to the QA build.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPanel`, Swift Testing, SwiftPM, QuotaMonitor LocalQA.

**Spec:** `docs/superpowers/specs/2026-06-08-floating-quota-widget-design.md`

---

## File Map

- Create: `QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetModel.swift`
  - Pure row/headline/status builder.
- Create: `QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetView.swift`
  - SwiftUI HUD content and controls.
- Create: `QuotaMonitor/App/FloatingQuotaWidgetController.swift`
  - AppKit `NSPanel` lifecycle and placement.
- Modify: `QuotaMonitor/App/WindowManager.swift`
  - Own one floating widget controller and expose show/hide/toggle/restore.
- Modify: `QuotaMonitor/App/AppDelegate.swift`
  - Restore the widget after launch when onboarding is complete.
- Modify: `QuotaMonitor/App/AppEnvironment.swift`
  - Use existing refresh APIs from widget actions; no new data source.
- Modify: `QuotaMonitor/App/LocalQAController.swift`
  - Add the `show-floating-widget` step and include widget snapshot data.
- Modify: `QuotaMonitor/App/LocalQAReport.swift`
  - Add a `floatingWidget` object.
- Modify: `QuotaMonitor/Core/Settings/SettingsStore.swift`
  - Add `floatingQuotaWidgetEnabled`, `floatingQuotaWidgetPinned`, and
    `floatingQuotaWidgetEdgeAutoHideEnabled`.
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
  - Add English and Simplified Chinese strings.
- Modify: `QuotaMonitor/Features/MenuBar/MenuBarContentView.swift`
  - Add popover entry point.
- Modify: `QuotaMonitor/Features/MenuBar/MenuBarWindowActions.swift`
  - Add widget actions for testable button behavior.
- Modify: `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`
  - Add Settings -> General -> Menu bar controls.
- Modify: `docs/local-qa.md` and `docs/computer-qa.md`
  - Document widget QA.
- Modify: `qa/lib/common.sh`, `qa/prepare-computer-use-fixture.sh`,
  `qa/prepare-computer-use-real-data.sh`, `qa/tests/common_tests.sh`
  - Add artifact checks.
- Test: `Tests/QuotaMonitorTests/FloatingQuotaWidgetModelTests.swift`
- Test: `Tests/QuotaMonitorTests/FloatingQuotaWidgetSettingTests.swift`
- Test: `Tests/QuotaMonitorTests/FloatingQuotaWidgetControllerTests.swift`
- Test: `Tests/QuotaMonitorTests/MenuBarWindowActionsTests.swift`
- Test: `Tests/QuotaMonitorTests/LocalQAReportTests.swift`

---

### Task 1: Add Widget Settings And Localization

**Files:**
- Modify: `QuotaMonitor/Core/Settings/SettingsStore.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
- Create: `Tests/QuotaMonitorTests/FloatingQuotaWidgetSettingTests.swift`

- [ ] **Step 1: Write the failing settings tests**

Create `Tests/QuotaMonitorTests/FloatingQuotaWidgetSettingTests.swift`:

```swift
import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Floating quota widget settings")
struct FloatingQuotaWidgetSettingTests {

    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.floating-widget.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test
    func widgetDefaultsToHiddenAndPinned() {
        let store = SettingsStore(defaults: Self.freshDefaults())
        #expect(store.floatingQuotaWidgetEnabled == false)
        #expect(store.floatingQuotaWidgetPinned == true)
        #expect(store.floatingQuotaWidgetEdgeAutoHideEnabled == true)
    }

    @Test
    func enabledPersistsToUserDefaults() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.floatingQuotaWidgetEnabled = true
        #expect(d.bool(forKey: "settings.floatingQuotaWidgetEnabled") == true)
        #expect(SettingsStore(defaults: d).floatingQuotaWidgetEnabled == true)
    }

    @Test
    func pinnedPersistsToUserDefaults() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.floatingQuotaWidgetPinned = false
        #expect(d.bool(forKey: "settings.floatingQuotaWidgetPinned") == false)
        #expect(SettingsStore(defaults: d).floatingQuotaWidgetPinned == false)
    }

    @Test
    func edgeAutoHidePersistsToUserDefaults() {
        let d = Self.freshDefaults()
        let store = SettingsStore(defaults: d)
        store.floatingQuotaWidgetEdgeAutoHideEnabled = false
        #expect(d.bool(forKey: "settings.floatingQuotaWidgetEdgeAutoHideEnabled") == false)
        #expect(SettingsStore(defaults: d).floatingQuotaWidgetEdgeAutoHideEnabled == false)
    }
}
```

- [ ] **Step 2: Run the settings tests and confirm the expected failure**

Run:

```bash
swift test --filter FloatingQuotaWidgetSettingTests
```

Expected: compile failure because `SettingsStore` does not yet expose
`floatingQuotaWidgetEnabled`, `floatingQuotaWidgetPinned`, and
`floatingQuotaWidgetEdgeAutoHideEnabled`.

- [ ] **Step 3: Add the persisted settings**

In `QuotaMonitor/Core/Settings/SettingsStore.swift`, add the two properties near
the existing menu-bar display settings:

```swift
var floatingQuotaWidgetEnabled: Bool {
    didSet { defaults.set(floatingQuotaWidgetEnabled,
                          forKey: Keys.floatingQuotaWidgetEnabled) }
}

var floatingQuotaWidgetPinned: Bool {
    didSet { defaults.set(floatingQuotaWidgetPinned,
                          forKey: Keys.floatingQuotaWidgetPinned) }
}

var floatingQuotaWidgetEdgeAutoHideEnabled: Bool {
    didSet { defaults.set(floatingQuotaWidgetEdgeAutoHideEnabled,
                          forKey: Keys.floatingQuotaWidgetEdgeAutoHideEnabled) }
}
```

Add keys inside `SettingsStore.Keys`:

```swift
static let floatingQuotaWidgetEnabled = "settings.floatingQuotaWidgetEnabled"
static let floatingQuotaWidgetPinned = "settings.floatingQuotaWidgetPinned"
static let floatingQuotaWidgetEdgeAutoHideEnabled = "settings.floatingQuotaWidgetEdgeAutoHideEnabled"
```

Initialize them in `init(defaults:)`:

```swift
self.floatingQuotaWidgetEnabled =
    defaults.bool(forKey: Keys.floatingQuotaWidgetEnabled)
if defaults.object(forKey: Keys.floatingQuotaWidgetPinned) == nil {
    self.floatingQuotaWidgetPinned = true
} else {
    self.floatingQuotaWidgetPinned =
        defaults.bool(forKey: Keys.floatingQuotaWidgetPinned)
}
if defaults.object(forKey: Keys.floatingQuotaWidgetEdgeAutoHideEnabled) == nil {
    self.floatingQuotaWidgetEdgeAutoHideEnabled = true
} else {
    self.floatingQuotaWidgetEdgeAutoHideEnabled =
        defaults.bool(forKey: Keys.floatingQuotaWidgetEdgeAutoHideEnabled)
}
```

- [ ] **Step 4: Add localization keys**

In `QuotaMonitor/Core/Localization/L10n.swift`, add:

```swift
static var floatingWidgetLabel: String {
    t(en: "Floating quota widget", zh: "悬浮配额组件")
}
static var floatingWidgetShow: String {
    t(en: "Show Widget", zh: "显示组件")
}
static var floatingWidgetHide: String {
    t(en: "Hide Widget", zh: "隐藏组件")
}
static var floatingWidgetHelp: String {
    t(en: "Keep a small quota HUD on the desktop using the same providers and percentage mode as the menu bar.",
      zh: "在桌面保留一个小型配额浮窗，使用与菜单栏相同的 Provider 与百分比显示方式。")
}
static var floatingWidgetPinnedLabel: String {
    t(en: "Keep above windows", zh: "保持在窗口上方")
}
static var floatingWidgetPinnedHelp: String {
    t(en: "Pinned widgets float above normal windows and can appear in full-screen Spaces.",
      zh: "固定后组件会浮在普通窗口上方，并可显示在全屏 Space 中。")
}
static var floatingWidgetEdgeAutoHideLabel: String {
    t(en: "Hide at screen edge", zh: "拖到屏幕边缘时隐藏")
}
static var floatingWidgetEdgeAutoHideHelp: String {
    t(en: "When you drag the widget to a screen edge, it collapses into a thin tab. Click the tab to expand it.",
      zh: "把组件拖到屏幕边缘后会收成一个窄边；点击窄边即可展开。")
}
static var floatingWidgetRefreshTooltip: String {
    t(en: "Refresh quota", zh: "刷新配额")
}
static var floatingWidgetPinTooltip: String {
    t(en: "Pin widget", zh: "固定组件")
}
static var floatingWidgetCloseTooltip: String {
    t(en: "Close widget", zh: "关闭组件")
}
static var floatingWidgetExpandTooltip: String {
    t(en: "Expand widget", zh: "展开组件")
}
static var floatingWidgetContextHide: String {
    t(en: "Hide Widget", zh: "隐藏组件")
}
static var quotaStatusOK: String {
    t(en: "OK", zh: "正常")
}
static var quotaStatusWarning: String {
    t(en: "Watch", zh: "注意")
}
static var quotaStatusDanger: String {
    t(en: "Low", zh: "紧张")
}
static var quotaStatusUnknown: String {
    t(en: "No quota data", zh: "暂无配额数据")
}
```

- [ ] **Step 5: Verify and commit**

Run:

```bash
swift test --filter FloatingQuotaWidgetSettingTests
git diff --check
```

Expected: settings tests pass and `git diff --check` prints no output.

Commit:

```bash
git add QuotaMonitor/Core/Settings/SettingsStore.swift \
        QuotaMonitor/Core/Localization/L10n.swift \
        Tests/QuotaMonitorTests/FloatingQuotaWidgetSettingTests.swift
git commit -m "feat: add floating quota widget settings"
```

---

### Task 2: Add The Pure Widget Model

**Files:**
- Create: `QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetModel.swift`
- Create: `Tests/QuotaMonitorTests/FloatingQuotaWidgetModelTests.swift`

- [ ] **Step 1: Write the model tests**

Create `Tests/QuotaMonitorTests/FloatingQuotaWidgetModelTests.swift`:

```swift
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("Floating quota widget model")
struct FloatingQuotaWidgetModelTests {

    private func codexRateLimits(five: Double?, seven: Double?) -> RateLimitSnapshot {
        func win(_ p: Double?) -> RateLimitSnapshot.Window? {
            p.map { RateLimitSnapshot.Window(usedPercent: $0, windowDuration: 18_000, resetAt: Date()) }
        }
        return RateLimitSnapshot(capturedAt: Date(), planType: "plus",
                                 primary: win(five), secondary: win(seven), additional: [])
    }

    private func claudeUsage(five: Double?, seven: Double?) -> ClaudeUsageSnapshot {
        func win(_ p: Double?) -> ClaudeUsageSnapshot.Window? {
            p.map { ClaudeUsageSnapshot.Window(usedPercent: $0, resetAt: Date(), windowDuration: 18_000) }
        }
        return ClaudeUsageSnapshot(capturedAt: Date(), tier: "pro",
                                   fiveHour: win(five), sevenDay: win(seven),
                                   sevenDayOpus: nil, sevenDaySonnet: nil)
    }

    @Test
    func buildsCodexRowsFromMenuBarProviderIntent() {
        let snapshot = FloatingQuotaWidgetModel.snapshot(
            iconProviders: ["codex"],
            enabledProviders: ["codex", "claude"],
            rateLimits: codexRateLimits(five: 73, seven: 80),
            claudeUsage: claudeUsage(five: 20, seven: 30),
            codexQuota: nil,
            displayMode: .used,
            isRefreshing: false)

        #expect(snapshot.rows.map(\.id) == ["codex"])
        #expect(snapshot.rows[0].fiveHour.displayText == "73%")
        #expect(snapshot.rows[0].sevenDay.displayText == "80%")
        #expect(snapshot.status == .warning)
        #expect(snapshot.headline?.displayText == "80%")
    }

    @Test
    func remainingModeInvertsTextAndProgress() {
        let snapshot = FloatingQuotaWidgetModel.snapshot(
            iconProviders: ["codex"],
            enabledProviders: ["codex"],
            rateLimits: codexRateLimits(five: 25, seven: 40),
            claudeUsage: nil,
            codexQuota: nil,
            displayMode: .remaining,
            isRefreshing: false)

        #expect(snapshot.rows[0].fiveHour.displayText == "75%")
        #expect(snapshot.rows[0].fiveHour.progressValue == 0.75)
        #expect(snapshot.rows[0].sevenDay.displayText == "60%")
        #expect(snapshot.rows[0].sevenDay.progressValue == 0.60)
    }

    @Test
    func dangerUsesUnderlyingUsedPercentEvenInRemainingMode() {
        let snapshot = FloatingQuotaWidgetModel.snapshot(
            iconProviders: ["codex"],
            enabledProviders: ["codex"],
            rateLimits: codexRateLimits(five: 95, seven: 10),
            claudeUsage: nil,
            codexQuota: nil,
            displayMode: .remaining,
            isRefreshing: false)

        #expect(snapshot.rows[0].fiveHour.displayText == "5%")
        #expect(snapshot.status == .danger)
    }

    @Test
    func unknownWhenSelectedProvidersHaveNoNumbers() {
        let snapshot = FloatingQuotaWidgetModel.snapshot(
            iconProviders: ["codex"],
            enabledProviders: ["codex"],
            rateLimits: codexRateLimits(five: nil, seven: nil),
            claudeUsage: nil,
            codexQuota: nil,
            displayMode: .used,
            isRefreshing: false)

        #expect(snapshot.rows[0].fiveHour.displayText == "--")
        #expect(snapshot.status == .unknown)
        #expect(snapshot.headline == nil)
    }
}
```

- [ ] **Step 2: Run the model tests and confirm the expected failure**

Run:

```bash
swift test --filter FloatingQuotaWidgetModelTests
```

Expected: compile failure because `FloatingQuotaWidgetModel` does not exist.

- [ ] **Step 3: Implement the model**

Create `QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetModel.swift`:

```swift
import Foundation

enum FloatingQuotaWidgetModel {
    struct Snapshot: Equatable {
        var rows: [ProviderRow]
        var headline: Headline?
        var status: Status
        var displayMode: SettingsStore.QuotaDisplayMode
        var isRefreshing: Bool
    }

    struct ProviderRow: Equatable {
        var id: String
        var label: String
        var fiveHour: WindowValue
        var sevenDay: WindowValue
        var plan: String?
    }

    struct WindowValue: Equatable {
        var usedPercent: Double?
        var displayText: String
        var progressValue: Double?
    }

    struct Headline: Equatable {
        var providerID: String
        var displayText: String
        var windowLabel: String
    }

    enum Status: String, Equatable {
        case ok
        case warning
        case danger
        case unknown
    }

    static func snapshot(iconProviders: Set<String>,
                         enabledProviders: Set<String>,
                         rateLimits: RateLimitSnapshot?,
                         claudeUsage: ClaudeUsageSnapshot?,
                         codexQuota: CodexQuotaSnapshot?,
                         displayMode: SettingsStore.QuotaDisplayMode,
                         isRefreshing: Bool) -> Snapshot {
        var rows: [ProviderRow] = []
        for id in ["codex", "claude"] {
            guard iconProviders.contains(id), enabledProviders.contains(id) else { continue }
            switch id {
            case "codex":
                let five = rateLimits?.primary?.usedPercent
                    ?? codexQuota?.primary?.usedPercent
                let seven = rateLimits?.secondary?.usedPercent
                    ?? codexQuota?.secondary?.usedPercent
                rows.append(ProviderRow(
                    id: "codex",
                    label: L10n.codex,
                    fiveHour: windowValue(five, displayMode: displayMode),
                    sevenDay: windowValue(seven, displayMode: displayMode),
                    plan: rateLimits?.planType ?? codexQuota?.primary?.planType))
            case "claude":
                rows.append(ProviderRow(
                    id: "claude",
                    label: L10n.claudeCode,
                    fiveHour: windowValue(claudeUsage?.fiveHour?.usedPercent,
                                          displayMode: displayMode),
                    sevenDay: windowValue(claudeUsage?.sevenDay?.usedPercent,
                                          displayMode: displayMode),
                    plan: claudeUsage?.tier))
            default:
                break
            }
        }
        return Snapshot(rows: rows,
                        headline: headline(rows: rows),
                        status: status(rows: rows),
                        displayMode: displayMode,
                        isRefreshing: isRefreshing)
    }

    private static func windowValue(_ usedPercent: Double?,
                                    displayMode: SettingsStore.QuotaDisplayMode) -> WindowValue {
        guard let usedPercent else {
            return WindowValue(usedPercent: nil,
                               displayText: "--",
                               progressValue: nil)
        }
        let display = displayMode.displayPercent(forUsedPercent: usedPercent)
        return WindowValue(usedPercent: usedPercent,
                           displayText: "\(Int(display.rounded()))%",
                           progressValue: display / 100)
    }

    private static func headline(rows: [ProviderRow]) -> Headline? {
        let candidates = rows.flatMap { row in
            [
                (row, "5h", row.fiveHour),
                (row, "7d", row.sevenDay)
            ]
        }
        let numbered = candidates.compactMap { candidate -> (ProviderRow, String, WindowValue)? in
            candidate.2.usedPercent == nil ? nil : candidate
        }
        return numbered
            .max { lhs, rhs in
                (lhs.2.usedPercent ?? -1) < (rhs.2.usedPercent ?? -1)
            }
            .map { row, label, value in
                Headline(providerID: row.id,
                         displayText: value.displayText,
                         windowLabel: label)
            }
    }

    private static func status(rows: [ProviderRow]) -> Status {
        let values = rows.flatMap { [$0.fiveHour.usedPercent, $0.sevenDay.usedPercent] }
            .compactMap { $0 }
        guard let worst = values.max() else { return .unknown }
        if worst >= 85 { return .danger }
        if worst >= 60 { return .warning }
        return .ok
    }
}
```

- [ ] **Step 4: Verify and commit**

Run:

```bash
swift test --filter FloatingQuotaWidgetModelTests
swift test --filter MenuBarLabelModelTests
git diff --check
```

Expected: both test suites pass and no whitespace errors are reported.

Commit:

```bash
git add QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetModel.swift \
        Tests/QuotaMonitorTests/FloatingQuotaWidgetModelTests.swift
git commit -m "feat: model floating quota widget state"
```

---

### Task 3: Build The SwiftUI Widget View

**Files:**
- Create: `QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetView.swift`
- Modify: `Package.swift` only if the target requires an explicit path update.

- [ ] **Step 1: Create the actions type and view**

Create `QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetView.swift`:

```swift
import SwiftUI

enum FloatingQuotaWidgetEdge: String, Codable, Equatable {
    case left
    case right
    case top
    case bottom
}

struct FloatingQuotaWidgetPresentationState: Equatable {
    var isCollapsed: Bool
    var edge: FloatingQuotaWidgetEdge?
    var lastExpandedFrame: CGRect?
}

struct FloatingQuotaWidgetActions {
    var refresh: @MainActor () -> Void
    var togglePinned: @MainActor () -> Void
    var expand: @MainActor () -> Void
    var close: @MainActor () -> Void
}

struct FloatingQuotaWidgetView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalizationStore.self) private var loc

    let actions: FloatingQuotaWidgetActions
    let presentation: FloatingQuotaWidgetPresentationState

    var body: some View {
        let snapshot = FloatingQuotaWidgetModel.snapshot(
            iconProviders: settings.menuBarIconProviders,
            enabledProviders: settings.enabledProviders,
            rateLimits: env.latestRateLimits,
            claudeUsage: env.latestClaudeUsage,
            codexQuota: env.dashboardSnapshot?.codexQuota,
            displayMode: settings.quotaDisplayMode,
            isRefreshing: env.isScanning || env.isRefreshingRateLimits)

        Group {
            if presentation.isCollapsed {
                collapsedTab(snapshot)
            } else {
                expandedContent(snapshot)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: presentation.isCollapsed ? 4 : 10,
                                    style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: presentation.isCollapsed ? 4 : 10,
                             style: .continuous)
                .strokeBorder(.separator.opacity(0.45))
        }
        .contextMenu {
            Button(L10n.floatingWidgetContextHide) {
                actions.close()
            }
        }
        .environment(\.locale, loc.locale)
        .id(loc.tickForceRedraw)
    }

    private func expandedContent(_ snapshot: FloatingQuotaWidgetModel.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(snapshot)
            content(snapshot)
        }
        .padding(14)
        .frame(width: 320, height: 184)
    }

    private func collapsedTab(_ snapshot: FloatingQuotaWidgetModel.Snapshot) -> some View {
        Button {
            actions.expand()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.regularMaterial)
                Capsule()
                    .fill(color(for: snapshot.status))
                    .frame(width: presentation.edge == .left || presentation.edge == .right ? 3 : 32,
                           height: presentation.edge == .left || presentation.edge == .right ? 32 : 3)
            }
            .frame(width: collapsedTabSize.width,
                   height: collapsedTabSize.height)
        }
        .buttonStyle(.plain)
        .help(L10n.floatingWidgetExpandTooltip)
    }

    private func header(_ snapshot: FloatingQuotaWidgetModel.Snapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: snapshot.status))
                .frame(width: 8, height: 8)
            Text("Quota Monitor")
                .font(.headline)
            Spacer()
            Button {
                actions.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.floatingWidgetRefreshTooltip)
            .buttonStyle(.borderless)
            Button {
                actions.togglePinned()
            } label: {
                Image(systemName: settings.floatingQuotaWidgetPinned ? "pin.fill" : "pin")
            }
            .help(L10n.floatingWidgetPinTooltip)
            .buttonStyle(.borderless)
            Button {
                actions.close()
            } label: {
                Image(systemName: "xmark")
            }
            .help(L10n.floatingWidgetCloseTooltip)
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: FloatingQuotaWidgetModel.Snapshot) -> some View {
        if let headline = snapshot.headline {
            HStack(alignment: .center, spacing: 14) {
                Gauge(value: headlineProgress(snapshot), in: 0...1) {
                    EmptyView()
                } currentValueLabel: {
                    Text(headline.displayText)
                        .font(.system(size: 32, weight: .semibold, design: .rounded)
                            .monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(color(for: snapshot.status))
                .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.rows, id: \.id) { row in
                        providerRow(row)
                    }
                }
            }
        } else {
            Text(L10n.quotaStatusUnknown)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func providerRow(_ row: FloatingQuotaWidgetModel.ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label).font(.caption.weight(.semibold))
            HStack {
                Text("5h \(row.fiveHour.displayText)")
                Text("7d \(row.sevenDay.displayText)")
            }
            .font(.callout.monospacedDigit())
        }
    }

    private func headlineProgress(_ snapshot: FloatingQuotaWidgetModel.Snapshot) -> Double {
        snapshot.rows
            .flatMap { [$0.fiveHour.progressValue, $0.sevenDay.progressValue] }
            .compactMap { $0 }
            .max() ?? 0
    }

    private func color(for status: FloatingQuotaWidgetModel.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .danger: return .red
        case .unknown: return .secondary
        }
    }

    private var collapsedTabSize: CGSize {
        switch presentation.edge {
        case .left, .right: return CGSize(width: 12, height: 72)
        case .top, .bottom: return CGSize(width: 72, height: 12)
        case nil: return CGSize(width: 12, height: 72)
        }
    }
}
```

- [ ] **Step 2: Build the target**

Run:

```bash
swift test --filter FloatingQuotaWidgetModelTests
```

Expected: build succeeds and the model tests still pass. The view has no direct
snapshot test yet; visual behavior is covered by the AppKit and QA tasks.

- [ ] **Step 3: Commit**

```bash
git add QuotaMonitor/Features/FloatingWidget/FloatingQuotaWidgetView.swift
git commit -m "feat: add floating quota widget view"
```

---

### Task 4: Add The AppKit Panel Controller

**Files:**
- Create: `QuotaMonitor/App/FloatingQuotaWidgetController.swift`
- Modify: `QuotaMonitor/App/WindowManager.swift`
- Create: `Tests/QuotaMonitorTests/FloatingQuotaWidgetControllerTests.swift`

- [ ] **Step 1: Add pure placement and policy tests**

Create `Tests/QuotaMonitorTests/FloatingQuotaWidgetControllerTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Floating quota widget controller")
struct FloatingQuotaWidgetControllerTests {

    @Test
    func initialPlacementUsesTopRightVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 320, height: 184)
        let origin = FloatingQuotaWidgetController.initialOrigin(
            widgetSize: size,
            visibleFrame: visible,
            padding: 18)

        #expect(origin.x == 1102)
        #expect(origin.y == 698)
    }

    @Test
    func pinnedPolicyFloatsAcrossSpaces() {
        let policy = FloatingQuotaWidgetController.windowPolicy(pinned: true)
        #expect(policy.level == .floating)
        #expect(policy.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(policy.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test
    func unpinnedPolicyUsesNormalLevel() {
        let policy = FloatingQuotaWidgetController.windowPolicy(pinned: false)
        #expect(policy.level == .normal)
        #expect(policy.collectionBehavior.contains(.canJoinAllSpaces) == false)
    }

    @Test
    func detectsNearestScreenEdgeAtDragEnd() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 5, y: 300, width: 320, height: 184)

        #expect(FloatingQuotaWidgetController.edgeAttachment(
            for: frame,
            visibleFrame: visible) == .left)
    }

    @Test
    func doesNotAttachWhenOutsideThreshold() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 40, y: 300, width: 320, height: 184)

        #expect(FloatingQuotaWidgetController.edgeAttachment(
            for: frame,
            visibleFrame: visible) == nil)
    }

    @Test
    func collapsedLeftFrameLeavesThinVisibleTab() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let expanded = NSRect(x: 0, y: 300, width: 320, height: 184)
        let collapsed = FloatingQuotaWidgetController.collapsedFrame(
            edge: .left,
            expandedFrame: expanded,
            visibleFrame: visible)

        #expect(collapsed.minX == 0)
        #expect(collapsed.width == 12)
        #expect(collapsed.height == 72)
    }

    @Test
    func clampedExpandedFrameKeepsRecoveryAreaVisible() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offscreen = NSRect(x: -500, y: 120, width: 320, height: 184)
        let clamped = FloatingQuotaWidgetController.clampedExpandedFrame(
            offscreen,
            visibleFrame: visible)

        #expect(clamped.minX == -296)
    }
}
```

- [ ] **Step 2: Run the controller tests and confirm expected failure**

Run:

```bash
swift test --filter FloatingQuotaWidgetControllerTests
```

Expected: compile failure because `FloatingQuotaWidgetController` does not yet
exist.

- [ ] **Step 3: Implement `FloatingQuotaWidgetController`**

Create `QuotaMonitor/App/FloatingQuotaWidgetController.swift`:

```swift
import AppKit
import SwiftUI

private final class FloatingQuotaWidgetPanel: NSPanel {
    var onMouseUp: ((NSEvent) -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?(event)
    }
}

@MainActor
final class FloatingQuotaWidgetController: NSObject, NSWindowDelegate {
    struct WindowPolicy: Equatable {
        var level: NSWindow.Level
        var collectionBehavior: NSWindow.CollectionBehavior
    }

    private var panel: NSPanel?
    private var presentation = FloatingQuotaWidgetPresentationState(
        isCollapsed: false,
        edge: nil,
        lastExpandedFrame: nil)
    private let env: AppEnvironment
    private let localization: LocalizationStore
    private let settings: SettingsStore

    init(env: AppEnvironment,
         localization: LocalizationStore,
         settings: SettingsStore) {
        self.env = env
        self.localization = localization
        self.settings = settings
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var presentationState: FloatingQuotaWidgetPresentationState {
        presentation
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        applyPinnedPolicy()
        if panel.frame.origin == .zero {
            placeInitially(panel)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func expandFromEdge() {
        guard let panel else { return }
        presentation.isCollapsed = false
        presentation.edge = nil
        let target = Self.expandedFrame(
            lastExpandedFrame: presentation.lastExpandedFrame,
            fallbackSize: Self.expandedSize,
            visibleFrame: Self.visibleFrame(containing: panel.frame))
        panel.setFrame(target, display: true)
        refreshHostedView()
    }

    func setPinned(_ pinned: Bool) {
        settings.floatingQuotaWidgetPinned = pinned
        applyPinnedPolicy()
    }

    func windowWillClose(_ notification: Notification) {
        settings.floatingQuotaWidgetEnabled = false
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, !presentation.isCollapsed else { return }
        presentation.lastExpandedFrame = panel.frame
    }

    func handleDragEnded() {
        guard let panel else { return }
        let visible = Self.visibleFrame(containing: panel.frame)
        let clamped = Self.clampedExpandedFrame(panel.frame,
                                               visibleFrame: visible)
        panel.setFrame(clamped, display: true)
        presentation.lastExpandedFrame = clamped
        guard settings.floatingQuotaWidgetEdgeAutoHideEnabled,
              let edge = Self.edgeAttachment(for: clamped,
                                             visibleFrame: visible) else {
            return
        }
        collapse(to: edge, visibleFrame: visible)
    }

    static func initialOrigin(widgetSize: NSSize,
                              visibleFrame: NSRect,
                              padding: CGFloat = 18) -> NSPoint {
        NSPoint(x: visibleFrame.maxX - widgetSize.width - padding,
                y: visibleFrame.maxY - widgetSize.height - padding)
    }

    static let expandedSize = NSSize(width: 320, height: 184)
    static let visibleTabThickness: CGFloat = 12
    static let edgeSnapThreshold: CGFloat = 16

    static func windowPolicy(pinned: Bool) -> WindowPolicy {
        if pinned {
            return WindowPolicy(
                level: .floating,
                collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        return WindowPolicy(level: .normal, collectionBehavior: [])
    }

    static func edgeAttachment(for frame: NSRect,
                               visibleFrame: NSRect,
                               threshold: CGFloat = edgeSnapThreshold) -> FloatingQuotaWidgetEdge? {
        let distances: [(FloatingQuotaWidgetEdge, CGFloat)] = [
            (.left, abs(frame.minX - visibleFrame.minX)),
            (.right, abs(visibleFrame.maxX - frame.maxX)),
            (.top, abs(visibleFrame.maxY - frame.maxY)),
            (.bottom, abs(frame.minY - visibleFrame.minY))
        ]
        return distances
            .filter { $0.1 <= threshold }
            .min { $0.1 < $1.1 }?
            .0
    }

    static func collapsedFrame(edge: FloatingQuotaWidgetEdge,
                               expandedFrame: NSRect,
                               visibleFrame: NSRect,
                               thickness: CGFloat = visibleTabThickness) -> NSRect {
        switch edge {
        case .left:
            return NSRect(x: visibleFrame.minX,
                          y: clamp(expandedFrame.midY - 36,
                                   min: visibleFrame.minY,
                                   max: visibleFrame.maxY - 72),
                          width: thickness,
                          height: 72)
        case .right:
            return NSRect(x: visibleFrame.maxX - thickness,
                          y: clamp(expandedFrame.midY - 36,
                                   min: visibleFrame.minY,
                                   max: visibleFrame.maxY - 72),
                          width: thickness,
                          height: 72)
        case .top:
            return NSRect(x: clamp(expandedFrame.midX - 36,
                                   min: visibleFrame.minX,
                                   max: visibleFrame.maxX - 72),
                          y: visibleFrame.maxY - thickness,
                          width: 72,
                          height: thickness)
        case .bottom:
            return NSRect(x: clamp(expandedFrame.midX - 36,
                                   min: visibleFrame.minX,
                                   max: visibleFrame.maxX - 72),
                          y: visibleFrame.minY,
                          width: 72,
                          height: thickness)
        }
    }

    static func clampedExpandedFrame(_ frame: NSRect,
                                     visibleFrame: NSRect,
                                     minimumVisible: CGFloat = 24) -> NSRect {
        var out = frame
        out.origin.x = clamp(out.origin.x,
                             min: visibleFrame.minX - out.width + minimumVisible,
                             max: visibleFrame.maxX - minimumVisible)
        out.origin.y = clamp(out.origin.y,
                             min: visibleFrame.minY - out.height + minimumVisible,
                             max: visibleFrame.maxY - minimumVisible)
        return out
    }

    static func expandedFrame(lastExpandedFrame: NSRect?,
                              fallbackSize: NSSize,
                              visibleFrame: NSRect) -> NSRect {
        let candidate = lastExpandedFrame
            ?? NSRect(origin: initialOrigin(widgetSize: fallbackSize,
                                           visibleFrame: visibleFrame),
                      size: fallbackSize)
        return clampedExpandedFrame(candidate, visibleFrame: visibleFrame)
    }

    static func visibleFrame(containing frame: NSRect) -> NSRect {
        let midpoint = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midpoint) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func clamp(_ value: CGFloat,
                              min minValue: CGFloat,
                              max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), Swift.max(minValue, maxValue))
    }

    private func collapse(to edge: FloatingQuotaWidgetEdge,
                          visibleFrame: NSRect) {
        guard let panel else { return }
        presentation.isCollapsed = true
        presentation.edge = edge
        let collapsed = Self.collapsedFrame(edge: edge,
                                            expandedFrame: panel.frame,
                                            visibleFrame: visibleFrame)
        panel.setFrame(collapsed, display: true)
        refreshHostedView()
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: makeRootView())
        let panel = FloatingQuotaWidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 184),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.contentViewController = hosting
        panel.identifier = NSUserInterfaceItemIdentifier("floating-quota-widget")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onMouseUp = { [weak self] _ in
            guard let self else { return }
            if self.presentation.isCollapsed {
                self.expandFromEdge()
            } else {
                self.handleDragEnded()
            }
        }
        panel.setFrameAutosaveName("floating-quota-widget")
        return panel
    }

    private func placeInitially(_ panel: NSPanel) {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(Self.initialOrigin(widgetSize: panel.frame.size,
                                                visibleFrame: visible))
    }

    private func applyPinnedPolicy() {
        guard let panel else { return }
        let policy = Self.windowPolicy(pinned: settings.floatingQuotaWidgetPinned)
        panel.level = policy.level
        panel.collectionBehavior = policy.collectionBehavior
    }

    private func refreshHostedView() {
        guard let hosting = panel?.contentViewController as? NSHostingController<AnyView> else {
            return
        }
        hosting.rootView = makeRootView()
    }

    private func makeRootView() -> AnyView {
        AnyView(
            FloatingQuotaWidgetView(actions: makeActions(),
                                    presentation: presentation)
                .environment(env)
                .environment(localization)
                .environment(settings)
                .environment(\.locale, localization.locale)
        )
    }

    private func makeActions() -> FloatingQuotaWidgetActions {
        FloatingQuotaWidgetActions(
            refresh: { [env] in env.refreshAll(throttle: false, trigger: "floating-widget") },
            togglePinned: { [weak self] in
                guard let self else { return }
                self.setPinned(!self.settings.floatingQuotaWidgetPinned)
            },
            expand: { [weak self] in
                self?.expandFromEdge()
            },
            close: { [weak self] in
                self?.settings.floatingQuotaWidgetEnabled = false
                self?.hide()
            })
    }
}
```

- [ ] **Step 4: Wire it through `WindowManager`**

In `QuotaMonitor/App/WindowManager.swift`, add:

```swift
private lazy var floatingWidget = FloatingQuotaWidgetController(
    env: AppEnvironment.shared,
    localization: LocalizationStore.shared,
    settings: SettingsStore.shared)
```

Add methods:

```swift
func showFloatingQuotaWidget() {
    SettingsStore.shared.floatingQuotaWidgetEnabled = true
    floatingWidget.show()
}

func hideFloatingQuotaWidget() {
    SettingsStore.shared.floatingQuotaWidgetEnabled = false
    floatingWidget.hide()
}

func toggleFloatingQuotaWidget() {
    if floatingWidget.isVisible {
        hideFloatingQuotaWidget()
    } else {
        showFloatingQuotaWidget()
    }
}

func restoreFloatingQuotaWidgetIfNeeded() {
    guard SettingsStore.shared.floatingQuotaWidgetEnabled,
          !LocalizationStore.shared.needsOnboarding,
          !SettingsStore.shared.needsProviderOnboarding else { return }
    floatingWidget.show()
}

var floatingQuotaWidgetPresentation: FloatingQuotaWidgetPresentationState {
    floatingWidget.presentationState
}
```

Do not include the floating widget in `controllers` and do not change
`hasVisibleWindow(excluding:)`.

- [ ] **Step 5: Verify and commit**

Run:

```bash
swift test --filter FloatingQuotaWidgetControllerTests
swift test --filter WindowOnboardingGateTests
git diff --check
```

Expected: controller tests and existing window lifecycle tests pass.

Commit:

```bash
git add QuotaMonitor/App/FloatingQuotaWidgetController.swift \
        QuotaMonitor/App/WindowManager.swift \
        Tests/QuotaMonitorTests/FloatingQuotaWidgetControllerTests.swift
git commit -m "feat: own floating quota widget in AppKit"
```

---

### Task 5: Add Popover, Settings, And Launch Entry Points

**Files:**
- Modify: `QuotaMonitor/App/AppDelegate.swift`
- Modify: `QuotaMonitor/Features/MenuBar/MenuBarContentView.swift`
- Modify: `QuotaMonitor/Features/MenuBar/MenuBarWindowActions.swift`
- Modify: `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`
- Modify: `Tests/QuotaMonitorTests/MenuBarWindowActionsTests.swift`

- [ ] **Step 1: Extend menu-bar actions tests**

In `Tests/QuotaMonitorTests/MenuBarWindowActionsTests.swift`, add a test that
proves the popover action can request the widget without reaching AppKit:

```swift
@MainActor
@Test
func widgetActionRoutesThroughInjectedClosure() {
    var didShowWidget = false
    let actions = MenuBarWindowActions(
        requestWindow: { _ in },
        refreshDashboard: {},
        showFloatingWidget: { didShowWidget = true },
        hideFloatingWidget: {})

    actions.showWidget()

    #expect(didShowWidget == true)
}
```

- [ ] **Step 2: Extend `MenuBarWindowActions`**

In `QuotaMonitor/Features/MenuBar/MenuBarWindowActions.swift`, add closures and
methods:

```swift
var showFloatingWidget: @MainActor () -> Void
var hideFloatingWidget: @MainActor () -> Void
```

Update `live(env:)`:

```swift
showFloatingWidget: { WindowManager.shared.showFloatingQuotaWidget() },
hideFloatingWidget: { WindowManager.shared.hideFloatingQuotaWidget() }
```

Add methods:

```swift
@MainActor
func showWidget() {
    showFloatingWidget()
}

@MainActor
func hideWidget() {
    hideFloatingWidget()
}
```

Update existing test initializers to pass the new closures.

- [ ] **Step 3: Add the popover button**

In `QuotaMonitor/Features/MenuBar/MenuBarContentView.swift`, add a button near
the Dashboard/Settings actions:

```swift
Button {
    if settings.floatingQuotaWidgetEnabled {
        windowActions(env).hideWidget()
    } else {
        windowActions(env).showWidget()
    }
} label: {
    Label(settings.floatingQuotaWidgetEnabled
          ? L10n.floatingWidgetHide
          : L10n.floatingWidgetShow,
          systemImage: "rectangle.on.rectangle")
        .frame(maxWidth: .infinity)
}
.controlSize(.regular)
```

- [ ] **Step 4: Add Settings controls**

In `QuotaMonitor/Features/Settings/GeneralSettingsTab.swift`, inside
`Section(L10n.sectionMenuBar)`, add:

```swift
LabeledContent(L10n.floatingWidgetLabel) {
    Toggle("", isOn: Binding(
        get: { settings.floatingQuotaWidgetEnabled },
        set: { visible in
            if visible {
                WindowManager.shared.showFloatingQuotaWidget()
            } else {
                WindowManager.shared.hideFloatingQuotaWidget()
            }
        }
    ))
    .labelsHidden()
}
Text(L10n.floatingWidgetHelp)
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)

LabeledContent(L10n.floatingWidgetPinnedLabel) {
    Toggle("", isOn: Binding(
        get: { settings.floatingQuotaWidgetPinned },
        set: { pinned in
            settings.floatingQuotaWidgetPinned = pinned
            if settings.floatingQuotaWidgetEnabled {
                WindowManager.shared.showFloatingQuotaWidget()
            }
        }
    ))
    .labelsHidden()
}
Text(L10n.floatingWidgetPinnedHelp)
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)

LabeledContent(L10n.floatingWidgetEdgeAutoHideLabel) {
    Toggle("", isOn: $settings.floatingQuotaWidgetEdgeAutoHideEnabled)
        .labelsHidden()
}
Text(L10n.floatingWidgetEdgeAutoHideHelp)
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 5: Restore on launch after onboarding is complete**

In `QuotaMonitor/App/AppDelegate.swift`, after the existing onboarding/window
launch handling has configured `WindowManager`, call:

```swift
WindowManager.shared.restoreFloatingQuotaWidgetIfNeeded()
```

Also call the same method in the onboarding-completed notification path, after
the provider step has been marked complete.

- [ ] **Step 6: Verify and commit**

Run:

```bash
swift test --filter MenuBarWindowActionsTests
swift test --filter FloatingQuotaWidgetSettingTests
git diff --check
```

Expected: tests pass and no whitespace errors are reported.

Commit:

```bash
git add QuotaMonitor/App/AppDelegate.swift \
        QuotaMonitor/Features/MenuBar/MenuBarContentView.swift \
        QuotaMonitor/Features/MenuBar/MenuBarWindowActions.swift \
        QuotaMonitor/Features/Settings/GeneralSettingsTab.swift \
        Tests/QuotaMonitorTests/MenuBarWindowActionsTests.swift
git commit -m "feat: add floating widget entry points"
```

---

### Task 6: Extend LocalQA And Documentation

**Files:**
- Modify: `QuotaMonitor/App/LocalQAController.swift`
- Modify: `QuotaMonitor/App/LocalQAReport.swift`
- Modify: `Tests/QuotaMonitorTests/LocalQAReportTests.swift`
- Modify: `qa/lib/common.sh`
- Modify: `qa/prepare-computer-use-fixture.sh`
- Modify: `qa/prepare-computer-use-real-data.sh`
- Modify: `qa/tests/common_tests.sh`
- Modify: `docs/local-qa.md`
- Modify: `docs/computer-qa.md`

- [ ] **Step 1: Add report model tests**

In `Tests/QuotaMonitorTests/LocalQAReportTests.swift`, extend the fixture report
with:

```swift
floatingWidget: LocalQAFloatingWidgetReport(
    isVisible: true,
    isPinned: true,
    isCollapsed: false,
    edge: nil,
    windowIdentifier: "floating-quota-widget",
    status: "warning")
```

After decoding, assert:

```swift
#expect(decoded.floatingWidget?.isVisible == true)
#expect(decoded.floatingWidget?.isCollapsed == false)
#expect(decoded.floatingWidget?.windowIdentifier == "floating-quota-widget")
#expect(decoded.floatingWidget?.status == "warning")
```

- [ ] **Step 2: Add the report type**

In `QuotaMonitor/App/LocalQAReport.swift`, add:

```swift
struct LocalQAFloatingWidgetReport: Codable, Equatable {
    let isVisible: Bool
    let isPinned: Bool
    let isCollapsed: Bool
    let edge: String?
    let windowIdentifier: String
    let status: String
}
```

Add to `LocalQAReport`:

```swift
let floatingWidget: LocalQAFloatingWidgetReport?
```

- [ ] **Step 3: Add the QA step**

In `QuotaMonitor/App/LocalQAController.swift`, accept a new step string:

```swift
show-floating-widget
```

When the step runs:

```swift
settings.floatingQuotaWidgetEnabled = true
WindowManager.shared.showFloatingQuotaWidget()
```

When building the report, compute the pure model snapshot and write:

```swift
LocalQAFloatingWidgetReport(
    isVisible: settings.floatingQuotaWidgetEnabled,
    isPinned: settings.floatingQuotaWidgetPinned,
    isCollapsed: WindowManager.shared.floatingQuotaWidgetPresentation.isCollapsed,
    edge: WindowManager.shared.floatingQuotaWidgetPresentation.edge?.rawValue,
    windowIdentifier: "floating-quota-widget",
    status: widgetSnapshot.status.rawValue)
```

- [ ] **Step 4: Update shell artifact checks**

In `qa/lib/common.sh`, update the required app-state assertions for widget QA:

```sh
qm_assert_plutil_equals "$state" "floatingWidget.isVisible" "true"
qm_assert_plutil_equals "$state" "floatingWidget.isCollapsed" "false"
qm_assert_plutil_equals "$state" "floatingWidget.windowIdentifier" "floating-quota-widget"
qm_plutil_raw "floatingWidget.status" "$state" >/dev/null || {
    echo "missing floating widget status" >&2
    return 1
}
```

In the fixture and real-data setup scripts, append `show-floating-widget` to the
default QA steps only for Computer Use setup paths.

- [ ] **Step 5: Update QA docs**

In `docs/local-qa.md`, add `show-floating-widget` to the Computer Use setup
step list and document the `floatingWidget` artifact object, including
`isCollapsed` and `edge`.

In `docs/computer-qa.md`, add a checklist item:

```text
- Confirm the floating quota widget is visible, belongs to the QA app path, and
  shows 5h/7d values consistent with the menu-bar label/settings display mode.
- Drag the widget to the left edge, confirm it collapses to a thin tab, click
  the tab, and confirm it expands back to a full widget.
- Confirm the Settings switch can hide and show the widget without quitting
  QuotaMonitor.
```

- [ ] **Step 6: Verify and commit**

Run:

```bash
bash qa/tests/common_tests.sh
swift test --filter LocalQAReportTests
git diff --check
```

Expected: shell tests and report tests pass.

Commit:

```bash
git add QuotaMonitor/App/LocalQAController.swift \
        QuotaMonitor/App/LocalQAReport.swift \
        Tests/QuotaMonitorTests/LocalQAReportTests.swift \
        qa/lib/common.sh \
        qa/prepare-computer-use-fixture.sh \
        qa/prepare-computer-use-real-data.sh \
        qa/tests/common_tests.sh \
        docs/local-qa.md \
        docs/computer-qa.md
git commit -m "test: cover floating widget in local QA"
```

---

### Task 7: Final Verification

**Files:**
- No new files. This task verifies the branch.

- [ ] **Step 1: Run static gate**

Run:

```bash
./qa/run-static.sh
```

Expected: shell tests, Python tests, release-note validation, whitespace check,
and Swift tests all pass.

- [ ] **Step 2: Run fixture GUI setup**

Run:

```bash
./qa/prepare-computer-use-fixture.sh
```

Expected: the script launches `.build/QuotaMonitor.app`, writes an artifact
directory, and `app-state.json` includes `floatingWidget.isVisible = true`.

- [ ] **Step 3: Run real-data shadow GUI setup**

Run:

```bash
./qa/prepare-computer-use-real-data.sh
```

Expected: the script launches the QA build with a shadow database, keeps source
data unchanged, and reports the widget state in `app-state.json`.

- [ ] **Step 4: Manual GUI checks**

Using the exact app path from the generated `computer-use-qa.md`, verify:

- the widget is visible and small
- the widget can be dragged freely within the visible screen area
- dragging it into a screen edge collapses it to a thin tab when edge auto-hide is on
- clicking the collapsed tab expands it
- right-clicking the tab and choosing `Hide Widget` closes it
- close hides it and keeps QuotaMonitor running
- popover button can show it again
- Settings toggle can show/hide it
- Settings edge auto-hide toggle disables edge collapse
- pin toggle changes whether it appears above other windows
- 5h/7d text matches the menu-bar label's used/remaining mode
- full-screen Space still shows the pinned widget
- installed `/Applications/QuotaMonitor.app` is not confused with the QA build

- [ ] **Step 5: Commit any verification-only doc updates**

If manual QA finds documentation corrections, commit them:

```bash
git add docs/local-qa.md docs/computer-qa.md
git commit -m "docs: clarify floating widget QA"
```

If no documentation correction is needed, skip this commit.
