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
