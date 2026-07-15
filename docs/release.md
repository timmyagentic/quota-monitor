# Release workflow

QuotaMonitor ships outside the Mac App Store as a Developer ID signed and
notarized DMG, with updates delivered through the existing self-hosted Sparkle
appcast. Every release follows the same handful of steps. **One-time setup** is
at the bottom — do that first.

---

## Compatibility contract for existing installs

Existing users can update directly as long as we preserve the identity that
Sparkle already trusts:

- Keep `Resources/Info.plist` `SUPublicEDKey` unchanged unless you are doing a
  deliberate Sparkle key-rotation release.
- Keep using the same `SPARKLE_PRIVATE_KEY` GitHub secret that matches that
  public key.
- Keep `SUFeedURL`, `CFBundleIdentifier`, and the semver `CFBundleVersion` /
  `sparkle:version` path stable.

Apple Developer ID signing is a separate layer from Sparkle's Ed25519 update
signature. Moving the release artifact from ad-hoc signing to Developer ID
signing/notarization does not require old users to reinstall, provided the
first Developer ID release is still signed into the same appcast with the same
Sparkle key.

## Why CI signs the appcast (read this first)

The appcast `sparkle:edSignature` is an Ed25519 signature over the **exact
DMG bytes** Sparkle downloads — and Sparkle downloads the DMG attached to the
GitHub Release, which `release.yml` **builds on its own runner**. A macOS DMG
is not byte-reproducible (HFS timestamps, compression, the code-sign seal), so
a DMG you build locally is **not** the same file CI publishes. Signing the
local DMG and pasting that signature into `appcast.xml` therefore produces a
signature that does not match what users download → Sparkle rejects every
update as *"improperly signed."* (This is exactly what broke 0.2.26/0.2.27.)

So **Sparkle signing still happens in CI, over the published DMG**, after the
DMG has been Developer ID signed, notarized, stapled, and uploaded. CI opens the
appcast PR for you. You no longer paste an appcast entry by hand on the happy
path. `tools/release-sparkle.sh` still exists as a manual fallback (see the
bottom of this doc).

## Per-release checklist

1. **Bump version**: edit `Resources/VERSION` to the new `X.Y.Z` unless the
   version was already bumped during the release-prep patch.
2. **Update docs + release notes**:
   - `CHANGELOG.md` must contain a `## [X.Y.Z] — YYYY-MM-DD` section because
     the English Sparkle release notes are extracted from that exact heading.
   - `CHANGELOG.zh-Hans.md` must contain a matching `## [X.Y.Z]` section — the
     Simplified-Chinese release notes come from there. Release notes are
     **fixed bilingual**: `release-sparkle.sh` aborts if this section is
     missing, so don't skip it. Keep each `- ` bullet on a single physical
     line in the Chinese file (the markdown→HTML joiner glues wrapped lines
     with a space, which would inject stray spaces between Chinese
     characters).
   - Every PR after the previous tag should first update `## [Unreleased]`.
     During release prep, move those entries into the new `## [X.Y.Z]` section
     and leave a fresh empty `## [Unreleased]` for future PRs.
     Pull-request CI enforces the bilingual changelog update for non-appcast
     PRs; the generated `appcast/vX.Y.Z` PR is exempt because it only publishes
     the release notes from the release PR.
   - Each release section must begin with `#### Summary`: 1-4 short bullets
     written for the update window. Keep the always-visible Summary focused on
     what changed and why it matters to a non-technical user. Do not mention
     implementation details, AppKit/SwiftUI/WebKit, QA, PR checks, CI,
     artifacts, appcast, signing, notarization, or release workflow plumbing in
     Summary.
   - Detail sections must use the standard headings (`Added`, `Changed`,
     `Fixed`, `Removed`, `Known limitation(s)` / `新增`, `变更`, `修复`, `移除`,
     `已知限制`) and bullets shaped as `**Short title.** One concise sentence.`
     The generated Sparkle update window renders only the Summary as a rich
     visual card layout; the detail sections remain in GitHub Release notes and
     in optional richer HTML notes.
   - Before opening the release PR, run:
     ```sh
     python3 tools/validate-release-notes.py X.Y.Z
     ```
   - Optional richer notes: `ReleaseNotes/X.Y.Z.en.html` +
     `ReleaseNotes/X.Y.Z.zh-Hans.html` override the changelog-derived HTML if
     present.
   - `README.md`, `docs/findings.md`, and `docs/parity.md` should reflect any
     changed user-visible behavior or important support boundaries.
3. **Local sanity build** (optional but recommended):
   ```sh
   QM_RELEASE_SIGNING=developer-id ./tools/release.sh
   ```
   This runs tests, builds the release bundle, Developer ID signs/notarizes and
   staples the `.app`, creates `dist/QuotaMonitor-X.Y.Z.dmg`, signs and
   notarizes/staples the DMG, writes the `.sha256`, mounts the DMG, and verifies
   the app inside it. **Do not sign or edit `appcast.xml` from this build** —
   CI signs the DMG it publishes (see the section above).

   Without `QM_RELEASE_SIGNING=developer-id`, `tools/release.sh` uses `auto`: it
   makes a Developer ID release if the local machine has both a Developer ID
   identity and notary credentials; otherwise it falls back to a local/ad-hoc
   artifact for smoke testing only.
   > **`main` is protected.** A GitHub ruleset requires every change to
   > `main` to land through a pull request — `git push origin main` is
   > rejected server-side. So the release commits go on a branch and merge
   > via PR (step 4). Tags are *not* branch-protected, so the tag push in
   > step 5 still works directly.
4. **Commit on a release branch, then PR + merge** (the ruleset requires 0
   approvals, so you can self-merge). Note `appcast.xml` is **not** in this
   commit — CI updates it after the build:
   ```sh
   git switch -c release/vX.Y.Z
   git add Resources/VERSION CHANGELOG.md CHANGELOG.zh-Hans.md README.md docs ReleaseNotes
   git commit -m "Release vX.Y.Z"
   git push -u origin release/vX.Y.Z
   gh pr create --base main --title "Release vX.Y.Z" --fill
   gh pr merge --squash --delete-branch    # or --merge
   ```
5. **Tag** (run from `main` after the merge so the tag points at the
   released commit):
   ```sh
   git switch main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
   The tag push triggers `.github/workflows/release.yml`, which:
   1. imports the Developer ID certificate from GitHub secrets;
   2. rebuilds from the tagged commit, signs/notarizes/staples the `.app`,
      builds a DMG, signs/notarizes/staples that DMG, and publishes the GitHub
      Release (DMG + `.sha256` + release notes sliced from `CHANGELOG.md`);
   3. **signs that exact published DMG** with `SPARKLE_PRIVATE_KEY` and builds
      the appcast `<item>` (bilingual notes + correct signature and `length`);
   4. opens an **`appcast/vX.Y.Z` PR** that splices the entry into
      `appcast.xml`.

   **Don't run `gh release create` locally** — it would race the workflow's
   own release-create step.
6. **Merge the `appcast/vX.Y.Z` PR.** This is the moment the update goes
   live: the feed is served from
   `raw.githubusercontent.com/.../main/appcast.xml`, so the instant the PR
   merges, every running copy of QuotaMonitor sees the new version on its
   next scheduled check (default 24 h; raw.githubusercontent caches ~5 min).
   The GitHub release page hosts the actual DMG download.

That's it. The Ed25519 signature in the appcast item is what old Sparkle
clients verify before swapping the bundle, while the Developer ID signature and
notarization satisfy Gatekeeper for new downloads and the installed app. Users
should not need the first-launch right-click bypass on current Developer ID
releases.

> **If CI couldn't sign** (no `appcast/vX.Y.Z` PR appeared), the workflow
> logs a `SPARKLE_PRIVATE_KEY not set` warning — configure the secret (see
> one-time setup below) and re-run the job, or fall back to the manual path
> at the bottom of this doc.

---

## One-time setup: Developer ID release signing

### Local maintainer machine

1. Install a **Developer ID Application** certificate in the login keychain.
   Verify it appears in:
   ```sh
   security find-identity -v -p codesigning
   ```
2. Store notarization credentials once:
   ```sh
   xcrun notarytool store-credentials quotamonitor-notary \
     --apple-id you@example.com \
     --team-id ABCDE12345 \
     --password app-specific-password
   ```
3. Use these env vars for local release checks:
   ```sh
   export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
   export NOTARYTOOL_PROFILE=quotamonitor-notary
   QM_RELEASE_SIGNING=developer-id ./tools/release.sh
   ```

`DEVELOPER_ID_APPLICATION` is optional if there is only one Developer ID
Application identity in the keychain; the scripts auto-detect the first one.
`NOTARYTOOL_PROFILE` is optional on the maintainer machine when the default
`quotamonitor-notary` profile is already stored.

### GitHub Actions secrets

The tag workflow requires these repository secrets:

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` export containing the Developer ID Application cert and private key. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for that `.p12`. |
| `DEVELOPER_ID_APPLICATION` | Optional exact identity name, e.g. `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_ID` | Apple ID used for notarization. |
| `APPLE_TEAM_ID` | Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool`. |
| `SPARKLE_PRIVATE_KEY` | Existing Sparkle Ed25519 private key. Do not rotate for the Developer ID migration. |

To create the certificate secret from an exported `.p12`:

```sh
base64 -i DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_BASE64
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD
gh secret set DEVELOPER_ID_APPLICATION
gh secret set APPLE_ID
gh secret set APPLE_TEAM_ID
gh secret set APPLE_APP_SPECIFIC_PASSWORD
```

The release workflow hard-fails if Developer ID secrets are missing. That is
intentional: after the migration, a public tag should not silently publish an
ad-hoc DMG.

### GitHub Actions pull-request permission

The QuotaMonitor release job pushes `appcast/vX.Y.Z` and then opens the
Appcast pull request. The repository must allow Actions to create and approve
pull requests: **Settings → Actions → General → Workflow permissions → Allow
GitHub Actions to create and approve pull requests**.

The workflow's own `pull-requests: write` declaration is necessary but not
sufficient. It grants that workflow's token the requested scope, while the
repository-level switch separately decides whether an Actions token may create
or approve a pull request. Both must allow the operation.

Audit the live repository setting with this read-only command:

```sh
gh api repos/timmyagentic/quota-monitor/actions/permissions/workflow
```

The result must keep the least-privilege default and enable PR creation:

```json
{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}
```

If repair is needed, preserve the read-only default while enabling only the PR
switch:

```sh
gh api --method PUT \
  repos/timmyagentic/quota-monitor/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

Do not broaden `default_workflow_permissions` to `write`. The release workflow
declares its narrow write permissions explicitly; unrelated workflows should
continue to receive read-only tokens by default.

If the GitHub Release already exists and the workflow pushed
`appcast/vX.Y.Z` but failed while creating the PR, recover from that exact
branch. Inspect it before opening the PR:

```sh
VERSION=X.Y.Z
BRANCH="appcast/v${VERSION}"
git fetch origin "${BRANCH}"
git diff --stat origin/main.."origin/${BRANCH}"
git diff origin/main.."origin/${BRANCH}" -- \
  appcast.xml "ReleaseNotes/${VERSION}.en.html" \
  "ReleaseNotes/${VERSION}.zh-Hans.html"
gh pr create --repo timmyagentic/quota-monitor \
  --base main --head "${BRANCH}" \
  --title "appcast: v${VERSION}" \
  --body "Recover the Appcast PR from the branch generated by release.yml."
```

Never rebuild or re-sign the already-published DMG merely to recover PR
creation. Its existing Appcast entry was signed against those exact published
bytes; the missing operation is only opening the PR from the branch that the
workflow already prepared.

### Scheduled release/feed health monitor

`.github/workflows/update-feed-health.yml` runs once a day and can also be
started manually with `workflow_dispatch`. It is strictly read-only
(`contents: read`) and checks these two release/feed pairs independently:

| Brand | Latest-release repository | Installed-client feed |
|---|---|---|
| QuotaMonitor | `timmyagentic/quota-monitor` | `https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml` |
| CodexMonitor | `timmyagentic/codex-monitor` | `https://raw.githubusercontent.com/systemoutprintlnnnn/codex-monitor/main/appcast.xml` |

The CodexMonitor split is intentional. GitHub release metadata and assets use
the canonical `timmyagentic/codex-monitor` repository, while existing installed
clients continue polling the legacy raw feed URL. Do not migrate that client
URL merely to make the two owner names look alike.

Each matrix row compares the latest GitHub Release tag with the first direct
Appcast item and rejects a feed larger than **100,000 bytes (100 KB)**. The
matrix uses `fail-fast: false`, so one brand's failure does not hide the other
brand's result. Start an on-demand read-only check with:

```sh
gh workflow run update-feed-health.yml
```

When a row fails, inspect its Actions log and reproduce the same check locally
before changing anything:

```sh
python3 tools/check-update-feed-health.py \
  --repo OWNER/REPO \
  --feed-url HTTPS_INSTALLED_CLIENT_FEED \
  --max-bytes 100000
```

Check whether the failure is an oversized or malformed feed, a mismatch
between the latest release tag and the first direct Appcast item, or a network
failure. For QuotaMonitor, confirm the generated Appcast PR was merged; for
CodexMonitor, inspect the canonical repository and the intentionally retained
legacy raw URL as one publication path. The monitor never repairs or writes a
feed automatically.

`tools/slim-legacy-appcast.py` is a separate, deliberate maintenance tool for
removing only item-level CDATA release-note descriptions. It validates XML
before and after the surgical edit and requires `--in-place` for an atomic
same-path replacement; it is not invoked by the scheduled monitor.

## One-time setup: Sparkle Ed25519 signing

You only do this once per machine, ever. The QuotaMonitor maintainer
machine ALREADY has this set up — the steps below are for restoring it
on a fresh machine (new laptop, etc.).

### 1. Generate an Ed25519 key pair

Sparkle stores the private key in your macOS **login Keychain**, never
on disk as plaintext. macOS will pop a Keychain dialog the first time
the tool writes — click "Always Allow" so future signings don't
prompt.

```sh
# Resolve the Sparkle artifact so the bin/ tools exist:
swift package resolve

# Generates the key, stores in Keychain under account "quotamonitor",
# prints the public key + a ready-to-paste Info.plist snippet on stdout.
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account quotamonitor
```

If a key already exists for that account, the tool reuses it instead
of overwriting — running it twice is safe.

### 2. Embed the public key

Open `Resources/Info.plist`, find `SUPublicEDKey`, paste the base64
public key the tool printed in step 1 into the `<string>...</string>`.
Commit + push.

### 3. Back up the private key offline

Export the private key from Keychain to an offline backup (USB stick,
encrypted disk, password manager):

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account quotamonitor \
    -x ~/Desktop/quotamonitor-private-key-BACKUP.key
chmod 600 ~/Desktop/quotamonitor-private-key-BACKUP.key
```

Then move that file off this Mac and onto your backup medium.
**Delete the on-disk copy** once it's backed up:

```sh
rm ~/Desktop/quotamonitor-private-key-BACKUP.key
```

**If you lose this key, every existing install is stuck on its current
version forever** — there's no way to ship a new signed update without
it.

Conversely, if this key leaks, an attacker can ship a malicious
"update" that every running copy will silently install. Treat it like
production database credentials.

### 3b. Store the private key as a GitHub Actions secret (enables CI signing)

`release.yml` signs the published DMG using a repo secret named
`SPARKLE_PRIVATE_KEY`. Its value is exactly what `generate_keys -x`
exports (the runner has no Keychain, so `sign_update --ed-key-file`
reads it from a temp file). Set it once:

```sh
# Export the key to a temp file, push it to the repo secret, delete it.
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account quotamonitor -x /tmp/qm-sparkle.key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/qm-sparkle.key
rm -f /tmp/qm-sparkle.key
```

If the secret is missing, `release.yml` still builds and publishes the
release — it just skips signing and logs a warning instead of opening
the appcast PR. The same private key signs both locally (Keychain) and
in CI (secret); they must correspond to the `SUPublicEDKey` in
`Resources/Info.plist`.

**Confirm the secret is the right key** (you can't read a secret's value
back, so verify its *derived* public key instead). Run the on-demand
check after setting or rotating it:

```sh
gh workflow run verify-signing-secret      # then: gh run watch
```

It imports the secret's key into a throwaway Keychain account, prints
the derived public key, and fails if it doesn't equal `SUPublicEDKey`.
`release.yml` runs the same `tools/verify-signing-key.sh` guard before
signing, so a wrong key fails the release loudly instead of shipping an
appcast Sparkle rejects.

### 4. Restoring on a fresh machine

If you ever import the backed-up private key onto a new Mac:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account quotamonitor \
    -f /path/to/quotamonitor-private-key-BACKUP.key
```

### 5. (Optional) Override the Keychain account name

Default account is `quotamonitor`. If you want a different label (e.g.
because you share a Mac with another Sparkle project), set:

```sh
export QM_SPARKLE_ACCOUNT=myname
./tools/release-sparkle.sh
```

Make sure `generate_keys --account` and `sign_update --account` use
the same name.

---

## Manual appcast fallback

If CI signing is unavailable (secret not set, runner down), reproduce
what CI does by hand — the one rule that matters is **sign the DMG that
is actually published, never a fresh local rebuild** (their bytes
differ, so a local-DMG signature won't validate against the download):

```sh
gh release download vX.Y.Z -p '*.dmg' -D /tmp/qm
./tools/release-sparkle.sh /tmp/qm/QuotaMonitor-X.Y.Z.dmg   # signs the DMG + writes ReleaseNotes/X.Y.Z.*.html
python3 tools/appcast-insert.py dist/appcast-item-X.Y.Z.xml appcast.xml
# then commit appcast.xml AND ReleaseNotes/X.Y.Z.*.html on a branch, open a PR, merge.
# (the appcast links the notes via sparkle:releaseNotesLink, so the feed only
#  works once those files are on main.)
```

You can confirm a signature without shipping by verifying it against the
published DMG and the public key:

```sh
.build/artifacts/sparkle/Sparkle/bin/sign_update --account quotamonitor --verify \
    /tmp/qm/QuotaMonitor-X.Y.Z.dmg "<edSignature-from-appcast>"
```

## Verifying the appcast manually

To test the appcast without a full release, point a debug build at a
local file via `SUFeedURL` override:

```sh
defaults write dev.tjzhou.QuotaMonitor SUFeedURL \
    "file:///$PWD/appcast.xml"
open .build/QuotaMonitor.app
```

Open Settings → Advanced → Updates → "Check Now". Sparkle should show
the most recent appcast item.

To check the **Chinese** release notes without changing your whole Mac to
Chinese, run the app once with `AppleLanguages` forced — Sparkle selects
`<description xml:lang="…">` from the process's preferred languages:

```sh
defaults write dev.tjzhou.QuotaMonitor AppleLanguages '("zh-Hans")'
open .build/QuotaMonitor.app   # Check Now → notes render in Chinese
defaults delete dev.tjzhou.QuotaMonitor AppleLanguages
```

(The shipping app never writes `AppleLanguages` itself — this is a
test-only override. The release-notes language tracks the macOS system
language, independent of the in-app language picker.)

Reset with:

```sh
defaults delete dev.tjzhou.QuotaMonitor SUFeedURL
```

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Update is improperly signed" alert | Either (a) the signature was computed over a **different DMG** than the one published — e.g. a local `release.sh` build instead of the CI-published file (the usual cause; let CI sign, or use the manual fallback against the downloaded DMG), or (b) the public key in Info.plist doesn't match the signing key. Verify with `sign_update --account quotamonitor --verify <published.dmg> "<edSignature>"`. |
| Sparkle never fires a check | `SUEnableAutomaticChecks` is off, or the user has never opened the app long enough for the schedule to land. Check `defaults read dev.tjzhou.QuotaMonitor` for the keys Sparkle persists. |
| "Update is missing" / 404 on download | `enclosure url` in the appcast item points at a release asset that hasn't been uploaded yet. Check the `release.yml` Actions run succeeded and attached the DMG to the release. |
| Sparkle crashes on first "Install Update" click | `Sparkle.framework` is missing from `.app/Contents/Frameworks/`. Re-run `./build.sh release` (it copies the framework from `.build/artifacts/`). |
