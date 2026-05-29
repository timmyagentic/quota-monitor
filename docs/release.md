# Release workflow

QuotaMonitor ships via a self-hosted Sparkle appcast (no Apple Developer
account, no Mac App Store). Every release follows the same handful of
steps. **One-time setup** is at the bottom — do that first.

---

## Per-release checklist

1. **Bump version**: edit `Resources/VERSION` to the new `X.Y.Z` unless the
   version was already bumped during the release-prep patch.
2. **Update docs**:
   - `CHANGELOG.md` must contain a `## [X.Y.Z] — YYYY-MM-DD` section because
     the English Sparkle release notes are extracted from that exact heading.
   - `CHANGELOG.zh-Hans.md` must contain a matching `## [X.Y.Z]` section — the
     Simplified-Chinese release notes come from there. Release notes are
     **fixed bilingual**: `release-sparkle.sh` aborts if this section is
     missing, so don't skip it. Keep each `- ` bullet on a single physical
     line in the Chinese file (the markdown→HTML joiner glues wrapped lines
     with a space, which would inject stray spaces between Chinese
     characters).
   - `README.md`, `docs/findings.md`, and `docs/parity.md` should reflect any
     changed user-visible behavior or important support boundaries.
3. **Run the release pipeline**:
   ```sh
   ./tools/release.sh           # use --force only to overwrite an existing local DMG
   ```
   This runs tests, builds the release bundle, verifies codesigning, creates
   `dist/QuotaMonitor-X.Y.Z.dmg`, writes the `.sha256`, mounts the DMG, and
   verifies the app inside it.
4. **Commit + tag**:
   ```sh
   git add Resources/VERSION CHANGELOG.md CHANGELOG.zh-Hans.md README.md docs
   git commit -m "Release vX.Y.Z"
   git tag vX.Y.Z
   ```
5. **Generate the appcast entry** (signs the DMG with your Ed25519
   private key and prints a ready-to-paste `<item>` block):
   ```sh
   ./tools/release-sparkle.sh
   ```
   Paste the printed block at the top of `appcast.xml` under
   `<channel>`. The block carries two `<description xml:lang="en">` /
   `<description xml:lang="zh-Hans">` nodes; Sparkle shows whichever
   matches the user's macOS system language (falling back to English),
   so leave both in place.
6. **Publish**:
   ```sh
   git add appcast.xml
   git commit -m "appcast: vX.Y.Z"
   git push origin main vX.Y.Z
   gh release create vX.Y.Z dist/QuotaMonitor-X.Y.Z.dmg \
       --title "QuotaMonitor X.Y.Z" --notes-from-tag
   ```
   The instant `appcast.xml` lands on `main`, every running copy of
   QuotaMonitor will see the new version on its next scheduled check
   (default 24 h). The GitHub release page hosts the actual DMG
   download.

That's it. No notarization, no Apple Developer cert, no PKG. The Ed25519
signature in the appcast item is what Sparkle verifies before swapping the
bundle. Users still need the first manual right-click → Open install because
the app is ad-hoc signed.

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
| "Update is improperly signed" alert | Public key in Info.plist doesn't match the private key you signed with. Either regenerate Info.plist or re-sign the DMG. |
| Sparkle never fires a check | `SUEnableAutomaticChecks` is off, or the user has never opened the app long enough for the schedule to land. Check `defaults read dev.tjzhou.QuotaMonitor` for the keys Sparkle persists. |
| "Update is missing" / 404 on download | `enclosure url` in the appcast item points at a release asset that hasn't been uploaded yet. The `gh release create` step must include the DMG. |
| Sparkle crashes on first "Install Update" click | `Sparkle.framework` is missing from `.app/Contents/Frameworks/`. Re-run `./build.sh release` (it copies the framework from `.build/artifacts/`). |
