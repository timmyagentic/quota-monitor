# Private Beta in-app updates

QuotaMonitor's Private Beta channel is a separate, owner-operated Sparkle
delivery path. Stable builds continue to use the public `SUFeedURL`. Private
Beta builds, notes, checksums, and the appcast live under `private-beta/` in a
private R2 bucket and are reachable only through authenticated Worker routes.
No Beta command in this repository creates a GitHub tag, GitHub Release, or
public appcast entry.

## Security model

- A maintainer creates a 15-minute, one-use enrollment code through the admin
  route. D1 stores only its SHA-256 digest.
- The Mac exchanges that code for a random 256-bit device token. The token is
  stored in a device-only Keychain item; D1 stores only its SHA-256 digest.
- Sparkle sends the device token as a Bearer header for the private appcast,
  localized notes, and DMG range requests.
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
refuses to replace an existing versioned object, uploads all versioned objects,
and updates `private-beta/appcast.xml` last:

```sh
python3 tools/private-beta-release.py --beta-sequence 1
```

The internal build number is numeric and monotonic. For a given semantic
version, Private Beta sequences occupy slots 1–8999 and the stable build uses
slot 9000, so stable supersedes every Beta of that version. A later semantic
version sorts above the preceding stable version.

## Verification boundary

Automated tests cover the D1 schema, enrollment, token hashing, revocation,
hidden failures, rate limiting, R2 streaming/ranges, cache headers, Sparkle
channel configuration, Keychain token validation, and build ordering. A real
end-to-end update still requires reviewed Cloudflare provisioning, a signed and
notarized Beta artifact, an enrolled Developer ID build, and a controlled
installation test. Until those operator steps are performed, production
deployment and real Beta publication are `UNVERIFIED`.
