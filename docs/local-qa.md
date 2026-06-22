# Testing Circuit

QuotaMonitor keeps static checks separate from visible macOS UI validation.
The default local and CI path must not launch a new `QuotaMonitor.app`
instance. Visible behavior is checked by Computer Use against an explicitly
launched, isolated QA build.

## Standard Test Circuit

| Responsibility | Command | Launches app? | What it owns |
| --- | --- | --- | --- |
| Static gate | `./qa/run-static.sh` or `./qa/run-all.sh` | No | Shell/Python helper tests, release-note format, whitespace checks, and Swift tests. |
| Computer Use setup | `./qa/prepare-computer-use-real-data.sh` or `./qa/prepare-computer-use-fixture-smoke.sh` | Yes, isolated QA build only | Build the latest app, prepare real-data-shadow or deterministic fixture-smoke state, verify the artifact boundary, and write the Computer Use brief. |
| Computer Use walkthrough | Computer Use using the exact app target from `computer-use-qa.md` | Uses the running QA build | User-facing Dashboard, Sessions, History, Settings, menu bar, help, and visual checks. |
| Artifact replay | `./qa/check-artifacts.sh .build/qa-artifacts/<timestamp>` | No | Re-check an existing artifact directory without rebuilding or relaunching the app. |

`qa/run-all.sh` is intentionally an alias for the Static gate. It exists so
agents can run the default local suite without starting a GUI app by mistake.

## Commands

Run only the shell harness tests:

```sh
./qa/tests/common_tests.sh
```

Run the Swift test suite:

```sh
swift test --disable-keychain
```

Run the default non-GUI gate:

```sh
./qa/run-static.sh
./qa/run-all.sh
```

Launch the real-data shadow setup and keep it open for Computer Use. Use this
for local test-version checks that should resemble the installed app:

```sh
./qa/prepare-computer-use-real-data.sh
```

Launch the deterministic fixture smoke setup and keep it open for Computer Use.
Use this for fixed-input regression checks:

```sh
./qa/prepare-computer-use-fixture-smoke.sh
```

`./qa/prepare-computer-use-fixture.sh` is kept as a compatibility wrapper for
older instructions; new docs and reports should use `fixture-smoke`.

Re-check a QA artifact directory:

```sh
./qa/check-artifacts.sh .build/qa-artifacts/<timestamp>
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

## Static Gate

`qa/run-static.sh` is the default non-GUI gate. It runs:

- `qa/tests/common_tests.sh`
- Python tests under `tools/tests`
- release-note format validation for `Resources/VERSION`
- `git diff --check`
- `swift test --disable-keychain`

## What Computer Use Setup Prepares

The harness creates a temporary profile and writes `qa-config.json` into the
artifact directory. `script/build_and_run.sh --qa` validates that config file,
base64-encodes it, and launches the app with:

```sh
open .build/QuotaMonitor.app --args --quotamonitor-qa-config-base64 <payload>
```

The app still accepts the older
`--quotamonitor-qa-config <artifact-dir>/qa-config.json` form for focused
debugging, but the normal Computer Use setup path uses the inline config
payload so startup does not depend on app-side file reads from the artifact
volume.

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
environment variables still work for focused unit tests, but the Computer Use
setup path uses command-line config because LaunchServices environment
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

Each Computer Use setup prints an artifact directory under
`.build/qa-artifacts/<timestamp>-computer-use-fixture-smoke/` or
`.build/qa-artifacts/<timestamp>-computer-use-real-data/`. Important files:

- `app-state.json` — app-reported PID, bundle id, database/log paths, visible
  windows, status-item visibility, settings snapshot, and menu-bar totals.
- `qa-boundary.json` — machine-readable QA boundary contract: fixture vs
  real-data-shadow mode, QA write roots, disabled external data sources, and
  Computer Use actions that require explicit approval.
- `db-counts.txt` — provider/session/event/rate-limit counts read from the
  isolated SQLite database.
- `qa-config.json` — launch config passed to the app.
- `quotamonitor-dev.log` — Developer Mode JSONL log for the QA run, present
  only when Developer Mode is enabled in the copied or fixture settings.
- `screen.png` — full-screen screenshot when macOS allows `screencapture`.
- `ax-tree.txt` — Accessibility tree dump for open QuotaMonitor windows.

Before a setup script reports the artifact directory, it asserts the artifact
contract:

- `qa-boundary.json` exists, is valid JSON, matches the expected QA mode, keeps
  app writes under the QA home, disables live external sources, and documents
  Computer Use approval boundaries.
- `app-state.json` is valid JSON and contains Dashboard and Settings windows.
- `app-state.json` includes the `exercise-settings` step and the expected
  settings snapshot.
- `db-counts.txt` includes Codex, Claude, and both primary/secondary JSONL
  rate-limit samples.
- For fixture artifacts, `quotamonitor-dev.log` includes `qa.settings.exercise`
  and `qa.snapshot.write`. Real-data artifacts keep the log optional so copied
  installed settings are not changed just to produce diagnostics.
- `screen.png` and `ax-tree.txt` are nonempty when available; if macOS denies
  Screen Recording or Accessibility, the harness writes a warning file instead.

If the AX dump is required, run:

```sh
QM_QA_REQUIRE_AX=1 ./qa/prepare-computer-use-fixture-smoke.sh
```

Grant Accessibility permission to the terminal/Codex host app if this fails.

## Fixture Data

Codex fixture data comes from:

```text
qa/fixtures/qa-codex-session.jsonl
qa/fixtures/qa-codex-project-only.jsonl
```

Claude fixture data comes from:

```text
qa/fixtures/qa-claude-session.jsonl
qa/fixtures/qa-claude-project-only.jsonl
```

The expected isolated import result is at least two Codex sessions, two Claude
sessions, usage events for both providers, and Codex JSONL rate-limit samples.
For session-title screenshots, search `Show Codex reset cards` to see a real
session title and `billing-api` to see the project-name fallback row.

## Computer Use QA

`qa/prepare-computer-use-fixture-smoke.sh` sets up an isolated fixture smoke
run and keeps the app open. It writes a per-run `computer-use-qa.md` brief into
the artifact directory, keeps the latest local build open, and prints a cleanup
script path. The brief includes the exact `.app` path to pass to Computer Use;
use that path instead of the bare `QuotaMonitor` app name so the agent does not
attach to a separately installed copy.

Run the printed cleanup script after the Computer Use pass unless the QA app
should intentionally stay open. The cleanup script closes only QA-launched
processes and restores `/Applications/QuotaMonitor.app` if it was already
running before the QA launch.

Use this after `qa/run-static.sh` when the change needs a deterministic
fixed-input UI smoke. For installed-like local test-version checks, prefer
real-data shadow QA. See `docs/computer-qa.md` for the expected Computer Use
checklist.

## Real Data Shadow QA

`qa/prepare-computer-use-real-data.sh` is the default setup path for checking
how the latest local build renders the user's real historical QuotaMonitor data
without letting the app touch the original profile.

The script:

- computes a fingerprint for the source database,
- copies the source database with SQLite backup into a temporary QA home,
- copies the current QuotaMonitor UserDefaults into the isolated QA suite,
- launches the app with that temporary HOME, an isolated UserDefaults suite,
  and `CODEX_HOME` inside the QA home,
- does not copy real Codex or Claude credentials,
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
QM_QA_REAL_DB_PATH=/path/to/quotamonitor.sqlite ./qa/prepare-computer-use-real-data.sh
```

Real-data shadow QA copies the current `dev.tjzhou.QuotaMonitor` preferences
into the QA defaults suite without applying product-setting overrides. Visible
state therefore matches the installed app's language, provider, menu-bar, quota
display, window preferences, Claude credential mode, Developer Mode, and
credential-mirroring setting. If those preferences cannot be copied, the script
fails instead of falling back to deterministic QA defaults. Use
`./qa/prepare-computer-use-fixture-smoke.sh` when deterministic fixture settings are
more useful than the installed app's visible configuration.

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
