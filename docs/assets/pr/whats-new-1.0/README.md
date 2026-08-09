# Quota Monitor 1.0 update-edition evidence

The images in this directory come from uniquely scoped, isolated QA app
bundles. They use synthetic data and do not read the installed app's database,
preferences, credentials, or account content.

Verified surfaces:

- English and Simplified Chinese update-window captures show the resizable
  1.0 release edition with its large version stage, 44 changes, localized
  controls, complete chapter list, and fixed action shelf.
- Computer Use read the complete WebView accessibility tree, scrolled the
  release, and jumped directly from the chapter navigation to `Removed`,
  proving that the page is not a static hero or a four-card summary.
- English and Simplified Chinese What's New pages 1 and 4 prove that the new
  update edition is bundled into the replayable product tour and that its copy,
  accessibility label, and controls follow the app language.
- `bilingual-update-pages.png` is the exact final-build comparison board for
  What's New pages 1 and 4 in both languages.

Exact builds:

- Release-edition implementation commit: `a90b3b929ed312136c462bab8f67d42b8d7182e0`
- What's New media commit: `1c223afaa79fec4354bfb6cae3f77f71e3dce88c`
- App version: `1.0.0`
- Build number: `10000009000`
- Embedded `BuildCommit` values: `a90b3b9` for the standalone update-window
  captures and `1c223af` for the final What's New captures.
- Distribution configuration: Developer ID debug assembly, ad-hoc signed
  because the local Developer ID identity was unavailable.

QA evidence:

- Isolated fixture and capture directory:
  `.build/qa-artifacts/20260809T184414Z-computer-use-fixture-smoke`
- Standalone exact-build app:
  `.build/QuotaMonitor-ReleaseEditionQA-a90b3b9.app`
- What's New exact-build app:
  `.build/QuotaMonitor-WhatsNewReleaseEditionQA-1c223af.app`

The boundary manifest records fixture mode, a unique defaults suite and QA
home, disabled live external sources, and no copied credentials.

SHA-256:

- `bilingual-update-pages.png`: `53a87f365883091e7a39e91d259a2547dd50406bcd365a94cbe8c91d2267397a`
- `update-window.en.png`: `476acc667760f0d0651456fcfbdabc861db5a1cb398fb1ba7f3f140891c1c63c`
- `update-window.zh-Hans.png`: `8de186e17eacd261dfc2bb307b2fb5c4ecc17fc88893cbc675d48538a1c497f9`
- `whats-new.en.png`: `9a5ba2bcacd64402a10285f86a0916175e9e234539350b07b573867243d0fcd7`
- `whats-new.zh-Hans.png`: `7f81a9bbb137077e0591a85f9674f5ed10dd101e382dcc5b3eb9841233f1fdd0`
