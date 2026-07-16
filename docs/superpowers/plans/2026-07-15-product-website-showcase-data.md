# Product Website Showcase Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the website's sparse product imagery with reproducible, high-density synthetic Quota Monitor captures that visibly demonstrate Forecast, Trends, Activity, Composition, and Sessions.

**Architecture:** A checked-in showcase scenario describes safe product-demo density, while a Node generator materializes date-relative Codex and Claude JSONL files inside an isolated QA home. The existing fixture-smoke launcher imports that home into its isolated SQLite database; four real-app captures then replace the public imagery and feed the existing static site and social card.

**Tech Stack:** Node.js 22, Vitest, existing Quota Monitor JSONL importers and local-QA fixture launcher, SwiftUI macOS app, `cwebp`, static HTML/CSS, Cloudflare Workers/Wrangler.

## Global Constraints

- Use the existing `codex/product-website` linked worktree; never edit the primary checkout or `main`.
- Use only synthetic data under the isolated QA home; do not read or publish installed-app history, credentials, account identifiers, titles, paths, or values.
- Keep all visitor-facing website surfaces free of visible, clickable, canonical, structured-data, or metadata GitHub links.
- The Dashboard headline and Trends chart use the 30-day window.
- At least 24 sessions span at least 18 active days in the last 30 days.
- Both providers and at least five model or tier series must be visible.
- Publish only current real-app UI captures; image processing may resize, crop, and compose verified captures but must not invent controls or data panels.
- Preserve the same-origin `/download` behavior and all existing download validation/security behavior.

---

## File Map

- `website/design/showcase-scenario.json` — human-reviewable density, provider, model, title, and safety contract for the synthetic showcase.
- `website/scripts/generate-showcase-fixtures.mjs` — deterministic date-relative Codex/Claude JSONL materializer; accepts a target QA home, mandatory destructive opt-in, and optional fixed clock.
- `website/tests/showcase-fixtures.test.ts` — validates scenario density, generator output, safe paths/titles, recent events, and current Codex quota windows.
- `website/public/assets/dashboard-hero.webp` — real-app Forecast and 30-day Trends capture.
- `website/public/assets/dashboard-insights.webp` — real-app Activity and Composition capture.
- `website/public/assets/sessions-detail.webp` — real-app dense Sessions capture.
- `website/public/assets/history-detail.webp` — real-app populated day-by-day History capture.
- `website/design/social-card-source.png` and `website/public/assets/social-card.webp` — social composition using the verified new Dashboard overview.
- `website/public/index.html` — routes the Trends feature block to the distinct insights capture and declares exact intrinsic dimensions.
- `website/public/app.js` — keeps English and Simplified Chinese Sessions copy aligned with fields present in the current app.
- `website/public/styles.css` — provides a phone-only localized full-size-view affordance without changing the approved Native Focus layout.
- `website/tests/site-content.test.ts` — locks the new asset inventory, dimensions, and retirement of sparse assets.
- `CHANGELOG.md` and `CHANGELOG.zh-Hans.md` — describe the richer website product tour in both release-note languages.

---

### Task 1: Reproducible High-Density Showcase Fixture

**Files:**
- Create: `website/design/showcase-scenario.json`
- Create: `website/scripts/generate-showcase-fixtures.mjs`
- Create: `website/tests/showcase-fixtures.test.ts`

**Interfaces:**
- Consumes: `node website/scripts/generate-showcase-fixtures.mjs <qa-home> --allow-showcase-overwrite [--now=<ISO-8601>]`.
- Produces: Codex rollouts under `<qa-home>/.codex/sessions/showcase/`, Codex metadata at `<qa-home>/.codex/session_index.jsonl`, and Claude sessions under safe synthetic project roots in `<qa-home>/.claude/projects/`.

- [ ] **Step 1: Write the failing scenario/generator tests**

Create tests that require `showcase-scenario.json` and `generate-showcase-fixtures.mjs`, verify the generator refuses to mutate a target without `--allow-showcase-overwrite`, then run it with that opt-in and `--now=2026-07-15T12:00:00.000Z`, parse every JSONL line, and assert all of the following exact contracts:

```ts
expect(scenario.sessionCount).toBeGreaterThanOrEqual(24);
expect(scenario.activeDayOffsets.length).toBeGreaterThanOrEqual(18);
expect(new Set(scenario.providers)).toEqual(new Set(["codex", "claude"]));
expect(new Set([...scenario.codexModels, ...scenario.claudeModels]).size)
  .toBeGreaterThanOrEqual(5);
expect(scenario.selectedSessionEventCount).toBeGreaterThanOrEqual(6);
expect(generated.codexSessions + generated.claudeSessions)
  .toBe(scenario.sessionCount);
expect(generated.latestTimestamp).toBeGreaterThanOrEqual(
  Date.parse("2026-07-15T07:00:00.000Z"),
);
expect(generated.codexQuotaBuckets).toEqual(new Set([300, 10080]));
```

Reject any generated string matching `/Users/`, `/Volumes/`, `github.com`, `timmy`, `token=`, `api[_-]?key`, or `sk-`.

- [ ] **Step 2: Run the focused test and observe the missing-source failure**

Run: `cd website && npm test -- --run tests/showcase-fixtures.test.ts`

Expected: FAIL because the scenario and generator do not exist yet.

- [ ] **Step 3: Add the minimal scenario and generator**

The scenario declares 28 sessions, 22 distinct active-day offsets from `-29` through `0`, Codex models `gpt-5.5`, `gpt-5.5-fast`, and `gpt-5.5-flex`, Claude models `claude-opus-4-8`, `claude-sonnet-4-5-20250929`, and `claude-haiku-4-5-20251001`, safe project slugs under `/showcase/projects/`, and 28 clearly synthetic feature-oriented titles. The generator must:

```js
const now = new Date(nowArgument ?? Date.now());
const atOffset = (days, minutes = 0) =>
  new Date(now.getTime() + days * 86_400_000 + minutes * 60_000).toISOString();
```

Generate 16 Codex and 12 Claude sessions, distribute them across the declared active days, include 2–8 usage events per session, write cumulative Codex totals, write per-message Claude usage, and attach current `rate_limits` to the newest Codex event with `window_minutes` values `300` and `10080` and future reset epochs. The selected Codex session must contain eight events and a safe title from the scenario.

- [ ] **Step 4: Run generator and tests**

Run:

```bash
cd website
npm test -- --run tests/showcase-fixtures.test.ts
node scripts/generate-showcase-fixtures.mjs /tmp/quotamonitor-showcase-plan-check --allow-showcase-overwrite --now=2026-07-15T12:00:00.000Z
```

Expected: focused tests PASS; the target contains exactly 28 generated session files plus the Codex metadata index.

- [ ] **Step 5: Commit the fixture slice**

```bash
git add website/design/showcase-scenario.json website/scripts/generate-showcase-fixtures.mjs website/tests/showcase-fixtures.test.ts
git commit -m "Add reproducible website showcase data"
```

---

### Task 2: Capture and Wire Distinct Feature-Rich Product Images

**Files:**
- Modify: `website/tests/site-content.test.ts`
- Modify: `website/public/index.html`
- Modify: `website/public/app.js`
- Modify: `website/public/styles.css`
- Replace: `website/public/assets/dashboard-hero.webp`
- Create: `website/public/assets/dashboard-insights.webp`
- Replace: `website/public/assets/sessions-detail.webp`
- Create: `website/public/assets/history-detail.webp`
- Replace: `website/design/social-card-source.png`
- Replace: `website/public/assets/social-card.webp`
- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`

**Interfaces:**
- Consumes: the Task 1 generator and existing fixture-smoke QA launcher.
- Produces: four 980×732 verified product WebPs and one 1200×630 social WebP referenced by the static website.

- [ ] **Step 1: Extend the asset tests first**

Require `/assets/dashboard-insights.webp` and `/assets/history-detail.webp`, require all four product screenshots to be exactly 980×732, require six product-image occurrences in HTML, and add each currently sparse asset digest to a `retiredSha256` array so the test fails until the imagery is replaced. Require the Trends block to source `dashboard-insights.webp`, Local history to source `history-detail.webp`, and Hero plus Live quota clarity to source `dashboard-hero.webp`. Require English and Simplified Chinese Sessions copy and alt text to omit `duration` / `时长` and name event timing instead. Require each product image to be wrapped by a same-origin full-size asset link with the localized `viewImageFullSize` label visible under the mobile media query.

- [ ] **Step 2: Run the content test and observe the missing/reused-image failure**

Run: `cd website && npm test -- --run tests/site-content.test.ts`

Expected: FAIL because `dashboard-insights.webp` is missing and the Trends block still reuses the overview image.

- [ ] **Step 3: Prepare the isolated showcase app**

Run:

```bash
rm -rf /tmp/quotamonitor-website-showcase .build/qa-artifacts/website-showcase
mkdir -p /tmp/quotamonitor-website-showcase/home .build/qa-artifacts/website-showcase/no-ui-introspection
node website/scripts/generate-showcase-fixtures.mjs /tmp/quotamonitor-website-showcase/home --allow-showcase-overwrite
HOME=/tmp/quotamonitor-website-showcase/home defaults write dev.tjzhou.QuotaMonitor.WebsiteShowcase settings.menuBarHeadlineWindow -string last30d
ln -sf /usr/bin/false .build/qa-artifacts/website-showcase/no-ui-introspection/screencapture
ln -sf /usr/bin/false .build/qa-artifacts/website-showcase/no-ui-introspection/osascript
PATH="$PWD/.build/qa-artifacts/website-showcase/no-ui-introspection:$PATH" \
QM_QA_LANGUAGE=en \
QM_QA_DEFAULTS_SUITE=dev.tjzhou.QuotaMonitor.WebsiteShowcase \
QM_QA_ARTIFACTS="$PWD/.build/qa-artifacts/website-showcase" \
QM_QA_WORK_ROOT=/tmp/quotamonitor-website-showcase \
QUOTAMONITOR_QA_APP_BUNDLE="$PWD/.build/QuotaMonitor-WebsiteShowcase.app" \
QUOTAMONITOR_QA_STEPS="refresh-all,open-dashboard,wait,snapshot" \
./qa/prepare-computer-use-fixture-smoke.sh
```

Expected: `qa-boundary.json` reports `fixture`, SQLite reports 28 showcase sessions plus the small baseline fixture, both providers have usage, and the only imported paths/titles are synthetic.

- [ ] **Step 4: Capture four real-app states**

Use Computer Use only on `.build/QuotaMonitor-WebsiteShowcase.app`. Capture at one stable 980×732 content size:

1. Dashboard top: 30-day headline, populated Codex/Claude Forecast cards, and a dense multi-series 30-day Trends chart.
2. Dashboard lower scroll: Activity metrics/heatmap and Composition provider/model breakdown.
3. Sessions: at least ten visible rows and the selected eight-event synthetic session detail.
4. History: at least eighteen day rows, a populated latest-day model breakdown, and multiple sessions in the detail pane.

Save PNG sources under `.build/qa-artifacts/website-showcase/screenshots/`, inspect each with `view_image`, and run `./qa/check-artifacts.sh .build/qa-artifacts/website-showcase`.

- [ ] **Step 5: Publish exact-size product assets and wire the distinct Trends image**

Run:

```bash
cwebp -q 90 -resize 980 732 .build/qa-artifacts/website-showcase/screenshots/dashboard.png -o website/public/assets/dashboard-hero.webp
cwebp -q 90 -resize 980 732 .build/qa-artifacts/website-showcase/screenshots/dashboard-insights.png -o website/public/assets/dashboard-insights.webp
cwebp -q 90 -resize 980 732 .build/qa-artifacts/website-showcase/screenshots/sessions.png -o website/public/assets/sessions-detail.webp
cwebp -q 90 -resize 980 732 .build/qa-artifacts/website-showcase/screenshots/history.png -o website/public/assets/history-detail.webp
```

Change only the Trends block's `source` and `img` to `/assets/dashboard-insights.webp`, and replace the Local history icon treatment with `/assets/history-detail.webp`; retain localized alt text and declare `width="980" height="732"`. Change Sessions copy to “models, token details, event timing, and API-equivalent cost estimates” / “模型、Token 明细、事件时间与 API 等价费用估算”, and remove the unsupported duration claim from both localized alt strings. Wrap all product captures in same-origin asset links, add `viewImageFullSize` to both locale dictionaries, and show that label only below 760 px.

- [ ] **Step 6: Recompose the social card from the verified Dashboard overview**

Create a 1200×630 source using the existing icon, headline/copy, and the verified `dashboard-hero.webp` capture; do not regenerate or redraw the application window. Export `social-card.webp`, inspect both source and output with `view_image`, and update approved SHA-256 values only after visual acceptance.

- [ ] **Step 7: Update bilingual release notes and pass focused tests**

Amend the existing website Summary/Added bullets in both changelogs to say the product tour uses rich synthetic 30-day Dashboard and Sessions examples. Run:

```bash
cd website
npm test -- --run tests/showcase-fixtures.test.ts tests/site-content.test.ts
```

Expected: all focused tests PASS and all retired sparse digests are absent.

- [ ] **Step 8: Commit the visual slice**

```bash
git add CHANGELOG.md CHANGELOG.zh-Hans.md website/public/index.html website/public/assets website/design/social-card-source.png website/tests/site-content.test.ts
git commit -m "Showcase Quota Monitor with richer product data"
```

---

### Task 3: Full Verification, PR Update, and Cloudflare Redeploy

**Files:**
- Replace: `docs/assets/website/homepage-desktop-en.jpg`
- Replace: `docs/assets/website/homepage-mobile-en.jpg`
- Update: pull request description and verification evidence.

**Interfaces:**
- Consumes: the verified website build and same-origin Cloudflare download worker.
- Produces: reviewed browser captures, a green ready PR, and the updated custom-domain deployment.

- [ ] **Step 1: Run all local gates**

Run:

```bash
cd website && npm run check
cd .. && ./qa/run-static.sh
```

Expected: all website tests/type checks/dry-run checks and the repository static gate PASS.

- [ ] **Step 2: Compare local desktop and mobile renders**

Capture the local site at 1440×1100 and 390×844. Inspect the prior approved Native Focus concept, new desktop render, new mobile render, all four app assets, and social card in the same visual comparison pass. Confirm no cropping, distortion, private data, invented UI, horizontal overflow, or GitHub visitor link.

- [ ] **Step 3: Commit QA assets and request review**

```bash
git add docs/assets/website/homepage-desktop-en.jpg docs/assets/website/homepage-mobile-en.jpg
git commit -m "Refresh website visual QA evidence"
git push origin codex/product-website
```

Keep PR #102 ready, update its body with exact tests and new desktop/mobile images, and request a final code/design review.

- [ ] **Step 4: Redeploy and verify live behavior**

Deploy with `cd website && npm run deploy`. Verify `https://quota-monitor.timmyagentic.com/`, `/api/release`, and `/download`; require valid TLS, exact DMG attachment bytes/hash, no redirect, and no GitHub reference on any visitor-facing response. Confirm the live image digests equal the committed assets.

- [ ] **Step 5: Clean up isolated QA state**

Run the generated `.build/qa-artifacts/website-showcase/cleanup-computer-use.sh` and remove `/tmp/quotamonitor-showcase-plan-check` if present. Confirm the linked worktree is clean and branch-tracks `origin/codex/product-website`.
