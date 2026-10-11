# Cloud development contract

Use a clean checkout with Git, Bash, Python 3.10+ and Node 22 LTS (at least
22.12), npm, and network access to the public npm registry during setup:

```sh
./qa/bootstrap-cloud.sh
./qa/run-cloud.sh
```

Bootstrap installs only the locked website dependencies with `npm ci` and is
safe to rerun. No Swift SDK, global packages, GitHub token, Cloudflare login,
Keychain export, signing identity or production data is needed. Cache, config
and Wrangler logs go under ignored `.build/cloud/`; HOME is never changed.
Use the same bootstrap as the environment maintenance command after a cache
restore. Re-run it when the lockfile changes. Setup needs internet; website
checks start local workerd processes and require loopback networking.

The check runs Python tool tests (platform-specific tests explicitly skip on
Linux), release-note/whitespace checks, TypeScript and website unit tests,
local D1 migrations/integration tests, and the existing Worker bundle dry run
and startup profile. D1 tests use Miniflare fixture bindings; no remote database
is used. No cloud credentials are configured, and website `.env*`/`.dev.vars*`
files are rejected. This is a development checkout, not a publishing host.

## Evidence required before delivery

Linux can edit Swift but cannot compile this AppKit/SwiftUI app. The portable
check never writes the Swift static-gate success stamp. Existing macOS
contributors must still run `./qa/run-static.sh` immediately before commit/push.
Linux contributors may push after the portable check and open a **ready** PR;
the PR is awaiting macOS verification until all of the following are true:

1. The current PR head equals the full SHA being handed off.
2. The latest `tests.yml` pull-request run for that SHA succeeded.
3. Its real `macOS Swift tests` job ran on `macos-15`, with successful
   `static QA checks` and `swift build -c release (smoke)` steps.
4. Its `Cloud development checks` job and both entrypoint steps succeeded.

The macOS job explicitly checks out the PR head, not GitHub's synthetic merge
commit. A Draft skip or green `swift-test` summary is insufficient. Using an
already authorized GitHub CLI outside the credential-free environment:

```sh
python3 tools/verify-cloud-pr.py PR_NUMBER FULL_HEAD_SHA
```

The helper is read-only, fails closed on pending/skipped/stale results, and
rechecks the PR head after collecting jobs. It does not merge. CI success
proves the GitHub runner checks, not a separate Codex cloud environment's cold
start; record that environment's bootstrap/check output and SHA separately.

## GUI and release limits

`python3 qa/run.py --data fixture --view dashboard --seconds 10` supports a bounded isolated fixture launch and app-state readiness check, but
visible app execution requires a macOS graphical session. Its readiness check alone is not visible GUI acceptance. The historical fixture-smoke shell
entrypoint mentioned in CLAUDE.md is absent from this checkout. Keep GUI
acceptance UNVERIFIED until a macOS fixture run and visible walkthrough are
performed. The cloud job does not launch or claim to test the GUI.

Private Beta, mirror upload, signing/notarization and production publication
remain on their existing authorized release path. Their local Keychain,
Wrangler/admin credentials must not migrate here. A website bundle dry run is
not a release dry run and does not validate those credentials or publishing.
