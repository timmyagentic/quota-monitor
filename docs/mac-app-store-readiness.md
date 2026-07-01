# Mac App Store Readiness Spike

This spike adds a repeatable local smoke path for a Mac App Store-shaped
QuotaMonitor build without changing the existing Developer ID + Sparkle release
pipeline.

## Local Smoke Command

```sh
QM_DISTRIBUTION=app-store CONFIG=release ./build.sh
codesign -dvvv --entitlements :- .build/QuotaMonitor.app
plutil -p .build/QuotaMonitor.app/Contents/Info.plist
```

Expected local smoke evidence:

- `QMDistributionChannel` is `app-store` in the assembled `Info.plist`.
- The signed app entitlements include `com.apple.security.app-sandbox = true`.
- `com.apple.security.network.client = true` remains present for HTTPS quota
  and pricing requests.
- `com.apple.security.files.user-selected.read-only = true` and
  `com.apple.security.files.bookmarks.app-scope = true` are present so local
  Codex / Claude history imports can use user-selected folders with persistent
  security-scoped bookmarks.
- The Developer ID-only `allow-dyld-environment-variables` entitlement is not
  present.
- `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval`, and `SUEnableInstallerLauncherService` are removed
  from the assembled app-store `Info.plist`.
- `UpdaterController` does not start Sparkle when `QMDistributionChannel` is
  `app-store`, and Advanced settings hides the Sparkle update controls.

This command is a local smoke build only. It has not uploaded anything to App
Store Connect, has not used Transporter or `altool`, and has not created or
modified Apple certificates, provisioning profiles, App Store Connect app
records, GitHub secrets, or production release automation.

## Developer ID Guardrail

The existing direct-distribution path remains the default:

```sh
CONFIG=debug ./build.sh
```

Expected evidence:

- `QMDistributionChannel` is `developer-id`.
- Sparkle update keys remain present in the assembled direct-distribution
  `Info.plist`.
- The Sparkle framework is still embedded for the direct-distribution app.

## Apple Requirements Checked

- App Review Guideline 2.5.2 says apps should be self-contained, should not read
  or write outside the designated container area, and should not download,
  install, or execute code that changes app features.
- Apple's Mac-specific App Review guidance says Mac apps must use the Mac App
  Store for updates; other update mechanisms are not allowed.
- App Store Connect upload requires an explicit App ID and a Mac App Store
  Connect provisioning profile before a real submission build can be uploaded.
- App Store Connect can accept builds through Xcode, Transporter, or `altool`,
  but this spike deliberately stops before any upload or account mutation.

## Current Feasibility Result

The repository can produce a local Mac App Store-shaped `.app` smoke artifact:
it is sandbox-signed, carries an app-store distribution marker, and routes local
Codex / Claude history import roots through user-selected security-scoped
bookmarks. The existing Developer ID source plist and release scripts remain
unchanged.

This is not yet a production-ready App Store submission. It proves a build-time
separation point and exposes the remaining product and review risks.

## Remaining Review Risks

1. The security-scoped bookmark flow is covered by local tests and a smoke
   entitlement check, but still needs a manual pass from a signed App Store
   artifact: fresh launch, choose folders, relaunch, import, and verify stale
   bookmark behavior.
2. Live Codex quota checks currently spawn a user-installed `codex` binary.
   That is high-risk for App Review and sandbox behavior; the App Store variant
   should either disable that path or replace it with an App Store-safe API
   flow.
3. Claude credential *reading* still relies on App-Store-incompatible access.
   QuotaMonitor now refreshes the token itself via a direct OAuth grant (a
   network call — sandbox-safe), but to bootstrap a token it still reads
   `~/.claude/.credentials.json` (outside the sandbox container) and the
   `Claude Code-credentials` Keychain item by spawning `/usr/bin/security`, and
   separately spawns the `claude` binary to detect the Code version. Those
   reads — not the refresh — need an App-Store-safe path (e.g. a user-selected
   credential flow) or disabling.
4. Sparkle is runtime-disabled and its update plist keys are removed from the
   app-store artifact, but the SwiftPM target still links and embeds Sparkle in
   this spike because the existing app code depends on update-window types. A
   submission-hardening pass should compile Sparkle out of the App Store target
   entirely.
5. A real App Store Connect upload still needs App Store metadata, a privacy
   policy URL, a bundle/app record decision, an App Store provisioning profile,
   and review notes that explain the data sources and sandbox permissions.
6. Data continuity for a user moving from the Developer ID build to the App
   Store build is unaddressed. `DatabaseManager` migrates the legacy
   `~/Library/Application Support/CodexMonitor/*.sqlite` on first launch, but in
   the sandbox `Application Support` is redirected into the app container, so the
   Developer-ID-written database (outside the container) is neither readable nor
   migratable — an App Store install would silently start from an empty history.
   A migration path (e.g. a user-selected import of the old database) is needed
   before the two builds can be presented as the same product.

## Recommended Next Steps

1. Manually validate the folder authorization flow from a signed App Store
   smoke build, including persistence of security-scoped bookmarks after
   relaunch.
2. Add a compile-time App Store target or package variant that removes Sparkle
   from target dependencies instead of only disabling it at runtime.
3. Decide whether the App Store product should support live Codex/Claude quota
   checks, or ship a history-only App Store variant.
4. Prepare privacy-policy copy and App Review notes before creating the App
   Store Connect record.
