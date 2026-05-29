# Menu-bar icon recovery guide — design

**Date:** 2026-05-29
**Status:** Approved (brainstorming) → ready for implementation
**Builds on:** `2026-05-29-menubar-discoverability-design.md`

## Problem

When the status item is clipped, the current fallback (permanent Dock icon +
auto-opened Dashboard + an orange hint banner) explains the situation but
doesn't actively help a novice *fix* it. The user picked: when clipped, pop a
dedicated guidance window that teaches them how to make the icon reappear.

## Hard truth baked into the copy

A fully clipped item (behind the notch / hidden by a manager) **cannot be
dragged directly — you can't grab what you can't see.** The achievable
root-cause fix is to **free up menu-bar space** (⌘-drag/remove other items,
quit menu-bar apps); once there's room, macOS shows our item automatically. The
guidance teaches that, not "drag our icon."

## Behavior

- Clipped detected (the existing `.openFallbackWindow` path, one-time gated by
  `hasShownFirstRunPresentation`) now opens a dedicated **`menubar-help`**
  window instead of the Dashboard. The permanent Dock icon + `menuBarUnreachable`
  per-launch enforcement are unchanged.
- The window is also reachable any time (not only when clipped) from
  **Settings → General → Menu bar** and from the Dashboard hint banner.

## The guidance window (`MenuBarHelpView`)

New SwiftUI `Window(id: "menubar-help")`, opened via the existing
`quotamonitor://menubar-help` URL route (`WindowRouter` / `handlesExternalEvents`).

Content:
- Title + one-line explanation ("your menu bar is too full to show the icon").
- Numbered, actionable steps with SF Symbols:
  1. Hold ⌘ and drag menu-bar icons to rearrange; drag one off the bar to
     remove it and free space.
  2. Quit menu-bar apps you don't need.
  3. Using Bartender / Ice etc.? Set QuotaMonitor to "always show".
  4. Notched Mac: space left of the notch is limited; remove a few items and
     the icon appears automatically.
- Footer: "You can always open QuotaMonitor from its Dock icon."
- Buttons: **Re-check** · **Open Dashboard** · **Got it**.

### Re-check interaction

"Re-check" posts `.quotaMonitorRecheckVisibility`. `AppDelegate` observes it,
re-runs `enforceClipFallback()` (which sets `env.menuBarUnreachable` from a
fresh `currentVisibility()`), and — if now visible — calls
`statusItemController.showPopover()` to point at the recovered icon. The view
binds to the observable `env.menuBarUnreachable`:
- still clipped → "Still no room — free up a bit more and try again."
- now visible → "✅ The icon is back in your menu bar." (and the popover pops).

## Changes to the previous discoverability work

- `AppDelegate.runDiscoverabilityCheck()`: `.openFallbackWindow` requests
  `"menubar-help"` instead of `"dashboard"`.
- `AppDelegate.closeStrayWindows()`: add `"menubar-help"` to the id set.
- Dashboard hint banner (`DashboardView.hiddenIconHint`): primary button
  becomes "Show me how" → opens `menubar-help`; keep the dismiss button.

## Files

| File | Change |
| --- | --- |
| `Features/MenuBarHelp/MenuBarHelpView.swift` (new) | The guidance window view + re-check |
| `App/QuotaMonitorApp.swift` | New `Window(id:"menubar-help")` + `handlesExternalEvents(["menubar-help"])` |
| `App/AppDelegate.swift` | `.openFallbackWindow` → `menubar-help`; observe `.quotaMonitorRecheckVisibility` → recheck + showPopover; add id to `closeStrayWindows`; declare the notification name |
| `Features/Dashboard/DashboardView.swift` | Banner button opens `menubar-help` |
| `Features/Settings/GeneralSettingsTab.swift` | "Can't find the menu-bar icon?" → open `menubar-help` |
| `Core/Localization/L10n.swift` | All EN + zh copy |

## Risks

- Re-check accuracy depends on `currentVisibility()` (same geometry caveat).
- Steps are text + SF Symbols (no screenshots/gifs) — locale-safe and light;
  if users still struggle, richer visuals can come later.

## Out of scope

- Animated/gif tutorials, auto-relocating the icon (impossible), wallpaper-based
  template contrast (tracked in the label-style spec).
