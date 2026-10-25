# Repository Guidelines

## Project Structure & Module Organization

QuotaMonitor is a SwiftPM macOS app. App source lives in `QuotaMonitor/`, grouped by `App/`, `Core/`, and `Features/`. Tests live in `Tests/QuotaMonitorTests/` and use Swift Testing with `@Suite` and `@Test`. Local QA fixtures and launch helpers are under `qa/`; release, changelog, and packaging utilities are under `tools/`, `scripts/`, and `docs/`. User-facing release notes are maintained in both `CHANGELOG.md` and `CHANGELOG.zh-Hans.md`.

## Build, Test, and Development Commands

- `swift test --disable-keychain --filter SuiteName`: runs only an affected suite while iterating.
- `./qa/run-static.sh`: final non-GUI PR gate; runs shell/Python checks, release-note validation, `git diff --check`, and the Swift suite. Passing Swift output is summarized and its full log is saved under `.build/qa-logs/`.
- `./qa/run-static.sh --force`: bypasses Swift-result reuse. CI uses this; local iteration normally should not.
- `./qa/run.py --view <target>`: launches one isolated UI target; exits cleanly with the QA app or Ctrl-C. Use `--data snapshot` only when copied local history is relevant.
- `./build.sh`: builds and assembles `.build/QuotaMonitor.app` for local use.
- `CONFIG=release ./build.sh`: release-style app build.
- `./tools/make-dmg.sh`: creates the distributable DMG after a release build.

## Coding Style & Naming Conventions

Use Swift 6 with strict concurrency enabled. Keep indentation at four spaces and follow existing local patterns before adding abstractions. Prefer small, focused types named by domain, such as `ClaudeUsagePoller`, `RateLimitsHydrator`, or `MenuBarLabelModel`. Keep comments short and only where they clarify non-obvious behavior.

## Testing Guidelines

Add focused tests beside related suites in `Tests/QuotaMonitorTests/`. Test names should describe behavior, not implementation. During Codex iteration, run only the smallest affected suite or suites; do not run an unfiltered `swift test` before the final gate. Once code, tests, and QA scripts are stable, run `./qa/run-static.sh` once for that PR candidate immediately before commit/push. Do not run a separate `git diff --check` alongside it, because the gate already owns that check, and do not rerun the gate merely to collect another log.

`qa/run-static.sh` always reruns the inexpensive shell, Python, release-note, and whitespace checks. It reuses a passing Swift-suite result when the current code/test/QA/tool inputs and Swift toolchain have the same content fingerprint, independent of staging or committing. Changes under source, tests, `qa/`, build/tool scripts, package metadata, or bundled resources invalidate that result; documentation and changelog-only edits do not invalidate Swift tests but still receive their lightweight checks. Use `--force` only when a genuinely fresh full suite is required. Historical plans and execution records are evidence, not permission to restore redundant full-test sequences.

## Commit & Pull Request Guidelines

For UI verification, follow `docs/local-qa.md` and the checked-in `.codex/skills/quota-monitor-computer-qa/SKILL.md`. Inspect only affected behavior; do not restore the retired full-window tour, artifact checker, or compatibility launchers from older global skills or historical plans.

History uses concise imperative subjects, often with PR numbers after merge, for example `Split session titles from project metadata (#60)`. For every task, fetch latest `origin/main`, create an independent worktree, and create a `codex/` branch there. Do not edit the primary checkout or `main` directly. Commit, push, and open a PR from that worktree before handoff. Non-appcast PRs must update both changelog files. Include a clear PR summary, verification commands, screenshots for visible UI changes, and linked issues when available.

For visible UI changes, also embed at least one verified post-change screenshot directly in the final user handoff; a PR-only image link is not sufficient. When the user supplies a visual reference or the change spans multiple entry points, prefer a compact comparison board. Capture the exact build and commit being handed off. If a screenshot cannot be produced, state why and report the visual verification completed.

## Security & Configuration Tips

Never commit credentials, keychain data, local history exports, signing keys, or notarization secrets. Keep local QA deterministic; use `LocalQAEnvironment` and `--disable-keychain` paths when tests should avoid external data.

## Cloud development exception

Linux contributors may edit Swift and run `./qa/bootstrap-cloud.sh` followed by `./qa/run-cloud.sh` before commit/push instead of the macOS-only static gate. This exception permits opening a ready PR, not claiming full verification. Delivery/merge requires the same PR head SHA to pass the real `macOS Swift tests` job (static QA plus release build) and `Cloud development checks`; verify with `python3 tools/verify-cloud-pr.py <PR> <full-head-SHA>`. Draft skips and the `swift-test` summary alone are not proof. macOS contributors retain the existing `./qa/run-static.sh` pre-push gate. See `docs/cloud-development.md` for the complete contract and GUI/release limits.

## Repository workflow and branch protection

- Confirm the current GitHub default branch before starting; it is currently `main`. Fetch it, use a separate `codex/` branch in an isolated worktree, and keep the primary checkout read-only. Under Tingjun Workspace, activate the Task and Session, acknowledge the current Context revision and hold the worktree's unique writer claim.
- All changes to the GitHub default branch must go through a PR. Direct pushes, force pushes and deletion of that branch are prohibited. Administrators and apps have no bypass. Never use `--admin`, disable protection or add a bypass actor to land a change.
- Only squash merging is allowed. Inspect the final diff, current head, review threads and actual verification results before an authorized merge. Resolve all review conversations and address substantive findings; zero mandatory approvals supports the single-maintainer workflow. Merge with `gh pr merge <PR> --squash --match-head-commit <verified-full-head-SHA>` and verify the merged state afterward.
- Keep `delete_branch_on_merge = true` and verify that GitHub automatically removes the merged PR's remote task branch when eligible. Do not use `--delete-branch`, which also removes the local branch. Under Tingjun Workspace, completion only releases the writer claim; local branches and worktrees remain for the existing archive workflow.
- The default-branch ruleset declaration is [`.github/rulesets/default-branch.json`](.github/rulesets/default-branch.json); repository merge and deletion settings are declared in [`.github/repository-settings.json`](.github/repository-settings.json). These files do not apply themselves. After an authorized configuration update, read back the GitHub repository settings, effective rules and any classic branch protection. Protect the actual default branch rather than assuming it is named `main`.
- Preserve the existing CI workflows, trigger conditions, required checks, app bindings and strictness. Existing stronger protections and immutable release tags remain in force. An empty or legitimately path-filtered checks list does not prove application tests passed; report the checks actually run and mark unavailable verification `UNVERIFIED`. Follow this repository's existing verification requirements and use proportionate document/configuration checks for documentation changes.
