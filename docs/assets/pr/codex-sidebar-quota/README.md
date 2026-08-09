# Codex sidebar quota evidence

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
keeps only its configured percentage in the emphasized top-right position and
the progress bar follows the same direction. No account identity or unrelated
conversation content is included.

SHA-256:
`e50b63a9909dccd8ef80134443ef4e2316e1e218aa8f9c753c4b73f182f127f5`

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
