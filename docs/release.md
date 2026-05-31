# Release workflow

QuotaMonitor ships via a self-hosted Sparkle appcast (no Apple Developer
account, no Mac App Store). Every release follows the same handful of
steps. **One-time setup** is at the bottom — do that first.

---

## Why CI signs the appcast (read this first)

The appcast `sparkle:edSignature` is an Ed25519 signature over the **exact
DMG bytes** Sparkle downloads — and Sparkle downloads the DMG attached to the
GitHub Release, which `release.yml` **builds on its own runner**. A macOS DMG
is not byte-reproducible (HFS timestamps, compression, the code-sign seal), so
a DMG you build locally is **not** the same file CI publishes. Signing the
local DMG and pasting that signature into `appcast.xml` therefore produces a
signature that does not match what users download → Sparkle rejects every
update as *"improperly signed."* (This is exactly what broke 0.2.26/0.2.27.)

So **signing now happens in CI, over the published DMG**, and CI opens the
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
   - Optional richer notes: `ReleaseNotes/X.Y.Z.en.html` +
     `ReleaseNotes/X.Y.Z.zh-Hans.html` override the changelog-derived HTML if
     present.
   - `README.md`, `docs/findings.md`, and `docs/parity.md` should reflect any
     changed user-visible behavior or important support boundaries.
3. **Local sanity build** (optional but recommended):
   ```sh
   ./tools/release.sh           # use --force only to overwrite an existing local DMG
   ```
   This runs tests, builds the release bundle, verifies codesigning, creates
   `dist/QuotaMonitor-X.Y.Z.dmg`, writes the `.sha256`, mounts the DMG, and
   verifies the app inside it. **Do not sign or edit `appcast.xml` from this
   build** — CI signs the DMG it publishes (see the section above).
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
   1. rebuilds the DMG from the tagged commit and publishes the GitHub
      Release (DMG + `.sha256` + release notes sliced from `CHANGELOG.md`);
   2. **signs that exact published DMG** with `SPARKLE_PRIVATE_KEY` and
      builds the appcast `<item>` (bilingual notes + correct signature and
      `length`);
   3. opens an **`appcast/vX.Y.Z` PR** that splices the entry into
      `appcast.xml`.

   **Don't run `gh release create` locally** — it would race the workflow's
   own release-create step.
6. **Merge the `appcast/vX.Y.Z` PR.** This is the moment the update goes
   live: the feed is served from
   `raw.githubusercontent.com/.../main/appcast.xml`, so the instant the PR
   merges, every running copy of QuotaMonitor sees the new version on its
   next scheduled check (default 24 h; raw.githubusercontent caches ~5 min).
   The GitHub release page hosts the actual DMG download.

That's it. No notarization, no Apple Developer cert, no PKG. The Ed25519
signature in the appcast item is what Sparkle verifies before swapping the
bundle. Users still need the first manual right-click → Open install because
the app is ad-hoc signed.

> **If CI couldn't sign** (no `appcast/vX.Y.Z` PR appeared), the workflow
> logs a `SPARKLE_PRIVATE_KEY not set` warning — configure the secret (see
> one-time setup below) and re-run the job, or fall back to the manual path
> at the bottom of this doc.

---

## One-time setup (per developer machine)

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
./tools/release-sparkle.sh /tmp/qm/QuotaMonitor-X.Y.Z.dmg   # signs the published DMG
python3 tools/appcast-insert.py dist/appcast-item-X.Y.Z.xml appcast.xml
# then commit appcast.xml on a branch, open a PR, merge.
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
