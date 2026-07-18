# Quota Monitor Website Design QA

## Reference and implementation

- Approved source: `website/design/native-focus-homepage.png` (Native Focus, 864 × 1821).
- Desktop implementation: `docs/assets/website/homepage-desktop-en.jpg`, captured in the Codex in-app Browser with a 1440 × 1000 viewport override (1425 × 990 content image), English state.
- Mobile implementation: `docs/assets/website/homepage-mobile-en.jpg`, captured in the same Browser with a 390 × 844 viewport override (375 × 812 content image), English state.
- Full-view comparison: `docs/assets/website/design-qa-hero-comparison.png` places the approved first viewport on the left and the rendered first viewport on the right at the same 864 × 600 comparison size.
- Focused comparison: `docs/assets/website/design-qa-title-comparison.png` places the approved hero-title region on the left and the post-fix rendered region on the right.

The in-app Browser's stitched full-page screenshot repeated the first viewport, so it was excluded as unreliable evidence. Below-fold coverage instead used the complete rendered DOM snapshot plus direct Features, Privacy, and installation-anchor navigation. The comparison images above use only trustworthy viewport captures.

## Findings and disposition

- Final severity count: P0 0, P1 0, P2 0.
- Hero copy now matches the approved two-line phrase boundary on desktop: `Know your quota.` / `Keep your flow.`. Mobile remains unclipped and free of horizontal overflow.
- Header, cool white and pale-blue palette, bold system typography, primary blue CTA, product-window framing, whitespace, and next-section reveal remain aligned with Native Focus.
- The implementation intentionally uses the current Quota Monitor top-toolbar Dashboard rather than the concept's invented sidebar, so the public page represents the shipping product. The planned secondary in-page Features CTA remains after the primary download CTA.
- Dashboard and Sessions artwork is marked as synthetic data. No private user information appears in the assets.

## Comparison history

1. P1: the first product capture showed a mid-scroll Dashboard, the social asset inherited an invented sidebar, the Worker error view was unstyled, and image dimensions were inaccurate. Fixed in `a5b3246` with current product framing, a branded error view, and correct intrinsic dimensions.
2. P1: the revised hero used an empty seven-day state and compact language controls measured 40 px. Fixed in `01f1fd2` with populated recent synthetic activity and 44 px touch targets.
3. P2: the English desktop hero title wrapped into three lines rather than the approved two-line composition. Fixed in `898363d` with localized semantic line spans that are stable above 980 px and return to natural wrapping on smaller viewports.
4. Post-fix review: the combined hero and focused-title comparisons showed no remaining actionable P0, P1, or P2 issues.

## Browser interaction QA

- English and Simplified Chinese controls update `lang`, title, hero copy, CTA copy, metadata, and persist across reloads.
- Desktop navigation reaches Features and Privacy anchors; the secondary hero action reaches Features.
- Primary download emits a Browser download event and remains on the site origin.
- Mobile 390 × 844 layout has no horizontal overflow; language targets measure 44 × 44 px.
- Keyboard focus on the language control is visibly rendered with a 3 px blue focus ring.
- The localized 404 page is responsive, carries `noindex`, and returns home through a same-origin link.
- Console warning/error checks were empty during desktop, mobile, language, anchor, 404, and download validation.

final result: passed

---

# Persistent Update Download Icon Design QA

## Source and target

- Source image: the user-provided reference preserved on the left side of `docs/assets/pr/update-download-icon/reference-vs-implementation.png`.
- Shared implementation: `QuotaMonitor/Features/Shared/PersistentUpdateBadge.swift`.
- Comparison image: `docs/assets/pr/update-download-icon/reference-vs-implementation.png` (reference on the left, implementation on the right).
- In-context image: `docs/assets/pr/update-download-icon/dashboard-toolbar.png`.

## Viewport and state

- macOS light appearance on a Retina display at 2x capture scale.
- Simplified Chinese Local QA session with a copied real-data database and copied user preferences.
- Pending version `0.2.99` injected only into the isolated QA defaults suite so the persistent entry rendered without contacting Sparkle.
- Exact app target: `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-update-download-icon/.build/QuotaMonitor.app`.

## Comparison evidence

- The source circle measures 40 px across; the implementation circle also measures 40 px, corresponding to 20 pt at the captured scale.
- Both use the sampled `#339CFF` fill, a white download-to-container glyph, and no border or shadow on the circle.
- The implementation uses the native SF Symbol `square.and.arrow.down`, the closest available library icon to the supplied tray-and-arrow silhouette.
- The first implementation pass measured 44 px and was reduced to 40 px before final comparison.

## Fidelity surfaces

- Dashboard toolbar: passed; the icon is compact, vertically centered, and leaves the adjacent Reload and Settings actions unchanged.
- Menu-bar popover header: passed; the icon is aligned opposite the product title without changing the native menu-bar text.
- Advanced settings update row: passed; the version copy remains readable and the icon stays aligned at the trailing edge.
- Interaction contract: passed by source inspection and tests; the existing install action, contextual help, and accessibility label remain attached to the icon-only button. The QA boundary prohibited activating the updater, so the button was not clicked.

## Evidence files

- `.build/qa-artifacts/update-download-icon/dashboard-update-icon-final.png`
- `.build/qa-artifacts/update-download-icon/menu-popover-update-icon-active.png`
- `.build/qa-artifacts/update-download-icon/settings-update-icon.png`
- `.build/qa-artifacts/update-download-icon/reference-vs-implementation-final.png`

final result: passed
