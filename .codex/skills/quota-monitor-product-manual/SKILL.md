---
name: quota-monitor-product-manual
description: Use when creating or updating QuotaMonitor's user-facing product manual from the current commit, including running the app, capturing screenshots, mapping UI flows, and appending durable documentation.
---

# QuotaMonitor Product Manual

Use this skill from the current `quota-monitor` checkout root when the user asks for product documentation, feature explanation, screenshot-based user docs, or continuing updates to `docs/product-manual.md`.

## Workflow

1. Confirm repo state.
   - Run `git status --short --branch`.
   - Record `git rev-parse --short HEAD` and `Resources/VERSION`.
   - Do not remove unrelated dirty files.

2. Read the current UI surface.
   - Inspect `QuotaMonitor/Features/**`, `QuotaMonitor/App/**`, and `QuotaMonitor/Core/Localization/L10n.swift` for user-visible pages, buttons, labels, and conditional states.
   - Start from these surfaces: onboarding, menu-bar popover, Dashboard, History, Sessions, Settings General, Settings Advanced, menu-bar help, update window, and uninstall confirmation.

3. Verify with the real app.
   - Run `./qa/run-static.sh` first.
   - Launch visible QA with `./qa/prepare-computer-use-fixture.sh`.
   - Read the printed `computer-use-qa.md`, `app-state.json`, `qa-boundary.json`, and `db-counts.txt`.
   - Run `./qa/check-artifacts.sh <artifact-dir>`.
   - Use the exact Computer Use app target from the brief. Do not target bare `QuotaMonitor` when an installed app is also running.

4. Capture screenshots.
   - Save durable documentation screenshots under `docs/assets/product-manual/<commit>/`.
   - Prefer window-level screenshots using CoreGraphics window IDs or `screencapture -l` so Codex or other desktop windows do not cover the app.
   - Capture changed or important states, not every possible scroll position.

5. Write or update `docs/product-manual.md`.
   - Write for ordinary users in concise Chinese unless the user asks for another language.
   - Explain what each main page is for, where to click, what buttons do, and what changes after clicking.
   - Avoid implementation details in user-facing sections.
   - Put commands, commit IDs, QA artifact paths, and test evidence only in a maintenance/update-record section.
   - Append future changes to the update log instead of replacing history.

6. Clean up and verify.
   - Run the printed `cleanup-computer-use.sh` unless the user asks to keep the QA app open.
   - Check `pgrep -fl QuotaMonitor` and distinguish the installed app from QA-launched processes.
   - Run `git diff --check`.
   - Review `git diff -- docs/product-manual.md .codex/skills/quota-monitor-product-manual/SKILL.md`.

## Boundaries

- Do not use real Codex or Claude credentials in QA.
- Ask before clicking destructive or external-side-effect actions: uninstall, export CSV, reveal files, sync pricing, check updates, changing system settings, or transmitting credentials.
- If a page cannot be safely exercised, document the expected user-facing behavior from source and mark the evidence source in the maintenance record.
