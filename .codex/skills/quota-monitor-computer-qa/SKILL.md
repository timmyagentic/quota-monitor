---
name: quota-monitor-computer-qa
description: Use when testing QuotaMonitor macOS app changes, validating local QA artifacts, or performing Computer Use walkthroughs in this repo.
---

# QuotaMonitor Computer QA

Use this project skill for QuotaMonitor local QA and visible-behavior checks in
`/Volumes/SamsungDisk/Code/quota-monitor`.

## Workflow

1. Confirm branch and dirty state:

   ```sh
   git status --short --branch
   ```

2. Run deterministic checks first:

   ```sh
   ./qa/run-all.sh
   ```

   If this fails, inspect the failing command and artifact before using
   Computer Use.

3. For fixture UI walkthroughs, launch:

   ```sh
   ./qa/run-interactive.sh
   ```

   For realistic historical rendering with protected source data, launch:

   ```sh
   ./qa/run-real-data-interactive.sh
   ```

4. Open the run's `computer-use-qa.md` and use its `Computer Use app target`
   exactly. Do not target by bare name `QuotaMonitor` or only by bundle id:
   this machine can also have `/Applications/QuotaMonitor.app` running.

5. Use Computer Use on the exact `.app` path from the brief:
   - Dashboard: Forecast, Trends, Composition.
   - Sessions: search, sort, detail, token/cost/event rows.
   - History: day selection, rollups, per-session details.
   - Settings: General and Advanced controls, excluding destructive actions.
   - Menu bar: popover, provider display, navigation buttons.
   - Menu-bar help: readability and close behavior.
   - Visual pass: clipping, overlaps, blank charts, missing icons.

6. Re-check the artifact contract:

   ```sh
   ./qa/check-artifacts.sh <artifact-dir>
   ```

7. Clean up with the printed `cleanup-interactive.sh` unless the user wants the
   QA app left open.

## Boundaries

- Treat `qa-boundary.json` as the source of truth for allowed Computer Use
  actions, QA write roots, disabled live sources, and approval-required actions.
- For real-data shadow runs, verify `real-data-protection.txt` contains
  `source_unchanged=true`.
- Do not use real Codex or Claude credentials.
- Ask before uninstall, export CSV, reveal files, sync pricing, check updates,
  changing system settings, accepting permission prompts, uploading files, or
  transmitting credentials.
- `screen.png` is a full-screen artifact and may show another foreground app.
  Use Computer Use state plus `app-state.json` and `ax-tree.txt` as primary UI
  evidence.

## Troubleshooting

- If Computer Use returns `noWindowsAvailable`, re-check `app-state.json`, use
  the exact app target from the brief, and activate or raise the QA window before
  treating it as a product failure.
- If artifacts show `appserver.*`, `ratelimits.poll*`, `claude_usage.poll*`,
  `claude_credentials*`, `claude_cli*`, or `pricing.litellm_refresh`, treat the
  run as a QA boundary failure.
- If an installed QuotaMonitor process is also running, do not kill it while
  cleaning up QA. The QA cleanup targets only processes launched with the QA
  config argument.

## Report

Report commands run, artifact directory, exact Computer Use app target,
Computer Use observations by area, failures with screenshot or AX evidence,
untested areas, cleanup state, and whether a real installed QuotaMonitor
process was present.
