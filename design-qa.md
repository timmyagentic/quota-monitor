# QuotaMonitor website design QA

Date: 2026-10-13

**Findings:** No remaining P0/P1/P2 findings.

The implementation follows the selected QuotaMonitor direction. Real, previously verified app captures replace the generated mock UI. That intentionally changes the chart colors, internal text and window proportions; the website must describe the real app. The additional demonstration-data label and full-size-image hint are intentional accessibility/context additions.

Desktop viewport: 1024 × 1536 CSS pixels, full-page capture 1009 × 5111. Mobile viewport: 390 × 844, full-page capture 375 × 4724.

## Evidence and comparison method

- Selected visual truth: `website/design/qa/visual-target.webp` (1019 × 1543 pixels). The user selected the first displayed concept, a light, spacious QuotaMonitor direction. It is a generated design reference, not application evidence.
- Browser-rendered implementation: `website/design/qa/home-desktop.webp` and `website/design/qa/home-mobile.webp`.
- Full-view comparison: `website/design/qa/comparison.webp`. Source and implementation appear in the same image; the implementation is scaled to the reference width for the top-region comparison. Full-page implementation files retain their original browser pixels.
- Focused comparison: `website/design/qa/type-and-spacing.webp`, covering navigation, headline, supporting copy, CTA and the start of the product surface. This was inspected in addition to the full view.
- Device scale factor is 1. Browser screenshots omit the 15-pixel scrollbar: a 1024/1280/390 CSS-pixel viewport therefore produces a 1009/1265/375-pixel content capture. No device frame is included.
- State: light theme, Chinese, default first tab, menus and FAQ closed. Additional English, alternate-tab, menu-open, keyboard-focus, document and narrow-screen states were checked separately.

## Required fidelity surfaces

1. **Fonts and typography:** native macOS system sans with PingFang fallback; dark, tightly tracked display type and quieter body text. Heading hierarchy, wrapping and button labels are readable on desktop and mobile. Browser rendering replaces the generated lettering in the reference.
2. **Spacing and layout rhythm:** centered hero, single dominant action, a substantial product surface and clearly separated content sections. Mobile layouts reflow into one column; no horizontal overflow was observed at 320, 375, 390, 430, 768 or 1440 CSS pixels. Product-specific sections below the reference crop are deliberate additions.
3. **Colors and visual tokens:** light surfaces, dark primary actions, restrained accents, visible keyboard outlines and non-color selected-state semantics. Reduced-motion styles disable transitions and smooth scrolling. No looping or scroll-triggered animation is required to read the page.
4. **Image quality and asset fidelity:** existing product/brand assets and licensed Tabler Icons are used. The shared landscape is an ImageGen raster asset. Screenshots and examples retain their aspect ratio and complete image content; no chart, logo or illustration is reconstructed with CSS/SVG drawing tricks.
5. **Copy and content:** the implementation uses product-specific, verifiable claims. Generated interface text in the concept is not shipped as product truth. Demos are labeled and do not impersonate live services.

## Verification boundary

This is browser-simulated responsive QA in the Codex in-app browser, not a physical-device test. Production publication is not included in this result. The three final homepages loaded without browser console errors. Every referenced local route, image, script and in-page anchor was checked. No personal account data, live credentials or real conversation content is present in the captures.

## Comparison history

- Initial P2: the headline was too small and the product-stage spacing pushed the next section below the reference composition. Initial evidence: `website/design/qa/before-fixes.webp`.
- Fix: increased the headline, reduced the top/stage gaps, balanced the two window sizes, and removed a redundant default-tab caption. The final comparison shows the restored hierarchy and next-section rhythm.
- Initial P2: the landscape ended in a visible blue edge. Fix: regenerated a matching raster asset that fades to white at both vertical edges; final desktop capture shows a clean transition.
- Initial P2: the English headline wrapped to three lines at 320 pixels. Fix: a compact-width type size. The final 320-pixel DOM check measured two 40.68-pixel title lines, with no overflow.

## Primary interactions and checks

- English/Chinese switch updates content and survives navigation; both header and footer controls remain synchronized.
- All three screenshot tabs work with click and arrow keys, with matching `aria-selected`, focus and panels. Full-size image links point to their actual assets.
- Mobile menu opens, closes on navigation and closes with Escape; keyboard focus is visible.
- Live release API hydration displayed 1.0.12. All download actions retain `/download`; no static release version is baked into HTML or structured data.
- Privacy route and its mobile navigation were inspected. Existing detailed data, provider and Cloudflare disclosures remain covered by tests.
- `npm run check`: 210 website tests plus 3 integration tests, typecheck, deployment dry run and startup analysis passed.
- `./qa/run-static.sh`: 217 Python checks and 1106 Swift tests passed; release-note and whitespace gates passed.

## Open questions

None for the frontend acceptance. Merge and production publication await explicit authorization.

## Follow-up polish

P3: the genuine app screenshots have different internal proportions from the generated concept. Preserve their truth and full-image access rather than imitating the mock data.

## Implementation checklist

- [x] Desktop/mobile source comparison
- [x] Bilingual content, tabs, menu and links
- [x] Download and privacy contracts
- [x] Repository validation gates

final result: passed
