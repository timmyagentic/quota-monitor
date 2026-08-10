# Quota Monitor 1.0 update-edition evidence

The images in this directory come from uniquely scoped, isolated QA app
bundles. They use synthetic data and do not read the installed app's database,
preferences, credentials, or account content.

Verified surfaces:

- English and Simplified Chinese update-window captures show the resizable
  1.0 release edition with its large version stage, 48 changes, localized
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

- Release-edition implementation commit: `011b2f3`
- What's New media commit: `3e3cd86`
- App version: `1.0.0`
- Build number: `10000009000`
- Embedded `BuildCommit` values: `011b2f3` for the standalone update-window
  captures and `3e3cd86` for the final What's New captures.
- Distribution configuration: Developer ID debug assembly, ad-hoc signed
  because the local Developer ID identity was unavailable.

QA evidence:

- Standalone update-window fixture directories:
  `.build/qa-artifacts/20260810T163150Z-computer-use-fixture-smoke` and
  `.build/qa-artifacts/20260810T163318Z-computer-use-fixture-smoke`
- Final What's New fixture directories:
  `.build/qa-artifacts/20260810T163514Z-computer-use-fixture-smoke` and
  `.build/qa-artifacts/20260810T163550Z-computer-use-fixture-smoke`
- Exact app target: `.build/QuotaMonitor.app`

The boundary manifest records fixture mode, a unique defaults suite and QA
home, disabled live external sources, and no copied credentials.

SHA-256:

- `bilingual-update-pages.png`: `d4f598a76e2b03b2ca31b12df45bd5e3f66b43b2a5ab9087f8dcce2e69039adc`
- `update-window.en.png`: `f6ac509535e5ee2722c53d72d78b34df62b81136495df8521e730c48e960389e`
- `update-window.zh-Hans.png`: `663fee5abcba45ab6a99e672eb5df5ffbebfdde885cc0977d92f2d1c12aa10d8`
- `whats-new.en.png`: `66191c77ebc643b433dc87dc8e524ac3d962f5fe5fd1abf54fa1aabde36f66ad`
- `whats-new.zh-Hans.png`: `023570566be7fe81bd8be81b289d566111f40741484709f1dee59b38ae87e2f9`
