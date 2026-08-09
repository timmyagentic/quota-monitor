# Quota Monitor 1.0 update-page evidence

The images in this directory come from uniquely scoped, isolated QA app
bundles. They use synthetic data and do not read the installed app's database,
preferences, credentials, or account content.

Verified surfaces:

- English and Simplified Chinese pages 1, 3, and 4 of the final in-app What's
  New campaign, proving that the quota widget, History view, update-window
  image, copy, accessibility labels, and controls all follow the app language.
- English and Simplified Chinese update-window captures demonstrate the full
  four-card 1.0 release summary and localized controls. The final generated
  release-note HTML is additionally covered by the release-note validator and
  update-window tests.
- `bilingual-update-pages.png` is the exact final-build comparison board for
  What's New pages 1 and 4 in both languages.

Final What's New build:

- App and media commit: `75d30959e0396b5799350c94e4730d94c0efede8`
- App version: `1.0.0`
- Build number: `10000009000`
- Embedded `BuildCommit`: `75d3095`
- Distribution configuration: Developer ID debug assembly, ad-hoc signed
  because the local Developer ID identity was unavailable.

The standalone update-window images are the exact pre-rebase implementation
captures from `8d0c8aa6478205be212c7cb1b4312ea548a60a11`.

QA artifact directories:

- `.build/qa-artifacts/20260810T015500Z-whatsnew-final-75d3095-en`
- `.build/qa-artifacts/20260810T015500Z-whatsnew-final-75d3095-zh-Hans`
- `.build/qa-artifacts/20260809T174000Z-update-final-8d0c8aa-en`
- `.build/qa-artifacts/20260809T174100Z-update-final-8d0c8aa-zh`

Each boundary manifest records fixture mode, a unique defaults suite and QA
home, disabled live external sources, and no copied credentials.

SHA-256:

- `bilingual-update-pages.png`: `39af47c7aa5a2201074717730714e7e68d8ed018f8dfa987defb3767cb752035`
- `update-window.en.png`: `d0b3732487d4a7bb2ee7ac614d0ad675bfc787e534b47244007d5a1a63fa795f`
- `update-window.zh-Hans.png`: `5f6a824ca88bf3dc964799dfd37ead01876d686451a3c9da0f0c17a9f7f5b4ac`
- `whats-new.en.png`: `ed273baaf9081e4d69d61c52de49259a7c1ed8a3d695043664dc5615b9fc9d76`
- `whats-new.zh-Hans.png`: `f83757058a8f8d01eb2549a50c1ed04e415a4deff34b052012b21fb640ba1e25`
