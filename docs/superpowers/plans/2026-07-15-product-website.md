# Quota Monitor Product Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a bilingual Quota Monitor product website whose same-domain download button streams the latest notarized DMG directly to the visitor.

**Architecture:** A focused `website/` module contains semantic static HTML, CSS, and a small localization script. A TypeScript Cloudflare Worker handles release metadata and DMG streaming before falling through to Workers Static Assets; release parsing and HTTP behavior remain pure and dependency-injected so they can be tested with Vitest.

**Tech Stack:** HTML5, CSS, browser JavaScript, TypeScript, Vitest, Cloudflare Workers Static Assets, Wrangler 4, current Quota Monitor QA fixtures, Swift macOS app screenshots.

## Global Constraints

- Deploy to `https://quota-monitor.timmyagentic.com` using Worker name `quota-monitor-site`.
- Ship complete Simplified Chinese and English experiences with browser-locale selection and a persisted manual override.
- Render no GitHub text, icon, anchor, canonical URL, structured-data URL, or social metadata URL anywhere in public website assets or visitor-facing Worker responses.
- The primary CTA targets same-domain `/download`; the browser must not visit an external release page.
- Use “API-equivalent cost estimate,” never “bill” or “actual spend.”
- State accurately that local history stays on the Mac while live quota refreshes contact provider services; do not claim the app is fully offline.
- Use current synthetic app data for product screenshots; never publish private real-data QA captures or the stale sparse `0.2.31` Dashboard screenshot.
- Support macOS 14 Sonoma or later and state that public builds are Developer ID signed and Apple notarized.
- Keep the site free of analytics, accounts, cookies, CMS, and third-party UI runtimes.
- Update both `CHANGELOG.md` and `CHANGELOG.zh-Hans.md` under `[Unreleased]`.

---

## File Map

- `website/package.json` — website scripts and pinned development dependencies.
- `website/package-lock.json` — reproducible npm dependency resolution.
- `website/tsconfig.json` — strict Worker and test TypeScript configuration.
- `website/vitest.config.ts` — deterministic unit-test configuration.
- `website/wrangler.jsonc` — Worker, static assets, and custom-domain source of truth.
- `website/worker-configuration.d.ts` — generated Static Assets binding types checked by Wrangler.
- `website/src/release.ts` — appcast parsing and release-metadata retrieval.
- `website/src/error-page.ts` — bilingual visitor-facing download failure page.
- `website/src/worker.ts` — `/api/release`, `/download`, security headers, and asset fallback.
- `website/tests/release.test.ts` — appcast parser and metadata failure behavior.
- `website/tests/worker.test.ts` — API, download streaming, error page, and asset fallback behavior.
- `website/tests/site-content.test.ts` — localization parity, public-link policy, semantic landmarks, and config checks.
- `website/public/index.html` — semantic single-page content and SEO metadata.
- `website/public/404.html` — bilingual same-domain not-found page.
- `website/public/_headers` — security headers for assets served without invoking the Worker.
- `website/public/styles.css` — Native Focus design system and responsive layout.
- `website/public/app.js` — locale detection, translations, version hydration, and restrained interactions.
- `website/public/assets/app-icon.png` — existing 1024 px Quota Monitor icon.
- `website/public/assets/dashboard-hero.webp` — current synthetic-data Dashboard capture.
- `website/public/assets/sessions-detail.webp` — current synthetic-data Sessions capture.
- `website/public/assets/social-card.webp` — approved Native Focus social preview.
- `docs/superpowers/specs/2026-07-15-product-website-design.md` — approved design contract.
- `CHANGELOG.md` and `CHANGELOG.zh-Hans.md` — user-facing Unreleased entry.

---

### Task 1: Release Metadata Parser

**Files:**
- Create: `website/package.json`
- Create: `website/tsconfig.json`
- Create: `website/vitest.config.ts`
- Create: `website/src/release.ts`
- Create: `website/tests/release.test.ts`

**Interfaces:**
- Consumes: public appcast XML fetched through an injected `typeof fetch`.
- Produces: `ReleaseInfo`, `ReleaseLookupError`, `parseLatestRelease(xml: string): ReleaseInfo`, and `fetchLatestRelease(fetcher?: typeof fetch): Promise<ReleaseInfo>`.

- [ ] **Step 1: Add the minimal website test toolchain**

Create `website/package.json`:

```json
{
  "name": "quota-monitor-website",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit",
    "check": "npm run typecheck && npm test && wrangler types --check && wrangler deploy --dry-run --outdir .wrangler/dry-run && wrangler check startup",
    "dev": "wrangler dev",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "latest",
    "typescript": "latest",
    "vitest": "latest",
    "wrangler": "latest"
  }
}
```

Create strict `tsconfig.json` with `ES2022`, `Bundler` resolution, `@cloudflare/workers-types`, `noEmit`, `strict`, `noUncheckedIndexedAccess`, and `exactOptionalPropertyTypes`. Create `vitest.config.ts` with the Node environment and include pattern `tests/**/*.test.ts`.

Run: `cd website && npm install`

Expected: `package-lock.json` is created and npm exits 0 without production dependencies.

- [ ] **Step 2: Write failing parser tests**

Create `website/tests/release.test.ts` with these exact behaviors:

```ts
import { describe, expect, it, vi } from "vitest";
import {
  ReleaseLookupError,
  fetchLatestRelease,
  parseLatestRelease,
} from "../src/release";

const APPCAST = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
  <item>
    <title>QuotaMonitor 0.2.40</title>
    <sparkle:version>0.2.40</sparkle:version>
    <enclosure url="https://downloads.example.test/v0.2.40/QuotaMonitor-0.2.40.dmg" length="6992960" />
  </item>
  <item>
    <sparkle:version>0.2.39</sparkle:version>
    <enclosure url="https://downloads.example.test/v0.2.39/QuotaMonitor-0.2.39.dmg" length="6978296" />
  </item>
</channel></rss>`;

describe("parseLatestRelease", () => {
  it("selects the first DMG item and returns public metadata", () => {
    expect(parseLatestRelease(APPCAST)).toEqual({
      version: "0.2.40",
      filename: "QuotaMonitor-0.2.40.dmg",
      size: 6992960,
      upstreamUrl: "https://downloads.example.test/v0.2.40/QuotaMonitor-0.2.40.dmg",
    });
  });

  it.each([
    ["missing version", APPCAST.replace("<sparkle:version>0.2.40</sparkle:version>", "")],
    ["non-DMG asset", APPCAST.replace("QuotaMonitor-0.2.40.dmg", "QuotaMonitor-0.2.40.zip")],
    ["missing length", APPCAST.replace(' length="6992960"', "")],
  ])("rejects %s", (_label, xml) => {
    expect(() => parseLatestRelease(xml)).toThrow(ReleaseLookupError);
  });
});

describe("fetchLatestRelease", () => {
  it("rejects a failed appcast response", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response("down", { status: 503 }));
    await expect(fetchLatestRelease(fetcher)).rejects.toThrow("Appcast request failed: 503");
  });
});
```

- [ ] **Step 3: Run the parser tests and verify RED**

Run: `cd website && npm test -- --run tests/release.test.ts`

Expected: FAIL because `../src/release` does not exist.

- [ ] **Step 4: Implement strict appcast parsing**

Create `website/src/release.ts` with:

```ts
export const APPCAST_URL =
  "https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/appcast.xml";

export interface ReleaseInfo {
  version: string;
  filename: string;
  size: number;
  upstreamUrl: string;
}

export class ReleaseLookupError extends Error {
  override name = "ReleaseLookupError";
}

const decodeXML = (value: string): string =>
  value
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">");

export function parseLatestRelease(xml: string): ReleaseInfo {
  const item = xml.match(/<item>[\s\S]*?<\/item>/)?.[0];
  const version = item?.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim();
  const enclosure = item?.match(/<enclosure\b([^>]+?)\/?\s*>/)?.[1];
  const encodedUrl = enclosure?.match(/\burl="([^"]+)"/)?.[1];
  const encodedLength = enclosure?.match(/\blength="(\d+)"/)?.[1];

  if (!version || !encodedUrl || !encodedLength) {
    throw new ReleaseLookupError("Latest appcast item is incomplete");
  }

  const upstreamUrl = decodeXML(encodedUrl);
  const pathname = new URL(upstreamUrl).pathname;
  const filename = decodeURIComponent(pathname.split("/").at(-1) ?? "");
  const size = Number(encodedLength);

  if (!/^QuotaMonitor-[0-9A-Za-z.-]+\.dmg$/.test(filename) || !Number.isSafeInteger(size) || size < 1_000_000) {
    throw new ReleaseLookupError("Latest appcast enclosure is not a valid QuotaMonitor DMG");
  }

  return { version, filename, size, upstreamUrl };
}

export async function fetchLatestRelease(fetcher: typeof fetch = fetch): Promise<ReleaseInfo> {
  const response = await fetcher(APPCAST_URL, {
    headers: { Accept: "application/xml, text/xml;q=0.9" },
    cf: { cacheEverything: true, cacheTtl: 300 },
  });
  if (!response.ok) {
    throw new ReleaseLookupError(`Appcast request failed: ${response.status}`);
  }
  return parseLatestRelease(await response.text());
}
```

- [ ] **Step 5: Run parser tests and typecheck**

Run: `cd website && npm test -- --run tests/release.test.ts && npm run typecheck`

Expected: parser tests PASS and TypeScript exits 0.

- [ ] **Step 6: Commit the parser slice**

```bash
git add website/package.json website/package-lock.json website/tsconfig.json website/vitest.config.ts website/src/release.ts website/tests/release.test.ts
git commit -m "Add latest release metadata parser"
```

---

### Task 2: Same-Domain Download Worker

**Files:**
- Create: `website/src/error-page.ts`
- Create: `website/src/worker.ts`
- Create: `website/tests/worker.test.ts`

**Interfaces:**
- Consumes: `fetchLatestRelease()` and the Cloudflare `ASSETS` Fetcher binding.
- Produces: default Worker export, `handleReleaseAPI()`, `handleDownload()`, and `renderDownloadError()`.

- [ ] **Step 1: Write failing Worker route tests**

Create `website/tests/worker.test.ts`. Inject a fake release lookup and upstream fetch so tests never contact external services. Cover these assertions:

```ts
expect((await handleReleaseAPI(async () => RELEASE)).status).toBe(200);
expect(await (await handleReleaseAPI(async () => RELEASE)).json()).toEqual({
  version: "0.2.40",
  filename: "QuotaMonitor-0.2.40.dmg",
  size: 6992960,
  minimumSystemVersion: "14.0",
});

const download = await handleDownload(
  new Request("https://quota-monitor.test/download", { headers: { "Accept-Language": "zh-CN" } }),
  async () => RELEASE,
  vi.fn<typeof fetch>().mockResolvedValue(new Response(new Uint8Array([0x44, 0x4d, 0x47]), {
    status: 200,
    headers: { "Content-Length": "6992960" },
  })),
);
expect(download.status).toBe(200);
expect(download.headers.get("Content-Disposition")).toBe('attachment; filename="QuotaMonitor-0.2.40.dmg"');
expect(download.headers.get("X-Content-Type-Options")).toBe("nosniff");

const failure = await handleDownload(
  new Request("https://quota-monitor.test/download", { headers: { "Accept-Language": "zh-CN" } }),
  async () => { throw new ReleaseLookupError("unavailable"); },
  fetch,
);
expect(failure.status).toBe(503);
expect(await failure.text()).toContain("暂时无法开始下载");
```

Also assert that the visitor-facing error response contains neither `github` nor external anchors.

- [ ] **Step 2: Run Worker tests and verify RED**

Run: `cd website && npm test -- --run tests/worker.test.ts`

Expected: FAIL because `worker.ts` and `error-page.ts` do not exist.

- [ ] **Step 3: Implement the bilingual error page**

Create `website/src/error-page.ts` with an Accept-Language helper and a complete HTML document. Its only actions are `<a href="/download">重试 / Retry</a>` and `<a href="/">返回首页 / Back home</a>`. Escape all interpolated text, set `<meta name="robots" content="noindex">`, load same-origin `/styles.css`, use no inline styles or event attributes, and render no external link.

- [ ] **Step 4: Implement Worker routing and streaming**

Create `website/src/worker.ts` around these exact public helpers:

```ts
import { renderDownloadError } from "./error-page";
import { fetchLatestRelease, type ReleaseInfo } from "./release";

export interface Env { ASSETS: Fetcher; }
type ReleaseLoader = () => Promise<ReleaseInfo>;

const securityHeaders = {
  "Content-Security-Policy": "default-src 'self'; base-uri 'none'; connect-src 'self'; font-src 'self'; form-action 'none'; frame-ancestors 'none'; frame-src 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'self'; object-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'; upgrade-insecure-requests",
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "X-XSS-Protection": "0",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "Permissions-Policy": "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
} as const;

export async function handleReleaseAPI(load: ReleaseLoader = fetchLatestRelease): Promise<Response> {
  try {
    const release = await load();
    return Response.json({
      version: release.version,
      filename: release.filename,
      size: release.size,
      minimumSystemVersion: "14.0",
    }, { headers: { ...securityHeaders, "Cache-Control": "public, max-age=300" } });
  } catch {
    return Response.json({ available: false }, {
      status: 503,
      headers: { ...securityHeaders, "Cache-Control": "no-store" },
    });
  }
}

export async function handleDownload(
  request: Request,
  load: ReleaseLoader = fetchLatestRelease,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  try {
    const release = await load();
    const upstream = await fetcher(release.upstreamUrl, {
      redirect: "follow",
      cf: { cacheEverything: true, cacheTtl: 86_400 },
    });
    const length = Number(upstream.headers.get("Content-Length") ?? release.size);
    if (!upstream.ok || !upstream.body || length < 1_000_000) throw new Error("Invalid DMG response");

    return new Response(upstream.body, {
      status: 200,
      headers: {
        ...securityHeaders,
        "Cache-Control": "public, max-age=3600",
        "Content-Disposition": `attachment; filename="${release.filename}"`,
        "Content-Length": String(length),
        "Content-Type": "application/x-apple-diskimage",
      },
    });
  } catch {
    return new Response(renderDownloadError(request.headers.get("Accept-Language")), {
      status: 503,
      headers: { ...securityHeaders, "Cache-Control": "no-store", "Content-Type": "text/html; charset=utf-8" },
    });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/api/release") return handleReleaseAPI();
    if (request.method === "GET" && url.pathname === "/download") return handleDownload(request);
    if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method Not Allowed", { status: 405 });
    const asset = await env.ASSETS.fetch(request);
    const response = new Response(asset.body, asset);
    Object.entries(securityHeaders).forEach(([name, value]) => response.headers.set(name, value));
    return response;
  },
} satisfies ExportedHandler<Env>;
```

- [ ] **Step 5: Run Worker tests and typecheck**

Run: `cd website && npm test -- --run tests/worker.test.ts && npm run typecheck`

Expected: Worker tests PASS; typecheck exits 0.

- [ ] **Step 6: Commit the Worker slice**

```bash
git add website/src/error-page.ts website/src/worker.ts website/tests/worker.test.ts
git commit -m "Stream latest DMG from site download route"
```

---

### Task 3: Bilingual Semantic Product Page

**Files:**
- Create: `website/public/index.html`
- Create: `website/public/404.html`
- Create: `website/public/_headers`
- Create: `website/public/app.js`
- Create: `website/tests/site-content.test.ts`

**Interfaces:**
- Consumes: `/api/release` JSON `{ version, filename, size, minimumSystemVersion }`.
- Produces: semantic sections keyed by stable `data-i18n` names and locale functions `resolveLanguage()`, `applyLanguage()`, and `hydrateRelease()`.

- [ ] **Step 1: Write failing public-content tests**

Create `website/tests/site-content.test.ts` to read `public/index.html` and `public/app.js`. Assert:

```ts
expect(html).toContain('<main id="main-content">');
expect(html).toContain('href="/download"');
expect(html).toContain('id="features"');
expect(html).toContain('id="privacy"');
expect(`${html}\n${app}`).not.toMatch(/github/i);
for (const url of html.match(/https?:\/\/[^"'\s<]+/g) ?? []) {
  expect(
    url.startsWith("https://quota-monitor.timmyagentic.com/") ||
      url === "https://schema.org",
  ).toBe(true);
}
expect(app).toContain('"zh-Hans"');
expect(app).toContain('"en"');
```

Parse the translation object keys and assert English and Chinese key sets are identical. Assert every `data-i18n` value in HTML exists in both locales. Assert all public anchors are same-origin paths or fragment identifiers.

- [ ] **Step 2: Run the site tests and verify RED**

Run: `cd website && npm test -- --run tests/site-content.test.ts`

Expected: FAIL because public page files do not exist.

- [ ] **Step 3: Create semantic HTML with exact approved copy**

Create `website/public/index.html` with:

- Skip link, header, main, and footer landmarks.
- Header brand, `#features`, `#privacy`, and language controls.
- Hero H1 `Know your quota. Keep your flow.` as the English no-script fallback.
- Supporting copy from the approved spec.
- Primary `/download` CTA with `data-version` and a secondary `#features` action.
- A `picture`/`img` product window using `assets/dashboard-hero.webp`.
- Four feature sections, a Sessions image section, truthful privacy section, three installation steps, and final `/download` CTA.
- Canonical URL and Open Graph URL pointing only to `https://quota-monitor.timmyagentic.com/`.
- `SoftwareApplication` JSON-LD containing operating-system, software-version fallback, application-category, MIT license name, and same-domain download URL only.
- No external anchors.

Create `website/public/404.html` as a complete bilingual not-found document whose only link is `href="/"`. Create `website/public/_headers` so directly served Static Assets receive the same baseline protection without running the Worker:

```text
/*
  Content-Security-Policy: default-src 'self'; base-uri 'none'; connect-src 'self'; font-src 'self'; form-action 'none'; frame-ancestors 'none'; frame-src 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'self'; object-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'; upgrade-insecure-requests
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
  Permissions-Policy: camera=(), geolocation=(), microphone=(), payment=(), usb=()
  Referrer-Policy: strict-origin-when-cross-origin
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  X-XSS-Protection: 0
```

Keep executable JavaScript and CSS in same-origin external files. Inline JSON-LD is permitted only with `type="application/ld+json"`; do not add inline executable scripts, `style` attributes, or event-handler attributes.

- [ ] **Step 4: Implement complete localization and release hydration**

Create `website/public/app.js` with one frozen translations object containing every visible string in `en` and `zh-Hans`.

```js
const STORAGE_KEY = "quota-monitor-site-language";
const supported = new Set(["en", "zh-Hans"]);

export function resolveLanguage(saved = localStorage.getItem(STORAGE_KEY), languages = navigator.languages) {
  if (saved && supported.has(saved)) return saved;
  return languages.some((value) => value.toLowerCase().startsWith("zh")) ? "zh-Hans" : "en";
}

export function applyLanguage(language) {
  const locale = supported.has(language) ? language : "en";
  document.documentElement.lang = locale;
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    node.textContent = translations[locale][node.dataset.i18n];
  });
  document.title = translations[locale].metaTitle;
  document.querySelector('meta[name="description"]').content = translations[locale].metaDescription;
  document.querySelectorAll("[data-language]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.language === locale));
  });
}

export async function hydrateRelease() {
  try {
    const response = await fetch("/api/release", { headers: { Accept: "application/json" } });
    if (!response.ok) return;
    const release = await response.json();
    document.querySelectorAll("[data-version]").forEach((node) => { node.textContent = release.version; });
  } catch { /* The approved build-time fallback remains visible. */ }
}
```

Bind language buttons, persist explicit choices with `localStorage`, set a `js` class before animation, hydrate release metadata, and avoid external runtime dependencies.

- [ ] **Step 5: Run content tests**

Run: `cd website && npm test -- --run tests/site-content.test.ts`

Expected: localization parity, semantic content, same-origin links, and public GitHub-reference checks PASS.

- [ ] **Step 6: Commit the content slice**

```bash
git add website/public/index.html website/public/404.html website/public/_headers website/public/app.js website/tests/site-content.test.ts
git commit -m "Add bilingual Quota Monitor product content"
```

---

### Task 4: Native Focus Visual System and Product Assets

**Files:**
- Create: `website/design/native-focus-homepage.png`
- Create: `website/public/styles.css`
- Create: `website/public/assets/app-icon.png`
- Create: `website/public/assets/dashboard-hero.webp`
- Create: `website/public/assets/sessions-detail.webp`
- Create: `website/public/assets/social-card.webp`
- Modify: `website/tests/site-content.test.ts`

**Interfaces:**
- Consumes: the approved A direction, `Resources/AppIcon.png`, current synthetic QA state, and semantic class names from Task 3.
- Produces: the visual source of truth and optimized production assets referenced by `index.html`.

- [ ] **Step 1: Generate the accepted high-fidelity concept**

Use the image-generation skill with `Resources/AppIcon.png` as the reference and this exact intent:

> Create a polished 1440×1100 desktop website concept for “Quota Monitor,” a native macOS menu-bar app. Follow the approved Native Focus direction: crisp white and cool pale-blue background, generous whitespace, actual supplied app icon, bold system-style headline “Know your quota. Keep your flow.”, one blue download CTA, and a large realistic macOS Dashboard window with teal, light-blue, terracotta, and green data visualization. No GitHub branding or links, no stock photos, no glossy promo-card grid, no dark theme, no invented badges, and no decorative hero eyebrow. Show the beginning of the next feature section below the fold.

Save the accepted result at `website/design/native-focus-homepage.png` and inspect it with `view_image` before writing CSS.

- [ ] **Step 2: Capture current synthetic Quota Monitor screens**

Run the repository's isolated local-QA fixture path for the current worktree with `--disable-keychain` behavior:

```bash
rm -rf .build/qa-artifacts/website-fixture
mkdir -p .build/qa-artifacts/website-fixture/no-ui-introspection
ln -sf /usr/bin/false .build/qa-artifacts/website-fixture/no-ui-introspection/screencapture
ln -sf /usr/bin/false .build/qa-artifacts/website-fixture/no-ui-introspection/osascript
PATH="$PWD/.build/qa-artifacts/website-fixture/no-ui-introspection:$PATH" \
QM_QA_LANGUAGE=en \
QM_QA_ARTIFACTS="$PWD/.build/qa-artifacts/website-fixture" \
QM_QA_WORK_ROOT="/tmp/quotamonitor-website-fixture" \
QUOTAMONITOR_QA_APP_BUNDLE="$PWD/.build/QuotaMonitor-WebsiteQA.app" \
QUOTAMONITOR_QA_STEPS="refresh-all,open-dashboard,open-settings,wait,snapshot" \
./qa/prepare-computer-use-fixture-smoke.sh
mkdir -p .build/qa-artifacts/website-fixture/screenshots
```

The false-command PATH shim intentionally prevents the harness from taking a full-desktop screenshot or reading windows by a broad process name. Use Computer Use only on `$PWD/.build/QuotaMonitor-WebsiteQA.app`, close Settings, capture the full Dashboard window to `.build/qa-artifacts/website-fixture/screenshots/dashboard.png`, switch the same QA app to Sessions, select the synthetic `Show Codex reset cards in the menu bar` row, and capture that window to `.build/qa-artifacts/website-fixture/screenshots/sessions.png`. Do not open the installed production app. Verify `qa-boundary.json` says fixture mode and inspect both screenshots for names, session titles, paths, values, or other private information before copying. The fixed fixtures are older than seven days, so select the 30-day Dashboard range before capture; do not present an empty 7-day panel as the hero.

Convert losslessly captured PNGs to quality-88 WebP:

```bash
mkdir -p website/public/assets
cwebp -q 88 .build/qa-artifacts/website-fixture/screenshots/dashboard.png -o website/public/assets/dashboard-hero.webp
cwebp -q 88 .build/qa-artifacts/website-fixture/screenshots/sessions.png -o website/public/assets/sessions-detail.webp
```

Expected: both images reflect current Dashboard/Sessions anatomy, contain only fixture data, and have no clipped app content.

- [ ] **Step 3: Add brand and social assets**

Copy `Resources/AppIcon.png` to `website/public/assets/app-icon.png`. Generate `social-card.webp` from the approved concept at 1200×630 with the icon, headline, current Dashboard window, and no external branding. Check each output with `view_image`.

- [ ] **Step 4: Implement Native Focus CSS**

Create `website/public/styles.css` with these fixed tokens and behavior:

```css
:root {
  color-scheme: light;
  --ink: #142033;
  --muted: #5f6f83;
  --surface: #ffffff;
  --surface-soft: #f4f8fd;
  --line: rgba(49, 75, 108, 0.14);
  --blue: #1868d5;
  --blue-hover: #105bbf;
  --codex: #4aa8b8;
  --claude: #cc7a59;
  --sky: #8cc7f2;
  --safe: #76b85a;
  --danger: #f06b7a;
  --radius-window: 28px;
  --shadow-window: 0 36px 90px rgba(36, 75, 122, 0.18);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
}
```

Implement a 1200 px content container, 64 px desktop header, two-column hero, minimum 48 px primary controls, open-whitespace feature layouts, macOS window framing around real screenshots, responsive stacking below 760 px, typography using `clamp()`, explicit focus rings, reduced-motion removal, and `forced-colors` compatibility. Avoid card grids for the core narrative.

- [ ] **Step 5: Compare implementation against concept**

Run the site locally, capture 1440×1100 and 390×844 screenshots, and inspect both concept and implementation with `view_image` in the same pass. Record at least these comparison points in the PR notes: exact hero copy, CTA prominence, first-viewport balance, palette, product-window framing, next-section visibility, mobile stacking, typography, and absence of invented copy.

- [ ] **Step 6: Run tests and commit visual slice**

Run: `cd website && npm test && npm run typecheck`

Expected: all tests PASS and every production asset resolves.

```bash
git add website/design website/public/styles.css website/public/assets website/tests/site-content.test.ts
git commit -m "Implement Native Focus website design"
```

---

### Task 5: Cloudflare Configuration and Local Integration

**Files:**
- Create: `website/wrangler.jsonc`
- Create: `website/worker-configuration.d.ts`
- Modify: `website/tests/site-content.test.ts`

**Interfaces:**
- Consumes: `src/worker.ts` and `public/` assets.
- Produces: local Worker dev server, validated production bundle, and custom-domain deployment source of truth.

- [ ] **Step 1: Write failing configuration assertions**

Extend `site-content.test.ts` to load `wrangler.jsonc` after stripping comments and assert:

```ts
expect(config.name).toBe("quota-monitor-site");
expect(config.main).toBe("src/worker.ts");
expect(config.compatibility_date).toBe("2026-07-15");
expect(config.workers_dev).toBe(false);
expect(config.assets.directory).toBe("./public");
expect(config.assets.binding).toBe("ASSETS");
expect(config.assets.not_found_handling).toBe("404-page");
expect(config.assets.run_worker_first).toEqual(["/download", "/api/release"]);
expect(config.routes).toContainEqual({
  pattern: "quota-monitor.timmyagentic.com",
  custom_domain: true,
});
```

- [ ] **Step 2: Run the config test and verify RED**

Run: `cd website && npm test -- --run tests/site-content.test.ts`

Expected: FAIL because `wrangler.jsonc` does not exist.

- [ ] **Step 3: Add validated Wrangler configuration**

Create `website/wrangler.jsonc`:

```jsonc
{
  "$schema": "./node_modules/wrangler/config-schema.json",
  "name": "quota-monitor-site",
  "main": "src/worker.ts",
  "compatibility_date": "2026-07-15",
  "workers_dev": false,
  "assets": {
    "directory": "./public",
    "binding": "ASSETS",
    "not_found_handling": "404-page",
    "run_worker_first": ["/download", "/api/release"]
  },
  "routes": [
    {
      "pattern": "quota-monitor.timmyagentic.com",
      "custom_domain": true
    }
  ],
  "observability": {
    "enabled": true
  }
}
```

Run `npx wrangler types` to generate `worker-configuration.d.ts`, then `npx wrangler types --check` to validate the exact binding and route configuration against Wrangler 4.110.0. Include the generated file from `tsconfig.json`. The two exact `run_worker_first` paths enter Worker code; ordinary static assets stay on the Static Assets path and receive the checked-in `_headers` rules.

- [ ] **Step 4: Verify local Worker behavior**

Run `cd website && npm run dev -- --port 8787`, then check:

```bash
curl -fsS http://127.0.0.1:8787/ > /tmp/qm-site-home.html
curl -fsS http://127.0.0.1:8787/api/release
curl -fsSI http://127.0.0.1:8787/styles.css
curl -fsS http://127.0.0.1:8787/robots.txt
```

Expected: home and CSS return 200, release JSON names the latest version, security headers are present, and public HTML contains no GitHub reference.

Issue a real `/download` request to a temporary file, verify the `Content-Disposition` filename, size above 1 MB, SHA-256 against the published `.sha256`, and UDIF trailer marker `koly`. Delete the temporary DMG after verification.

- [ ] **Step 5: Run complete website check and dry run**

Run: `cd website && npm run check`

Expected: typecheck PASS, Vitest PASS, Wrangler resolves the static directory and Worker entry, and dry-run bundle creation exits 0.

- [ ] **Step 6: Commit deployment configuration**

```bash
git add website/wrangler.jsonc website/worker-configuration.d.ts website/tests/site-content.test.ts
git commit -m "Configure Quota Monitor website deployment"
```

---

### Task 6: Repository Gate, Publication, Deployment, and Live Verification

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`
- Modify: PR body only outside the repository.

**Interfaces:**
- Consumes: completed website module and repository QA gate.
- Produces: pushed branch, ready PR, Cloudflare production deployment, and verified public download.

- [ ] **Step 1: Add bilingual Unreleased entries**

Under `## [Unreleased]`, add:

```md
### Added

- **Quota Monitor product website.** Added a bilingual macOS product site with current feature guidance and a one-click download that always serves the latest notarized DMG.
```

Chinese:

```md
### 新增

- **Quota Monitor 产品官网。** 新增中英双语 macOS 产品网站，介绍当前功能，并通过一次点击直接下载最新的已公证 DMG。
```

- [ ] **Step 2: Run focused and repository-wide gates**

Run:

```bash
cd website && npm run check
cd .. && ./qa/run-static.sh
git diff --check
```

Expected: website tests/typecheck/dry-run PASS; shell, Python, release-note, Swift, and diff checks PASS.

- [ ] **Step 3: Perform final fidelity and content audit**

Capture desktop 1440×1100 and mobile 390×844 renders. Inspect the accepted concept, latest desktop render, latest mobile render, app screenshot assets, and social card with `view_image`. Confirm:

- Exact approved hero copy and CTA order.
- No above-the-fold copy additions/removals.
- Native Focus color, type, spacing, and window treatment.
- No clipped content, horizontal overflow, or undersized mobile CTA.
- Complete English/Chinese switching and metadata updates.
- No visitor-visible GitHub text, icon, link, redirect, or error response.
- Download attachment matches the current appcast version and SHA-256.

- [ ] **Step 4: Commit final integration**

```bash
git add CHANGELOG.md CHANGELOG.zh-Hans.md
git commit -m "Document Quota Monitor product website"
```

- [ ] **Step 5: Push and open a ready PR**

Push `codex/product-website`, open a non-draft PR against `main`, and include summary, exact verification commands, desktop/mobile screenshots, download evidence, Cloudflare target, and the explicit no-GitHub-link audit. Do not merge unless required for the deployment mechanism.

- [ ] **Step 6: Deploy to Cloudflare**

From `website/`, run `npx wrangler deploy`. Record the Worker version/deployment ID and confirm the custom domain and certificate become active. Do not alter any unrelated Worker, zone, or DNS record.

- [ ] **Step 7: Verify production end to end**

Verify:

```bash
curl -fsS https://quota-monitor.timmyagentic.com/ > /tmp/qm-site-production.html
curl -fsS https://quota-monitor.timmyagentic.com/api/release
curl -fsS -D /tmp/qm-download-headers.txt -o /tmp/QuotaMonitor-latest.dmg https://quota-monitor.timmyagentic.com/download
```

Check TLS, security headers, localized browser rendering, attachment filename, file size, SHA-256, and `koly` trailer. Scan the production HTML, scripts, metadata, error-page response, and redirect chain for visitor-visible GitHub references. Remove temporary artifacts after verification.

- [ ] **Step 8: Final handoff**

Report the public website URL, direct download URL, PR URL, current served version, verification summary, and any intentional visual deviations. Only claim completion after both the live site and live download are proven.
