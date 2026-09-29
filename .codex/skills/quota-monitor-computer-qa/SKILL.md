---
name: quota-monitor-computer-qa
description: Verify the affected QuotaMonitor macOS UI in an isolated local build.
---

# QuotaMonitor UI verification

Use the current worktree and [local verification guide](../../../docs/local-qa.md).

1. While editing, run affected tests. Before delivery, run `./qa/run-static.sh`
   once; accept its matching Swift-result cache. Do not duplicate the full gate.
2. If the change affects UI, start `./qa/run.py --view <target>`. Choose fixture
   data by default; use `--data snapshot` only when local history is relevant.
3. Select the exact printed QA app path in Computer Use. Verify the changed
   behavior and its immediate effects; do not require unrelated screens.
4. Capture a screenshot when needed for the visible change. A ready app or
   `app-state.json` does not prove UI acceptance; report any untested behavior.
5. Quit the QA app or interrupt the launcher. It removes its own app/profile and
   preferences and leaves the installed application running.

Keep real credentials out of QA. Data isolation and disabling external requests
remain mandatory. Widget fixture checks do not establish external-host tracking
or physical-drag behavior. Do not change system settings or accept permission
prompts without user authorization.
