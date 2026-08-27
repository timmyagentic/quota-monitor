# Private Beta in-app updates

QuotaMonitor's Private Beta channel is a separate, owner-operated Sparkle
delivery path. Stable builds continue to use the public `SUFeedURL`. Private
Beta builds, notes, checksums, and the appcast live under `private-beta/` in a
private R2 bucket and are reachable only through authenticated Worker routes.
No Beta command in this repository creates a GitHub tag, GitHub Release, or
public appcast entry.

The authenticated appcast can contain both the latest Private Beta item and a
mirrored copy of the latest Stable item. Stable bytes remain the exact public
GitHub Release bytes, but their authenticated enclosure and release-note URLs
point back through the private Worker. This lets an enrolled Beta device
discover a higher Stable build without sending its Bearer token to GitHub or
another third-party origin.

## Security model

- A maintainer creates a 15-minute, one-use enrollment code through the admin
  route. D1 stores only its SHA-256 digest.
- The Mac exchanges that code for a random 256-bit device token. The token is
  stored in a device-only Keychain item; D1 stores only its SHA-256 digest.
- Sparkle sends the device token as a Bearer header for the private appcast,
  localized notes, and DMG range requests.
- Every URL in the authenticated appcast must stay under the private Worker;
  never link a private-feed item directly to GitHub or another origin because
  Sparkle applies the updater's Bearer header to its requests.
- Missing, invalid, expired, and revoked credentials receive the same
  non-cacheable 404 response. Private objects are never exposed as public R2
  URLs.
- A device is revoked by setting its D1 row's `revoked_at`; other devices keep
  working.

The Worker uses `PRIVATE_BETA_DB`, `PRIVATE_BETA_BUCKET`, three independent rate
limit bindings, and the `PRIVATE_BETA_ADMIN_TOKEN` secret. Do not put admin
tokens, device tokens, R2 credentials, Cloudflare API tokens, or Sparkle private
keys in source control, app configuration, shell history, or issue/PR text.

## One-time Cloudflare setup

These are operator instructions, not actions performed by this change:

1. Create the private R2 bucket named `quota-monitor-private-beta`.
2. Create the D1 database named `quota-monitor-private-beta`, put its generated
   `database_id` in the `PRIVATE_BETA_DB` entry in `website/wrangler.jsonc`, and
   apply `website/migrations/private-beta`.
3. Generate a random admin secret of at least 32 characters and install it with
   `cd website && npx wrangler secret put PRIVATE_BETA_ADMIN_TOKEN`. Wrangler
   prompts for the value so it does not appear in the command line.
4. Review the Worker route, bindings, and rate limits, then deploy through the
   normal reviewed website release process.

Production resource creation, secret installation, migration, and deployment
are intentionally outside this implementation task.

## Enroll and revoke a Mac

After deployment, request a one-time code without placing the admin secret in
the command line:

```sh
curl --fail-with-body --user admin \
  --request POST \
  https://quota-monitor.timmyagentic.com/api/private-beta/admin/enrollment-codes
```

Enter the prompted admin password, then paste the returned code into
Settings → Advanced → Updates. Successful enrollment writes the device token
to Keychain, selects Private Beta, resets Sparkle's update cycle, and checks
immediately.

To revoke one device, obtain its non-secret `device_id` from D1 and call:

```sh
curl --fail-with-body --user admin \
  --request POST \
  https://quota-monitor.timmyagentic.com/api/private-beta/admin/devices/DEVICE_ID/revoke
```

Selecting Stable immediately removes the authorization header and restores the
public appcast. `leavePrivateBeta()` additionally deletes the local Keychain
credential; server-side revocation remains the authoritative access control.

## Package and publish a Beta

Inspect the complete plan without signing, packaging, or uploading:

```sh
python3 tools/private-beta-release.py --beta-sequence 1 --dry-run
```

The real command runs the existing Developer ID packaging path, including
notarization and stapling, signs the DMG with Sparkle EdDSA, writes a checksum,
atomically acquires a 30-minute R2 publication lease through the admin route,
refuses to replace an existing versioned object, preserves the newest
channel-less Stable item already present in the private feed, uploads all
versioned objects, and updates `private-beta/appcast.xml` last. The admin token is read from
`PRIVATE_BETA_ADMIN_TOKEN` or, when unset, from a hidden prompt; it is never put
in a URL or command-line argument:

```sh
python3 tools/private-beta-release.py --beta-sequence 1
```

Only one publisher can hold the lease. A failed or interrupted publisher leaves
the lease in place until its expiry, so another run cannot interleave artifact
and appcast writes. Successful publication releases the lease immediately.

### Sync a Stable release into the private feed

After the public Stable Release exists and its QuotaMonitor Appcast PR has
merged, download the actual published DMG and sidecar into `dist/` from a fresh
checkout of the new public `main`, then run:

```sh
gh release download vX.Y.Z \
  --repo timmyagentic/quota-monitor \
  --pattern 'QuotaMonitor-X.Y.Z.dmg*' \
  --dir dist
python3 tools/private-beta-release.py \
  --sync-stable \
  --stable-artifact dist/QuotaMonitor-X.Y.Z.dmg \
  --stable-checksum dist/QuotaMonitor-X.Y.Z.dmg.sha256 \
  --public-appcast appcast.xml
```

The sync command requires the existing Wrangler login and reads the admin token
from the same hidden prompt or environment boundary as a Beta publication. It
verifies the sidecar SHA-256 and recomputes the Appcast length and Sparkle signature,
mirrors the exact Stable DMG, checksum, and bilingual notes to immutable
private paths, preserves current Private Beta items, and uploads the merged
appcast last under the same publication lock. Existing identical objects are
reused only after byte-for-byte comparison; different bytes fail closed.

Do not run Stable sync before the public Appcast PR merges: the public item is
the signed source of truth. After sync, fetch the authenticated feed and both
enclosures, verify the Stable build sorts above same-version Beta builds, and
confirm unauthenticated feed, notes, and artifact routes still return 404.

### Encrypted CI packaging handoff

When the release Mac has the Sparkle and Cloudflare publisher credentials but
not the Apple notarization credentials, the maintainer can dispatch
`private-beta-package.yml`. The workflow accepts only an exact commit already
contained in `main`, runs the existing Developer ID signing and notarization
pipeline, and uploads only two one-day-retention files: an AES-256-GCM CMS
ciphertext and its provenance metadata. It has read-only repository permission
and contains no Sparkle, Cloudflare, R2, publication-lock, GitHub Release, or
appcast publication capability.

Generate a new one-time RSA recipient on the release Mac and keep its private
key there:

```sh
openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
  -keyout private-beta-recipient.key \
  -out private-beta-recipient.pem \
  -subj "/CN=QuotaMonitor Private Beta One-Time Recipient" \
  -days 2
chmod 600 private-beta-recipient.key
RECIPIENT_CERTIFICATE_BASE64="$(base64 < private-beta-recipient.pem | tr -d '\n')"
gh workflow run private-beta-package.yml \
  -f source_sha="FULL_MAIN_COMMIT_SHA" \
  -f beta_sequence="1" \
  -f recipient_certificate_base64="${RECIPIENT_CERTIFICATE_BASE64}"
```

After the workflow succeeds, download the named artifact and decrypt it
locally. Compare both ciphertext and plaintext SHA-256 values with the metadata
before continuing with the normal publisher in `--skip-package` mode:

```sh
openssl cms -decrypt -binary -inform DER \
  -in QuotaMonitor-0.2.43-beta.1.dmg.cms \
  -recip private-beta-recipient.pem \
  -inkey private-beta-recipient.key \
  -out dist/QuotaMonitor-0.2.43-beta.1.dmg
python3 tools/private-beta-release.py --beta-sequence 1 --skip-package
```

The recipient key is single-release material. Delete it after the decrypted
DMG, code signature, notarization ticket, hashes, private Worker routes, and
unchanged public stable feed have all been verified.

The internal build number is numeric and monotonic. For a given semantic
version, Private Beta sequences occupy slots 1–8999 and the stable build uses
slot 9000, so the mirrored Stable item supersedes every Beta of that version.
A later semantic version sorts above the preceding stable version.

## Verification boundary

Automated tests cover the D1 schema, enrollment, token hashing, revocation,
hidden failures, rate limiting, R2 streaming/ranges, cache headers, Sparkle
channel configuration, private-only authenticated URLs, Stable mirror
hash/length/signature validation, Keychain token validation, and build ordering. A real
end-to-end update still requires reviewed Cloudflare provisioning, a signed and
notarized Beta artifact, an enrolled Developer ID build, and a controlled
installation test. Until those operator steps are performed, production
deployment and real Beta publication are `UNVERIFIED`.
