# Release workflow

QuotaMonitor ships via a self-hosted Sparkle appcast (no Apple Developer
account, no Mac App Store). Every release follows the same handful of
steps. **One-time setup** is at the bottom — do that first.

---

## Per-release checklist

1. **Bump version**: edit `Resources/VERSION` to the new `X.Y.Z`.
2. **Update CHANGELOG**: convert `[Unreleased]` to `[X.Y.Z] — YYYY-MM-DD`
   and add a fresh empty `[Unreleased]` heading on top.
3. **Commit + tag**:
   ```sh
   git add Resources/VERSION CHANGELOG.md
   git commit -m "Release vX.Y.Z"
   git tag vX.Y.Z
   ```
4. **Build the signed DMG**:
   ```sh
   ./make-dmg.sh           # produces dist/QuotaMonitor-X.Y.Z.dmg
   ```
5. **Generate the appcast entry** (signs the DMG with your Ed25519
   private key and prints a ready-to-paste `<item>` block):
   ```sh
   ./tools/release-sparkle.sh
   ```
   Paste the printed block at the top of `appcast.xml` under
   `<channel>`.
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

That's it. No notarization, no Apple Developer cert, no PKG. The
Ed25519 signature in the appcast item is what Sparkle verifies before
swapping the bundle.

---

## One-time setup (per developer machine)

You only do this once per machine, ever.

### 1. Generate an Ed25519 key pair

```sh
# Resolve the Sparkle artifact so the bin/ tools exist:
swift package resolve

mkdir -p ~/.config/sparkle

# Generate the keypair. -x writes the PRIVATE key; -p reads it back
# and prints the public key on stdout.
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
    -x ~/.config/sparkle/quotamonitor-ed25519.key

# Lock it down. Anyone who reads this file can sign updates that
# every QuotaMonitor user will trust and auto-install.
chmod 600 ~/.config/sparkle/quotamonitor-ed25519.key

# Print the public key (you'll paste this into Info.plist):
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
    -p ~/.config/sparkle/quotamonitor-ed25519.key
```

### 2. Embed the public key

Open `Resources/Info.plist`, find `SUPublicEDKey`, paste the base64
public key from the previous step. Commit + push.

### 3. Back up the private key offline

Burn it to a USB stick, print it on paper, store in a password manager
— anything not connected to the internet. **If you lose this key, every
existing install is stuck on its current version forever** (no way to
ship a new signed update without it).

Conversely, if this key leaks, an attacker can ship a malicious
"update" that every running copy will silently install. Treat it like
production database credentials.

### 4. (Optional) Override the key path

Default path is `~/.config/sparkle/quotamonitor-ed25519.key`. To put it
elsewhere (e.g. on a hardware token like a YubiKey-backed file), set:

```sh
export QM_SPARKLE_KEY=~/some/other/path/qm.key
./tools/release-sparkle.sh
```

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
