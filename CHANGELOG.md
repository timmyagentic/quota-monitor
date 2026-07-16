# Changelog

All notable changes to QuotaMonitor (formerly CodexMonitor) are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Release-note standard

Every merged PR should update `## [Unreleased]` before or with the merge.
These entries become both the GitHub Release notes and the Sparkle update
window copy.

- Start each release section with `#### Summary`: plain, user-readable
  bullets. Generated Sparkle update notes render these as rich visual cards.
  Write these bullets for a non-technical user who only needs to know what
  feels better after updating. Avoid implementation, test, CI, PR, and release
  plumbing terms in Summary.
- Put details under `### Added`, `### Changed`, `### Fixed`, `### Removed`,
  or `### Known limitation(s)`. These remain in the GitHub Release notes.
- Start each detail bullet with a short bold title, then one concise sentence:
  `- **Short title.** What changed and why it matters.`
- Keep implementation details, commit archaeology, and internal test evidence
  in PR bodies or docs unless they directly explain user impact.
- Pull-request CI enforces this for non-appcast PRs; the generated appcast PR
  is exempt because it publishes the release notes already authored in the
  release PR.
- Validate before a release with
  `python3 tools/validate-release-notes.py X.Y.Z`.

## [Unreleased]

## [0.2.41] — 2026-07-16

#### Summary

- Quota Monitor now has a bilingual website where you can explore rich synthetic 30-day Dashboard and Sessions examples and download the latest Mac installer in one click.
- Update reminders now survive relaunches, remain visible in the menu bar, and return gently instead of disappearing after Later.
- Update releases are now checked end to end so a published download cannot quietly disappear from the in-app updater.
- You can now choose to share anonymous version statistics, helping show which app versions remain active without sending account or usage data.

### Added

- **Quota Monitor product website.** The new English and Simplified Chinese product tour uses rich synthetic 30-day Dashboard and Sessions examples on desktop and mobile; its download button serves the latest notarized DMG directly from the site, adds no application-level visitor analytics or custom request logging, and never reuses a stale browser-cached installer.
- **Opt-in anonymous version statistics.** With explicit permission, Developer ID builds send only the UTC day, app version, brand, distribution channel, schema version, and a rotating daily token so maintainers can see anonymous active-install version distribution; Settings can turn it off at any time, and the bilingual privacy policy explains retention and network-boundary handling.

### Changed

- **Brand-aware update-feed migration.** Existing custom and CodexMonitor feeds now stay untouched while only known incorrect QuotaMonitor feeds are repaired.
- **Daily release-feed monitoring.** Read-only daily checks now cover both brands, compare each latest release with its installed-client Appcast, verify the newest DMG's URL, size, signature-metadata format, and byte-range availability, and fail when a feed exceeds 100 KB.
- **Gentle reminder cadence.** Choosing Later schedules the first reminder for exactly 24 hours later, followed by another reminder every 3 days until the update is resolved.
- **Quiet menu-bar reminders.** A due reminder emphasizes the native menu-bar status item for eight seconds without stealing focus, opening a window, or requesting notification permission.
- **Clear update choices.** Automatic checks for the same version stay quiet while snoozed, while Check Now still presents the update; Skip is offered only before download, and a ready update offers Later or Install & Relaunch.

### Fixed

- **Update publication cannot silently skip the Appcast.** A release now hard-fails when publishing credentials are missing, checks the completed notarized DMG against its sidecar checksum, Sparkle-signs it before uploading the same unchanged file, and fails if its bytes change or Appcast publication cannot proceed.
- **Legacy CodexMonitor feed size.** The oversized installed-client feed was surgically reduced without changing versions, download URLs, lengths, signatures, or the legacy URL existing clients use.
- **Pending updates no longer disappear.** The pending version and menu-bar marker survive relaunches, then clear after installation or current-version validation, an explicit Skip, or a definitive no-update result.

## [0.2.40] — 2026-07-15

#### Summary

- Codex quota cards and the menu-bar label now follow the quota windows that are actually active, so the temporary weekly-only policy no longer appears as a false 5-hour limit or a stale weekly value.
- Daily trend charts now keep the newest day's bar inside the plot instead of drawing it past the right axis.
- Hovering the dashboard activity heatmap feels right again: the tooltip floats above the day square instead of covering it, and the whole square — including the small gaps between squares — now triggers it.
- Codex cost estimates now distinguish recorded Standard, Fast, and Flex turns, treat missing tier evidence as Standard, apply long-context pricing, and avoid duplicated parent usage in subagent history.

### Changed

- **Per-turn Codex service-tier estimates.** Recent Codex turns now use their recorded Standard, Fast, or Flex preference; Flex uses its published lower rates, while older or untagged usage conservatively stays on Standard pricing.

### Removed

- **Unknown Codex usage Fast fallback.** The setting that treated older or untagged Codex history as Fast has been removed because missing tier evidence must default to Standard.

### Fixed

- **Accurate Codex child-session costs.** Parent history replayed into a child or forked rollout is now excluded until the child's first real task while still seeding cumulative-token baselines. Older tasks that omit `started_at` use their UUIDv7 turn time without trusting rewritten envelope timestamps, and unchanged cumulative snapshots are no longer billed again when stale last-usage details differ.
- **Codex long-context pricing.** Supported requests above 272K input tokens now use 2× input and 1.5× output rates. Priority is not applied beyond that boundary because OpenAI does not support Priority for long context; Flex keeps its published tier before the long-context multipliers are applied.
- **Existing Codex costs are repriced on upgrade.** A one-time pricing-policy migration recalculates stored dollar values immediately, so databases previously priced with the unknown-as-Fast fallback cannot keep stale totals while waiting for a rollout file to change.
- **Dynamic Codex quota windows.** QuotaMonitor now identifies 5-hour and 7-day quotas by their actual duration, treats a missing window as absent instead of mixing in older database data, and automatically brings the 5-hour display back if Codex restores it.
- **Trend chart final-day alignment.** Daily bars now reserve the complete final calendar-day interval, so 7-day, 30-day, 90-day, and yearly views keep the newest bar and label inside the plot, including across daylight-saving changes.
- **Activity heatmap tooltip position and hover range.** The hover tooltip kept a stale layout offset from an earlier design that placed month labels above the grid, so it rendered on top of the hovered square — where it could also intercept the cursor and flicker — and only the 13-pt square itself was hover-sensitive, leaving the 4-pt gaps as dead zones. The tooltip is now pinned just above the square and never intercepts the cursor, and each day's hover area covers the full grid pitch.

## [0.2.39] — 2026-07-10

#### Summary

- Fixed an update-check error that could show "An error occurred in retrieving update information — please try again later" instead of finding the new version.
- Release notes now load a little more smoothly in the update window.
- Model-specific Codex quota rows now show their weekly limit when available.
- Dashboard now looks more like a dense usage cockpit, with forecast, activity, composition, and stacked trends in one flow.
- Dashboard charts and totals now stay consistent when a provider is disabled.
- Usage from the new GPT-5.6 models (Sol, Terra, Luna) is now priced correctly, including Fast Mode.

### Added

- **GPT-5.6 pricing.** The bundled pricing catalog now covers `gpt-5.6-sol` ($5/$30 per 1M tokens), `gpt-5.6-terra` ($2.50/$15), and `gpt-5.6-luna` ($1/$6), plus their 2× Fast-Mode rows, so usage from these models gets a correct dollar value.

### Changed

- **Dashboard visual refresh.** Dashboard now keeps forecast, stacked token trends, activity, and composition in one scrollable dashboard with a denser metric strip and clearer activity color.
- **The update window shows a brief loading indicator while release notes download.** Because notes are now fetched on demand, the window shows a short spinner instead of momentarily flashing the "no release notes" placeholder before the notes appear.

### Fixed

- **Update checks no longer fail with a retrieval error.** The update feed had grown large enough that its download host began rate-limiting it (HTTP 429), so a check would sometimes report "An error occurred in retrieving update information" instead of offering the update. Release notes are now linked and fetched on demand rather than embedded in the feed, shrinking it roughly 30× (≈600 KB → ≈20 KB) so it downloads reliably.
- **Model-specific Codex weekly limits are visible.** Additional Codex model quotas, including GPT-5.3-Codex-Spark, now render both their 5-hour and 7-day rows instead of only the 5-hour row.
- **Real-data QA mirrors saved setup.** The local real-data shadow runner now chooses the saved preferences domain that contains language and onboarding settings, so validation launches in the same language instead of reopening setup.
- **Dashboard provider filtering is consistent.** Activity, composition, and trends now use the same enabled-provider scope, preserve "Other" model usage in stacked trends, and keep sparse ranges visually anchored to the selected window.

## [0.2.38] — 2026-07-06

#### Summary
- Import history directories are handled safely in sandboxed App Store builds, and updates continue to flow without breaking local folder permissions.
- QuotaMonitor can start automatically after sign-in, with a settings switch if you want to disable launch-at-login behavior.
- Update and release links now point directly at the current repository to prevent migration-related update errors.

### Added
- **App Store history folder access.** App Store builds now save read-only security-scoped bookmarks for selected Codex and Claude history folders, so local history import can stay inside the macOS sandbox.
- **Launch at login by default.** QuotaMonitor now registers as a macOS login item on launch and exposes a General settings toggle so users can turn it off.

### Changed
- **Current GitHub release links.** Sparkle feed URLs, appcast download links, README links, and release tooling now point directly at `timmyagentic/quota-monitor` instead of relying on the old repository owner redirect.

### Fixed
- **Automatic Sparkle feed repair for old installs.** Existing users whose installed app still stored the legacy `SUFeedURL` will have it repaired automatically on first launch, so update checks work after the repository migration.

## [0.2.37] — 2026-07-01

#### Summary
- Claude usage around midnight no longer makes a previous day's Dashboard total keep changing while you keep working

### Added
- **Architecture guide (`CLAUDE.md`).** Added a concise architecture map covering the `AppEnvironment` hub, the two data planes, and common editing pitfalls, complementing the existing contributor guide.

### Fixed
- **Claude daily usage stays stable after midnight.** When Claude Code finishes streaming a message after the local day changes, QuotaMonitor now keeps the earlier day's total fixed, records only the newly observed token delta on the later day, and rebuilds existing local Claude usage once after upgrade.

## [0.2.36] — 2026-06-29

#### Summary
- Contributors now have a concise setup guide for project layout and local checks
- Existing installs that already picked a language no longer see the Landing Page again after updating
- Long-time users who got stuck on the setup screen after an update (with their usage meters frozen) are now recognized and taken straight to the app
- Claude live usage keeps updating on its own instead of freezing when its sign-in token expires, and Refresh re-checks Claude right away
- The Claude usage meter now refreshes about every 10 minutes instead of every 2 hours, so it stays current
- Claude usage and cost now update the moment you use Claude Code, without opening the menu
- When an app update is available, a small update icon stays visible until you install or skip it

### Added
- **Contributor guide.** Added a concise repository guide covering project layout, common commands, testing expectations, and contribution steps.
- **Claude usage updates live as you work.** QuotaMonitor watches your Claude transcript folder and refreshes local Claude usage/cost the moment Claude Code writes to it, instead of only when the menu is opened. The rescan is Claude-only and throttled, so it never re-parses Codex history and can't scan on every small append.

### Changed
- **Claude live usage refreshes ~every 10 minutes (was 2 hours).** The scheduled `/api/oauth/usage` poll cadence drops from 7200s to 600s so the 5h/7d quota meter stays current; the existing 429 cooldown ladder (5 min → 30 min, honouring `Retry-After`) still backs off automatically if the endpoint rate-limits us.
- **Removed the dead Claude CLI refresh trigger (internal).** The legacy `claude --version` spawn-to-refresh path (`ClaudeCLIRefreshTrigger`) has been unused since QuotaMonitor began refreshing the Claude token itself via a direct OAuth grant; it and its cooldown / Keychain-polling machinery are deleted. The still-needed `claude` binary-location helpers moved to a focused `ClaudeBinaryLocator` used only for Claude Code version detection. No user-facing behaviour change.

### Fixed
- **Update onboarding no longer repeats for language-only profiles.** Existing installs that had already saved a language choice now skip the Landing Page even if older builds never wrote provider onboarding markers.
- **Existing installs stranded mid-setup are repaired.** A user with real usage history left at `providerStepStarted=true` / `providersDone=false` by a bad upgrade launch is now recognized as an existing user and skips provider onboarding, instead of being re-gated on every launch — which silently froze live quota polling.
- **Claude live usage no longer freezes when its token expires.** QuotaMonitor now refreshes the Claude access token itself instead of relying on a `claude` CLI side effect that stopped working, so the 5h/7d meters keep updating once the token lapses.
- **Refreshed Claude tokens stay private.** Rotated tokens are kept in QuotaMonitor's own cache and are never written back to your Claude Code credentials, so a refresh can't disrupt the `claude` CLI's own login.
- **Clearer Claude sign-in state and a more responsive Refresh.** When a refresh genuinely fails (token revoked) the menu bar shows a re-login hint instead of leaving stale numbers, and the Refresh button now bypasses the 60-second poll gap so a click always re-checks Claude.
- **Update prompt stays visible.** When Sparkle finds a new version, QuotaMonitor now keeps a small update icon in the main window, menu popover, and Settings until you install or explicitly skip the update.

## [0.2.34] — 2026-06-21

#### Summary
- Codex now shows available reset cards and their expiration times in the menu bar
- Claude live quota cards now keep their last numbers visible while waiting to refresh
- Existing settings now stay intact after update repairs, preserving configured providers and menu-bar preferences
- Claude credential disk cache now stays enabled by default when unset, reducing repeated Keychain prompts after local rebuilds
- History and Sessions now show real session titles, falling back to the project name only when no title exists

### Added
- **Codex reset-card visibility.** The menu bar now shows how many Codex active reset cards are available and when the available cards expire.
- **Mac App Store readiness check.** The project now has a documented local preflight for an App Store-friendly build, so future store work can be evaluated before any account or release-credential changes.

### Changed
- **Claude credential disk cache defaults on when unset.** New installs and existing users without a saved preference now get the Claude credentials disk cache enabled and persisted by default, reducing repeated macOS Keychain prompts after local rebuilds; users who turn the setting off keep that explicit choice across later updates.

### Fixed
- **Update repairs preserve settings.** Existing installs that already configured providers or menu-bar preferences now keep those choices when the app repairs older onboarding state.
- **Claude live quota refreshes stay readable.** When Claude temporarily delays live quota refreshes, the menu bar keeps the last successful quota snapshot visible and labels when it will try again.
- **Session rows show clearer titles.** History, Sessions, and Session Detail now keep project folder names as secondary metadata, use real session titles when available, and fall back to the project name instead of “Untitled session” when no title exists.

## [0.2.33] — 2026-06-15

#### Summary
- New downloads open normally, while existing installs keep updating in place
- Developer diagnostics now use clearer structured levels for easier troubleshooting
- Log inspection docs now use the correct macOS error predicate
- The app icon now sits cleanly on dark Dock and Finder backgrounds
- Today's usage and spend now appear right away across the dashboard instead of only showing up the next day
- Long-running installs stay fast — usage history no longer piles up and slows things down over time
- Near-midnight usage now lands on the correct local day and month across daylight-saving changes

### Added
- **Architecture review backlog.** Added `docs/architecture-review-2026-06-14.md` cataloguing known correctness, performance, concurrency, and maintainability issues to triage and fix incrementally.

### Changed
- **Trusted release delivery.** Public releases now use Apple Developer ID distribution while keeping the same Sparkle update identity, so installed copies can keep using in-app updates.
- **Structured developer logging.** Developer diagnostics now mirror info, warning, and error events into macOS unified logging with stable event names, provider, result, trigger, and reason fields, while the opt-in Developer Mode JSONL file keeps the same structured records for local troubleshooting.

### Fixed
- **Unified log error query.** The README now filters macOS unified logs with `logType == "error"` instead of the unsupported `log show --level error` flag.
- **App icon transparency.** The committed app icon now preserves transparent rounded corners, preventing a white square from appearing behind the icon on dark backgrounds.
- **Today's usage counts immediately.** Dashboard composition, burn-rate forecasts, and the usage and rate-limit charts now include events from earlier today instead of dropping them until the next day.
- **Monthly totals include the first day in your time zone.** The monthly usage chart no longer drops first-of-month activity whose UTC instant lands in the previous month, so the earliest month's totals are complete in time zones ahead of UTC.
- **Bounded rate-limit history.** Live Codex and Claude usage samples are now trimmed to a rolling 7-day window (always keeping the latest snapshot per window), so the local database no longer grows without limit and cold-start plus refresh stay fast on long-running installs.
- **Daily, monthly, and History charts bucket by your local day across DST.** Usage near midnight now lands on the correct local day and month all year, instead of occasionally shifting into the neighbouring day when the event fell in the opposite daylight-saving half of the year.

## [0.2.32] — 2026-06-12

#### Summary
- Dashboard's tool selector now stays neatly in the title bar without crowding the window buttons
- Claude settings now hide the credential-source picker and offer recovery only when automatic refresh is disabled
- Claude 5-hour quota rows keep the last reset value visible instead of turning into an empty idle line
- Claude Code model statistics are more accurate, and Claude Fable 5 usage can be priced

### Added
- **Product manual.** A new Chinese guide explains onboarding, the menu-bar popover, Dashboard, History, Sessions, Settings, updates, and uninstall flows with screenshots.

### Changed
- **Claude credential settings.** Advanced settings now use automatic Claude credential refresh by default, hide the file-only/Keychain picker from normal use, and show a restore button only when a saved file-only mode can stop live quota refreshes.
- **QA launch naming.** Local test-version checks now point to real-data shadow QA by default, while the fixture launch path is renamed to fixture-smoke for deterministic regression checks.

### Fixed
- **Dashboard filter layout.** The title-bar tool selector now uses a stable labeled menu, preventing it from collapsing into a tiny control or overlapping the window title after opening or moving the window.
- **Local QA preference isolation.** QA runs now refuse the installed app's preferences domain, preventing QA-only defaults from leaking into installed app settings.
- **Claude reset quota row.** When Claude's current 5-hour window has reset and the next `/usage` response only reports 7-day quota, the popover keeps the last 5-hour percentage greyed out with a reset hint.
- **Claude Code model statistics.** Claude imports now keep the final usage snapshot for each streamed message, so model totals and cost estimates no longer undercount output tokens; Claude Fable 5 usage also has a bundled price seed.

## [0.2.31] — 2026-06-08

#### Summary
- Windows open and switch more predictably, so Settings, Dashboard, and Help are easier to return to
- Update prompts are clearer, with the important changes visible before you install
- Quota numbers stay more useful when live data is temporarily unavailable
- Refresh feels more responsive: clicking refresh updates right away, while background checks stay quieter

### Changed
- **AppKit window ownership.** Dashboard, Settings, onboarding, and the menu-bar recovery guide now share one AppKit window manager, making window opening and focusing more consistent.
- **Codex usage refresh throttling.** Automatic Codex live quota refreshes now skip redundant requests within a short window, while manual refresh still bypasses that short-window throttle.
- **Static QA default.** `qa/run-all.sh` now delegates to `qa/run-static.sh` and no longer launches a new QuotaMonitor instance.
- **Computer Use owns visible app validation.** The standard visible QA path is `qa/prepare-computer-use-fixture.sh` or `qa/prepare-computer-use-real-data.sh` followed by Computer Use.
- **Real-data QA preserves visible preferences.** `qa/prepare-computer-use-real-data.sh` now copies the current QuotaMonitor UserDefaults into the isolated QA suite, while still overriding credential-sensitive settings.
- **Testing circuit documentation.** `docs/local-qa.md`, `docs/computer-qa.md`, and the project QA skill now describe the same responsibilities: static gate, Computer Use setup, Computer Use walkthrough, and artifact replay.
- **Gated macOS CI.** The required `swift-test` check now runs a fast summary job first and starts the macOS Swift suite only for app, test, QA, resource, package, tool, or workflow changes on ready PRs.

### Added
- **Isolated Local QA harness.** Local QA runs now launch QuotaMonitor with an isolated profile, fixture data, redirected Codex/Claude homes, and machine-checkable artifacts for app state, database counts, logs, screenshots, and accessibility snapshots.
- **Computer Use QA workflow.** Interactive fixture and real-data shadow runs now produce a per-run brief with the exact QA app path, making visible Dashboard, History, Sessions, Settings, and help-window checks repeatable without targeting the installed app by mistake.
- **PR changelog enforcement.** Pull-request CI now requires both English and Simplified-Chinese changelog updates for non-appcast PRs, then validates the section that will appear in the update window.

### Fixed
- **Menu-bar readout follows Settings.** When the selected provider has no live quota sample yet, the menu-bar item now keeps the configured text readout with dash placeholders or the dashboard quota snapshot instead of falling back to the gauge icon.
- **Codex popover quota fallback.** The Codex menu-bar card now uses the dashboard quota snapshot when live CLI quota fetching is unavailable, avoiding a misleading sign-in prompt during real-data QA runs.
- **Settings window layout after upgrade.** AppKit-hosted Settings now reuses the old Settings window frame key while keeping the pane width aligned with the original grouped Settings layout.
- **Update-window Dock cleanup.** Closing the Sparkle update window now lets QuotaMonitor return to menu-bar-only mode when no other app window is open.
- **Codex quota source isolation.** Codex quota cards and history now ignore Claude OAuth samples that share the same storage table, preventing provider views from crossing over.
- **Codex refresh diagnostics.** Codex rate-limit refreshes keep a timeout guard on the poller path, failed operations now close their developer-log entry, active 429 cooldowns report the cooldown reason before normal automatic-poll throttling, and only a genuine HTTP 429 (not an unrelated error that merely contains the digits 429) starts a cooldown.
- **Installed app restoration after QA cleanup.** QA cleanup now records whether `/Applications/QuotaMonitor.app` was already running, closes only QA-launched processes, and restores the installed app when needed.
- **Update window no longer blanks on empty release notes.** When an appcast item ships no description, the update window now shows a short placeholder and keeps Install enabled instead of rendering an empty web view; the previous emptiness check ran on the always-wrapped HTML, so it never fired.

### Removed
- **Old app E2E entrypoint.** `qa/run-local.sh` has been removed so the QA architecture has no separate visible-app test layer outside Computer Use.

## [0.2.30] — 2026-06-01

#### Summary
- Dashboard and Settings now link to each other from their top-right toolbar buttons
- Icon-only navigation buttons now show quicker hover help so users can identify them without waiting

### Added
- **Dashboard and Settings cross-links.** Dashboard now includes a top-right Settings shortcut, and Settings includes a matching Dashboard shortcut, so users can move between the two windows without returning to the menu bar.
- **Fast hover help for the new navigation icons.** The toolbar shortcuts use a shorter hover delay than the system default tooltip timing, making icon-only actions easier to understand.

## [0.2.29] — 2026-05-31

#### Summary
- Update windows now show the embedded HTML change log instead of a blank panel

### Fixed
- **Release notes HTML now loads in the custom Sparkle update window.** WebKit reports `loadHTMLString(..., baseURL: nil)` as an initial `about:blank` navigation on current macOS, so the updater now allows that initial document load while continuing to block external navigation.

## [0.2.28] — 2026-05-31

### Added
- **Pricing seeds for newly observed Claude and GLM models.** QuotaMonitor now ships bundled catalog rows for `claude-opus-4-8`, `claude-sonnet-4-5-20250929`, `glm-4.7`, and `glm-5.1`, so imported usage for those model IDs is priced on first launch instead of staying at `$0`.

### Fixed
- **Sparkle update signatures now match the published DMG bytes.** The release workflow signs the DMG produced by GitHub Actions and opens the appcast PR automatically, avoiding the previous failure mode where a locally signed DMG differed from the file Sparkle downloaded.
- **Existing 0.2.26 and 0.2.27 appcast entries were repaired.** Their signatures and lengths were regenerated from the CI-built release assets, so Sparkle can validate those updates correctly.

## [0.2.27] — 2026-05-31

### Fixed
- **Sparkle now selects Chinese release notes on Chinese macOS.** Added `CFBundleLocalizations` (en + zh-Hans) to Info.plist so Sparkle's appcast parser knows the app supports Simplified Chinese and picks `<description xml:lang="zh-Hans">` accordingly.

## [0.2.26] — 2026-05-30

#### Summary
- Dashboard now shows a usage profile: lifetime tokens, peak day, active-day streaks, and a GitHub-style heatmap
- Update notifications have a fresh new look with animated release notes and dark mode support

### Added
- **Dashboard "Activity" section.** A usage profile: a four-up stat strip (lifetime tokens, peak-day tokens, current streak, longest streak) above a GitHub-style token-activity heatmap. Every figure follows the active provider filter and is derived entirely from the existing local history — no new data collection or schema change.
- **Custom Sparkle update UI.** Replaces Sparkle's standard system-style update alert with a SwiftUI window presenting a `WKWebView` for animated, visually polished release notes. Supports dark mode, `prefers-reduced-motion` accessibility, and bilingual release notes (en + zh-Hans). Release notes are now authored as HTML for full visual control — images, CSS animations, and rich layouts are all possible.
- **HTML release notes pipeline.** `tools/release-sparkle.sh` now reads from `ReleaseNotes/<version>.{en,zh-Hans}.html` when present, giving full HTML control over the update dialog content. Falls back to `changelog-to-html.py` conversion when HTML files are absent.

## [0.2.25] — 2026-05-23

### Added
- **Codex desktop-app installs now work without a separate CLI on PATH.**
  QuotaMonitor still prefers an explicit `CODEX_BINARY` override and the
  user's login-shell `codex`, but now falls back to the first-party
  `Codex.app` bundled binary at
  `/Applications/Codex.app/Contents/Resources/codex` (and the matching
  `~/Applications` path). This lets live Codex quota rows update for users
  who installed only the Codex desktop app.
- **Claude Desktop's bundled Claude Code build is discovered automatically.**
  When no standalone `claude` binary is available, the refresh trigger now
  probes
  `~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude`
  and chooses the newest executable bundle. This covers Claude Desktop
  installs that have downloaded the native Claude Code helper, while leaving
  the pure Claude Desktop web-session token cache untouched.
- **Resolver tests now cover app-only installs.** New tests pin Codex
  binary resolution, Claude binary resolution, Claude Desktop bundle
  discovery, and non-interactive Claude Keychain query construction.

### Changed
- **Menu-bar popover now only shows scan status while a scan is active.**
  The always-visible "Last scan / files / changed / events" summary is
  hidden again to keep the compact menu focused on quota state and the
  primary actions. Manual refresh still shows the live scan progress bar.
- **Claude Keychain fallback is explicitly non-interactive.** Settings copy
  now says Keychain is used only when macOS allows a silent read of an
  already-authorized `Claude Code-credentials` item. QuotaMonitor no longer
  describes this path as something that may pop a prompt from the background
  poller.

### Fixed
- **Live quota progress bars recover from broken package-manager shims.**
  The binary resolvers now prefer the user's login-shell path before
  hardcoded Homebrew locations, so a stale executable shim no longer blocks
  an otherwise working nvm/asdf/bun install.
- **Claude live quota polling no longer hangs inside Security.framework.**
  Production Keychain reads now shell through `/usr/bin/security` with a
  short timeout and decode either the JSON credential wrapper or a legacy
  bare token. If the item needs interaction, QuotaMonitor records the
  credential source as unavailable instead of leaving the poller suspended.
- **Menu-bar window height is pinned to content.** `MenuBarExtra(.window)`
  now uses content-size window resizability plus a fixed vertical content
  size, avoiding the blank bands macOS could preserve after provider blocks
  were hidden.
- **Local builds are more reliable on CLT-only machines.** `build.sh`
  sources Swiftly when available and passes `--disable-keychain` to SwiftPM
  so public dependency resolution does not stall in macOS Keychain access.

### Known limitation
- **Pure Claude Desktop auth is not read directly.** Claude Desktop stores
  its own `oauth:tokenCache` in Electron safeStorage under
  `~/Library/Application Support/Claude/config.json`. QuotaMonitor does not
  decrypt or reuse that cache; live Claude quotas still require Claude Code
  OAuth credentials from `~/.claude/.credentials.json`,
  `Claude Code-credentials`, or the bundled Claude Code helper described
  above.

## [0.2.23] — 2026-05-21

### Context
- **Why this token spike appeared suddenly.** Modern Codex JSONL rows can
  emit both `token_count.info.last_token_usage` (the current event's
  usage) and `token_count.info.total_token_usage` (a cumulative session
  snapshot). In long-lived, replayed, forked, or restarted sessions those
  cumulative snapshots can repeat or move backwards while still being
  valid log rows. Older QuotaMonitor builds interpreted those rollback
  snapshots as fresh full-session deltas, which is what caused the
  massive local token overcount after a clean database rebuild. The raw
  `~/.codex/sessions` JSONL files do not need to be edited or deleted for
  this release; the fix is in how QuotaMonitor imports them.
- **This matches parser bugs seen in other Codex usage tools.**
  `codex-pacer` shipped a similar rollback-overcount fix in v1.1.2, and
  `ccusage` has tracked related duplicate / replayed `token_count`
  overcount issues. QuotaMonitor's importer now treats Codex snapshots as
  replay-prone data instead of assuming every cumulative total is a clean
  monotonic counter.

### Fixed
- **Codex token totals no longer explode on modern rollouts.** The
  importer now prefers `token_count.info.last_token_usage` as the
  per-event delta when Codex emits it, instead of deriving deltas from
  interleaved `total_token_usage` snapshots that can move backwards in
  long-running sessions. Legacy rows that only contain cumulative
  totals still use the old cumulative-diff fallback.
- **Duplicate token_count snapshots are ignored without dropping distinct
  events.** Replayed rows with the same `total_token_usage` and
  `last_token_usage` pair are skipped, while rows with a different
  `last_token_usage` remain billable. This keeps long active sessions
  from double-counting repeated status snapshots without returning to
  the previous under/over-counting behavior.
- **Malformed token_count rows with only a large `total_tokens` value are
  discarded.** Rows whose input/cache/output/reasoning buckets are all
  zero cannot be priced correctly and no longer inflate history totals.
- **DMG creation no longer collides with older mounted releases.** The
  installer volume name now includes the release version, so a stale
  `Install QuotaMonitor` mount cannot block packaging a new DMG.

## [0.2.22] — 2026-05-21

### Changed
- **Advanced settings sections reordered by relevance.** Updates now
  sits at the top of the form (it's the single most useful control
  for end users), and Developer Mode moves down adjacent to Uninstall
  where the other "rarely needed" knobs cluster. Final order: Updates
  → Codex CLI → Claude Code → Database → Export → Pricing →
  Developer Mode → Uninstall.

### Fixed
- **Sparkle release-notes dialog now renders the actual CHANGELOG
  entries** instead of a "See CHANGELOG.md for what's new in X.Y.Z"
  placeholder. `tools/release-sparkle.sh` runs the new
  `tools/changelog-to-html.py` script to extract the per-version
  section from CHANGELOG.md, convert its markdown bullet lists +
  headings + bold + code spans to inline HTML, and embed the result
  in the appcast item's `<description>` CDATA block. Sparkle's
  WebView then renders it as a proper "What's new" panel.

## [0.2.21] — 2026-05-21

### Added
- **Per-event hover popover with cache breakdown + hit rate.** Hovering
  any row in the History day-detail "events" timeline or the Session
  detail timeline now reveals a popover (200 ms hover delay, 120 ms
  dismiss delay with cursor-in-popover detection so the popover stays
  put when you move the cursor over it) listing Cache / Hit Rate /
  Input / Output / (Reasoning if non-zero) / Total. Cache is a single
  number — split into read vs write would have left "Cache Write: 0"
  on every Codex row because OpenAI's cache is server-managed. Hit
  Rate tints green ≥ 90 %, neutral 40–90 %, orange < 40 % so the eye
  can scan a long timeline for events that failed to reuse cache.
- **Provider-aware "Input" column.** Codex stores OpenAI's
  `prompt_tokens` (full prompt including the cached subset), Claude
  stores the uncached remainder. The popover now subtracts the cached
  portion on Codex rows so "Input" means the same thing across
  providers and Cache + Input + Output ≈ Total in both columns.
- **Inferred-cost warning surfaces in the UI.** When the parser fell
  back to gpt-5 because no model metadata existed in the rollout
  (the `model_inferred` flag, in the schema since v4 but never shown),
  the row now displays an orange warning triangle next to the model
  name and a footnote in the popover explaining that the cost figure
  is approximate.
- **Column headers above the event timeline.** New shared
  `EventRowHeader` struct shows "时间 / 模型 / Tokens / 金额" above
  the LazyVStack in both HistoryView and SessionDetailView, sharing
  frame widths with EventRow so the header alignment stays
  pixel-accurate.

### Changed
- **Event row layout is now four columns instead of nine.** Time /
  Model / Total Tokens / Cost. The four token-chip values
  (input / cache / output / reasoning) used to be inline; they now
  live exclusively in the hover popover. Removes ~70 % of the visual
  noise from a 908-event timeline.
- **Scan-status row collapses two lines into one.** "Scanning local
  history" and "X/Y files processed" now share a row with a Spacer
  between them; the monospacedDigit count is right-aligned so the
  number stays anchored as files stream in.

### Fixed
- **App no longer freezes when expanding a session with many events.**
  `ExpandableSessionRow` used a plain `VStack` inside its expanded
  block, which materialized every EventRow + its ~5 token-chip
  subviews on the main thread the instant the user clicked the
  chevron. With xhs-workspace's 908 events that was ~7 000 view
  bodies + layouts blocking the UI for multiple seconds. Switching
  to `LazyVStack` lets SwiftUI virtualize against the outer
  ScrollView and only materialize what's visible.

## [0.2.20] — 2026-05-21

### Fixed
- **Sparkle no longer offers a spurious "update available" for the
  installed version.** `build.sh` used to stuff the git short SHA
  into `CFBundleVersion` for traceability (e.g. `a5c2a1c`), while
  `tools/release-sparkle.sh` emits appcast items with
  `sparkle:version` set to the dotted semver (e.g. `0.2.19`).
  Sparkle compares `CFBundleVersion` against `sparkle:version` to
  decide "is this newer?" — comparing a hex SHA against a dotted
  version yielded "different, therefore newer", which meant every
  launch of v0.2.19 would have prompted users to download v0.2.19
  again forever. `CFBundleVersion` is now set to the same dotted
  version as `CFBundleShortVersionString`. Git SHA traceability
  moves into a new custom Info.plist key `BuildCommit` (read via
  `PlistBuddy -c 'Print :BuildCommit' ...`), which is invisible to
  Sparkle's comparator.

## [0.2.19] — 2026-05-21

### Fixed
- **App now launches.** v0.2.18 shipped a regression where the
  embedded Sparkle.framework could not be located by dyld at startup
  because SwiftPM's executable target only sets `@loader_path` as
  its LC_RPATH — which resolves to `Contents/MacOS/`, the wrong
  directory for frameworks that live under `Contents/Frameworks/`.
  Every v0.2.18 launch SIGABRTed with `Library not loaded:
  @rpath/Sparkle.framework/...` before the menu-bar icon could
  appear. `build.sh` now runs `install_name_tool -add_rpath
  "@executable_path/../Frameworks"` against the binary before
  embedding Sparkle.framework and re-signing, which restores the
  standard macOS bundle search path. **v0.2.18 should be considered
  unusable; this release supersedes it.**

## [0.2.18] — 2026-05-21

### Changed
- **Sparkle is now actually functional.** v0.2.17 shipped the
  framework + UI but with an empty `SUPublicEDKey` placeholder, so
  Sparkle had no way to verify a downloaded update. This release
  embeds the real maintainer Ed25519 public key into `Info.plist`,
  so v0.2.18+ users get end-to-end signed auto-updates: from this
  version forward, Sparkle can verify any signed appcast item and
  install it in place. (Going from v0.2.17 → v0.2.18 itself is still
  manual because v0.2.17's empty key blocks signature verification.)
- **Signing uses the macOS Keychain instead of a key file on disk.**
  `tools/release-sparkle.sh` now reads the private key directly from
  the login Keychain via `sign_update --account quotamonitor`. The
  key never has to exist as plaintext bytes on disk. The
  `QM_SPARKLE_KEY` env var (path override) is replaced by
  `QM_SPARKLE_ACCOUNT` (Keychain account name override). `docs/release.md`
  is rewritten around the Keychain flow + offline backup / restore.

### Fixed
- **Appcast pubDate now RFC-822 regardless of system locale.**
  `tools/release-sparkle.sh` pins `LC_ALL=C` around the `date` call
  that produces `<pubDate>` so the string is always English month +
  weekday instead of whatever locale the maintainer happens to be in
  (RSS spec requires English).

## [0.2.17] — 2026-05-21

### Added
- **Auto-update via Sparkle.** QuotaMonitor now ships with the
  Sparkle framework wired into a signed appcast hosted in this repo.
  Once the maintainer has generated an Ed25519 key pair (see
  `docs/release.md`), every subsequent release becomes a one-click
  in-app upgrade: Sparkle polls the appcast on a 24h schedule,
  surfaces the standard macOS "Update available" alert when a new
  version is published, downloads + verifies the Ed25519 signature,
  quits the running instance, swaps the bundle in `/Applications`,
  and relaunches. Solves the "user updated by dragging the new .app
  in but the old process is still running so nothing happens" trap.
- **Settings → Advanced → Updates.** New section with an "Check for
  updates automatically" toggle (bound to Sparkle's
  `SUEnableAutomaticChecks`), a "Check Now" button, and a "Last
  checked" relative timestamp. Toggle and timestamp stay in sync via
  KVO → `@Observable` bridging in the new `UpdaterController` wrapper.

### Internal
- New `Core/Updater/UpdaterController.swift` wraps
  `SPUStandardUpdaterController` and exposes Sparkle's KVO state
  (`canCheckForUpdates`, `lastUpdateCheckDate`,
  `automaticallyChecksForUpdates`) as `@Observable` properties so
  SwiftUI views can bind directly without importing Combine at each
  call site.
- `build.sh` now copies the resolved `Sparkle.xcframework` macOS
  slice into `.app/Contents/Frameworks/Sparkle.framework/` after
  every build. SwiftPM links the dylib at build time but won't embed
  the framework's runtime payload (Autoupdate.app, XPCServices) —
  doing it by hand is the SwiftPM-as-app workaround. `codesign
  --deep` then re-signs the framework + its nested signed components.
- `appcast.xml` lives at the repo root, currently empty.
  `tools/release-sparkle.sh` signs the per-release DMG with the
  Ed25519 private key (read from `~/.config/sparkle/` by default;
  `QM_SPARKLE_KEY` overrides) and prints a ready-to-paste appcast
  `<item>` block. `.gitignore` patterns defend against accidentally
  committing the private key.
- `Resources/Info.plist` gains `SUFeedURL`, `SUPublicEDKey` (empty
  placeholder; must be filled in before the first signed release),
  `SUEnableAutomaticChecks` (default on), and
  `SUScheduledCheckInterval` (24 h).

## [0.2.16] — 2026-05-20

### Added
- **Developer Mode persistent diagnostics.** Settings → Advanced now
  includes a Developer Mode toggle that writes lifecycle, refresh,
  scan, pricing, query, settings, migration, and uninstall diagnostics
  to `~/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log`.
  Records are structured JSONL with operation IDs that thread parent /
  child calls together, automatic redaction of sensitive fields, and
  size-based rotation. The file logger is off by default, creates its
  parent directory on demand, escapes multiline messages, and exposes a
  "Reveal Log File" button for support / debug sessions.
- **Quota percentage display mode.** General settings now exposes a
  "Used vs Remaining" toggle that flips every quota percentage between
  the two framings. Applies to the menu-bar icon, the popover quota
  rows, and the Dashboard forecast rows; the choice persists across
  launches.

### Changed
- **Refresh fan-out is now centralized.** Cold launch, popover-open
  auto-refresh, and the explicit Refresh button all route through the
  same `refreshAll(throttle:)` path. Cold launch performs an immediate
  full refresh + local scan and warms the Dashboard cache; popover-open
  uses throttles; the button remains explicit user intent and bypasses
  those throttles.
- **Passive refresh feedback is less misleading.** The menu-bar
  Refresh button no longer changes to "Refreshing..." or disables just
  because a background scan started from opening the popover. Scan
  status now lives in the progress row, while the refresh actions keep
  their own re-entrancy guards.
- **Claude cache-creation billing now splits 5-minute and 1-hour
  writes.** A new schema migration adds `cache_creation_5m_tokens` /
  `cache_creation_1h_tokens` columns and re-reads existing Claude
  rollouts so historical rows pick up the split. The pricing backfill
  bills 1h cache writes at 2x base input while 5m writes keep the
  catalog `cache_creation` rate; seeded Claude prices were refreshed to
  the April-2026 list rates. See `docs/billing-logic.md` for the full
  pricing pipeline.
- **L10n copy.** "Indexing local history" → "Scanning local history"
  so the wording lines up with the rest of the scan-status UI.

### Fixed
- **Menu-bar auto-refresh now fires when the popover opens.**
  `scenePhase` is app-wide and does not change just because a
  `MenuBarExtra(.window)` popover is toggled, so the previous hook
  silently missed the common open-popover path. The refresh now hangs
  off `.onAppear`, which remounts on each popover open.
- **Main-window Reload works outside Dashboard.** The toolbar Reload
  button now remounts the active tab, so History and Sessions re-run
  their own list-loading tasks instead of only refreshing the Dashboard
  snapshot.
- **Popover no longer shows a "Loading…" placeholder during the
  cold-launch scan.** Launch now hydrates `menuBarSnapshot` from the
  database before the initial scan completes, so opening the popover
  during a first-run scan immediately surfaces the previous run's data
  instead of a generic spinner. The scan-tail refresh still overwrites
  it with fresh numbers once the scan finishes.

### Internal
- **Post-refactor dead-code sweep.** Removed the unused
  `account/read` JSONRPC method and `AccountReadResult` decoder,
  six `RateLimitsPayload` fields that were decoded but never read
  (`userId`, `accountId`, `email`, `credits`, `spendControl`,
  `rateLimitReachedType`) plus their `Credits` / `SpendControl`
  helper structs, two write-only `@Observable` properties
  (`lastPricingFetchedAt`, `lastPricingUpdateCount`), and six unused
  L10n keys. Marked `isRefreshingPricing` as `@ObservationIgnored`
  since no view observes it. Net –80 lines.

## [0.2.15] — 2026-05-20

### Fixed
- **First-run setup now starts and explains the initial scan.** After
  onboarding finishes, QuotaMonitor explicitly starts a local history
  scan instead of waiting for the menu-bar popover's foreground
  refresh hook. While the scan is running, the menu-bar status now
  shows "Indexing local history" / "正在建立索引", the current file,
  processed file count, and a linear progress bar so a large first
  import no longer looks like an endless spinner.
- **Codex rollout scans skip irrelevant payload decoding.** The
  importer now reads the JSONL envelope discriminator first and only
  decodes payloads for `session_meta`, `turn_context`, and
  `event_msg(type=token_count)`. Large `response_item` lines are
  skipped without building a full `JSONValue` tree and re-encoding it,
  cutting the hot parse path on large first scans while preserving
  parsed usage/rate-limit results in regression checks.
- **Codex JSONL rate-limit samples no longer require usage info.**
  Some Codex `token_count` rows carry `rate_limits` while `info` is
  `null`. The parser now retains those primary/secondary samples and
  `plan_type` instead of dropping the whole row just because it has no
  token delta.
- **In-app uninstall now removes stale installed app copies.** The
  uninstaller no longer only moves the currently-running bundle to
  Trash. It also scans trusted install locations
  (`/Applications` and `~/Applications`) for `QuotaMonitor.app` and
  legacy `CodexMonitor.app` copies, then removes only candidates whose
  `Contents/Info.plist` bundle id matches `dev.tjzhou.QuotaMonitor` or
  `dev.tjzhou.CodexMonitor`. This fixes the reinstall flow where a user
  ran a dev/DMG copy, clicked Uninstall, and Finder still prompted to
  replace an existing `/Applications/QuotaMonitor.app`.

## [0.2.14] — 2026-05-20

### Added
- **Pricing catalog viewer in Advanced.** Settings → Advanced →
  Pricing → "View Catalog" opens a sheet with the per-model rate
  table (input / cached / output / cache-creation $/M, plus a
  LIVE / LOCAL / SEED source badge per row). The top-level Pricing
  tab was folded into Advanced back in 0.2.8 and lost the inspection
  surface; this restores it as a read-only sheet without making
  pricing a first-class concern again. Sync from LiteLLM and Restore
  Defaults still live alongside the View Catalog button on the same
  row.
- **General-tab Codex Billing section.** A "Codex Fast-Mode billing"
  toggle for users on Fast Mode — the Codex CLI doesn't tag each
  request with its billing tier, so this is a global re-price that
  also backfills history. Placed at position 2 (after Appearance,
  before Language) so it's discoverable for the audience that needs
  it without distracting users who don't.

### Changed
- **Codex Fast-Mode help copy reworded.** Drops the multiplier
  internals (2.5× / 2× per model) that users shouldn't have to know
  about and prefixes the explanation with the upstream constraint
  ("Due to Codex limitations, the CLI doesn't tag each request with
  its billing tier"). Ends with a plain rule of thumb — turn it on
  if you regularly use Fast Mode.
- **Advanced settings hide untracked-provider sections.** The Codex
  CLI and Claude Code sections in Advanced are only shown when the
  matching provider is enabled in General → Tracked tools. Showing
  knobs whose poller is already off was just dead controls; same
  filter the menu-bar block / Dashboard already apply.

### Removed
- **Codex binary / `CODEX_HOME` / Claude home path overrides.**
  Settings → Advanced no longer asks the user to type in path
  overrides for the Codex executable, the Codex sessions directory,
  or the Claude home directory. Resolving these is the app's
  problem to solve — it now autoprobes environment variables
  (`$CODEX_BINARY`, `$CODEX_HOME`) and well-known install
  locations. If a path can't be found, that's a bug we need to fix,
  not a knob to expose. The corresponding L10n strings and
  `SettingsStore.codexBinaryOverride` / `codexHomeOverride` /
  `claudeHomeOverride` properties are gone with no migration shim;
  any previously-stored values in UserDefaults are silently ignored.

### Fixed
- **Re-enabling a tracked tool restores its menu-bar icon.**
  Toggling a provider off in General → Tracked tools used to also
  drop it from the menu-bar icon set, but re-enabling the provider
  never re-seeded the icon — the slot stayed empty until the user
  manually re-checked it in the menu-bar provider picker. The icon
  set is now stored as user intent (independent of which providers
  are currently tracked); the renderer filters by enabled providers
  at draw time. The fix also catches an adjacent bug where Swift's
  `didSet` doesn't fire on the initializer's first assignment, so
  on a fresh install the initial icon-providers seed was never
  persisted to UserDefaults — the next launch re-derived from
  `enabledProviders` and the user's earlier choice didn't survive.
  Three regression tests (in-process, cross-relaunch, explicit-off
  survives) added to `EnabledProvidersTests`.

## [0.2.13] — 2026-05-19

### Added
- **Dock icon visibility toggle.** Settings → General → Appearance
  now has a "Show Dock icon when windows are open" toggle, default
  OFF. By default QuotaMonitor stays a pure menu-bar agent — no
  Dock icon ever appears, even while the Dashboard or Settings
  window is open. The trade-off accepted in this default is that
  the app's windows do not appear in Cmd+Tab; users who want the
  classic Dock-icon-while-window-open behaviour can flip the
  toggle on and the change applies immediately.

## [0.2.12] — 2026-05-19

### Fixed
- **Menu-bar label no longer collapses to the gauge icon when the
  Codex CLI can't find `node`.** On nvm-managed setups, `node` lives
  under `~/.nvm/versions/node/<version>/bin` — a path the spawned-
  child PATH builder didn't know about, so the npm-installed `codex`
  shell script (which starts with `#!/usr/bin/env node`) failed at
  shebang resolution. The poller logged `env: node: No such file or
  directory` followed by `stream ended before id=init` on every
  attempt, `latestRateLimits` stayed nil forever, and the menu-bar
  label fell back to the static gauge SF Symbol — looking like the
  live-usage display had vanished. `AppServerClient` and
  `ClaudeCLIRefreshTrigger` now each cache the user's interactive
  login-shell PATH once per process (`$SHELL -ilc 'printf %s
  "$PATH"'`) and splice it into the spawned child's environment, so
  whatever the user's dotfiles add — nvm, asdf, rbenv, manual
  prependers — comes along for the ride.
- **Cold-launch menu bar warm-starts from the database.**
  `startClaudePoller` already hydrated `latestClaudeUsage` from the
  last persisted `rate_limit_samples` row before the first live poll
  fired, but `startCodexPoller` didn't. Any cold launch where the
  first Codex poll was slow or transiently failing left the menu-bar
  label on the gauge fallback icon. A new `RateLimitsHydrator`
  mirrors the Claude side, taking the max-per-(bucket, limit_name)
  across `live` and `jsonl` source rows so the freshest stored
  snapshot is rendered immediately on launch.

## [0.2.11] — 2026-05-18

### Added
- **In-app uninstaller.** Settings → Advanced now has an "Uninstall
  QuotaMonitor…" button that wipes everything the app owns under
  `~/Library/` (Application Support, Preferences, Caches, Saved
  Application State, HTTPStorages — for both the current
  `dev.tjzhou.QuotaMonitor` bundle id and the legacy
  `dev.tjzhou.CodexMonitor` id from before the rename), moves the
  `.app` to Trash, and terminates. macOS has no first-party
  uninstaller framework — Apple's "drag to Trash" only removes the
  bundle and leaves orphan data behind, which is noticeably untidy
  for a menu-bar app that writes a SQLite database. The button is
  destructive-styled and gated behind a confirmation alert. The
  Codex CLI's `~/.codex/` and Claude Code's `~/.claude/` directories
  are deliberately not touched — they're owned by the upstream
  tools, not by QuotaMonitor.

### Fixed
- **Onboarding is now a hard gate against premature Keychain
  prompts and JSONL scans.** Before this release, on a fresh install
  the menu-bar popover could trigger a refresh (which reads the
  Claude Code Keychain credential and rescans local JSONL files)
  before the user finished the onboarding wizard's "Tracked tools"
  step. That meant the macOS Keychain ACL prompt could fire — for
  data the user hadn't yet opted in to track — and a JSONL scan
  could run against providers the user intended to disable. The
  four entry points (`startBackgroundPolling`, `refreshRateLimits`,
  `refreshClaudeUsage`, `runScan`) now short-circuit while
  `hasCompletedProviderOnboarding` is false. The menu-bar popover
  itself swaps in a lock screen with an "Open setup" button so the
  user can't accidentally click Refresh either.

## [0.2.10] — 2026-05-18

### Added
- **Menu-bar popover auto-refreshes on open.** Opening the menu-bar
  card now re-pulls Codex `/rateLimits/read`, Claude `/usage`, and
  rescans the local JSONL files automatically — you no longer have
  to click Refresh to see current numbers. Implicit triggers carry
  per-action time gates (30 s on Codex, 20 s on the file scan) so
  reopening the popover three times in five seconds doesn't spawn
  three back-to-back refreshes; the Refresh button itself stays
  un-throttled because clicking it is explicit intent.
- **Claude 5-hour window idle placeholder.** When you have 7-day
  Claude data but no 5-hour activity, the menu-bar card now shows
  an explicit "idle" row instead of dropping the line entirely.

### Changed
- **Popover-triggered refresh skips the Dashboard's heavy aggregator
  query.** `runScan()` only fires from the popover (open + Refresh
  button) and the Dashboard refreshes itself when its window opens,
  so chaining the Dashboard's aggregator off every popover refresh
  was wasted work. The popover refresh now only updates the menu-bar
  snapshot, making the Refresh button feel noticeably snappier.

### Removed
- **Quota threshold notification feature.** Settings → General →
  Notifications and the per-reset desktop alert that fired the
  first time a Codex rate-limit window crossed the threshold have
  been removed. The feature only covered Codex (Claude 5h/7d windows
  have different semantics and were never wired in), and the
  menu-bar percentage is glanceable enough on its own. The stale
  `settings.notifyThreshold` key in UserDefaults from older installs
  is left alone — it's harmless dead bytes that the app no longer
  reads.

## [0.2.9] — 2026-05-17

### Fixed
- **Claude token refresh no longer wedges on a server-revoked file
  token.** 0.2.8's file-first ordering avoided the recurring Keychain
  ACL prompt but exposed an adjacent failure: a token whose local
  `expiresAtMs` is still in the future but which Anthropic has already
  revoked (split-brain refresh from another client, manual logout on
  web, etc.) kept getting handed back from the file shortcut. Every
  poll re-sent the same dead token, `/usage` 401'd, the CLI refresh
  trigger fired but didn't always produce a fresher Keychain item
  (CLI cooldown, mdat-watch timeout) — and the next call returned
  the exact same locally-fresh file token instead of consulting the
  Keychain where the CLI may have already written a successor.
  `ClaudeUsageClient` now tracks rejected tokens in a process-scoped
  set: a credential counts as usable only when it's both locally
  not-expired AND its access token hasn't been 401'd this run. The
  401 handler inserts the just-used token; the 200 handler clears
  the set. The file shortcut still skips the Keychain when the file
  is genuinely fresh, but stops looping on a revoked token.

## [0.2.8] — 2026-05-16

### Fixed
- **macOS Keychain prompt no longer fires on every launch when the
  credentials file is already fresh.** `loadAccessToken` was reading
  both `~/.claude/.credentials.json` and the `Claude Code-credentials`
  keychain item up front before checking expiry, so the keychain ACL
  prompt could fire on every cold launch even when the file token was
  perfectly valid. The function now matches what its own doc comment
  already claimed: read the file first; only consult the keychain
  when the file is missing or stale. Combined with the existing
  `mirrorClaudeKeychainToFile` opt-in (Settings → Advanced), the
  steady-state launch flow becomes one file read with zero keychain
  access. Particularly visible during development — ad-hoc rebuilds
  generate a different code signature each time, invalidating the
  keychain ACL the user just approved.

### Changed
- **Settings → Pricing has been folded into Settings → Advanced.**
  The standalone Pricing tab's only purpose was to render a read-only
  5-column catalog table; the two interactive controls users actually
  touched (Sync from LiteLLM, Restore Defaults) plus a "last synced"
  timestamp now live as a section at the bottom of Advanced. Two
  tabs (General + Advanced) reads as "the normal stuff and the
  power-user stuff," which is the truer mental model than weighting
  pricing as a first-class concern. Users who want to inspect
  specific catalog rows can read the sqlite database directly via
  Advanced → Database → Reveal in Finder.
- **Onboarding gains a menu-bar display step** when the user picks
  both Codex and Claude Code on step 2. Users tracking both CLIs can
  now decide up front which provider's quotas appear in the menu-bar
  readout, instead of inheriting the "show both" default and having
  to flip it off in Advanced after the fact. Picking only one
  provider on step 2 still skips this step — the question is
  degenerate. Upgrading users get re-prompted once via the
  `lastOnboardedVersion` reset gate added in 0.2.7.

### Performance
- **Menu-bar refresh and dashboard now share a single BillingBlocks
  snapshot.** Both surfaces previously ran independent aggregations
  on every poll, querying the same `usage_events` rows twice. They
  now consume a shared snapshot recomputed once per poll cycle.
- **GRDB reader pool capped at 3 connections** (down from the default
  5). Five concurrent readers was over-provisioning a desktop
  menu-bar app whose hottest path has at most two simultaneous
  queries (poller + dashboard view).

### Polish
- **Menu-bar live-quota readout uses a mixed-font rhythm.** Window
  labels ("5h" / "7d") render at 9pt medium next to 11pt heavy
  monospaced-digit percentages, joined by a U+2009 thin space.
  Between the two windows " · " at 9pt regular reads as a calm
  pause; between providers a triple space separates "CX …" from
  "CC …" without adding another glyph. Replaces the previous flat
  11pt semibold row with " | " separators.

## [0.2.7] — 2026-05-14

### Fixed
- **Manual Refresh now also pulls a fresh Claude `/usage` snapshot.**
  Previously the menu-bar Refresh button only re-scanned local JSONL
  files and re-pulled Codex `/rateLimits/read`; the Claude quota rows
  were refreshed solely by the 5-minute background poller, so a user
  who clicked Refresh right after their 5h reset would still see the
  pre-reset percentages until the next poller tick. The button now
  also calls `pollOnce()` on the Claude poller alongside the Codex
  refresh.
- **Claude poller's 429 cooldown is now wall-clock based** so manual
  Refresh clicks honor it. The previous `nextDelayOverride: Duration`
  was consumed by the scheduled-loop's `currentInterval()` immediately
  after a 429 was observed, leaving no state for a manual caller to
  gate against. Wiring Refresh to `pollOnce()` naively would have let
  a click ~60s into a 5-min cooldown immediately re-fire `/usage` and
  earn another 429 — the cooldown is now a `Date` that both the
  scheduled loop and `pollOnce()` consult.

### Added
- **"Rate limited, retry in X" banner** above the Claude quota rows
  while the poller is in 429 cooldown, so spam-clicking Refresh
  doesn't look like a silent no-op. The countdown ticks once per
  second via `TimelineView` and self-hides at expiry without needing
  the actor to broadcast a "cleared" event.

### Changed
- **Upgrading users are dragged back through the provider step of
  onboarding once on first launch of this release.** `SettingsStore`
  now persists `lastOnboardedVersion` and resets the provider step
  whenever that stamp is missing or older than
  `onboardingResetMinVersion` (currently "0.2.7"). Language pick is
  preserved — only the provider screen re-prompts. Bumping the
  `onboardingResetMinVersion` constant in a future release will
  re-trigger the same one-shot prompt for whatever step needs
  re-confirmation then.

## [0.2.6] — 2026-05-14

### Performance
- **Claude rollouts now read incrementally.** `ClaudeImportEngine`
  was re-parsing every rollout from byte 0 each time mtime/size
  moved, then re-inserting every `usage_event` for the touched
  session. On heavy-Claude installs that dominated each menu-bar
  refresh cost — multi-MB JSONL files re-parsed every 5 minutes
  just to discover one new assistant turn. Schema v5 adds
  `import_state.byte_offset` and a Claude-only
  `usage_events.provider_message_id` (with a partial unique index),
  so the second pass only sees appended bytes and `INSERT OR IGNORE`
  silently deduplicates any rows re-emitted across a boundary.
  `LineReader.lastLineHadNewline` lets the parser leave a mid-write
  tail for the next pass to re-read once the writer finishes. Codex
  is unchanged — its parser's cumulative→delta math needs separate
  design work before incremental scanning there is safe.

## [0.2.5] — 2026-05-13

### Changed
- **Onboarding moved to a standalone window.** First-launch language +
  provider picks used to render as a sheet attached to the menu-bar
  popover, which made the modal feel cramped if the user opened the
  status item before finishing it. The flow now lives in a centered
  Window scene of its own.

### Performance
- **BillingBlocks no longer scans every Claude usage_event** on each
  menu-bar refresh. The 5h-window aggregator now pushes a
  `WHERE timestamp >= now - (recentDays + 1) days` filter into SQL,
  so the Swift side only sees rows it might actually use.
- **Cached process-wide ISO8601 formatters.** Constructing
  `ISO8601DateFormatter()` allocates a CFLocale + CFCalendar +
  CFDateFormatter each time. We were doing this per usage event
  during scans, per row during CSV export, and per redraw for some
  list views; everything now goes through a shared
  `ISO8601.fractional` / `.plain` singleton.
- **Dropped a duplicate `PricingService.backfillAllValues`** at the
  tail of the Codex import pass. ScanController already runs it once
  per scan after both engines finish, and now skips it entirely when
  no files changed.

## [0.2.4] — 2026-05-14

### Added
- **Per-tool tracking toggles.** Settings → General → "Tracked tools"
  lets you turn off Codex or Claude Code if you only have one of the
  CLIs installed. Disabling a provider stops its background poller,
  hides its menu-bar block, and drops it from the Dashboard's
  Forecast / Composition / statline. The first-launch onboarding
  sheet has a matching second step so new users can pick what they
  actually use; Codex defaults on, Claude Code defaults off (Claude
  triggers a one-time macOS Keychain prompt and many users won't
  have it installed).
- **Live usage in the menu-bar icon.** Settings → General → "Show in
  menu bar" replaces the static gauge symbol with one or both of:
  `5h XX% · 7d XX%` for Codex and/or Claude Code. Picking both joins
  them on a single line with `CX` / `CC` prefixes; picking neither
  falls back to the gauge symbol.
- **Opt-in Claude credentials cache.** Settings → Advanced → Claude
  Code → "Cache Claude credentials to disk" mirrors the Keychain
  entry to `~/.claude/.credentials.json` so the macOS Keychain
  password prompt stops firing on every ad-hoc-signed launch. Off
  by default — moving credentials from Keychain to a plain file is
  a security trade-off and the help text spells it out.

## [0.2.3] — 2026-05-11

### Fixed
- **Refresh / scan can no longer freeze the menu bar.** If the Codex
  `app-server` child wedged (e.g. went unresponsive mid-RPC), the
  `AppServerClient` actor would block forever on `Process.waitUntilExit()`
  and every subsequent click on Refresh would queue behind it. The actor
  now `terminate()`s the child and escalates to `SIGKILL` after 2 s
  asynchronously, so the request returns instead of stranding the actor.
- **Spinner can no longer be stuck "on" forever.** `runScan` and
  `refreshRateLimits` were only flipping their `isScanning` /
  `isRefreshingRateLimits` flags back to false when the underlying work
  returned. A hung parser, wedged actor, or stuck GRDB write meant the
  spinner stayed on and Refresh stayed disabled until the app was
  quit. Both calls are now wrapped in a hard timeout (5 min for
  `runScan`, 30 s for `refreshRateLimits`); on timeout the work task is
  cancelled (best-effort), the error is surfaced, and the UI flag is
  reset.
- **Token counts no longer drop the first sample of every session.**
  `RolloutParser.computeDelta` was treating the first `token_count`
  event as a baseline and emitting no delta, which silently undercounted
  every session by its opening turn. It now mirrors codex-pacer's
  importer: the first sample IS the delta from t=0. Same fix applies on
  context-reset (post-reset cumulative is emitted as a fresh delta
  rather than dropped).
- **Rollout parsing for very large active sessions is ~300× faster.**
  The line reader's `firstIndex(of: 0x0A)` + `removeSubrange` per-line
  pattern was O(n²) on the growing buffer. On a 469 MB active rollout,
  just reading the lines took ~3 min (2.5 MB/s) — dangerously close to
  the 5-min `runScan` timeout above. The reader now keeps a cursor into
  the buffer and scans the unread region via a raw pointer. Same file:
  0.65 s (760 MB/s) for line iteration, 3.7 s for the full
  parse-and-decode pass.

[0.2.3]: https://github.com/timmyagentic/quota-monitor/releases/tag/v0.2.3

## [0.2.2] — 2026-05-07

### Fixed
- **Simplified-Chinese localization gaps in the menu bar.** The pace
  verdict labels next to each quota row ("On pace" / "X% in deficit ·
  Runs out in 47m" / "X% in reserve") and the inline duration units
  (`d/h/m`) had no Chinese translation — Chinese users saw English
  chrome on every quota row. Now route through `L10n` and emit
  `节奏正常 / 超出节奏 N% · 预计 X后耗尽 / 慢于节奏 N%`, with duration
  units rendered as `天/小时/分`. Pinned by 9 new tests in
  `QuotaPaceLabelTests` (both languages, both deficit branches, the
  cold-start gate).
- **Pace percent rounding.** A `1.789` ratio rendered as `78%` due to
  `Int()` truncation; now uses `.rounded()` so the displayed integer
  matches the intuitive value (`79%`).

### Changed
- **Unified zh terminology.** Four small but visible inconsistencies
  resolved: `token` → `Token` in help text and the count chip, `服务商`
  → `Provider` (kept latin to match the rest of the file), `5h 窗口`
  → `5 小时窗口`. The "节余 N%" reserve label that read as a
  savings/accounting term was reworded to `慢于节奏 N%` so it pairs
  symmetrically with `超出节奏 N%`.

[0.2.2]: https://github.com/timmyagentic/quota-monitor/releases/tag/v0.2.2

## [0.2.1] — 2026-05-07

### Changed
- **Renamed product from CodexMonitor → QuotaMonitor** (display: "Quota Monitor").
  Bundle ID is now `dev.tjzhou.QuotaMonitor`; OSLog subsystem follows. The
  app's first launch under the new bundle id auto-migrates the legacy
  SQLite database (`~/Library/Application Support/CodexMonitor/codexmonitor.sqlite`
  → `…/QuotaMonitor/quotamonitor.sqlite`, including `-wal` / `-shm` siblings)
  and copies every key from `defaults read dev.tjzhou.CodexMonitor` into
  the new domain (idempotent, guarded). The old `/Applications/CodexMonitor.app`
  install must be removed manually — the rename leaves it intact so the
  user can roll back if the migration misbehaves.

[0.2.1]: https://github.com/timmyagentic/quota-monitor/releases/tag/v0.2.1

## [0.2.0] — 2026-05-06

Reliability release. Fixes silent regressions caused by upstream wire-format
drift in both the Codex CLI and the Claude Code CLI, plus a long-standing
GUI-launch path bug that left spawned `codex` unable to find `node`.

### Added
- **Delegated Claude OAuth refresh to the `claude` CLI.** When the cached
  access token is expired (file + Keychain both stale) — or when the
  server returns 401 — the app now spawns `claude --version` so the CLI
  performs the OAuth refresh against
  `platform.claude.com/v1/oauth/token` and writes the rotated credentials
  back to the Keychain. We then re-read the freshest token. We never
  refresh in-app: refresh tokens **rotate** server-side, so a split-brain
  refresh between CodexMonitor and the CLI would silently revoke the
  loser's token. Single in-flight task coalesces concurrent expiry
  detections; failed attempts back off 5 min → 1 h to avoid spawn storms.
- **Multi-item Keychain disambiguation.** `Claude Code-credentials` items
  are now queried with `kSecMatchLimitAll` and sorted by
  `kSecAttrModificationDate` desc — the freshest item wins. Fixes a case
  where dev machines accumulated stale duplicate items (from prior
  in-app refresh attempts) and the keychain returned the oldest one,
  producing perma-401s.

### Fixed
- **Codex live quota stuck on "Sign in via codex CLI"** even when fully
  signed in. codex CLI ≥ 0.128 silently flipped `account/rateLimits/read`
  from snake_case (`rate_limit`, `primary_window`, `limit_window_seconds`,
  `reset_at`, `additional_rate_limits: [...]`) to camelCase (`rateLimits`,
  `primary`, `windowDurationMins`, `resetsAt`, `rateLimitsByLimitId: {...}`).
  Decoder now accepts both shapes; the duplicate `codex` entry inside
  `rateLimitsByLimitId` is dropped to avoid double-counting against the
  headline `rateLimits` group. Pinned by new fixture under
  `Tests/.../Fixtures/RateLimits/`.
- **Claude "token rejected" infinite loop** after Claude Code CLI ≥ 2.1.x.
  Newer CLI versions only update the Keychain item `Claude Code-credentials`
  on token refresh and leave `~/.claude/.credentials.json` frozen at the last
  `claude login` value. `loadAccessToken` was reading the stale file, sending
  an expired token, getting 401, then re-reading the same file on the next
  poll. `readCredentialsFile` now parses `expiresAt` (60 s skew margin) and
  returns nil if past expiry, falling through to the live Keychain copy.
  `mirrorTokenToFile` was also relaxed to overwrite a file whose `expiresAt`
  is already in the past — the previous strict no-clobber rule was locking
  the app into perma-expired tokens.
- **Spawned `codex` exiting before `initialize` responds** ("stream ended
  before id=init") on machines where `node` lives only at
  `/opt/homebrew/bin/node`. GUI launches inherit launchd's near-empty PATH,
  so the npm-installed `codex` (a JS shebang script) couldn't find its own
  interpreter. `AppServerClient.runSession` now sets
  `process.environment = augmentedEnvironment()`, prepending
  `/opt/homebrew/bin:/usr/local/bin:~/.npm-global/bin:~/.local/bin:~/.cargo/bin:~/.bun/bin`
  to PATH for any spawned subprocess.
- **Silent codex spawn failures**: stderr from the codex subprocess was
  previously never read. A `Task.detached` now drains the stderr Pipe
  line-by-line into `Log.appServer.error("stderr: …")`, so future spawn
  / shebang / auth failures show up in `log show` instead of being swallowed.
- **Claude `/api/oauth/usage` 6000 % bug** (Day-25 → Day-26 regression):
  the `utilization` field is in **percent** (60.0 = 60 %), not a 0..1 ratio.
  Decoder now uses `<= 1.5 → ratio × 100, else → as-is` heuristic for
  backward compatibility with old CodexBar 0..1 captures, pinned by
  `Tests/.../Fixtures/ClaudeUsage/live_pro_2026-04-29.json`.

### Notes
- Build pipeline / DMG layout / signing strategy unchanged from 0.1.0.

### Test coverage
- 62 tests (was 37 in 0.1.0). New suites: `RateLimitsDecoderTests`
  (camelCase wire format), `ClaudeUsageDecoderTests` (utilization
  heuristic), `BillingBlocksTests`, `PricingValueBackfillTests`,
  `SalvageBodyFromErrorMessageTests`, `ClaudeOAuthRefreshTests`
  (URL-protocol-stubbed refresh + write-back + concurrency coalescing).

[0.2.0]: https://github.com/timmyagentic/quota-monitor/releases/tag/v0.2.0

## [0.1.0] — 2026-04-30


First public release. macOS menu-bar app for tracking Codex CLI and Claude Code
usage.

### Added
- Menu-bar popover with provider blocks for **Codex** and **Claude Code**:
  rolling 30-day API-equivalent spend, sessions / tokens summary, live quota
  rows (5h, 7d, per-model 7d for Opus/Sonnet on Pro/Max).
- **Live Codex quota** via `account/rateLimits/read` against the local
  `codex app-server` binary; auto-discovery of the `codex` executable plus
  GUI-aware login-shell fallback.
- **Live Claude quota** via Anthropic's OAuth `/api/oauth/usage` endpoint,
  with hard 2-hour background polling cadence (Anthropic edge rate-limits
  this endpoint aggressively) and an exponential 429 back-off ladder.
- **Local importer** for `~/.codex/sessions/**/*.jsonl` and Claude Code
  rollouts, with cumulative→delta token reconciliation, embedded rate-limit
  sample extraction, subagent rollups, and inferred-model fallback for
  legacy sessions without `turn_context`.
- **Pricing catalog** seeded from LiteLLM with per-row local override + sync
  button. API-equivalent value backfilled per event.
- **Dashboard window** with Forecast (5h / 7d burn-rate projection),
  Trends (configurable 7-day or 30-day window), and Composition (top
  models + provider donut over the last 30 days).
- **Sessions** drilldown with title/agent/model search, recency / value /
  tokens sort, and an event-level timeline with token-class chips.
- **History** day rollups + per-day session inspection.
- **Settings** with Language picker (English / 简体中文), Codex CLI paths,
  Claude home + Keychain policy, polling interval, notification threshold,
  pricing editor, database location reveal, and CSV export.
- **i18n**: English (default) + Simplified Chinese, runtime hot-swap
  without restart, first-launch language picker.
- **Notifications** at the configurable threshold (default 85%), deduped
  per reset cycle.
- **DMG distribution** with custom installer-window background (drag-icon
  arrow + first-launch hint). Build pipeline at `tools/release.sh`:
  `swift test` → release build → ad-hoc codesign → DMG → SHA-256 →
  mount-and-verify self-check.

### Notes
- **Ad-hoc signed**, not notarized. macOS will refuse the first launch —
  right-click → Open, or `xattr -dr com.apple.quarantine` (see README).
- **No auto-update** in this release. Users will need to download new DMGs
  manually until a future Sparkle integration.

### Test coverage
- 37 tests across `RolloutParser`, `Aggregator`, `ClaudeUsageDecoder`,
  `ClaudeUsagePoller`, and `ClaudeUsageHydrator`.

[0.1.0]: https://github.com/timmyagentic/quota-monitor/releases/tag/v0.1.0
