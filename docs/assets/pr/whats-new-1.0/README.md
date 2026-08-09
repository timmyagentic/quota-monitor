# Quota Monitor 1.0 update-page evidence

The images in this directory come from uniquely scoped, isolated QA app
bundles. They use synthetic data and do not read the installed app's database,
preferences, credentials, or account content.

Verified surfaces:

- English and Simplified Chinese Sparkle update windows, including the full
  four-card 1.0 release summary and localized controls.
- English and Simplified Chinese page 4 of the in-app What's New campaign,
  proving that the matching localized update-window image is embedded.

QA artifact directories:

- `.build/qa-artifacts/20260809T173000Z-update-preview-zh`
- `.build/qa-artifacts/20260809T173100Z-whats-new-final-en`
- `.build/qa-artifacts/20260809T173300Z-whats-new-final-zh`
- `.build/qa-artifacts/20260809T173600Z-history-final-en`

The final implementation commit and capture checksums are recorded after the
source commit is created so the evidence can identify the exact app build.
