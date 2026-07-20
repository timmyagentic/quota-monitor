# Repository Guidelines

## Project Structure & Module Organization

QuotaMonitor is a SwiftPM macOS app. App source lives in `QuotaMonitor/`, grouped by `App/`, `Core/`, and `Features/`. Tests live in `Tests/QuotaMonitorTests/` and use Swift Testing with `@Suite` and `@Test`. Static QA fixtures and shell helpers are under `qa/`; release, changelog, and packaging utilities are under `tools/`, `scripts/`, and `docs/`. User-facing release notes are maintained in both `CHANGELOG.md` and `CHANGELOG.zh-Hans.md`.

## Build, Test, and Development Commands

- `swift test --disable-keychain`: runs the Swift test suite without keychain stalls.
- `swift test --filter SuiteName`: runs targeted tests while iterating.
- `./qa/run-static.sh`: default non-GUI gate; runs shell tests, Python tool tests, release-note validation, `git diff --check`, and Swift tests.
- `./build.sh`: builds and assembles `.build/QuotaMonitor.app` for local use.
- `CONFIG=release ./build.sh`: release-style app build.
- `./tools/make-dmg.sh`: creates the distributable DMG after a release build.

## Coding Style & Naming Conventions

Use Swift 6 with strict concurrency enabled. Keep indentation at four spaces and follow existing local patterns before adding abstractions. Prefer small, focused types named by domain, such as `ClaudeUsagePoller`, `RateLimitsHydrator`, or `MenuBarLabelModel`. Keep comments short and only where they clarify non-obvious behavior.

## Testing Guidelines

Add focused tests beside related suites in `Tests/QuotaMonitorTests/`. Test names should describe behavior, not implementation. For app logic changes, run a targeted `swift test --filter ...` first, then `./qa/run-static.sh` before PR publication.

## Commit & Pull Request Guidelines

History uses concise imperative subjects, often with PR numbers after merge, for example `Split session titles from project metadata (#60)`. For every task, fetch latest `origin/main`, create an independent worktree, and create a `codex/` branch there. Do not edit the primary checkout or `main` directly. Commit, push, and open a PR from that worktree before handoff. Non-appcast PRs must update both changelog files. Include a clear PR summary, verification commands, screenshots for visible UI changes, and linked issues when available.

For visible UI changes, also embed at least one verified post-change screenshot directly in the final user handoff; a PR-only image link is not sufficient. When the user supplies a visual reference or the change spans multiple entry points, prefer a compact comparison board. Capture the exact build and commit being handed off. If a screenshot cannot be produced, state why and report the visual verification completed.

## Security & Configuration Tips

Never commit credentials, keychain data, local history exports, signing keys, or notarization secrets. Keep local QA deterministic; use `LocalQAEnvironment` and `--disable-keychain` paths when tests should avoid external data.
