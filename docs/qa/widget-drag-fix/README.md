# Native quota widget drag correction

Captured on 2026-09-28 (Asia/Shanghai), from code commit `f8080a8` on `codex/widget-drag-placement`. The debug QA bundle is built from the shipping controller, summary view, and details view. Its profile, HOME, data, and defaults are isolated; quota values are synthetic.

![Actual native quota readout without a disclosure arrow](readout-native.jpg)

This is a Computer Use capture of the actual independent summary NSPanel, not a generated mockup or an embedded replacement. The separate fixture host is hidden by the opt-in inspection control so Computer Use can select the panel. Inspection freezes host tracking; it does not establish external-host or physical-drag behavior.

## Changes

- The installed Codex bundle labels its full title button with the current product mode (English, simplified Chinese, or traditional Chinese), rather than simply `Codex`. The old exact-name match rejected that button. Regression cases failed before the fix and pass afterward; Work-mode and unrelated Codex action labels remain rejected. The QA host also uses the new mode-selector label.

- Native mouse input reads screen coordinates while the containing panel moves. The existing one-second hold, click-to-toggle, movement hints, accessibility action, and reset menu remain.
- The final mouse-up point is applied before saving. Cancellation or loss of foreground cancels the gesture instead of saving an unfinished movement.
- Header discovery misses and changes in available width no longer replace the active drag's frame or compact state.
- A compact drop is normalized against the restored full readout width. Previously, a weekly compact drop at x = -700 in a 1200-point host could restore about 27 points to the left. Screen-edge containment still applies when the full readout needs more space.
- Only the trailing summary chevron is removed. `CodexQuotaOverlayDetailsView` and all localization strings are unchanged.
- The QA host now exercises the actual controller/panels and measures its title/action frames through the production header selection policy. The former gallery used embedded views, no-op drag callbacks, and hardcoded offsets.

## Verification

- Focused suites: 31 tests passed, including repeated movement with a moving NSPanel, final release, cancellation, compact persistence, and active-drag placement.
- `./qa/run-static.sh`: 1,030 Swift tests in 118 suites and 191 Python tests passed; shell checks and bilingual release-note validation passed.
- Fixture artifact validation: independent defaults and database paths; actual summary and detail panels visible, non-key, and interactive; no saved manual position.
- Measured fixture header: leading 147, trailing 350, center inset 72. Host frame `[440, 291, 1040, 692]`; actual summary frame `[587, 897, 148, 28]`. The summary aligns with the header center and stays inside its empty slot. Actual details frame `[587, 787, 272, 104]` opens below it.
- Computer Use captured the summary as a button with the existing one-second-drag accessibility hint and no chevron.

**UNVERIFIED:** physical pointer drag through Computer Use (`windowNotFoundAtPosition` for the nonactivating NSPanel), external Codex header discovery, and update verification on the user's installed app. Do not infer an old binary from its installation directory: the currently running app in an old worktree contains the beta.1 header implementation. The user confirmed that resetting their previous position made the widget disappear, consistent with the now-reproduced header-label mismatch. Read-only System Settings inspection showed QuotaMonitor's permission switch enabled; no permissions or installed applications were changed.

The general Dashboard artifact checker expects unrelated Dashboard, Settings, and history fixtures; this focused preview instead validates its isolated configuration, app-state report, and actual overlay frame report. Reproduce with `QM_QA_LANGUAGE=zh-Hans ./qa/prepare-sidebar-widget-preview.sh`, then use **Inspect floating windows** to select the standalone panel for capture. This inspection mode intentionally pauses host tracking; normal preview mode continues to track its fixture window.
