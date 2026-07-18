<div align="center">
  <img src="website/public/assets/app-icon.png" width="112" height="112" alt="Quota Monitor app icon">

# Quota Monitor

**Know your quota. Keep your flow.**

A native macOS menu-bar app for understanding Codex and Claude Code quotas,
token usage, API-equivalent cost estimates, trends, and sessions.

原生 macOS 菜单栏工具，集中查看 Codex 与 Claude Code 的额度、Token 用量、
API 等价费用估算、趋势和会话明细。

[Official website](https://quota-monitor.timmyagentic.com/) ·
[Download](https://quota-monitor.timmyagentic.com/download) ·
[Releases](https://github.com/timmyagentic/quota-monitor/releases) ·
[Privacy](https://quota-monitor.timmyagentic.com/privacy)

[![Latest release](https://img.shields.io/github/v/release/timmyagentic/quota-monitor?display_name=tag&sort=semver)](https://github.com/timmyagentic/quota-monitor/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![MIT License](https://img.shields.io/github/license/timmyagentic/quota-monitor)](LICENSE)
</div>

![Quota Monitor dashboard showing quota cards, token trends, and composition charts with synthetic data](website/public/assets/dashboard-hero.webp)

## Why Quota Monitor

Codex and Claude Code expose useful quota and usage information in different
places. Quota Monitor brings those signals together in a lightweight native
Mac app so you can answer three questions quickly:

- How much quota is left, and when does it reset?
- Where are tokens and API-equivalent costs going?
- Which days, models, and sessions account for the most usage?

Quota Monitor is designed for glanceable daily use from the menu bar, with a
full Dashboard when you want to investigate further.

## Highlights

- **Live quota clarity** — track Codex and Claude Code quota windows, usage
  percentages, reset times, availability, and burn-rate projections.
- **Menu-bar overview** — keep the most important 5-hour and 7-day numbers one
  click away without leaving your current workflow.
- **Trends and forecast** — compare recent periods, inspect activity over time,
  and see which providers and models dominate usage.
- **Session drill-down** — search and sort sessions, then inspect models,
  events, token categories, timing, and estimated value.
- **Local history** — index Codex and Claude Code history into a local SQLite
  database for fast daily and session-level exploration.
- **Native experience** — SwiftUI interface, English and Simplified Chinese,
  signed and notarized DMG releases, and in-app Sparkle updates.

| Dashboard | Sessions | History |
| --- | --- | --- |
| ![Dashboard insights with synthetic data](website/public/assets/dashboard-insights.webp) | ![Session details with synthetic data](website/public/assets/sessions-detail.webp) | ![History details with synthetic data](website/public/assets/history-detail.webp) |

## Install

Quota Monitor requires **macOS 14 Sonoma or later**.

1. [Download the latest notarized DMG](https://quota-monitor.timmyagentic.com/download).
2. Open the DMG and drag **Quota Monitor** into **Applications**.
3. Launch the app and choose Codex, Claude Code, or both during setup.

You can also download a specific version from
[GitHub Releases](https://github.com/timmyagentic/quota-monitor/releases).
Release builds are Developer ID signed and Apple notarized. Installed copies
receive future releases through the built-in Sparkle updater.

Optional checksum verification:

```bash
cd ~/Downloads
shasum -c QuotaMonitor-<version>.dmg.sha256
```

> Quota Monitor was renamed from CodexMonitor on 2026-05-07. The current
> bundle identifier is `dev.tjzhou.QuotaMonitor`; first launch automatically
> migrates the legacy database and preferences. An old
> `/Applications/CodexMonitor.app` copy can be removed manually.

## How data is collected

### Codex

- Live quotas come from `codex app-server` using
  `account/rateLimits/read`.
- Local history is read from `~/.codex/sessions` and
  `~/.codex/archived_sessions`.
- Quota Monitor can discover a standalone Codex CLI or the binary bundled
  inside the first-party `Codex.app`.

### Claude Code

- Live quotas come from Anthropic's OAuth usage endpoint using Claude Code
  credentials available on the Mac.
- Local history is read from `~/.claude/projects` and
  `~/.config/claude/projects`.
- Quota Monitor supports the standalone Claude Code CLI and Claude Desktop's
  bundled Claude Code helper. Claude Desktop's separate Electron token cache
  is not decrypted or reused.

API-equivalent costs are estimates based on model pricing and token counts;
they are not provider invoices or subscription charges.

## Privacy

Session history and usage events stay in Quota Monitor's local SQLite database.
Live quota refreshes contact the corresponding Codex or Claude Code provider
service.

Eligible Developer ID builds also send one anonymous daily active-installation
check-in containing exactly six fields: schema version, UTC day, app version,
brand, distribution channel, and a rotating daily token. It does **not** include
account details, quota values, usage history, file paths, a device ID, or any
stable identifier.

Read the complete bilingual
[privacy policy](https://quota-monitor.timmyagentic.com/privacy) for retention,
aggregation, and Cloudflare network-boundary details.

## Official website

The production website is
[quota-monitor.timmyagentic.com](https://quota-monitor.timmyagentic.com/).
Its source is part of this repository in [`website/`](website/), including the
English and Simplified Chinese product pages, privacy policy, download route,
Cloudflare Worker, D1 migrations, and tests.

Run it locally:

```bash
cd website
npm ci
npm run dev
```

Validate the complete website surface:

```bash
cd website
npm run check
```

## Build the macOS app

No Xcode project is required. The app is built with Swift Package Manager.

```bash
# Run the Swift test suite without macOS keychain stalls
swift test --disable-keychain

# Run the repository's default non-GUI validation gate
./qa/run-static.sh

# Assemble a locally signed app bundle
./build.sh
open .build/QuotaMonitor.app

# Build with release settings
CONFIG=release ./build.sh
```

For signing, notarization, packaging, and release details, see
[`docs/release.md`](docs/release.md).

## Repository map

```text
QuotaMonitor/
├── App/                 App lifecycle and shared state
├── Core/                Import, quota, analytics, storage, and settings logic
└── Features/            Menu bar, Dashboard, History, Sessions, and Settings UI
Tests/QuotaMonitorTests/ Swift Testing suites and fixtures
website/                 Official website, Worker APIs, D1 migrations, and tests
qa/                      Static checks and isolated macOS QA helpers
docs/                    Architecture, behavior, release, and product documentation
tools/                   Build, DMG, notarization, and release automation
```

Useful references:

- [Product manual](docs/product-manual.md)
- [Architecture notes](CLAUDE.md)
- [Codex and Claude integration findings](docs/findings.md)
- [Feature parity and design choices](docs/parity.md)
- [English changelog](CHANGELOG.md) ·
  [简体中文更新日志](CHANGELOG.zh-Hans.md)

## Contributing

Issues and pull requests are welcome. Keep changes focused, add tests for app
logic, update both changelogs for user-visible work, and run the relevant app
or website validation before opening a pull request.

Quota Monitor began as a Swift rewrite of
[codex-pacer](https://github.com/RyanZhangNTU/codex-pacer). It also draws on
ideas from [ccusage](https://github.com/ryoppippi/ccusage), especially its
usage-analysis and pricing work.

## License

[MIT](LICENSE) © 2026 tjzhou.
