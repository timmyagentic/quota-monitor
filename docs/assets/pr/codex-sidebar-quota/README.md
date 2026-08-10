# Codex sidebar quota evidence

The current handoff at source commit
`4216d979ec84c9b4824a0fcc8a01473da460bac3` creates neither a background nor
an outline node while the compact summary is idle. The 3.5% semantic-gray fill,
0.12-opacity outline, and shadow are created only during hover. Full Codex
window captures from intermediate builds were removed because their surrounding
sidebar contained local conversation and workspace titles. Do not add another
full-window capture here; future evidence must be cropped to the account row or
otherwise redact local history before it is committed.

`shifted-left-zh-Hans.png` is a direct 2x capture from the isolated real-data
QA build at source commit
`d3226a9d149f4908d4b3257d3729731d2f324f8a`. It verifies that the unchanged
detail card still renders cleanly after the summary and its anchored detail
surface move 16 points left. The layout regression contract verifies the new
416-point trailing anchor across normal, weekly-only, and secondary-display
frames, leaving additional clearance for Codex's official help control. No
account identity, credential, or conversation content is included.

SHA-256:
`e64474dfc1cf3f001689b268e77b3f2131b91ea2a60ac56755458fa1b5ff2877`

`summary-status-copy-zh-Hans.png` is a direct Computer Use capture from the
isolated real-data QA build at source commit
`40996a3622f38e2b7f837345170c1f02f0dae22f`. It shows the final weekly-only
summary after integrating the semantic-background change, rendering the same
compact text as the menu bar (`7d 64%` for the captured shadow snapshot), with
no additional health dot. The crop is the native 84 x 25 point overlay window
and contains no account identity or conversation content.

SHA-256:
`7745c78db4b0f792984a8c68b727e99312b965fcfbd4604fdad73b8b016305bf`

`native-overlay.png` and `native-overlay-expanded.png` are privacy-cropped
screenshots from the isolated real-data QA build. They show the
QuotaMonitor-owned native widget in the established slot immediately before
Codex's account-row help control and its hover detail card with remaining
quota, reset timing, progress, and reset-card expirations. The account name
and unrelated conversation content are excluded.

SHA-256:

- `native-overlay.png`: `62d8e1ac10e75ad64034085bcdede4cd114ecf6e74d4542533c4b311e1c52bd1`
- `native-overlay-expanded.png`: `587d5ee2c44581ac9d749a7d14e1e780ef762c1b4f29766fdeb1b76f3ca60e08`

`single-percentage-used.png` is a privacy-cropped screenshot from the isolated
fixture QA build. With the app-wide quota setting on Used, each detail row
keeps only its configured percentage in the top-right position and matches the
menu popover's caption hierarchy and green/orange/red progress styling. The
shared progress bar follows the same display direction, while redundant
refresh and local-time notes are omitted. No account identity or unrelated
conversation content is included.

SHA-256:
`36a5dc425352c2475fdaa58a06357117ac0048d3f0a3eecd9f5120814c496f43`

`refined-widget-zh-Hans.png` is the native SwiftUI fixture render captured for
PR #175 before the no-dot summary follow-up. Its branded 288-point detail card
remains current, while its summary is superseded by the direct Computer Use
capture above. The detail card begins with the same `Quota Monitor` product
title used by the menu-bar popover. No account identity, credential, or
conversation content is included.

SHA-256:
`737b4f2b6e648d5b6e6f8d54a035fbbe334394259aeba676fa97551320d1822d`

`refined-widget-title-comparison.png` is the focused visual comparison for the
title change. The left crop is the supplied menu-bar reference; the right crop
is the exact native hover-card render after the change. It intentionally
compares only the requested product-title region because the two surrounding
components have different roles and dimensions.

SHA-256:
`ca129088ad3acab48c6c98db2fc72106b10baf7f465f0f8c3b7878bb50a7dec0`

`no-scroll-expanded-zh-Hans.png` is a direct 2x capture from the isolated
real-data QA build at source commit
`c08994ea5670d5d1281a672a3babb27383dcb3cb`. It shows the final weekly-only
detail card at its measured ordinary-content height, with every row visible
and no scrollbar. The final
implementation uses `ViewThatFits` to retain a hidden-indicator scroll fallback
only when the available Codex window height is genuinely constrained. No
account identity, credential, or conversation content is included.

SHA-256:
`5e5e58b5dfe7202c8cd32791b05522eeaa45e70d419452a8c942957f478235c2`

## Legacy reference

These images document the superseded Chromium-injection implementation. They
are retained as historical PR evidence only; current builds use a
QuotaMonitor-owned native overlay and do not bundle Opsail, open a debugging
port, inject renderer assets, or relaunch Codex.

`opsail-v0.2.0-reference.png` is the upstream Opsail v0.2.0 product image
copied from the audited source snapshot
`4580d275d9910e68be2ebf6a524ce2ea6f98a5a9`.

It documents the renderer that the earlier implementation shipped through an
Opsail helper. It is a provenance/reference image, not evidence for the current
native overlay.

SHA-256:
`c60958d99126651308605092fefaf0ffe2d9b52575d3de1a396e8e7504fa0688`

`actual-expanded.png` is live evidence captured from an isolated second
ChatGPT/Codex process after the Opsail v0.2.0 helper bundled by the PR:

1. validated the signed ChatGPT application and its loopback-only CDP listener;
2. found the expected `app://-/index.html` renderer and local account bridge;
3. installed the usage UI from embedded renderer assets version `1.0.0`;
4. read the live weekly quota and reset-credit expirations; and
5. opened the real injected details card before capturing it through CDP.

The screenshot is cropped to the injected UI and placed over a neutral
background so unrelated private chat content is not published.

SHA-256:
`64d1b6e823b268b841d8c62f3bdd5bbfc295cf273f78a9b2ba538198faa238bb`
