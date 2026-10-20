# Website design QA

Source visual truth: https://timmyagentic.si/ (approved main-site design, personal-hub f4f67b0).

Implementation: existing quota-monitor product website. This is a visual-family adaptation with preserved product content, not a pixel-identical copy of the portfolio page.

- Desktop viewport: 1205 x 1000 CSS pixels; content width 1190 including the browser's reserved scrollbar layout. Source and implementation viewport screenshots are both 1190 x 988 pixels. Both are normalized by the same browser capture behavior.
- Mobile/narrow/tablet widths: 390, 320 and 768 CSS pixels; no horizontal document overflow.
- Source and implementation shown together: `docs/website-brand-comparison.jpg`.
- Current implementation screenshot: `docs/website-brand-preview.jpg`.
- Additional full-page, mobile, navigation and secondary-page evidence: Workspace Task T-20261021-PROJECT-BRAND artifacts and browser-qa.json.

## Required fidelity surfaces

- Fonts and typography: same licensed Instrument Sans and Noto Sans SC families, 400/500/600/700 weights, loaded locally. Headline, section, body and monospace-label hierarchy checked in rendered desktop/mobile views. Product-specific headline size/wrapping intentionally fits its content and composition.
- Spacing/layout rhythm: shared 1100 px maximum content measure, restrained header rule, open sections, pill actions, balanced product imagery, and stacked narrow-screen layouts. The product sublabel under the parent brand is intentional; the portfolio has no such sublabel.
- Colors/tokens: paper #f8f9f6, ink #151c23, muted #67717d, line #d4dadd, blue #4059ed. Existing semantic warning/error states are retained.
- Image fidelity: reused approved ambient raster and real existing public product images; original images and their links remain intact. Existing labelled interactive/conceptual diagrams are retained as informational content, never relabelled as screenshots or live data. No new fabricated product screenshot was introduced.
- Copy/content: original project links, setup/download paths, product versions, compatibility/privacy notes and all functional JavaScript preserved. Owner branding is timmyagentic. Original home/docs/account/error pages receive the same visual layer where present.

## Comparison and fixes

1. Initial desktop/mobile captures found a P2 background overpaint below the Quota hero, excessive CC mobile element gaps, and a duplicate SMB header rule. The background is now bounded to its section, CC retains block flow on mobile, and SMB uses only the outer header rule. Post-fix captures are the final desktop/mobile artifacts.
2. Static page coverage found four minimal error pages using implied head/body tags. Explicit document sections and the brand header/footer now cover them; narrow-screen error-page QA passed.
3. Full-page reviews plus focused full-resolution hero and secondary-page views found no remaining P0/P1/P2 visual issue. The paired comparison shows the shared typography, color, image treatment and spacing.

## Interactions and boundaries

Browser QA exercised Quota language/screenshot tabs/menu/privacy, CC language/demo/menu/command copying/docs, Emomo example selection/prompt copying/account layout, all three device/network install-copy and FAQ controls, and SMB screenshot dialog open/close. Download files and original links are checked independently. Reduced-motion overrides remain present.

Local previews use an isolated static server; account API responses are deliberately unauthenticated and app downloads are not installed. Real email sign-in, account key mutation, native hardware/app behavior and production publication are separate from this visual QA. They are not claimed by this report. Publication requires the repository checks and independent live verification.

**Findings:** no remaining P0/P1/P2 design findings.

**Implementation checklist:** completed visual adaptation, local responsive/interaction checks and comparison evidence; retain product behavior and publish only through the existing delivery gates.

**Follow-up polish:** no blocking follow-up.

final result: passed
