# Quota Monitor Product Website Design

**Date:** 2026-07-15

**Status:** Approved

**Target:** `https://quota-monitor.timmyagentic.com`

## Goal

Create and deploy a bilingual product website that introduces Quota Monitor and lets a visitor download the latest notarized DMG with one click. The website must feel like a focused native macOS product, work well on phones and desktops, and contain no visible or clickable GitHub links.

## Audience and Success Criteria

The primary audience is a macOS user who uses Codex, Claude Code, or both and wants to understand quota pressure and local usage without opening several tools.

The website succeeds when:

- A first-time visitor understands the product within the first viewport.
- The primary download action immediately starts the current DMG download.
- Chinese and English visitors receive a complete localized experience.
- No page text, icon, navigation item, anchor, canonical URL, or social metadata points visitors to GitHub.
- Product imagery reflects current Quota Monitor behavior without exposing private usage data.
- The deployed site works at the custom Cloudflare domain with valid TLS.

## Approved Visual Direction

Use the approved **A — Native Focus** direction.

- Bright white and cool-blue surfaces with generous whitespace.
- Native macOS window framing rather than generic marketing-card chrome.
- The existing Quota Monitor app icon as the primary brand asset.
- Product colors derived from the app: Codex teal, Claude terracotta, light blue, green quota states, and restrained warning red.
- One strong product window in the first viewport, followed by larger product-detail compositions.
- Typography should feel crisp and native. Prefer a system-first stack and deliberate control sizing.
- Motion is limited to subtle entrance and hover transitions and must respect `prefers-reduced-motion`.

Avoid dark-first presentation, glossy promotional card grids, decorative badges, excessive gradients, stock imagery, and invented UI that does not resemble the product.

## Information Architecture

### Header

- Quota Monitor icon and wordmark.
- Same-origin links for the homepage Features section and the full Privacy page.
- A compact `中 / EN` language control.
- No external repository or social links.

### Hero

Chinese headline: **看清额度，保持专注。**

English headline: **Know your quota. Keep your flow.**

Chinese supporting copy:

> Quota Monitor 把 Codex 与 Claude Code 的实时额度、Token 趋势、API 等价费用估算和会话明细，集中到一个轻量的 macOS 菜单栏应用。

English supporting copy:

> Quota Monitor brings Codex and Claude Code quotas, token trends, API-equivalent cost estimates, and session details into one lightweight macOS menu-bar app.

The primary button shows the current version, for example `下载 QuotaMonitor 0.2.40` / `Download QuotaMonitor 0.2.40`. Supporting metadata states `macOS 14+`, `Developer ID signed`, and `Apple notarized` in localized form.

The first-viewport product visual uses synthetic data and current UI anatomy. It must not reuse the stale, sparse `0.2.31` Dashboard screenshot or any private real-data QA capture.

### Showcase Data Density Amendment

Product screenshots must use a reproducible, isolated showcase profile rather than the four-session smoke fixture or edited approximations of the interface. The profile is synthetic and contains no copied session titles, paths, account identifiers, credentials, or usage values from the installed app.

- The Dashboard headline and Trends chart use the 30-day window.
- At least 24 sessions span at least 18 active days in the last 30 days.
- Both Codex and Claude Code contribute visible usage, with at least five model or service-tier series in total.
- The newest Codex and Claude sessions are recent enough to populate both Forecast cards; the Codex sample includes current 5-hour and 7-day windows.
- The selected Sessions row contains at least six events so model, token, time, and API-equivalent value columns are visibly exercised.
- The website uses four distinct current-app captures: the Dashboard overview for Forecast and Trends, a scrolled Dashboard state for Activity and Composition, the Sessions drill-down, and populated day-by-day History. The social card reuses the verified Dashboard overview instead of inventing another product UI.
- All capture source data and the resulting images are visually inspected for private information before publication.
- Every product capture is a same-origin link to its full-size asset. On phone layouts the link includes a localized visible “view full size” hint so dense current-app UI remains inspectable instead of only being reduced to the content column width.

### Feature Story

Use four focused feature blocks:

1. **Live quota clarity** — active quota windows, remaining/used percentage, reset timing, and provider status.
2. **Trends and forecast** — 7-day through yearly trends, burn-rate projection, activity, and composition.
3. **Session drill-down** — search, sort, model and token details, event timing, and API-equivalent cost estimates.
4. **Local history** — local Codex and Claude Code history is indexed into the app's local SQLite database.

Product claims must use “API-equivalent cost estimate,” not “bill” or “actual spend.” The privacy copy must not claim the application is fully offline: local history remains on the Mac, while live quota refreshes contact the corresponding provider services.

Website copy and alt text must describe only fields present in the current Sessions UI. In particular, they must not claim a duration field; the current detail surface shows Value, Tokens, Events, Started, and event rows for Time, Model, Tokens, and Cost.

### Installation

Present three steps:

1. Download the latest DMG.
2. Drag Quota Monitor into Applications.
3. Open the app and select the tools to track.

End with a second direct-download call to action and a minimal footer containing the product name, language control, MIT license text, and copyright. The footer contains no GitHub link.

## Localization

- Ship complete Simplified Chinese and English strings in the page bundle.
- Select the initial language from the browser locale, defaulting to English for non-Chinese locales.
- Persist an explicit visitor choice locally.
- Update `lang`, title, description, navigation, CTA text, accessibility labels, and status/error copy together.
- Do not duplicate separate localized URLs in the first release; use one canonical domain and client-side locale selection.

## Technical Architecture

Place the website in a focused `website/` module inside the repository.

- Static semantic HTML, CSS, and a small JavaScript localization/interaction layer.
- Workers Static Assets serves the bilingual homepage and full privacy policy.
- A Cloudflare Worker handles `/download`, `/api/release`, the opt-in
  `/api/v1/daily-active` endpoint, and the private
  `/maintainer/versions` dashboard before other requests fall through to the
  static assets binding.
- `wrangler.jsonc` declares the Worker name `quota-monitor-site`, the current compatibility date, the static asset directory, and the custom domain route.
- D1 stores date-scoped anonymous observations and closed-day aggregate counts;
  a scheduled Worker aggregates and expires them. The maintainer dashboard
  uses a required secret-backed Basic challenge, and public/private routes use
  separate rate-limit bindings.
- Website pages use no cookies, client analytics, or third-party UI runtime.
  Anonymous app version reporting is a separate, explicit opt-in and is fully
  disclosed on the privacy page.
- Invocation logs, Logpush, tail consumers, and traces remain disabled for
  request handling. Purpose-built scheduled-operation logs contain only the
  UTC aggregation day, change counts, and a generic result; they never contain
  request payloads, tokens, header values, IP addresses, or database rows.

This focused static-plus-Worker architecture is preferred over a client
framework because the two public pages share one small locale layer while the
four service routes stay server-side and narrowly scoped. It reduces
JavaScript and build complexity while keeping the privacy and release
contracts testable beside the Swift app.

## Download Data Flow

The visible button always targets the same-domain path `/download`.

1. The Worker reads the canonical Quota Monitor appcast and locates the newest DMG enclosure and version.
2. The Worker follows the upstream asset response server-side.
3. The Worker streams the DMG to the visitor with an attachment filename and safe content headers.
4. The browser remains on the Quota Monitor domain and never visits an external release page.

The homepage version label is obtained from a same-domain `/api/release` response or a build-time fallback so it stays useful if metadata is temporarily unavailable. Metadata responses are cached briefly; immutable versioned DMG responses may use Cloudflare caching without buffering the entire file in Worker memory.

No visitor-facing response, redirect, HTML anchor, or metadata field contains a GitHub URL. Upstream repository URLs may exist only inside Worker implementation details required to retrieve public release metadata and artifacts.

## Failure Handling

- If release metadata cannot be parsed, `/api/release` returns a typed unavailable response and the page keeps its build-time fallback version.
- If a download cannot begin, the Worker returns a branded bilingual HTML error with Retry and Back controls instead of redirecting to an external site.
- Upstream status codes, missing enclosures, incorrect asset content, and non-DMG filenames are treated as failures.
- Download responses set `Content-Disposition`, `X-Content-Type-Options: nosniff`, and a conservative content type.
- Visitors need no credential for the homepage, privacy policy, release
  metadata, download, or opt-in check-in. A Cloudflare secret is required only
  for the private maintainer dashboard and is never exposed to public routes or
  client JavaScript.

## Accessibility, Responsive Behavior, and SEO

- Use semantic headings, landmarks, buttons, and links with visible keyboard focus.
- Meet WCAG AA contrast for text and controls.
- Preserve a clear first viewport from 320 px phone width through large desktop widths.
- Stack product imagery below the hero copy on phones and keep the download button thumb-friendly.
- Keep screenshots tappable at phone widths and expose a localized full-size-view hint.
- Respect reduced-motion and high-contrast preferences.
- Provide localized document titles/descriptions, Open Graph imagery, favicon assets, canonical URL, and structured SoftwareApplication metadata.
- Structured data may identify the license as MIT but must not include a GitHub URL.

## Verification

Automated verification covers:

- Release/appcast parsing and newest-DMG selection.
- `/api/release` success and failure responses.
- `/download` attachment headers, filename, status handling, and streamed bytes.
- Daily-active HTTPS, bounded-body, exact-schema, same-day deduplication, and
  rate-limit behavior.
- Private dashboard authentication, cache isolation, allowlisted filters,
  aggregation, raw-row deletion, and 400-day aggregate retention.
- Project-owned HTTP GET/HEAD 301 redirects that preserve host, path, and query,
  while insecure POST bodies are rejected instead of redirected.
- Chinese/English string completeness and browser-locale selection.
- A rendered-site audit that fails on visible/clickable GitHub references.
- Static asset, semantic, and link integrity checks.
- `wrangler deploy --dry-run`.

Visual and functional verification covers:

- Desktop and mobile browser screenshots compared with the approved Native Focus concept.
- First viewport hierarchy, exact copy, typography, product colors, window framing, and CTA prominence.
- Language switching and persistence.
- Keyboard navigation, focus visibility, reduced motion, and mobile overflow.
- A real download request proving the deployed response is an attachment with the current DMG filename and valid disk-image bytes.
- Final HTTPS checks on `quota-monitor.timmyagentic.com` after deployment.

## Repository and Delivery

- Work is performed in the independent `codex/product-website` worktree and branch based on current `origin/main`.
- Both changelog files receive a concise user-facing Unreleased entry.
- Run focused website checks first, then the repository's `./qa/run-static.sh` gate.
- Commit, push, and open a ready PR with verification evidence and screenshots.
- Apply the D1 migration and required bindings, deploy the verified branch to
  the Cloudflare Worker and custom domain, then verify the public pages,
  download path, private boundary, and synthetic check-in cleanup before the
  app reporter is released.

## Non-Goals

- No documentation portal, blog, mailing list, payments, visitor accounts,
  behavioral visitor analytics, or CMS. The narrowly scoped, consented
  anonymous version check-in and private aggregate dashboard are the only
  telemetry surfaces in scope.
- No App Store download path in the first release.
- No GitHub, social-media, or community links anywhere in the rendered website.
- No hosting the DMG as a checked-in static asset.
