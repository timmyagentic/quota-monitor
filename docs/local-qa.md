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
artifact directory. `script/build_and_run.sh --qa` launches the app with:

```sh
open .build/QuotaMonitor.app --args --quotamonitor-qa-config <artifact-dir>/qa-config.json
```

The config includes:

- `mode=true`
- `home=<temp profile>`
- `defaultsSuite=<unique suite>`
- `codexHome=<temp profile>/.codex`
- `outputDirectory=<artifact directory>`
- `steps=[...]`

The app uses the config `home` for its SQLite database and Developer Mode log.
It uses `defaultsSuite` for settings and localization, so the harness does not
read or overwrite the normal `dev.tjzhou.QuotaMonitor` preferences domain. The
older `QUOTAMONITOR_QA_*` environment variables still work for focused unit
tests, but the end-to-end launch path uses command-line config because
LaunchServices environment propagation is not reliable for GUI app launches.

The default QA steps are:

```text
open-dashboard,open-settings,open-menubar-help,show-popover,refresh-all,wait,snapshot
```

In QA mode, `refresh-all` is local-only: it runs the importer and UI refreshes
without contacting the live Codex app-server or Claude OAuth endpoint.

## Artifacts

Each `qa/run-local.sh` run prints an artifact directory under
`.build/qa-artifacts/<timestamp>/`. Important files:

- `app-state.json` — app-reported PID, bundle id, database/log paths, visible
  windows, status-item visibility, and menu-bar totals.
- `db-counts.txt` — provider/session/event/rate-limit counts read from the
  isolated SQLite database.
- `qa-config.json` — launch config passed to the app.
- `quotamonitor-dev.log` — Developer Mode JSONL log for the QA run.
- `screen.png` — full-screen screenshot when macOS allows `screencapture`.
- `ax-tree.txt` — Accessibility tree dump for open QuotaMonitor windows.

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
