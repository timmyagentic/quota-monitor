# Release and Appcast Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a successful GitHub Release from silently lacking a discoverable Sparkle entry, repair brand-aware feed migration, and continuously detect release/feed drift for both QuotaMonitor and CodexMonitor.

**Architecture:** Fail release preflight before external publication when any signing/publishing credential is absent, sign the exact local DMG before uploading that unchanged file, and keep the protected-main Appcast PR gate. Enable the repository setting that permits `GITHUB_TOKEN` to create PRs, add a deterministic feed-health checker plus scheduled workflow, and replace the broad legacy URL rewrite with a pure brand-aware migration resolver.

**Tech Stack:** GitHub Actions, `gh`, Bash, Python 3 unittest/XML parsing, Swift 6/Swift Testing, Sparkle Appcast XML.

## Global Constraints

- Start from the latest `origin/main` in a new worktree `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-release-appcast-reliability` on `codex/release-appcast-reliability`; never edit the primary checkout or `main`.
- QuotaMonitor feed remains `https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml`.
- CodexMonitor feed remains `https://raw.githubusercontent.com/systemoutprintlnnnn/codex-monitor/main/appcast.xml`.
- Missing `SPARKLE_PRIVATE_KEY` or any required publishing credential must fail before either GitHub Release is created.
- The Sparkle signature must be computed over the same DMG bytes uploaded to GitHub Release.
- QuotaMonitor continues to publish Appcast changes through a PR to protected `main`; do not push `main` directly.
- A custom or correct CodexMonitor feed must never be rewritten to the QuotaMonitor feed.
- Scheduled health checks are read-only and must never edit a feed or release.
- Use test-first cycles for scripts and migration logic, update both changelogs, run `./qa/run-static.sh`, and wait for PR CI.

---

## File Structure

**New:**

- `tools/check-update-feed-health.py` — read-only latest-release/Appcast parity and size checker.
- `tools/tests/test_check_update_feed_health.py` — offline parser and error-policy tests.
- `.github/workflows/update-feed-health.yml` — daily/manual two-brand monitor.
- `Tests/QuotaMonitorTests/UserDefaultsMigrationTests.swift` — brand-aware feed migration behavior.

**Modified:**

- `.github/workflows/release.yml` — early secret preflight, pre-upload signing, reliable PR creation comments/ordering.
- `tools/tests/test_developer_id_release.py` — release ordering and failure-policy guardrails.
- `QuotaMonitor/Core/Settings/UserDefaultsMigration.swift` — v2 brand-aware resolver.
- `docs/release.md`, both changelogs — setup, recovery, and user-visible reliability.

## Interfaces

```swift
enum SparkleFeedMigration {
    static func resolvedURL(existing: String?, bundled: String?,
                            appCodeName: String,
                            distributionChannel: String?) -> String?
}
```

```python
@dataclass(frozen=True)
class FeedHealth:
    release_version: str
    appcast_version: str
    appcast_bytes: int
```

The module exports `parse_top_appcast_version(payload: bytes) -> str` and `validate_health(release_tag: str, appcast: bytes, max_bytes: int) -> FeedHealth`; both raise `FeedHealthError` on malformed, mismatched, or oversized input.

---

### Task 1: Make feed migration brand-aware and repeatable

**Files:**

- Create: `Tests/QuotaMonitorTests/UserDefaultsMigrationTests.swift`
- Modify: `QuotaMonitor/Core/Settings/UserDefaultsMigration.swift`

- [ ] **Step 1: Write failing pure resolver tests**

Cover these exact cases:

```swift
#expect(SparkleFeedMigration.resolvedURL(
    existing: "https://raw.githubusercontent.com/systemoutprintlnnnn/quota-monitor/main/appcast.xml",
    bundled: quotaFeed, appCodeName: "QuotaMonitor", distributionChannel: "developer-id") == quotaFeed)
#expect(SparkleFeedMigration.resolvedURL(
    existing: codexFeed, bundled: codexFeed,
    appCodeName: "CodexMonitor", distributionChannel: "developer-id") == codexFeed)
#expect(SparkleFeedMigration.resolvedURL(
    existing: quotaFeed, bundled: codexFeed,
    appCodeName: "CodexMonitor", distributionChannel: "developer-id") == codexFeed)
#expect(SparkleFeedMigration.resolvedURL(
    existing: "https://updates.example.test/custom.xml", bundled: quotaFeed,
    appCodeName: "QuotaMonitor", distributionChannel: "developer-id") == nil)
```

App Store returns nil and never writes `SUFeedURL`.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter UserDefaultsMigrationTests`.
Expected: compile failure because `SparkleFeedMigration` does not exist.

- [ ] **Step 3: Implement resolver and v2 migration key**

Replace the broad `contains("systemoutprintlnnnn")` condition. Use `app.updaterFeedMigrationV2Done`, the bundled feed as the target, exact allowlists for the two known QuotaMonitor URLs, and a CodexMonitor repair rule that converts the accidentally stored QuotaMonitor URL back to its bundled CodexMonitor URL. Preserve arbitrary custom URLs.

- [ ] **Step 4: Add UserDefaults integration tests**

Inject suite defaults and explicit bundle metadata into an internal migration entry point so tests prove the v2 guard is written once and no production domain is touched.

- [ ] **Step 5: Confirm GREEN and commit**

Run the suite and commit with `Make Sparkle feed migration brand-aware`.

### Task 2: Fail before publication and sign before upload

**Files:**

- Modify: `tools/tests/test_developer_id_release.py`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Write failing workflow-structure tests**

Assert the workflow contains a shared `Validate required release secrets` step before either release job can create a release, the missing-key warning/`skip=true` branches are gone, and within each brand job the `Sign release DMG + build appcast entry` step appears before `Create GitHub Release`.

```python
self.assertNotIn("skipping appcast signing", workflow.lower())
self.assertLess(workflow.index("Validate required release secrets"),
                workflow.index("Create GitHub Release"))
self.assertLess(workflow.index("Sign release DMG + build appcast entry"),
                workflow.index("Create GitHub Release"))
```

- [ ] **Step 2: Confirm RED**

Run `python3 -m unittest tools.tests.test_developer_id_release`.
Expected: assertions fail under warning-and-skip ordering.

- [ ] **Step 3: Add early secret preflight**

In the shared `test` job, export required secrets and fail with one error per missing name:

```bash
required=(DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD \
          APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD \
          SPARKLE_PRIVATE_KEY CODEX_MONITOR_PAT)
missing=0
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::required release secret ${name} is missing"
    missing=1
  fi
done
exit "${missing}"
```

- [ ] **Step 4: Reorder signing and upload**

Run `verify-signing-key.sh` and `release-sparkle.sh` against the completed/notarized DMG, then upload that unchanged path with `gh release create`. Keep the generated item and linked notes for the later Appcast PR/push step. Apply the same ordering to CodexMonitor.

- [ ] **Step 5: Confirm GREEN and commit**

Run the Python suite and commit with `Fail releases before an Appcast can be skipped`.

### Task 3: Restore automatic Appcast PR creation

**Files:**

- Modify: `docs/release.md`

- [ ] **Step 1: Record the live repository setting**

Run:

```bash
gh api repos/timmyagentic/quota-monitor/actions/permissions/workflow
```

Expected pre-change evidence: `can_approve_pull_request_reviews` is `false`.

- [ ] **Step 2: Enable Actions PR creation without broadening default token access**

Run the authenticated admin update while preserving read defaults:

```bash
gh api --method PUT repos/timmyagentic/quota-monitor/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

Re-read the endpoint and require `default_workflow_permissions=read` plus `can_approve_pull_request_reviews=true`.

- [ ] **Step 3: Document the required setting and recovery path**

Add the exact settings/API check to `docs/release.md`; document that a pushed `appcast/vX.Y.Z` branch can be used to recover if PR creation fails after the Release exists.

- [ ] **Step 4: Commit**

Commit the documentation with `Document Appcast PR repository permissions`.

### Task 4: Add an offline-tested release/feed health checker

**Files:**

- Create: `tools/check-update-feed-health.py`
- Create: `tools/tests/test_check_update_feed_health.py`

- [ ] **Step 1: Write failing parser/policy tests**

Use byte fixtures to prove the first `<item>` version is selected, `v0.2.40` normalizes to `0.2.40`, malformed/empty XML fails, mismatched release/feed versions fail, and payloads over the configured byte ceiling fail.

- [ ] **Step 2: Confirm RED**

Run `python3 -m unittest tools.tests.test_check_update_feed_health`.
Expected: import failure because the checker is absent.

- [ ] **Step 3: Implement the checker**

Use only Python stdlib (`argparse`, `json`, `urllib.request`, `xml.etree.ElementTree`). Network mode reads GitHub's latest-release API with an optional bearer token, downloads the feed with a bounded response read, validates parity/size, and prints one compact JSON result. Never mutate GitHub.

- [ ] **Step 4: Confirm GREEN and commit**

Run the test module and commit with `Add Sparkle release feed health checks`.

### Task 5: Monitor both brands and slim the legacy CodexMonitor feed

**Files:**

- Create: `.github/workflows/update-feed-health.yml`
- Create: `tools/slim-legacy-appcast.py`
- Create: `tools/tests/test_slim_legacy_appcast.py`
- Modify: `tools/tests/test_developer_id_release.py`
- Modify: `docs/release.md`

- [ ] **Step 1: Write failing workflow guard tests**

Assert a scheduled plus manual workflow calls the checker for both repo/feed pairs, uses `permissions: contents: read`, and supplies a 100,000-byte maximum.

- [ ] **Step 2: Write a failing legacy-feed slimming test**

Feed a two-item fixture with large CDATA `<description>` elements to `slim_feed(payload: str) -> str`. Assert descriptions are removed, item order, versions, enclosure URLs, lengths, and `sparkle:edSignature` values are byte-for-byte preserved, the result parses as XML, and a second pass is identical.

- [ ] **Step 3: Implement the focused slimming tool**

Use a bounded regular expression only for complete `<description>...</description>` elements, then validate the result with `xml.etree.ElementTree.fromstring`. The CLI accepts input/output paths, refuses in-place overwrite without `--in-place`, and writes UTF-8 only after validation.

- [ ] **Step 4: Add the read-only workflow**

Run daily and on `workflow_dispatch`; use a two-row matrix for QuotaMonitor and CodexMonitor. A mismatch or oversized feed fails the run so repository notifications surface it.

- [ ] **Step 5: Perform the one-time CodexMonitor feed cleanup**

Clone `systemoutprintlnnnn/codex-monitor` into a temporary directory, record `shasum -a 256 appcast.xml`, run `python3 tools/slim-legacy-appcast.py --in-place <clone>/appcast.xml`, require valid XML and size under 100 KB, commit, and push through that repository's normal protected/unprotected policy. Re-fetch the live raw feed and confirm the latest version remains unchanged.

- [ ] **Step 6: Confirm GREEN and commit**

Run `python3 -m unittest tools.tests.test_slim_legacy_appcast` plus all tooling tests and commit repository changes with `Monitor release and Appcast parity`.

### Task 6: Document and verify release reliability

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`

- [ ] **Step 1: Add bilingual release notes**

English Summary: `Update releases are now checked end to end so a published download cannot quietly disappear from the in-app updater.`

Chinese Summary: `更新发布现在会进行端到端校验，已发布的安装包不会再悄悄缺席于应用内更新。`

Describe brand-aware migration and automated release/feed monitoring under Fixed/Changed without exposing secret names in user-facing Summary copy.

- [ ] **Step 2: Run full gates**

```bash
python3 -m unittest discover tools/tests
swift test --disable-keychain --filter UserDefaultsMigrationTests
./qa/run-static.sh
```

- [ ] **Step 3: Live read-only validation**

Run the checker against both production feed/release pairs and confirm the workflow-permission API still reports read defaults with PR creation enabled.

- [ ] **Step 4: Commit**

Commit remaining files with `Document reliable update publication`.
