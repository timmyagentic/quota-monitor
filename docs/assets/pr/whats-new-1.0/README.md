# Quota Monitor 1.0 update-page evidence

The images in this directory come from uniquely scoped, isolated QA app
bundles. They use synthetic data and do not read the installed app's database,
preferences, credentials, or account content.

Verified surfaces:

- English and Simplified Chinese Sparkle update windows, including the full
  four-card 1.0 release summary and localized controls.
- English and Simplified Chinese pages 1, 3, and 4 of the in-app What's New
  campaign, proving that the quota widget, History view, update-window image,
  copy, accessibility labels, and controls all follow the app language.
- `bilingual-update-pages.png` is the compact comparison board for the two
  update-window states and the two matching What's New page-4 states.

Exact build:

- Implementation commit: `8d0c8aa6478205be212c7cb1b4312ea548a60a11`
- App version: `1.0.0`
- Build number: `10000009000`
- Embedded `BuildCommit`: `8d0c8aa`
- Distribution configuration: Developer ID debug assembly, ad-hoc signed
  because the local Developer ID identity was unavailable.

QA artifact directories:

- `.build/qa-artifacts/20260809T174000Z-update-final-8d0c8aa-en`
- `.build/qa-artifacts/20260809T174100Z-update-final-8d0c8aa-zh`
- `.build/qa-artifacts/20260809T174200Z-whats-new-final-8d0c8aa-en`
- `.build/qa-artifacts/20260809T174300Z-whats-new-final-8d0c8aa-zh`

Each boundary manifest records fixture mode, a unique defaults suite and QA
home, disabled live external sources, and no copied credentials.

SHA-256:

- `bilingual-update-pages.png`: `e1eb7471cf38fd0a0beb70671fde4961b198b93c16e8c0923fd1f1f3aabb866e`
- `update-window.en.png`: `d0b3732487d4a7bb2ee7ac614d0ad675bfc787e534b47244007d5a1a63fa795f`
- `update-window.zh-Hans.png`: `5f6a824ca88bf3dc964799dfd37ead01876d686451a3c9da0f0c17a9f7f5b4ac`
- `whats-new.en.png`: `766ae2df382e8ec248738d21e893ecb375a08a0c2561b9ffef27b1d41f001fc9`
- `whats-new.zh-Hans.png`: `fb50a44c5beaa0fb1ca8b624ed62e88516755a7af51d956374950a3cfd76aa6d`
