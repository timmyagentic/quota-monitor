# Local QA Harness

This repo has two local verification layers:

1. Swift/package tests for deterministic model, parser, storage, pricing, and
   UI-decision behavior.
2. A macOS app harness that builds and launches `QuotaMonitor.app` in an
   isolated QA profile, drives the main windows, imports fixture usage data,
   and captures artifacts Codex can inspect without manual clicking.

## Commands

Run only the shell harness tests:

```sh
./qa/tests/common_tests.sh
```

Run the Swift test suite:

```sh
swift test --disable-keychain
```

Run the isolated macOS end-to-end harness:

```sh
./qa/run-local.sh
```

Launch an isolated QA app and keep it open for Computer Use:

```sh
./qa/run-interactive.sh
```

Launch an isolated QA app with a copied snapshot of the real QuotaMonitor
SQLite database:

```sh
./qa/run-real-data-interactive.sh
```

Re-check a QA artifact directory:

```sh
./qa/check-artifacts.sh .build/qa-artifacts/<timestamp>
```

Run the full local suite:

```sh
./qa/run-all.sh
```

Launch the app manually through the shared build/run entrypoint:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

The Codex desktop Run action is wired to `./script/build_and_run.sh` through
`.codex/environments/environment.toml`.

## What `qa/run-local.sh` Verifies

The harness creates a temporary profile and writes `qa-config.json` into the
artifact directory. `script/build_and_run.sh --qa` validates that config file,
base64-encodes it, and launches the app with:

```sh
open .build/QuotaMonitor.app --args --quotamonitor-qa-config-base64 <payload>
```

The app still accepts the older
`--quotamonitor-qa-config <artifact-dir>/qa-config.json` form for focused
debugging, but the normal end-to-end script uses the inline config payload so
startup does not depend on app-side file reads from the artifact volume.

The config includes:

- `mode=true`
- `home=<temp profile>`
- `defaultsSuite=<unique suite>`
- `codexHome=<temp profile>/.codex`
- `outputDirectory=<temp profile app artifact directory>`
- `steps=[...]`

The app uses the config `home` for its SQLite database and Developer Mode log.
It writes app-side QA output under the temp profile, and the shell harness then
copies the app-reported state into `.build/qa-artifacts/<timestamp>/`. This
keeps GUI app file IO away from repo/external-volume paths that can trigger
macOS file-access prompts or stalls. It uses `defaultsSuite` for settings and
localization, so the harness does not read or overwrite the normal
`dev.tjzhou.QuotaMonitor` preferences domain. The older `QUOTAMONITOR_QA_*`
environment variables still work for focused unit tests, but the end-to-end
launch path uses command-line config because LaunchServices environment
propagation is not reliable for GUI app launches.

The default QA steps are:

```text
open-dashboard,open-settings,open-menubar-help,show-popover,refresh-all,exercise-settings,wait,snapshot
```

In QA mode, `refresh-all` is local-only: it runs the importer and UI refreshes
without contacting the live Codex app-server or Claude OAuth endpoint.
`exercise-settings` then changes settings through the real `SettingsStore`,
applies the environment side effects, and verifies those changes through the
artifact contract. The expected QA mutation is: English UI, Developer Mode on,
Codex disabled, Claude still enabled, quota display set to remaining, Dock icon
off, and a 15-minute polling interval.

## Artifacts

Each `qa/run-local.sh` run prints an artifact directory under
`.build/qa-artifacts/<timestamp>/`. Important files:

- `app-state.json` — app-reported PID, bundle id, database/log paths, visible
  windows, status-item visibility, settings snapshot, and menu-bar totals.
- `qa-boundary.json` — machine-readable QA boundary contract: fixture vs
  real-data-shadow mode, QA write roots, disabled external data sources, and
  Computer Use actions that require explicit approval.
- `db-counts.txt` — provider/session/event/rate-limit counts read from the
  isolated SQLite database.
- `qa-config.json` — launch config passed to the app.
- `quotamonitor-dev.log` — Developer Mode JSONL log for the QA run.
- `screen.png` — full-screen screenshot when macOS allows `screencapture`.
- `ax-tree.txt` — Accessibility tree dump for open QuotaMonitor windows.

Before `qa/run-local.sh` succeeds, it asserts the artifact contract:

- `qa-boundary.json` exists, is valid JSON, matches the expected QA mode, keeps
  app writes under the QA home, disables live external sources, and documents
  Computer Use approval boundaries.
- `app-state.json` is valid JSON and contains Dashboard and Settings windows.
- `app-state.json` includes the `exercise-settings` step and the expected
  settings snapshot.
- `db-counts.txt` includes Codex, Claude, and both primary/secondary JSONL
  rate-limit samples.
- `quotamonitor-dev.log` includes `qa.settings.exercise` and
  `qa.snapshot.write`.
- `screen.png` and `ax-tree.txt` are nonempty when available; if macOS denies
  Screen Recording or Accessibility, the harness writes a warning file instead.

If the AX dump is required, run:

```sh
QM_QA_REQUIRE_AX=1 ./qa/run-local.sh
```

Grant Accessibility permission to the terminal/Codex host app if this fails.

## Fixture Data

Codex fixture data comes from:

```text
Tests/QuotaMonitorTests/Fixtures/Rollout/cli_0_40_with_cwd.jsonl
```

Claude fixture data comes from:

```text
qa/fixtures/qa-claude-session.jsonl
```

The expected isolated import result is at least one Codex session, one Claude
session, usage events for both providers, and Codex JSONL rate-limit samples.

## Computer Use QA

`qa/run-interactive.sh` uses the same isolated harness but does not clean up or
quit the app. It writes a per-run `computer-use-qa.md` brief into the artifact
directory, keeps the latest local build open, and prints a cleanup script path.
The brief includes the exact `.app` path to pass to Computer Use; use that path
instead of the bare `QuotaMonitor` app name so the agent does not attach to a
separately installed copy.

Use this after `qa/run-all.sh` when the change needs a real UI walkthrough.
See `docs/computer-qa.md` for the expected Computer Use checklist.

## Real Data Shadow QA

`qa/run-real-data-interactive.sh` is the opt-in path for checking how the latest
local build renders the user's real historical QuotaMonitor data without
letting the app touch the original profile.

The script:

- computes a fingerprint for the source database,
- copies the source database with SQLite backup into a temporary QA home,
- launches the app with that temporary HOME, an isolated UserDefaults suite,
  and `CODEX_HOME` inside the QA home,
- does not copy real Codex or Claude credentials,
- sets the QA defaults so Keychain policy is `never`,
- disables live Codex app-server and Claude OAuth polling while QA mode is
  active,
- verifies the app-reported database path points at the shadow copy,
- computes the source database fingerprint again and writes
  `real-data-protection.txt`.

The default source is:

```text
~/Library/Application Support/QuotaMonitor/quotamonitor.sqlite
```

To test a different source database:

```sh
QM_QA_REAL_DB_PATH=/path/to/quotamonitor.sqlite ./qa/run-real-data-interactive.sh
```

The app is expected to mutate only the shadow database under the QA home. The
original database is treated as read-only input; if its fingerprint changes
during the run, the script fails before reporting success.

Real-data artifact checks also reject app-side artifacts that contain expanded
real provider paths such as `~/.codex`, `~/.claude`, or `~/.config/claude`.
Those paths can appear in human-facing docs as examples, but not in
`app-state.json`, `qa-config.json`, or `quotamonitor-dev.log`.

Artifact checks also reject Developer Mode logs that show live external-source
activity (`appserver.*`, `ratelimits.poll*`, `claude_usage.poll*`,
`claude_credentials*`, `claude_cli*`, `pricing.refresh_if_stale.refresh`, or
`pricing.litellm_refresh`). Real-data shadow QA is for rendering and manual UI
verification against a copied database, not for refreshing real provider quota
or pricing state.
