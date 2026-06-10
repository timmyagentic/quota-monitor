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

2. Run static checks first. This does not launch `QuotaMonitor.app`:

   ```sh
   ./qa/run-static.sh
   ```

   `./qa/run-all.sh` is an alias for the same static suite. If this fails,
   inspect the failing command before launching any QA app instance.

3. For visible UI work, launch an isolated setup app for Computer Use. The
   setup script prepares artifacts; it is not a separate visible-app test
   layer. For local test-version checks that should resemble the installed app,
   launch real-data shadow QA:

   ```sh
   ./qa/prepare-computer-use-real-data.sh
   ```

   For deterministic fixture smoke walkthroughs, launch:

   ```sh
   ./qa/prepare-computer-use-fixture-smoke.sh
   ```

   `./qa/prepare-computer-use-fixture.sh` is a compatibility wrapper for the
   fixture-smoke command; prefer the explicit name in new docs and reports.

   The real-data path copies the current QuotaMonitor UserDefaults into the isolated QA
   suite without applying product-visible setting overrides. If those
   preferences cannot be copied, use the fixture-smoke setup only when a
   deterministic clean-room check is acceptable.

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

7. After Computer Use, run the printed `cleanup-computer-use.sh` unless the user
   explicitly wants the QA app left open. The cleanup closes only QA-launched
   QuotaMonitor processes and restores `/Applications/QuotaMonitor.app` if it
   was running before the QA launch.

## Boundaries

- Treat `qa-boundary.json` as the source of truth for allowed Computer Use
  actions, QA write roots, disabled live sources, and approval-required actions.
- For real-data shadow runs, verify `real-data-protection.txt` contains
  `source_unchanged=true`.
- For real-data shadow runs, inspect `user-defaults-shadow.txt`; the normal
  realistic path should show `copied_user_defaults=true` and
  `safety_overrides=none` while still keeping credentials not copied.
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
  config argument, then restores the installed app if the run had displaced it.

## Report

Report commands run, artifact directory, exact Computer Use app target,
Computer Use observations by area, failures with screenshot or AX evidence,
untested areas, cleanup state, and whether a real installed QuotaMonitor
process was present/restored.
