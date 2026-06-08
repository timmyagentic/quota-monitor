# Floating Quota Widget Design

## Problem

QuotaMonitor already exposes quota state through the menu-bar label and the
popover. That is good for a compact always-available signal, but it still
requires a menu-bar click when the user wants a larger, glanceable quota card.
The attached reference image points at a useful product shape: an optional
floating desktop HUD that keeps the current 5h and 7d quota windows visible
without opening Dashboard or Settings.

The feature should feel like QuotaMonitor, not like a separate skin. The widget
must use the same source data, percentage direction, provider selection, refresh
behavior, and localization rules as the menu bar and popover.

## Goals

- Add an optional floating quota widget that the user can open from the popover
  and Settings.
- Reuse the existing quota data sources:
  - Codex live rate limits from `AppEnvironment.latestRateLimits`
  - Codex JSONL quota fallback from `AppEnvironment.dashboardSnapshot?.codexQuota`
  - Claude usage from `AppEnvironment.latestClaudeUsage`
  - provider visibility from `SettingsStore.enabledProviders` and
    `SettingsStore.menuBarIconProviders`
  - used-vs-remaining display from `SettingsStore.quotaDisplayMode`
- Keep the floating window under AppKit ownership. `WindowManager` remains the
  single window entry point after PR #25.
- Make the widget safe for a menu-bar agent:
  - opening it does not require a Dock icon
  - closing it does not quit the app
  - it does not count as a primary app window for Dock demotion decisions
  - it can appear in full-screen Spaces when pinned
- Make the floating surface ergonomic:
  - the user can drag it to any visible position on any attached display
  - dragging it into a screen edge can collapse it into a thin visible tab
  - the tab can be clicked to expand the widget back to its last full frame
  - the close action is explicit enough to avoid accidental dismissal
- Persist only the user-facing widget intent:
  - whether the widget should reopen on launch
  - whether it is pinned above normal windows and across Spaces
  - whether edge auto-hide is enabled
  - the user-positioned frame via AppKit frame autosave
- Extend LocalQA so visual/manual verification can prove which running app owns
  the widget window.

## Non-Goals

- Do not replace the menu-bar label.
- Do not add a Windows desktop widget.
- Do not add a second provider-selection setting for the widget in the first
  version. The widget uses the same providers selected for the menu-bar icon.
- Do not add a large marketing-style card, 3D assets, or bitmap-generated art.
  The widget should be a restrained utility surface that fits the existing app.
- Do not contact external services only because the widget is visible. Refresh
  behavior goes through the existing `refreshAll` throttle and QA guards.

## User Experience

### Entry Points

1. Popover footer: add a secondary button labeled `Show Widget` /
   `Hide Widget` with an icon such as `rectangle.on.rectangle`.
2. Settings -> General -> Menu bar: add a row labeled `Floating quota widget`
   with:
   - a toggle: show or hide the widget and persist the launch setting
   - a pin toggle: keep the widget above normal windows and visible across
     Spaces
   - an edge auto-hide toggle: allow edge docking and collapse to a thin tab

### Widget Layout

The default widget should be small enough to sit near the menu bar without
covering work:

- fixed content size near `320 x 190`
- compact header:
  - status dot
  - title: `Quota Monitor`
  - optional provider tag when exactly one provider is shown
  - refresh button
  - pin button
  - close button
- body:
  - headline percentage for the most urgent visible window
  - explicit direction label, `Used` or `Remaining`
  - 5h row
  - 7d row
  - provider summary chips when both Codex and Claude are selected
- footer:
  - plan or tier text when available
  - stale/no-data copy when no quota snapshot exists

The reference image uses a large glossy orb. QuotaMonitor should not copy that
literally. A compact ring or filled capsule is enough, and it must use the same
percentage direction as Settings. If the user selected `Remaining`, the widget
must say `Remaining`, and progress should represent remaining. If the user
selected `Used`, it must say `Used`, and progress should represent usage.

### Dragging, Edge Hide, And Close Semantics

The widget is a desktop utility, so movement must be forgiving:

- The header and non-control background are drag regions.
- Dragging works on every attached display, not just `NSScreen.main`.
- The user can place the expanded widget anywhere inside a screen's visible
  frame. The controller may clamp just enough to keep at least a small visible
  recovery area, so a widget cannot be lost completely off-screen.
- The last expanded frame is saved. Expanding from an edge returns to that
  frame, adjusted only if the display layout changed.

Edge auto-hide is intentionally a drag-end behavior, not a hover surprise:

- If `floatingQuotaWidgetEdgeAutoHideEnabled` is on and the user releases the
  widget within 16 px of a visible screen edge, the panel snaps to that edge and
  collapses.
- Collapsed state leaves a 10-14 px visible tab inside the screen. The tab uses
  the current status color and a subtle material, but no text.
- Supported edges: left, right, top, and bottom. Top docking respects the menu
  bar by using `visibleFrame`, not full `frame`.
- Single-click on the collapsed tab expands the widget.
- If edge auto-hide is off, dragging near an edge only clamps the expanded
  widget into the visible frame; it does not collapse.

Closing should be explicit:

- Normal expanded single-click never closes the widget. It conflicts with
  dragging and with refresh/pin controls.
- Expanded close paths:
  - close button in the header
  - Settings toggle off
  - popover `Hide Widget`
  - context menu `Hide Widget`
- Collapsed close shortcuts:
  - context menu `Hide Widget`
- Plain click on the collapsed tab expands. It does not close.

### Status Levels

Status is derived from used percentage, regardless of display direction:

- `ok`: worst visible used percentage below 70
- `warning`: worst visible used percentage from 70 through 89
- `danger`: worst visible used percentage 90 or above
- `unknown`: no visible provider window has a number

The colors should match provider/status semantics already used by the popover:
system green/yellow/red for status and provider accent colors for provider
identity. The status color is a small signal, not a full-background theme.

### Window Behavior

Use a small AppKit-owned panel:

- `NSPanel` subclass or controller-owned `NSPanel`
- borderless or titled-less utility styling
- `isReleasedWhenClosed = false`
- `hidesOnDeactivate = false`
- `collectionBehavior` includes `.fullScreenAuxiliary` while pinned
- pinned mode uses `.floating` level and `.canJoinAllSpaces`
- unpinned mode uses `.normal` level and current Space only
- frame autosave name: `floating-quota-widget`
- first placement: top-right of the main screen visible frame, with padding
- `isMovableByWindowBackground = true`, plus controller-level drag-end handling
  for edge docking
- collapsed frame and last expanded frame are owned by the controller, not by
  SwiftUI view state

The widget is an auxiliary surface. It is not one of the four primary managed
windows (`dashboard`, `settings`, `onboarding`, `menubar-help`) and should not
participate in `WindowManager.hasVisibleWindow(excluding:)` demotion logic.
That preserves the current menu-bar-agent behavior: the widget can exist while
the app remains accessory-only.

## Architecture

### Data Model

Add a pure model builder:

```swift
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
}
```

The builder takes the same inputs as `MenuBarLabelModel.rows(...)` plus
`isRefreshing`. It should prefer live Codex rate limits over the Dashboard JSONL
fallback, matching the menu-bar behavior.

### AppKit Ownership

Add a dedicated controller rather than stuffing special cases into
`AppWindowController`:

```swift
@MainActor
final class FloatingQuotaWidgetController: NSObject, NSWindowDelegate {
    func show()
    func hide()
    func setPinned(_ pinned: Bool)
    var isVisible: Bool { get }
}
```

`WindowManager` owns one instance:

```swift
func showFloatingQuotaWidget()
func hideFloatingQuotaWidget()
func toggleFloatingQuotaWidget()
func restoreFloatingQuotaWidgetIfNeeded()
```

`WindowManager.show(_:)` remains only for primary windows by id.

### SwiftUI Content

Create `FloatingQuotaWidgetView` as a SwiftUI view hosted inside the panel. The
view reads `AppEnvironment`, `SettingsStore`, and `LocalizationStore` from the
environment and builds the pure model inside `body`. The buttons call narrow
actions passed in by the controller:

```swift
struct FloatingQuotaWidgetActions {
    var refresh: @MainActor () -> Void
    var togglePinned: @MainActor () -> Void
    var close: @MainActor () -> Void
}
```

The view should not know about `NSPanel` or `WindowManager`.

### Settings

Add two persisted settings:

```swift
var floatingQuotaWidgetEnabled: Bool
var floatingQuotaWidgetPinned: Bool
var floatingQuotaWidgetEdgeAutoHideEnabled: Bool
```

Keys:

```swift
settings.floatingQuotaWidgetEnabled
settings.floatingQuotaWidgetPinned
settings.floatingQuotaWidgetEdgeAutoHideEnabled
```

Defaults:

- `floatingQuotaWidgetEnabled = false`
- `floatingQuotaWidgetPinned = true`
- `floatingQuotaWidgetEdgeAutoHideEnabled = true`

The enabled setting means "show on launch and currently visible unless closed."
The close button sets `floatingQuotaWidgetEnabled = false` and hides the panel.
The popover and Settings toggle set it to true and show the panel immediately.

The edge auto-hide setting gates only snap/collapse behavior. It does not
disable free dragging.

### Interaction State

Keep interaction state in the AppKit controller:

```swift
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
```

This state does not need to be a user default in the first version. AppKit frame
autosave covers normal expanded placement; a collapsed widget can restore as an
expanded widget on relaunch to avoid trapping the user behind a tiny tab after a
display-layout change.

### Localization

Add these keys in `L10n.swift`:

- `floatingWidgetLabel`
- `floatingWidgetShow`
- `floatingWidgetHide`
- `floatingWidgetHelp`
- `floatingWidgetPinnedLabel`
- `floatingWidgetPinnedHelp`
- `floatingWidgetEdgeAutoHideLabel`
- `floatingWidgetEdgeAutoHideHelp`
- `floatingWidgetRefreshTooltip`
- `floatingWidgetPinTooltip`
- `floatingWidgetCloseTooltip`
- `floatingWidgetExpandTooltip`
- `floatingWidgetContextHide`
- `quotaStatusOK`
- `quotaStatusWarning`
- `quotaStatusDanger`
- `quotaStatusUnknown`

All keys need English and Simplified Chinese translations in the same file, per
the current localization convention.

### LocalQA

Add a QA step:

```text
show-floating-widget
```

When present, the app should open the widget, snapshot the window state, and
write an explicit `floatingWidget` object into `app-state.json`:

```json
{
  "floatingWidget": {
    "isVisible": true,
    "isPinned": true,
    "isCollapsed": false,
    "edge": null,
    "windowIdentifier": "floating-quota-widget",
    "status": "ok"
  }
}
```

`qa/check-artifacts.sh` and `qa/tests/common_tests.sh` should verify that the
artifact exists and that the regular Dashboard/Settings window assertions still
pass. The widget should be additive to QA, not a replacement for existing
window checks.

## Acceptance Criteria

- The widget opens from the popover and Settings.
- The widget can be closed from its own close button.
- Closing the widget keeps QuotaMonitor running.
- With `floatingQuotaWidgetEnabled = true`, the widget reopens after relaunch
  once onboarding is complete.
- The widget reflects live quota changes without a separate data source.
- The widget respects `quotaDisplayMode` for both label text and progress fill.
- The widget respects `menuBarIconProviders` and `enabledProviders`.
- Pinning changes window level/Space behavior immediately.
- The expanded widget can be dragged freely on any attached display.
- Dragging to a screen edge collapses it to a thin visible tab when edge
  auto-hide is enabled.
- Clicking the collapsed tab expands it; context-menu `Hide Widget` closes it.
- The widget appears over full-screen Spaces while pinned.
- The widget does not trigger Dock icon promotion when
  `showDockIconForWindows` is false.
- LocalQA can report the widget state in `app-state.json`.
- Static tests pass with `./qa/run-static.sh`.
- Manual GUI QA captures a screenshot or AX tree proving the widget belongs to
  the QA build path, not `/Applications/QuotaMonitor.app`.

## Risks

- A borderless floating window can become hard to move if the drag region is
  too small. The design needs a clear draggable header.
- A nonactivating panel can miss keyboard shortcuts. The widget should not rely
  on keyboard input.
- A pinned panel can feel intrusive. Default size must stay small, and close
  must be obvious.
- Auto-hide can become confusing if it triggers while the user is only trying to
  align the widget. Treat snap/collapse as a drag-end threshold, not a live hover
  behavior, and expose a Settings toggle.
- If the widget counts as a primary window, it can regress the Dock demotion
  fixes from PR #25. Keep it outside `hasVisibleWindow`.
- If it recomputes percentages separately, it can diverge from Settings and the
  menu-bar label. Centralize the model formatting and test it.
