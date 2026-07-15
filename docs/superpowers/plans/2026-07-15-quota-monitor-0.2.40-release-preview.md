# QuotaMonitor 0.2.40 Release Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create and visibly verify the approved two-card English and Simplified-Chinese Sparkle release-note preview for QuotaMonitor 0.2.40.

**Architecture:** Copy the proven self-contained 0.2.39 release-note fragments so the update-window CSS and accessibility behavior remain unchanged, then replace only the hero and two card bodies. Validate the fragments structurally and render them through QuotaMonitor's QA-only real update-window preview launcher.

**Tech Stack:** HTML/CSS fragments, Python standard-library `html.parser`, SwiftPM macOS app, SwiftUI/AppKit/WKWebView QA preview.

## Global Constraints

- Create `ReleaseNotes/0.2.40.en.html` and `ReleaseNotes/0.2.40.zh-Hans.html` only in the release-note implementation task.
- Keep exactly two cards in matching order across both languages.
- Preserve dark mode and `prefers-reduced-motion` behavior from 0.2.39.
- Do not add external images, fonts, scripts, or network dependencies.
- Do not bump `Resources/VERSION`, roll changelogs, tag, publish, or edit `appcast.xml` before preview approval.
- Do not use the 0.2.39 `DAY-ONE` badge.

---

### Task 1: Build and verify the bilingual two-card preview

**Files:**
- Create: `ReleaseNotes/0.2.40.en.html`
- Create: `ReleaseNotes/0.2.40.zh-Hans.html`
- Reference: `ReleaseNotes/0.2.39.en.html`
- Reference: `ReleaseNotes/0.2.39.zh-Hans.html`
- Test: structural fragment validation and the QA-only update-window preview

**Interfaces:**
- Consumes: the 0.2.39 self-contained `<style>` plus `.qm-release-page` fragment structure.
- Produces: two release-note fragments accepted by `UpdateWindowPreviewLauncher` through `--quotamonitor-preview-update-window-html`.

- [ ] **Step 1: Copy the stable visual baseline**

```sh
cp ReleaseNotes/0.2.39.en.html ReleaseNotes/0.2.40.en.html
cp ReleaseNotes/0.2.39.zh-Hans.html ReleaseNotes/0.2.40.zh-Hans.html
```

Expected: both 0.2.40 files exist and initially match their 0.2.39 language counterpart.

- [ ] **Step 2: Replace the English content without changing the shared CSS**

Set the hero to:

```html
<p class="qm-release-eyebrow">Release highlights</p>
<h2 class="qm-release-title">Closer to your real Codex usage</h2>
<p class="qm-release-subtitle">Weekly-only quotas and complete Fast pricing support.</p>
```

Set card 1 to:

```html
<span class="qm-release-number">1</span>
<p><b>Weekly-only quotas are now supported.</b> When Codex offers only a weekly limit, QuotaMonitor follows it as-is. If the 5-hour limit returns, it appears automatically.</p>
```

Set card 2 to:

```html
<span class="qm-release-number">2</span>
<p><b>Complete Fast pricing support.</b> QuotaMonitor now prices each request from its recorded tier and correctly handles Standard, Flex, long-context, and subagent usage.</p>
```

- [ ] **Step 3: Replace the Simplified-Chinese content in structural parity**

Set the hero to:

```html
<p class="qm-release-eyebrow">更新亮点</p>
<h2 class="qm-release-title">更贴合 Codex 的真实用量</h2>
<p class="qm-release-subtitle">支持仅周额度模式，并完整覆盖 Fast 计费规则。</p>
```

Set card 1 to:

```html
<span class="qm-release-number">1</span>
<p><b>支持仅周额度模式。</b> 当 Codex 只提供周额度时，QuotaMonitor 会按实际状态显示；5 小时额度恢复后也会自动出现。</p>
```

Set card 2 to:

```html
<span class="qm-release-number">2</span>
<p><b>全面支持 Fast 计费规则。</b> QuotaMonitor 会按每次请求记录的档位估算费用，并正确处理 Standard、Flex、长上下文和子会话用量。</p>
```

- [ ] **Step 4: Validate both fragments**

Run a Python standard-library parser over both files and assert:

```python
from html.parser import HTMLParser
from pathlib import Path

for path in map(Path, [
    "ReleaseNotes/0.2.40.en.html",
    "ReleaseNotes/0.2.40.zh-Hans.html",
]):
    source = path.read_text()
    parser = HTMLParser()
    parser.feed(source)
    parser.close()
    assert source.count('<article class="qm-release-highlight release-animate"') == 2
    assert "DAY-ONE" not in source
    assert "<script" not in source.lower()
    assert "http://" not in source and "https://" not in source
print("release preview fragments: ok")
```

Expected: `release preview fragments: ok`.

- [ ] **Step 5: Run static QA before launching the preview app**

```sh
./qa/run-static.sh
```

Expected: shell/Python/release-note checks pass and the Swift test run reports zero failures.

- [ ] **Step 6: Render through the real update window**

Build the app and launch each file with isolated QA mode:

```sh
./build.sh
QUOTAMONITOR_QA_MODE=1 open -n .build/QuotaMonitor.app --args \
  --quotamonitor-preview-update-window-html "$PWD/ReleaseNotes/0.2.40.zh-Hans.html" \
  --quotamonitor-preview-update-window-version 0.2.40 \
  --quotamonitor-preview-current-version 0.2.39 \
  --quotamonitor-preview-locale zh-Hans
```

Repeat with the English file and `--quotamonitor-preview-locale en`. Inspect the exact QA app target, capture both windows, and confirm no clipping, overflow, blank content, or card-order mismatch.

- [ ] **Step 7: Review and commit the preview**

```sh
git diff --check
git diff -- ReleaseNotes/0.2.40.en.html ReleaseNotes/0.2.40.zh-Hans.html
git add ReleaseNotes/0.2.40.en.html ReleaseNotes/0.2.40.zh-Hans.html docs/superpowers/plans/2026-07-15-quota-monitor-0.2.40-release-preview.md
git commit -m "Add v0.2.40 release preview"
```

Expected: one commit containing the approved bilingual preview implementation and this plan, with the design-spec commit retained earlier in branch history.
