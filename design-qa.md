# Codex quota widget semantic-background design QA

## Evidence

- Source visual truth: `/var/folders/4f/qnyg3l7d66v_4k0vzwx69jk40000gn/T/codex-clipboard-ec1617eb-8d4f-4e12-8cf4-58218b593f4b.png`, together with the user's direction to preserve the existing content while replacing the dark slab with a Codex-like semantic background and light border.
- Supporting upstream reference: `docs/assets/pr/codex-sidebar-quota/opsail-v0.2.0-reference.png`; its compact summary uses the host list-hover background token and light-border token rather than a standalone material surface.
- Implementation screenshots: `docs/assets/pr/codex-widget-background/semantic-background-light.png` and `docs/assets/pr/codex-widget-background/semantic-background-dark.png`.
- Focused same-state comparison: `docs/assets/pr/codex-widget-background/semantic-background-comparison.png` (before on the left, implementation on the right).
- Source pixels: 792 x 80. Implementation pixels: 790 x 80 for a 395 x 40 point native SwiftUI canvas rendered at 2x density. The focused comparison normalizes both to matching 240 x 80 pixel crops.
- State: macOS light and dark appearances, weekly-only quota, `7d 55%`, pointer not hovering.

## Findings

No actionable P0, P1, or P2 differences remain for the requested background-only change.

- Fonts and typography: unchanged. The implementation uses the same native compact label, semibold weight, monospaced percentage digits, and text hierarchy as the supplied state.
- Spacing and layout rhythm: unchanged. The 84 x 25 point capsule, 8 point continuous radius, internal spacing, and account-row placement remain intact.
- Colors and visual tokens: passed. The supplied capture's surrounding surface sampled at `rgb(252,252,252)`, while the old fill sampled at `rgb(216,216,216)`, a 36-level separation that reads as a gray slab. The implementation uses adaptive `.primary` opacity directly over the host surface: its light fixture sampled at base `rgb(255,255,255)`, fill `rgb(247,247,247)`, and border `rgb(235,235,235)`, while its dark fixture sampled at base `rgb(30,30,30)`, fill `rgb(37,37,37)`, and border `rgb(48,48,48)`. Both appearances keep the fill close to the host surface and let the light semantic border preserve the capsule boundary.
- Image quality and asset fidelity: passed. The implementation evidence is a 2x native SwiftUI render of the shipping view; no placeholder, generated image, SVG, or approximate asset is used.
- Copy and content: unchanged. The dot, `7d` label, `55%` value, dimensions, shadow, and interactions were deliberately left outside this change.

The single 84 x 25 point capsule is fully readable in the focused comparison, so an additional crop would not expose more fidelity detail.

## Comparison history

1. Initial state: the translucent material layer introduced a P2 foreground/background balance mismatch in light Codex, visibly separating the widget from the account-row base.
2. Fix: removed the standalone material layer, retained a low-opacity adaptive semantic fill, and reduced the border from 12/20% to 8/12% opacity for normal/hover states.
3. Post-fix evidence: the focused comparison shows the capsule blending into the Codex-like base while retaining a visible light outline; no typography, spacing, copy, or status-color drift is visible.

## Implementation checklist

- [x] Replace the gray material slab with an adaptive semantic tint.
- [x] Keep a visible but light border in normal and hover states.
- [x] Preserve the dot, text, percentage, dimensions, shadow, and interactions.
- [x] Verify the exact native view at 2x density in light appearance.
- [x] Verify the same adaptive treatment at 2x density in dark appearance.
- [x] Compare the supplied state and implementation in one focused image.

## Follow-up polish

None required for this scoped background change.

final result: passed

---

# Codex hover-card title design QA

## Evidence

- Source visual truth: `/var/folders/4f/qnyg3l7d66v_4k0vzwx69jk40000gn/T/codex-clipboard-e7eb2489-968d-40a7-a8d1-770f56f1c76a.png`
- Implementation screenshot: `docs/assets/pr/codex-sidebar-quota/refined-widget-zh-Hans.png`
- Focused comparison: `docs/assets/pr/codex-sidebar-quota/refined-widget-title-comparison.png`
- Source pixels: 714 x 712; source component is a full menu-bar popover capture.
- Implementation pixels: 640 x 546; SwiftUI canvas is 320 x 273 points at 2x density.
- State: light appearance, Simplified Chinese, synthetic quota/reset-credit data, hover details open.

## Findings

No actionable P0, P1, or P2 differences remain for the requested title region.

- Typography: the implementation now uses the exact `Quota Monitor` product
  name and the app's native `.headline` style, matching the existing menu-bar
  header's family, weight, and semantic hierarchy.
- Spacing and layout rhythm: the 288-point detail card keeps its existing
  12-point content inset and reserves a 27-point top header slot, leaving clear
  separation before the first quota row without widening the card.
- Colors and visual tokens: the title uses the native primary foreground on the
  existing material card. Quota colors and the card background are unchanged.
- Image quality and asset fidelity: both compared titles are native system text;
  the implementation capture is rendered at 2x density. No raster replacement,
  custom icon, or generated asset is involved.
- Copy and content: the title comes from `Branding.appDisplayName`, so it stays
  identical to the menu-bar popover and remains correct for branded variants.

The full source and implementation components are intentionally not 1:1: the
source is the complete menu-bar popover, while the implementation is a compact
Codex-window hover card. The focused board isolates the requested upper-left
title treatment, so surrounding controls do not create false mismatches.

## Comparison history

1. Initial state: the hover card began directly with the 5-hour quota row and
   omitted the source's upper-left product title. This was a P2 hierarchy and
   product-identification mismatch.
2. Fix: added `Branding.appDisplayName` as an accessible native headline and
   increased the calculated detail height by 27 points.
3. Post-fix evidence: the focused comparison shows the `Quota Monitor` title in
   the same upper-left role; the complete implementation screenshot shows no
   clipping, overlap, wrapping, or quota-layout regression.

## Implementation checklist

- [x] Product title appears in the hover detail card.
- [x] Title reuses the menu popover's branding source and headline hierarchy.
- [x] Detail geometry accounts for the header at one- and two-window sizes.
- [x] Simplified Chinese fixture screenshot renders without clipping.
- [x] Focused source/implementation comparison contains no P0-P2 mismatch.

## Follow-up polish

None required for this scoped title change.

final result: passed


---

# Codex native quota widget baseline design QA (historical)

> This section preserves the initial native-overlay QA record for the earlier
> 464-point, click-pinned card. The current 288-point hover-card treatment and
> its latest title comparison are documented in the section above.

**Source visual truth**

- `docs/assets/pr/codex-sidebar-quota/opsail-v0.2.0-reference.png`
- Full source image: 2000 × 1408 px.
- Expanded source focus crop: 520 × 540 px (approximately 260 × 270 pt at the source Retina density).
- State: weekly-only quota, hover detail open, reset-credit rows visible, dark Codex appearance.

**Rendered implementation**

- Full screenshot: `.build/qa-artifacts/20260809-final-native-overlay/01-final-hover-full.png`
- Focus screenshot: `.build/qa-artifacts/20260809-final-native-overlay/02-final-hover-closeup.png`
- Side-by-side comparison: `.build/qa-artifacts/20260809-final-native-overlay/03-final-source-comparison.png`
- Full implementation image: 3840 × 2160 px for a 1920 × 1080 pt macOS display at 2× density.
- Focus implementation crop: 1040 × 680 px for a 520 × 340 pt region at 2× density.
- State: weekly-only quota, hover detail open, two reset cards visible, light Codex appearance.
- Runtime geometry: collapsed summary `(348, 1043, 84, 25)` pt; expanded detail card `(12, 842, 464, 193)` pt in Quartz coordinates.

The source was captured with a narrower sidebar and dark appearance, while the current user's Codex sidebar is wider and uses light appearance. Density was kept at the native Retina scale; the comparison therefore evaluates hierarchy, component proportions, typography, spacing, and interaction structure without treating theme or responsive width as drift. There is no CSS viewport for this native AppKit/SwiftUI implementation.

**Full-view comparison evidence**

- The widget keeps the legacy right-side account-row anchor immediately before Codex's help control.
- The detail card opens above the account row, stays inside the sidebar, and preserves the source order: remaining amount, used amount, reset countdown, absolute reset time, progress, reset-card rows, and local-time note.
- The current card expands responsively across the wider current sidebar rather than retaining the narrower source screenshot's fixed pixel width.

**Focused region comparison evidence**

- `03-final-source-comparison.png` places the source and current hover states in one comparison image at their native Retina densities.
- The privacy-cropped deliverables `docs/assets/pr/codex-sidebar-quota/native-overlay.png` and `docs/assets/pr/codex-sidebar-quota/native-overlay-expanded.png` confirm the final capsule and card without unrelated account or conversation content.

**Required fidelity surfaces**

- Fonts and typography: native San Francisco system fonts, compact UI optical sizes, semibold remaining value and section title, monospaced digits for timestamps and percentages, and no truncation in the verified state.
- Spacing and layout rhythm: 12 pt sidebar inset, 8 pt card-to-summary gap, 12 pt continuous card radius, compact vertical metadata rhythm, and the same right-side account-row anchor as the source.
- Colors and visual tokens: neutral capsule in the healthy state, semantic orange/red reserved for approaching limits, adaptive system material for the current Codex theme, and the source's pink remaining-progress accent.
- Image and asset fidelity: no source illustration or product image is present in this component; the only icon is the native Codex help control outside the widget. No image asset was substituted or approximated.
- Copy and content: localized weekly label, explicit remaining and used percentages, relative and absolute reset times, reset-card availability, expiration rows, stale-data notice, and local-time clarification.
- Interaction and accessibility: hover opens the card, the pointer can move from capsule to card without dismissal, leaving both closes after 120 ms, clicking toggles a pinned state, and the summary exposes a button trait, label, hint, and default accessibility action without activating or restarting Codex.

**Findings**

- No actionable P0, P1, or P2 differences remain.
- [P3] The source reference is dark and substantially narrower than the current user's light, wide Codex sidebar. This is an expected adaptive-theme and responsive-layout difference, not an implementation mismatch.

**Comparison history**

1. First comparison found two P2 hierarchy mismatches: the window reset countdown and absolute time were compressed onto one line, and reset-card countdowns appeared before expiration dates. The implementation restored separate reset lines and the source's date-left/countdown-right table order. Post-fix evidence: `.build/qa-artifacts/20260809T123458Z-computer-use-real-data/06-source-vs-revised-expanded.png`.
2. The second comparison found a P2 density mismatch in weekly-only state: the capsule still reserved space for an unavailable `5h —` value. The implementation now omits missing windows and uses an 84 pt single-window capsule while preserving the same trailing anchor; two-window state still uses the 132 pt capsule. Post-fix evidence: `.build/qa-artifacts/20260809T123748Z-computer-use-real-data/07-source-vs-adaptive-expanded.png`.
3. The final comparison found no actionable P0, P1, or P2 mismatch. Hover transfer retained both native overlay windows; moving outside reduced the visible overlay count from two to one, and the Codex PID remained unchanged.

**Implementation checklist**

- [x] Preserve the legacy account-row trailing anchor.
- [x] Match the source's compact single-window summary behavior.
- [x] Restore hover and click detail disclosure.
- [x] Keep the detail card open during capsule-to-card pointer transfer.
- [x] Restore the source information hierarchy and progress treatment.
- [x] Verify adaptive light appearance and localized real-data content.
- [x] Verify no Codex restart or renderer injection.

**Follow-up polish**

- Re-capture a dark-appearance current build if a future release needs a theme-identical marketing comparison; this is not required for functional or visual acceptance.

final result: passed

---

# Quota Monitor Website Design QA

## Reference and implementation

- Source visual truth: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/selected/quota-monitor.png`.
- Desktop implementation screenshot: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/local/quota-monitor/desktop-en-1440x1024.png`.
- Mobile implementation screenshot: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/local/quota-monitor/mobile-en-390x844.png`.
- Viewports: 1440 × 1024 desktop and 390 × 844 mobile, captured in the Codex in-app Browser.
- State: English home-page hero after entrance motion settled. The local static QA server has no `/api/release` response, so it intentionally shows the checked-in `0.2.40` fallback; the production Worker hydrates the current release dynamically.
- Full-view desktop comparison: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/comparisons/local/quota-monitor-desktop-en.png`.
- Full-view mobile comparison: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/comparisons/local/quota-monitor-mobile-en.png`.
- Focused product comparison: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/comparisons/local/quota-monitor-focus-product.png`.

Each comparison board places the selected visual direction and the rendered implementation in the same image. The focused board makes the real menu-bar popover, app icon, Dashboard window, crop, borders, shadows, and relative scale readable enough for asset-level review.

## Findings and disposition

- Final severity count: P0 0, P1 0, P2 0.
- Fonts and typography: the bold system display face, blue second phrase, compact navigation, body hierarchy, line height, and optical weight preserve the selected direction. The final desktop title is fully visible; mobile wraps cleanly without clipping or awkward orphaned punctuation.
- Spacing and layout rhythm: the hero keeps the copy/product split, deliberate product overlap, broad white space, and compact metadata row from the source. At 390 px the layout becomes a readable single column without horizontal overflow.
- Colors and visual tokens: navy text, saturated accessible blue, pale rules, restrained shadows, white surfaces, and the dark privacy section form a coherent token system without decorative gradients or CSS art.
- Image quality and asset fidelity: the hero uses the repository's real app icon, menu-bar popover capture, and Dashboard capture at their intrinsic aspect ratios. The source's simulated macOS menu strip is intentionally omitted; it is not part of the shipping website or product asset.
- Copy and content: the menu-bar-first promise is accurate to the app, privacy language distinguishes local quota history from documented anonymous version statistics, and all product screenshots identify synthetic data in their accessible text.
- Interaction and accessibility: native links and buttons retain visible focus styles, meaningful labels and alt text, 44 px language targets, forced-colors support, and reduced-motion handling. Marketing entrance motion uses only `transform` and `opacity`; the subtle image hover is pointer-gated and transform-only.
- Expected non-blocking state difference: the selected visual shows release `0.2.42`, while the static local capture shows the `0.2.40` fallback because release hydration requires the Worker endpoint. This is dynamic data rather than visual drift and must be rechecked after production deployment.

## Comparison history

1. First English desktop comparison — P1: the longer English title was clipped and collided with the product composition. The hero grid proportions, title scale and width, product-stage height, menu-popover size and position, and desktop copy offset were revised in `website/public/styles.css`; the accent phrase was made a stable block for intentional wrapping.
2. Post-fix desktop evidence: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/comparisons/local/quota-monitor-desktop-en.png` shows the complete title and separated copy/product regions with no remaining overlap.
3. Post-fix mobile evidence: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/comparisons/local/quota-monitor-mobile-en.png` shows clean four-line heading wrap, usable CTA and metadata, and no horizontal overflow.
4. Focused post-fix evidence: `/Users/timmy/.codex/visualizations/2026/07/19/019f79d0-42b0-7cc3-be35-4b071ec9aeec/five-site-redesign/comparisons/local/quota-monitor-focus-product.png` shows the intended menu-popover-over-Dashboard hierarchy using real product imagery. No actionable P0, P1, or P2 finding remains.

## Browser interaction QA

- The uniquely scoped English and Simplified Chinese controls were both activated; `lang`, heading, hero copy, metadata, accessible labels, and pressed state updated correctly.
- Desktop and 390 × 844 mobile captures showed no horizontal overflow (`scrollWidth` did not exceed the rendered document width).
- Console warning and error checks were empty during desktop, mobile, and language-switch validation.

final result: passed

---

# Codex Account Activity Scope Design QA

## Reference and implementation

- Selected Visualization: `/Users/timmy/.codex/visualizations/2026/07/21/019f8573-e295-7b53-b33e-9b5a72969a5c/quota-monitor-profile-minimal.html`.
- Native implementation: `QuotaMonitor/Features/Dashboard/Sections/ActivitySection.swift` and `QuotaMonitor/Features/Dashboard/DashboardView.swift`.
- Safe fixture screenshots: `docs/assets/pr/codex-account-activity/activity-local.jpg` and `docs/assets/pr/codex-account-activity/activity-account.jpg`.
- Shareable two-state board: `docs/assets/pr/codex-account-activity/activity-scope-comparison.png`.
- Focused reference-versus-implementation input: `.build/qa-artifacts/20260723T163024Z-computer-use-real-data/comparison/reference-vs-implementation.png`.
- Viewport: app minimum size, 820 x 560 pt; Computer Use capture was 1024 x 691 px at the active display scale.

The comparison input places both Visualization states beside the corresponding native Activity cards. The reference uses its browser-hosted surface while the implementation deliberately retains QuotaMonitor's existing SwiftUI card, typography, spacing, heatmap, and Dashboard order.

## Findings and disposition

- Final severity count: P0 0, P1 0, P2 0.
- Visual scope: passed. The only new persistent control is the small native `本地 / 账户` segmented picker inside the existing Codex Activity header.
- Local state: passed. The original eight metrics, heatmap geometry, legend, card size, and neighboring Composition section remain intact.
- Account state: passed. Five Codex profile totals replace the metric strip in place, while the same card and heatmap treatment are reused without a layout jump.
- Other providers: passed. All-providers and Claude filters render the prior Activity UI without the scope picker, source summary, or scope label.
- Responsive layout: passed at the 820 x 560 pt minimum window. Source and as-of copy use a fitting layout and showed no clipping, overlap, or horizontal overflow.
- Interaction: passed. Scope switching, Account selection through Reload, and the in-card state transition worked in the isolated QA app.
- Accessibility: passed. The picker exposes a label and hint; every metric has a semantic label/value; the heatmap is summarized as one meaningful accessibility element.
- Data boundary: passed. The fixture screenshots use deterministic synthetic data. A separate read-only shadow-data pass verified realistic density without modifying the source database or copying provider credentials.

final result: passed

---

# Persistent Update Download Icon Design QA

## Source and target

- Source image: the user-provided reference preserved on the left side of `docs/assets/pr/update-download-icon/reference-vs-implementation.png`.
- Shared implementation: `QuotaMonitor/Features/Shared/PersistentUpdateBadge.swift`.
- Comparison image: `docs/assets/pr/update-download-icon/reference-vs-implementation.png` (reference on the left, implementation on the right).
- In-context image: `docs/assets/pr/update-download-icon/dashboard-toolbar.png`.
- Complete three-surface board: `docs/assets/pr/update-download-icon/three-entry-comparison.png`, covering the Dashboard toolbar, menu-bar popover, and Advanced settings entry in one shareable image.

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
