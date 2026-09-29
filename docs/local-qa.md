# Local verification

Run the affected unit tests while changing code. Once the candidate is stable,
run `./qa/run-static.sh` once before committing. It checks the static-gate
helpers, Python tools, release notes, whitespace, and Swift tests. Passing Swift
results are reused only when the source/toolchain fingerprint matches; CI uses
`--force`. Static checks never launch a GUI app.

For UI changes, use one launcher and inspect only the affected behavior:

```sh
./qa/run.py --view settings
./qa/run.py --view widget --language zh-Hans
./qa/run.py --data snapshot --view dashboard
```

`--view` accepts `dashboard` (default), `settings`,
`popover`, `widget`, `permissions`, or `whats-new`. Each run opens only that
target; it does not exercise unrelated settings or require a full app tour.
History and Sessions are tabs inside the dashboard window; navigate to the
affected tab during the walkthrough. The widget preview uses a synthetic host and cannot certify real Codex window
tracking or physical dragging.

The default `--data fixture` uses synthetic histories and quota. `--data snapshot`
uses SQLite's read-only backup API to copy the installed QuotaMonitor database,
including committed WAL data, and copies its product settings. It never copies
Codex/Claude credentials or provider directories. Use snapshot mode only when
real local data is relevant to the change; the copy is private local data.

The launcher builds this worktree and creates a temporary app with a unique
bundle ID, preferences suite, and database. The app's existing QA isolation
blocks live provider requests, Keychain access, login registration, and update
checks. A small readiness check verifies the owned PID, bundle ID, and database
path; it makes no claim that the UI works. The installed app keeps running.

Keep the launcher running during the walkthrough. Use the exact app path it
prints when selecting the app in Computer Use. Quit the QA app, press Ctrl-C,
or use `--seconds 10` for a bounded launch smoke check. The launcher stops only
its own child and removes its temporary profile and preferences on normal exit,
interruption, or failure. `--no-build` can reuse the same worktree's current
build for a second target; rebuild after source changes.

Record the behavior checked, build/commit, result, and any untested behavior in
the PR. Save a screenshot when it helps demonstrate a visible change, before
exiting the launcher. There is no required report bundle, AX dump, full-screen
capture, generated walkthrough, or separate artifact-validation command.

Release signing, notarization, Sparkle signatures, feed verification, and
installation checks remain in the release workflow. They are not everyday UI
QA requirements. Commands in historical plans and evidence describe their
original runs; this document is the current workflow.
