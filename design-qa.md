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
