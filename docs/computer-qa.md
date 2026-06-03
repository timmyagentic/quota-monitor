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
- `Computer Use app target`, the exact `.app` path Computer Use should target,
- `cleanup-interactive.sh`, the command that stops the app and removes the QA
  work root.

The app writes its own state snapshot inside the isolated QA profile. The
script copies that snapshot into the printed artifact directory, so Computer
Use can inspect repo-local artifacts without making the app write directly to
repo or external-volume paths.

Every run also writes `qa-boundary.json`. Treat it as the source of truth for
the current test boundary: fixture vs real-data-shadow mode, QA-only write
roots, disabled live external sources, and UI actions that require explicit
approval before Computer Use can click them.

When using Computer Use, pass the exact `Computer Use app target` from the
brief. Do not target the app by the bare name `QuotaMonitor` or only by bundle
identifier: a developer machine may also have `/Applications/QuotaMonitor.app`
running, and the exact path keeps Computer Use attached to the isolated QA
build.

When the question is "does the latest app render my real historical data
correctly?", launch the real-data shadow mode instead:

```sh
./qa/run-real-data-interactive.sh
```

This still uses an isolated QA profile. It copies the real QuotaMonitor SQLite
database into the QA home with SQLite backup, points the app at that copy, does
not copy real Codex or Claude credentials, disables live Codex app-server and
Claude OAuth polling, and writes `real-data-protection.txt` to prove the source
database fingerprint did not change. Use this mode for visual checks that need
realistic charts, sessions, history, and model distribution.

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
- `qa-boundary.json` documents and passes the expected boundary contract,
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

For real-data shadow QA, the data is real but the profile is still isolated.
Treat the source database path as read-only evidence and avoid any Computer Use
actions that reveal files, export CSV, sync pricing, check for updates, or run
uninstall unless the user explicitly approves that exact action.

If `qa/check-artifacts.sh` sees Developer Mode events from live Codex/Claude data
sources, the artifact contract fails. Computer Use should inspect the copied
database and rendered UI, not trigger real provider quota refreshes.

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
