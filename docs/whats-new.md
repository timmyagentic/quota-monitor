# What's New campaigns

QuotaMonitor uses a small, native showcase after releases with product changes
that benefit from explanation. This is separate from first-run onboarding and
from Sparkle's install-before-update release notes.

## Presentation lifecycle

- `Resources/WhatsNew/catalog.json` names one featured campaign.
- Keep the same campaign ID across ordinary patch releases. Change it only for
  a release important enough to show automatically.
- Existing users see an unseen automatic campaign on their next deliberate app
  interaction. Login-item launches never steal focus.
- Fresh installs complete onboarding instead; the current campaign is marked
  handled so it does not appear as an old update tour on the second launch.
- Local QA never presents or persists a campaign automatically. Use the
  explicit `open-whats-new` step.
- The menu popover and Settings keep permanent manual reopen entries.

Only the newest featured campaign is presented when a user skips multiple app
versions. Updating the featured ID does not require changing onboarding keys.

## Content and media

Campaign copy is bilingual (`en` and `zh-Hans`) and every page needs a unique
ID, title, body, media item, and localized accessibility description. Media
paths are relative to `Resources/WhatsNew`; remote URLs, absolute paths, and
parent traversal are rejected.

Recommended assets:

- Images: PNG, optimized, with a stable aspect ratio.
- Video: short silent H.264 MP4, normally 6–10 seconds and under 5 MB.
- Every video requires a poster image. Do not depend on the first decoded
  frame for fallback.
- Use synthetic or otherwise publication-safe data. Never bundle local usage
  history, credentials, names, or filesystem paths.

Videos are muted, loop only on the active page, and stop when the page/window
disappears or the app resigns active. With Reduce Motion enabled, the poster is
shown until the user explicitly asks to play.

## Adding the next campaign

1. Add publication-safe media under a new dated directory.
2. Append the campaign to `catalog.json` and point `featuredCampaignID` at it.
3. Leave `autoPresent` off for content that should be manual-only.
4. Run `swift test --disable-keychain --filter WhatsNew` and the full
   `./qa/run-static.sh` gate.
5. Launch isolated visual QA with:

   ```sh
   QUOTAMONITOR_QA_STEPS='open-dashboard,open-settings,open-whats-new,wait,snapshot' \
     ./qa/prepare-computer-use-fixture-smoke.sh
   ```

6. Verify both languages, image and video pages, playback cleanup, keyboard
   navigation, window resizing, and manual reopen. Verify the Reduce Motion
   poster path when that system setting is already enabled or changing it has
   been explicitly authorized; otherwise rely on the focused lifecycle/source
   tests and record the live check as not exercised.
