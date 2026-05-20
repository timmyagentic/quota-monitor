# Feature parity vs codex-pacer

Snapshot of where the Swift rewrite stands relative to the original Tauri/Rust + React app at `../references/codex-pacer/` and the closely related `../references/codexbar/`. Last reviewed: 2026-05-20.

| Area | codex-pacer | QuotaMonitor (this app) | Status |
| --- | --- | --- | --- |
| Menu bar tray with live 5h / 7d quotas | ✅ | ✅ | parity |
| Plan-type badge (Pro / Free / etc.) | ✅ | ✅ (raw string, incl. `prolite`) | parity+ |
| Pace ratio (burn vs linear) | ✅ | ✅, with red/orange/green thresholds | parity |
| Additional limits (e.g. GPT-5.3-Codex-Spark) | ✅ | ✅ | parity |
| `prolite` plan-type decode bug salvage | n/a (pre-existed bug) | ✅ brace-balance JSON extractor | new |
| `account/rateLimits/read` RPC (current name) | ❌ uses removed `rateLimits/read` | ✅ | ahead |
| Codex binary auto-discovery for GUI launches | partial | ✅ candidate dirs + login-shell fallback | ahead |
| JSONL importer (`~/.codex/sessions/**/*.jsonl` + `archived_sessions/`) | ✅ | ✅ scans both directories, prunes orphan import_state rows on archival | parity |
| Cumulative→delta token logic | ✅ | ✅ with reset detection | parity |
| Embedded rate-limit samples extracted from rollouts | ✅ | ✅ stored as `source_kind='jsonl'` | parity |
| Live rate-limit polling (background) | ✅ | ✅ `RateLimitPoller` actor, configurable interval | parity |
| Pricing catalog & API-equivalent value | ✅ | ✅ same formula, 13 model entries (incl. `gpt-5` legacy fallback) | parity |
| Pricing seed updates idempotent on launch | ✅ | ✅ `INSERT … ON CONFLICT DO UPDATE` | parity |
| Pricing editor (per-model) | ✅ | 🚫 **removed** — Pricing tab folded into Advanced in 0.2.8 with Sync + Restore Defaults only. A read-only "View Catalog" sheet (added 0.2.14) shows the 5-column rate table for inspection; bulk fixes go through LiteLLM Sync or by editing the sqlite catalog directly. | removed |
| Backfill recompute after pricing edit | ✅ | ✅ single UPDATE … FROM subquery | parity |
| 14-day spend bar chart | ✅ | 🚫 **removed** in dashboard redesign — replaced by Trends section (7d / 30d toggle with prior-period delta). See `dashboard-redesign.md`. | removed |
| 12-month spend bar chart + MoM delta | ✅ ccusage `monthly` report | 🚫 **removed** in dashboard redesign — month-level rollup did not earn its space alongside Trends + Composition. | removed |
| 24h rate-limit history line chart | ✅ | 🚫 **removed** in dashboard redesign — quota cards still surface live %, but the time-series chart was a low-value visual. | removed |
| Codex quota cards (5h primary + weekly secondary, used%, reset countdown) | ✅ pacer renders only in menu-bar popup | ✅ menu-bar popover renders these inside the Codex provider block (Dashboard cards removed; Forecast section subsumes the projection role). | parity |
| Codex quota burn-rate / projected exhaustion | ❌ pacer shows raw line chart only | ✅ ahead — least-squares slope over last 60 min of samples, surfaces `Hits 100% in ~Xh` only when ETA precedes natural reset (now lives in Dashboard's Forecast section) | ahead |
| Recent 5h billing blocks list (last 3 days) | ✅ ccusage `blocks` CLI | 🚫 **removed** in dashboard redesign — the active 5h block remains visible inline on the menu-bar Claude block; the historical list was rarely consulted. | removed |
| Sessions list + drilldown | ✅ | ✅ `NavigationSplitView`, search, sort | parity |
| Per-session timeline (token-level) | ✅ | ✅ event chips: in / cache / out / reasoning | parity |
| Per-session model breakdown | ✅ | ✅ when >1 model used in a session | parity |
| Settings: poll interval, language, tracked tools, menu-bar display, pricing sync | ✅ pacer exposes codex binary + CODEX_HOME + threshold inline | ✅ `Settings` scene split into General + Advanced; **path overrides intentionally removed** in 0.2.14 (env-var + well-known-location autoprobe handles all path resolution); threshold notifications removed in 0.2.10 | partial (path overrides absent by design) |
| CSV export of usage events | ✅ | ✅ Settings → Advanced → Export → Export usage_events.csv (NSSavePanel, streamed) | parity |
| Threshold notifications (≥85%) | ✅ | 🚫 **removed** in 0.2.10 — only Codex was covered (Claude 5h/7d have different semantics and were never wired in), and the menu-bar percentage is glanceable enough on its own. | removed |
| Open DB in Finder | ✅ | ✅ Settings → Advanced → Database → Reveal in Finder | parity |
| OSLog / structured logging | ✅ Rust `tracing` | ✅ `OSLog` with categories: appserver/importer/poller/pricing/ui | parity |
| First-launch onboarding wizard | ✅ | ✅ language picker on first launch (English / 简体中文); other paths covered by auto-discovery + clear empty states | parity |
| Notarized DMG distribution | ✅ | ⚠️ ad-hoc by default; `tools/notarize.sh` + `Resources/QuotaMonitor.entitlements` ready, requires Apple Developer cert | partial |
| Custom AppIcon | ✅ | ✅ generated by `tools/make-icon.sh` (Core Graphics → `.iconset` → `iconutil`); `Resources/AppIcon.icns` wired via `CFBundleIconFile` | parity |
| Subagent rollups (`contains_subagents`) | ✅ | ✅ parser reads `forked_from_id` + nested `thread_spawn`, post-scan reconciliation walks parent chain; Sessions tab shows badge + child list | parity |
| Legacy session model attribution | ✅ pacer pins to "unknown" (no cost) | ✅ ahead — falls back to gpt-5 (matches ccusage), flags inferred events with asterisk + tooltip in UI | ahead |
| Subscription / sync_settings tables | ✅ | 🚫 **removed** — the "Subscription cost" Settings section + `codexMonthlyUSD` / `claudeMonthlyUSD` keys + payoff KPI were deleted. The menu-bar headline now shows rolling 30-day API-equivalent spend instead, which doesn't depend on a user-supplied subscription price. | removed |
| Live Claude (Anthropic) quota meter | ❌ pacer is Codex-only; ccusage measures from JSONL only | ✅ ahead — `ClaudeUsageClient` polls Anthropic's OAuth `/api/oauth/usage` (5h / 7d / per-model Opus & Sonnet), falls back to measured 5h block + last-7d spend when no creds; same QuotaRow UI as Codex. Pay-as-you-go `extra_usage` deliberately not surfaced. | ahead |
| Pace verdict text in menu bar | ✅ pacer / CodexBar both render numeric pace | ✅ — `QuotaPaceLabel` outputs "On pace" / "X% in deficit · Runs out in 47m" / "X% in reserve" with severity tint; replaces the "0.99x pace" string on every QuotaRow | ahead |
| Keychain access policy for Claude OAuth | n/a | ✅ Settings → Advanced → Claude Code → "Keychain policy" picker (`fallback` / `never`); credentials file (`~/.claude/.credentials.json`) tried first to avoid prompts | new |
| DMG installer-window layout (background + icon positions) | ✅ | ✅ generated by `tools/make-dmg-bg.swift` + AppleScript in `make-dmg.sh`; full pipeline at `tools/release.sh` | parity |
| i18n (English + Simplified Chinese) | ❌ | ✅ runtime hot-swap, first-launch picker | new |

## Architectural differences (not gaps, deliberate choices)

| Aspect | codex-pacer | QuotaMonitor |
| --- | --- | --- |
| Language / runtime | Rust (Tauri host) + React/TS (renderer) | Swift 6, native SwiftUI |
| Distribution surface | macOS / Windows / Linux | macOS only (intentional) |
| Subprocess lifecycle | long-lived `codex app-server` per session | one-shot per RPC call (no zombie risk) |
| Concurrency | tokio + JS event loop | Swift Structured Concurrency (actors, strict concurrency) |
| Build / sandbox | Tauri bundler, codesign + notarize | SwiftPM + manual `.app` wrap, ad-hoc sign |
| Persistence | SQLite via `rusqlite` | SQLite via GRDB.swift (WAL + busy_timeout) |

## Known closures we'd accept before calling 1.0

1. Notarization for distribution outside developer machines.
2. Auto-update (Sparkle) so users don't manually re-download every release.

