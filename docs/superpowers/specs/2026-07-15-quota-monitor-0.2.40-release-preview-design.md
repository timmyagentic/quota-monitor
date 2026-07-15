# QuotaMonitor 0.2.40 Release Preview Design

## Goal

Prepare the bilingual Sparkle release-note preview for QuotaMonitor 0.2.40 as
the first release gate. The preview should make the two most important user
outcomes immediately understandable inside the compact update window:

1. quota displays follow the Codex windows that are actually active;
2. Codex cost estimates use the recorded service tier and avoid inflated
   subagent usage.

The rendered English and Simplified-Chinese HTML is the approval surface. The
version bump, changelog rollover, release PR, tag, release workflow, and
appcast publication happen only after the preview is approved.

## Scope

Create these committed release-note fragments:

- `ReleaseNotes/0.2.40.en.html`
- `ReleaseNotes/0.2.40.zh-Hans.html`

The fragments remain self-contained and compatible with the existing Sparkle
`WKWebView`. They reuse the proven 0.2.39 visual system: compact hero, two-card
grid, subtle entrance animation, dark-mode colors, and reduced-motion support.

This preview does not yet modify `Resources/VERSION`, roll `Unreleased` into a
0.2.40 changelog section, create a tag, publish a DMG, or edit `appcast.xml`.
Those actions belong to the post-approval release-preparation stage.

## Content hierarchy

### Hero

The hero introduces the release as a trust and clarity update, without
implementation terminology.

English:

- Eyebrow: `Release highlights`
- Title: `Closer to your real Codex usage`
- Subtitle: `Weekly-only quotas and complete Fast pricing support.`

Simplified Chinese:

- Eyebrow: `更新亮点`
- Title: `更贴合 Codex 的真实用量`
- Subtitle: `支持仅周额度模式，并完整覆盖 Fast 计费规则。`

### Card 1: active quota windows

English:

> **Weekly-only quotas are now supported.** When Codex offers only a weekly
> limit, QuotaMonitor follows it as-is. If the 5-hour limit returns, it appears
> automatically.

Simplified Chinese:

> **支持仅周额度模式。** 当 Codex 只提供周额度时，QuotaMonitor 会按实际状态显示；5 小时额度恢复后也会自动出现。

### Card 2: trustworthy Codex costs

English:

> **Complete Fast pricing support.** QuotaMonitor now prices each request from
> its recorded tier and correctly handles Standard, Flex, long-context, and
> subagent usage.

Simplified Chinese:

> **全面支持 Fast 计费规则。** QuotaMonitor 会按每次请求记录的档位估算费用，并正确处理 Standard、Flex、长上下文和子会话用量。

The final HTML keeps the cards visually balanced and may tighten line breaks
without changing meaning. It does not use the 0.2.39 `DAY-ONE` badge.

## Deliberate omissions

The trend-chart final-day alignment and activity-heatmap hover fixes remain in
the full bilingual changelogs, but do not become additional preview cards.
They are valuable polish, while the active-quota and accurate-cost changes are
the clearest reasons to update. Keeping two cards preserves the intentionally
compact 0.2.39 update-window density.

## Visual and accessibility behavior

- Use two equal-width cards in the current update-window width.
- Preserve the existing accent, green, amber, and coral palette without adding
  external images, fonts, scripts, or network dependencies.
- Keep animation decorative and ensure `prefers-reduced-motion: reduce`
  displays the complete content without transitions.
- Keep sufficient contrast in both light and dark appearance.
- Use semantic `section`, `article`, heading, and paragraph elements with a
  localized `aria-label`.
- Keep English and Chinese structure, card order, numbering, and emphasis in
  parity.

## Preview and validation

Before asking for visual approval:

1. render both committed fragments at the app update window's effective width;
2. inspect English and Chinese in light appearance;
3. inspect dark appearance and reduced-motion fallback;
4. confirm there are exactly two cards, no overflow, no clipped text, no
   external resources, and no executable script;
5. provide clickable local HTML files and rendered screenshots to the user.

The preview approval is a content and visual gate. It does not authorize tag
creation or public release publication.

## Post-approval release sequence

After the user approves both previews:

1. bump `Resources/VERSION` from 0.2.39 to 0.2.40;
2. move both `Unreleased` sections into `0.2.40` with the actual release date,
   leaving new empty `Unreleased` sections;
3. validate the bilingual notes with
   `python3 tools/validate-release-notes.py 0.2.40`;
4. run `./qa/run-static.sh` and a release sanity build as appropriate;
5. commit, push `codex/release-0.2.40`, and open a ready release PR;
6. merge only after checks and review threads are clean;
7. fast-forward local `main`, create and push tag `v0.2.40`;
8. monitor `release.yml` until the signed/notarized DMG and checksum are
   published;
9. merge the generated `appcast/v0.2.40` PR, or use the documented manual
   fallback if workflow PR creation fails;
10. verify the public release assets, top appcast item, signature metadata,
    download URL, and both release-note links.

## Success criteria

- The two HTML files render cleanly and communicate the same two outcomes in
  both languages.
- The copy is user-facing and avoids PR, CI, parser, database, and migration
  terminology.
- The preview remains compact enough for the Sparkle update window.
- No public release action occurs before explicit preview approval.
- The later release follows the repository's PR, tag, CI signing, and appcast
  publication contract without hand-signing a locally rebuilt DMG.
