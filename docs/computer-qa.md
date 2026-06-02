# Computer Use QA

QuotaMonitor uses two complementary QA modes:

1. Code-driven checks verify deterministic logic, app startup, fixture import,
   core windows, settings state, logs, screenshots, and AX artifacts.
2. Computer Use verifies the real macOS UI by operating the latest built app
   like a user.

Use this flow when a change affects visible behavior, navigation, settings,
window lifecycle, or any workflow that is hard to trust from unit tests alone.

## Workflow

Run the full deterministic suite first:

```sh
./qa/run-all.sh
```

Then launch an isolated interactive QA app:

```sh
./qa/run-interactive.sh
```

This command builds the latest local app, starts it with fixture data, opens
the core windows, verifies the artifact contract, and keeps the app running
for Computer Use. It prints:

- the artifact directory,
- `computer-use-qa.md`, a per-run walkthrough brief,
- `cleanup-interactive.sh`, the command that stops the app and removes the QA
  work root.

The app writes its own state snapshot inside the isolated QA profile. The
script copies that snapshot into the printed artifact directory, so Computer
Use can inspect repo-local artifacts without making the app write directly to
repo or external-volume paths.

To re-check an artifact directory later:

```sh
./qa/check-artifacts.sh .build/qa-artifacts/<timestamp>-interactive
```

## What Code Verifies

The deterministic layer owns the assertions that should not depend on screen
reading:

- the app launches as a macOS `.app` bundle,
- Dashboard, Settings, menu-bar help, and the popover can be opened,
- fixture Codex and Claude data import into isolated SQLite,
- Developer Mode writes the expected QA events,
- the settings exercise applies the expected state,
- screenshot and AX artifacts exist or record a permission warning.

## What Computer Use Verifies

Computer Use owns user-facing operability:

- Dashboard: Forecast, Trends, and Composition render with fixture data.
- Sessions: search, sort, detail selection, token/cost/event rows.
- History: day selection, rollups, per-session details.
- Settings: General and Advanced controls are visible and usable.
- Menu bar: popover navigation, provider display, refresh affordance.
- Menu-bar help: readable copy and safe close behavior.
- Visual pass: clipped text, overlapping controls, blank charts, missing icons,
  unexpected disabled states.

Do not use real Codex or Claude credentials during this pass. The interactive
QA app is already configured with fixture data and an isolated profile.

Ask before destructive or external-side-effect UI actions, including uninstall,
deleting files, changing system settings, accepting permission prompts, or
transmitting credentials.

## Reporting

A useful report includes:

- commands run,
- artifact directory,
- Computer Use observations by area,
- screenshot or AX evidence for failures,
- areas not tested and the reason.
