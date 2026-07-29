# Codex sidebar quota reference

`opsail-v0.2.0-reference.png` is the upstream Opsail v0.2.0 product image
copied from the audited source snapshot
`4580d275d9910e68be2ebf6a524ce2ea6f98a5a9`.

It documents the renderer now shipped unchanged through the bundled Opsail
helper. It is a provenance/reference image, not evidence of a live
QuotaMonitor-to-Codex restart test.

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
