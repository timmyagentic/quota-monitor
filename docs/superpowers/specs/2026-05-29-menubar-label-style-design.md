# Menu-bar label style setting — design

**Date:** 2026-05-29
**Status:** Approved (brainstorming) → ready for implementation
**Builds on:** `2026-05-29-menubar-discoverability-design.md` (the NSStatusItem migration)

## Problem

After migrating the menu bar from SwiftUI `MenuBarExtra` to an AppKit
`NSStatusItem`, the label is rendered by hosting `MenuBarLabelView` in an
`NSHostingView` pinned to the status button's bounds. The status item uses
`variableLength`, which sizes the button from its **title/image** — but the
content is a *subview*, so the button can't derive its width from it. The text
ends up in a wrongly-sized container with non-native insets/spacing, which
reads as "the spacing / font style changed" compared with the original
`MenuBarExtra` rendering.

Rather than only restoring the old look, expose the choice as a setting.

## Goals

1. Render the menu-bar label natively so spacing/sizing match the system menu
   bar again (fixes the regression).
2. Add a **menu-bar label style** setting with two options:
   - **Emphasis** (default): the existing rounded, mixed-weight look
     (`5h` light · `8%` heavy).
   - **Native**: plain system menu-bar font, single weight, system spacing.

## Non-goals

- Icon-only / icon+short-text styles (considered, dropped — YAGNI).
- Wallpaper-driven (vibrant) auto black/white for the text styles. Native style
  uses `labelColor` (follows light/dark mode). True wallpaper-template
  rendering is out of scope; revisit only if requested.

## Approach

Both styles render via `statusItem.button.attributedTitle` (an
`NSAttributedString`), NOT a hosted SwiftUI view. This is what restores native
status-item sizing (variableLength measures the title) and spacing. The two
styles differ only in fonts:

- **Emphasis:** rounded design via `NSFontDescriptor.withDesign(.rounded)`.
  `5h`/`7d` at 9pt medium, the percent values at 11pt heavy (monospaced
  digits), separated by ` · ` at 9pt regular; provider tag (`CX`/`CC`) prefix
  only in multi-provider mode. Mirrors the current `MenuBarLabelView.styledTitle`.
- **Native:** the standard menu-bar font (`NSFont.menuBarFont(ofSize: 0)`),
  regular weight, one size; `labelColor` foreground. Same text content.

Empty/no-data state (no selected provider has a usable percentage) keeps the
existing fallback: `statusItem.button.image` = the `gauge.with.dots.needle.50percent`
SF Symbol as a **template** image (auto black/white), with `attributedTitle`
cleared.

### Shared data model

The data logic currently in `MenuBarLabelView` (`pickRows` / `format`: which
providers to show, 5h/7d percentages, used-vs-remaining display mode, the
`CX`/`CC` tags) moves to a pure, testable `MenuBarLabelModel`:

```
struct MenuBarLabelModel {
    struct Row: Equatable { let tag: String; let fiveHour: String; let sevenDay: String }
    static func rows(iconProviders: Set<String>,
                     enabledProviders: Set<String>,
                     rateLimits: RateLimitSnapshot?,
                     claudeUsage: ClaudeUsageSnapshot?,
                     displayMode: SettingsStore.QuotaDisplayMode) -> [Row]
}
```

`StatusItemController` consumes `rows(...)` to build the `NSAttributedString`.
`MenuBarLabelView` is no longer used for the menu bar and is removed.

### Re-rendering (Observation → AppKit bridge)

`StatusItemController` is not a SwiftUI view, so it observes the `@Observable`
state with `withObservationTracking`: a `renderLabel()` pass reads
`env.latestRateLimits`, `env.latestClaudeUsage`, `settings.menuBarIconProviders`,
`settings.enabledProviders`, `settings.quotaDisplayMode`, and
`settings.menuBarLabelStyle`, builds + assigns the title/image, and re-arms the
tracking in the `onChange` callback (hopping to the main actor). This replaces
the SwiftUI `@Observable`-driven redraw the hosted view used to get for free.

### Setting

- `SettingsStore.menuBarLabelStyle: MenuBarLabelStyle` — enum `{ native, emphasis }`,
  default `.emphasis` (preserves the app's original look, now rendered
  correctly). Persisted under `settings.menuBarLabelStyle`. Hot-applied: the
  Observation pass above re-renders on change, no relaunch.
- Picker in **Settings → General → Menu bar** section, a segmented control:
  Native / Emphasis.

## Files

| File | Change |
| --- | --- |
| `Core/Settings/SettingsStore.swift` | `MenuBarLabelStyle` enum + property + key + (snapshot not required — UI-only) |
| `Features/MenuBar/MenuBarLabelModel.swift` (new) | Pure row data extracted from `MenuBarLabelView` |
| `App/StatusItemController.swift` | Drop label `NSHostingView`; build `attributedTitle` / template `image`; `withObservationTracking` re-render |
| `Features/MenuBar/MenuBarLabelView.swift` | Removed (logic moved to model; view no longer used) |
| `Features/Settings/GeneralSettingsTab.swift` | Style segmented picker |
| `Core/Localization/L10n.swift` | Style labels + section copy |
| `Tests/QuotaMonitorTests/MenuBarLabelModelTests.swift` (new) | Row logic |
| `Tests/QuotaMonitorTests/MenuBarLabelStyleSettingTests.swift` (new) | Default + persistence |

## Risks

- Rounded-design `NSFont` mapping should match the SwiftUI `.rounded` look;
  minor kerning differences may need on-device tuning.
- `withObservationTracking` must be re-armed every change (one-shot per call);
  the `onChange` re-registers. Verify the label keeps updating across multiple
  poll cycles.
