#!/usr/bin/env python3
"""Extract one version's section from a changelog and emit it as
HTML suitable for Sparkle's release-notes WebView. release-sparkle.sh
writes this into ReleaseNotes/<version>.<lang>.html, which the appcast
references via <sparkle:releaseNotesLink> (Sparkle downloads it lazily),
rather than inlining it — that keeps appcast.xml small enough to avoid
raw.githubusercontent.com rate-limiting the update feed.

Usage:
  ./changelog-to-html.py [--format summary|full|both] [--lang en|zh-Hans]
                         <version> [CHANGELOG.md]

The second positional argument is the changelog file to read from; it
defaults to CHANGELOG.md. Pass CHANGELOG.zh-Hans.md to render the
Simplified-Chinese release notes — release-sparkle.sh calls this once
per language to populate the two linked notes files that back the
bilingual <sparkle:releaseNotesLink xml:lang="…"> nodes.

The few user-visible labels (the ``both`` details toggle and the
missing-section fallback line) are localized via ``--lang``. When omitted,
the language is inferred from the changelog filename (e.g.
CHANGELOG.zh-Hans.md → zh-Hans), so the Chinese notes don't ship an English
"Show full details" toggle.

--format controls the output structure:
  summary  – a self-styled release edition with a short opening sequence and
             every detailed change organized into navigable chapters. This is
             the default for the update window.
  full     – the original behaviour (all ``###`` sections, no summary).
  both     – compatibility mode: ``#### Summary`` items wrapped in
             ``<div class="release-summary">``, a toggle button, and
             the full sections wrapped in
             ``<div class="release-details">``.

CJK authoring note: changelog bullets in CHANGELOG.zh-Hans.md must each
sit on a SINGLE physical line. The wrapped-line joiner below glues
continuation lines with a space, which would inject stray spaces between
Chinese characters. English bullets stay hard-wrapped as before.

Lives as a standalone file rather than inline in release-sparkle.sh
because bash's $( ... <<'EOF' ... EOF ) command substitution still
parses backticks in the heredoc body as legacy command substitution
even with a quoted delimiter — and the regex for `code` spans needs
literal backticks. Putting it in a .py file sidesteps the issue.
"""
from __future__ import annotations

import argparse
import re
import sys


# User-visible labels keyed by language. Only these few strings differ
# between languages — the emitted HTML structure is identical. Add a row to
# localize another language's appcast notes. ``fallback`` is a format string
# taking {changelog} and {version}.
LABELS = {
    'en': {
        'show': 'Show full details',
        'hide': 'Hide details',
        'eyebrow': 'Release highlights',
        'title': 'A new chapter for QuotaMonitor.',
        'subtitle': 'Start with the big picture, then explore every change in the release.',
        'version': 'Version',
        'overview': 'The release at a glance',
        'overview_hint': 'The shortest path through a release with much more beneath it.',
        'chapters': 'Release chapters',
        'all_changes': 'Every change, organized',
        'all_changes_hint': 'Browse the complete release without losing your place.',
        'change': 'change',
        'changes': 'changes',
        'chapter': 'chapter',
        'chapter_plural': 'chapters',
        'fallback': "See {changelog} for what's new in {version}.",
    },
    'zh-Hans': {
        # Match L10n.updateShowDetails / updateHideDetails so the appcast
        # toggle reads the same as the in-app one.
        'show': '查看完整变更',
        'hide': '收起详情',
        'eyebrow': '更新亮点',
        'title': '迈入 {version}，全新篇章。',
        'subtitle': '先看这次版本的全貌，再按章节浏览每一项变化。',
        'version': '版本',
        'overview': '快速了解这次更新',
        'overview_hint': '先抓住主线，下面还有完整变化可供浏览。',
        'chapters': '更新章节',
        'all_changes': '完整变化，分章呈现',
        'all_changes_hint': '所有更新都在这里，浏览时不会迷失位置。',
        'change': '项变化',
        'changes': '项变化',
        'chapter': '个章节',
        'chapter_plural': '个章节',
        'fallback': '{version} 的更新内容详见 {changelog}。',
    },
}


def resolve_lang(lang: str | None, changelog: str) -> str:
    """Pick the label language: explicit --lang wins; otherwise infer from
    the changelog filename (CHANGELOG.zh-Hans.md → zh-Hans); default English."""
    if lang:
        return lang if lang in LABELS else 'en'
    name = changelog.lower()
    for key in LABELS:
        if key != 'en' and key.lower() in name:
            return key
    return 'en'


def esc(s: str) -> str:
    return (s.replace('&', '&amp;')
             .replace('<', '&lt;')
             .replace('>', '&gt;'))


def inline_md(s: str) -> str:
    # HTML-escape first so user content can't smuggle in raw tags,
    # then re-introduce the small subset of markup we support.
    s = esc(s)
    s = re.sub(r'\*\*([^*]+?)\*\*', r'<b>\1</b>', s)
    s = re.sub(r'`([^`]+?)`', r'<code>\1</code>', s)
    return s


def parse_args() -> tuple[str, str, str, str | None]:
    """Return (format, version, changelog_path, lang)."""
    ap = argparse.ArgumentParser(
        description='Convert a changelog section to Sparkle HTML.')
    ap.add_argument('--format', choices=['summary', 'full', 'both'],
                    default='summary',
                    help='Output format (default: summary)')
    ap.add_argument('--lang', choices=sorted(LABELS), default=None,
                    help='Label language for the details toggle / fallback. '
                         'Default: inferred from the changelog filename.')
    ap.add_argument('version', help='Version string, e.g. 0.2.25')
    ap.add_argument('changelog', nargs='?', default='CHANGELOG.md',
                    help='Path to changelog file (default: CHANGELOG.md)')
    args = ap.parse_args()
    return args.format, args.version, args.changelog, args.lang


def extract_section(changelog: str, version: str) -> str | None:
    """Return the raw text of the version's section, or None."""
    try:
        with open(changelog, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return None

    m = re.search(
        r'^##\s+\[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^##\s+\[|\Z)',
        text, re.S | re.M)
    return m.group(1).strip() if m else None


def split_summary(section: str) -> tuple[list[str], str]:
    """Split a section into (summary_lines, remainder).

    Summary lines are the bullets under ``#### Summary`` (if present).
    Remainder is everything after the first ``###`` heading (or the
    full section if no ``#### Summary`` is found).
    """
    # Find #### Summary block: from "#### Summary" to the next ### or EOF.
    m = re.search(
        r'^####\s+Summary\s*\n(.*?)(?=^###|\Z)',
        section, re.S | re.M)
    if not m:
        return [], section

    summary_text = m.group(1).strip()
    summary_lines = [
        l[2:] for l in summary_text.split('\n') if l.startswith('- ')
    ]

    # Remainder = everything after #### Summary, starting at first ###
    remainder_m = re.search(r'^### ', section, re.M)
    remainder = remainder_m.group(0) + section[remainder_m.end():] \
        if remainder_m else ''

    return summary_lines, remainder


def render_bullets(lines: list[str], *,
                   join_wrapped: bool = False) -> str:
    """Render a list of bullet texts (without the ``- `` prefix) as
    ``<ul><li>…</li></ul>``."""
    if not lines:
        return ''
    items: list[str] = []
    for line in lines:
        if join_wrapped:
            text = line.strip()
        else:
            text = line.strip()
        items.append(f'<li>{inline_md(text)}</li>')
    return '<ul>\n' + '\n'.join(items) + '\n</ul>'


def parse_detail_sections(section: str) -> list[tuple[str, list[str]]]:
    """Return ``###`` headings and their complete bullet text.

    Changelog bullets may wrap on continuation lines. Keep the authored
    ordering and join those lines so the release edition can expose every
    detailed change, rather than stopping at the short Summary block.
    """
    sections: list[tuple[str, list[str]]] = []
    heading: str | None = None
    items: list[str] = []
    item_buffer: list[str] = []

    def flush_item() -> None:
        if item_buffer:
            items.append(' '.join(part.strip() for part in item_buffer))
            item_buffer.clear()

    def flush_section() -> None:
        nonlocal items
        flush_item()
        if heading is not None and items:
            sections.append((heading, items))
        items = []

    for line in section.split('\n'):
        if line.startswith('### '):
            flush_section()
            heading = line[4:].strip()
        elif line.startswith('- ') and heading is not None:
            flush_item()
            item_buffer.append(line[2:])
        elif line.startswith('  ') and item_buffer:
            item_buffer.append(line)
        elif not line.strip():
            flush_item()

    flush_section()
    return sections


def rich_summary_style() -> str:
    """Self-contained visual styling for appcast release notes.

    The style is emitted inline because users updating from an older app render
    this HTML with that older app's WebView and bundled CSS.
    """
    return """
<style class="qm-release-style">
.qm-release-page {
  --release-ink: var(--qm-text, #1d1d1f);
  --release-muted: var(--qm-secondary, #6e6e73);
  --release-accent: var(--qm-accent, #007aff);
  --release-green: #22a966;
  --release-amber: #c88b18;
  --release-coral: #df6254;
  --release-violet: #8b5cf6;
  --release-line: color-mix(in srgb, var(--release-ink), transparent 88%);
  --release-wash: color-mix(in srgb, var(--release-accent), transparent 94%);
  color: var(--release-ink);
  padding: 0 2px 32px;
}
.qm-release-hero {
  display: grid;
  grid-template-columns: minmax(0, 1.3fr) minmax(190px, .7fr);
  gap: 28px;
  align-items: end;
  min-height: 236px;
  padding: 32px 30px 28px;
  overflow: hidden;
  border-bottom: 1px solid var(--release-line);
  background:
    radial-gradient(circle at 88% 18%,
      color-mix(in srgb, var(--release-violet), transparent 80%), transparent 35%),
    linear-gradient(128deg,
      color-mix(in srgb, var(--release-accent), transparent 88%),
      color-mix(in srgb, var(--release-green), transparent 93%) 48%,
      color-mix(in srgb, var(--release-amber), transparent 91%));
}
.qm-release-eyebrow,
.qm-release-nav-label,
.qm-release-chapter-number {
  color: var(--release-accent);
  font-size: 10.5px;
  font-weight: 750;
  letter-spacing: .12em;
  text-transform: uppercase;
}
.qm-release-title {
  max-width: 11em;
  margin: 8px 0 0;
  font-size: clamp(29px, 5vw, 42px);
  line-height: .98;
  letter-spacing: -.045em;
}
.qm-release-subtitle {
  max-width: 36em;
  margin: 14px 0 0;
  color: var(--release-muted);
  font-size: 13px;
  line-height: 1.5;
}
.qm-release-metrics {
  display: flex;
  gap: 18px;
  margin-top: 22px;
  color: var(--release-muted);
  font-size: 11px;
}
.qm-release-metrics strong {
  display: block;
  margin-bottom: 1px;
  color: var(--release-ink);
  font-size: 19px;
  line-height: 1;
}
.qm-release-version {
  justify-self: end;
  text-align: right;
}
.qm-release-version span {
  display: block;
  margin-bottom: -5px;
  color: var(--release-muted);
  font-size: 11px;
  font-weight: 650;
  letter-spacing: .06em;
  text-transform: uppercase;
}
.qm-release-version strong {
  display: block;
  max-width: 5.2em;
  overflow-wrap: anywhere;
  color: var(--release-accent);
  background: linear-gradient(135deg,
    var(--release-accent), var(--release-violet) 48%, var(--release-coral));
  -webkit-background-clip: text;
  background-clip: text;
  -webkit-text-fill-color: transparent;
  font-size: clamp(58px, 10vw, 94px);
  font-weight: 780;
  line-height: .82;
  letter-spacing: -.075em;
}
.qm-release-overview {
  padding: 26px 30px 30px;
  border-bottom: 1px solid var(--release-line);
}
.qm-release-section-title {
  margin: 0;
  font-size: 21px;
  line-height: 1.15;
  letter-spacing: -.02em;
}
.qm-release-section-hint {
  margin: 5px 0 0;
  color: var(--release-muted);
  font-size: 11.5px;
}
.qm-release-summary {
  list-style: none;
  margin: 18px 0 0;
  padding: 0;
  counter-reset: release-summary;
}
.qm-release-summary li {
  display: grid;
  grid-template-columns: 38px minmax(0, 1fr);
  gap: 12px;
  align-items: start;
  padding: 13px 0;
  border-top: 1px solid var(--release-line);
  counter-increment: release-summary;
}
.qm-release-summary li::before {
  content: counter(release-summary, decimal-leading-zero);
  padding-top: 1px;
  color: var(--release-accent);
  font-size: 10px;
  font-weight: 750;
  letter-spacing: .08em;
}
.qm-release-summary p {
  margin: 0;
  font-size: 12.5px;
  line-height: 1.48;
}
.qm-release-atlas {
  display: grid;
  grid-template-columns: 156px minmax(0, 1fr);
  gap: 32px;
  padding: 30px;
}
.qm-release-nav {
  position: sticky;
  top: 14px;
  align-self: start;
}
.qm-release-nav-label {
  margin: 0 0 10px;
  color: var(--release-muted);
}
.qm-release-nav button {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 8px;
  width: 100%;
  padding: 8px 8px 8px 11px;
  border: 0;
  border-left: 2px solid var(--release-line);
  color: var(--release-muted);
  background: transparent;
  font: inherit;
  font-size: 11.5px;
  text-align: left;
  cursor: pointer;
  transition: color 180ms ease, border-color 180ms ease,
              background 180ms ease;
}
.qm-release-nav button:hover,
.qm-release-nav button[aria-current="true"] {
  border-left-color: var(--release-accent);
  color: var(--release-ink);
  background: var(--release-wash);
}
.qm-release-nav-count {
  color: var(--release-muted);
  font-variant-numeric: tabular-nums;
}
.qm-release-chapters-header {
  padding: 0 0 22px;
}
.qm-release-chapter {
  scroll-margin-top: 14px;
  padding: 25px 0 12px;
  border-top: 1px solid var(--release-line);
}
.qm-release-chapter:first-of-type {
  padding-top: 0;
  border-top: 0;
}
.qm-release-chapter-heading {
  display: grid;
  grid-template-columns: 36px minmax(0, 1fr) auto;
  gap: 10px;
  align-items: baseline;
  margin-bottom: 8px;
}
.qm-release-chapter-number {
  color: var(--chapter-tone, var(--release-accent));
}
.qm-release-chapter h3 {
  margin: 0;
  font-size: 20px;
  line-height: 1.15;
  letter-spacing: -.02em;
}
.qm-release-chapter-count {
  color: var(--release-muted);
  font-size: 10.5px;
}
.qm-release-change-list {
  list-style: none;
  margin: 0;
  padding: 0 0 0 46px;
}
.qm-release-change-list li {
  padding: 12px 0;
  border-top: 1px solid var(--release-line);
  color: var(--release-muted);
  font-size: 11.8px;
  line-height: 1.5;
}
.qm-release-change-list b {
  color: var(--release-ink);
  font-size: 12.2px;
  font-weight: 650;
}
.qm-release-chapter:nth-of-type(4n+1) { --chapter-tone: var(--release-accent); }
.qm-release-chapter:nth-of-type(4n+2) { --chapter-tone: var(--release-green); }
.qm-release-chapter:nth-of-type(4n+3) { --chapter-tone: var(--release-amber); }
.qm-release-chapter:nth-of-type(4n) { --chapter-tone: var(--release-coral); }
.release-animate {
  opacity: 0;
  transform: translateY(12px);
  transition: opacity 420ms cubic-bezier(.2, .8, .2, 1),
              transform 420ms cubic-bezier(.2, .8, .2, 1);
}
.release-animate.visible {
  opacity: 1;
  transform: translateY(0);
}
@media (prefers-color-scheme: dark) {
  .qm-release-page {
    --release-line: color-mix(in srgb, var(--release-ink), transparent 84%);
    --release-wash: color-mix(in srgb, var(--release-accent), transparent 88%);
  }
}
@media (max-width: 640px) {
  .qm-release-hero {
    grid-template-columns: minmax(0, 1fr);
    min-height: 0;
  }
  .qm-release-version {
    justify-self: start;
    text-align: left;
  }
  .qm-release-version strong { font-size: 64px; }
  .qm-release-atlas {
    grid-template-columns: minmax(0, 1fr);
    gap: 22px;
  }
  .qm-release-nav {
    position: static;
    display: flex;
    gap: 4px;
    overflow-x: auto;
    padding-bottom: 3px;
  }
  .qm-release-nav-label { display: none; }
  .qm-release-nav button {
    flex: 0 0 auto;
    width: auto;
    border-left: 0;
    border-bottom: 2px solid var(--release-line);
  }
  .qm-release-nav button:hover,
  .qm-release-nav button[aria-current="true"] {
    border-bottom-color: var(--release-accent);
  }
}
@media (prefers-contrast: more) {
  .qm-release-page { --release-line: currentColor; }
  .qm-release-hero { background: transparent; }
}
@media (prefers-reduced-motion: reduce) {
  .release-animate {
    opacity: 1;
    transform: none;
    transition: none;
  }
  .qm-release-nav button { transition: none; }
}
</style>
""".strip()


def release_edition_script() -> str:
    return """
<script class="qm-release-script">
(function () {
  var reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var animated = document.querySelectorAll('.release-animate');
  if (reducedMotion || !('IntersectionObserver' in window)) {
    animated.forEach(function (element) { element.classList.add('visible'); });
  } else {
    var revealObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          revealObserver.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08 });
    animated.forEach(function (element) { revealObserver.observe(element); });
  }

  var buttons = Array.from(document.querySelectorAll('.qm-release-nav button'));
  var chapters = Array.from(document.querySelectorAll('.qm-release-chapter'));
  function selectChapter(id) {
    buttons.forEach(function (button) {
      button.setAttribute('aria-current', button.dataset.target === id ? 'true' : 'false');
    });
  }
  buttons.forEach(function (button) {
    button.addEventListener('click', function () {
      var chapter = document.getElementById(button.dataset.target);
      if (!chapter) return;
      selectChapter(button.dataset.target);
      chapter.scrollIntoView({ behavior: reducedMotion ? 'auto' : 'smooth', block: 'start' });
    });
  });
  if (chapters.length && 'IntersectionObserver' in window) {
    var chapterObserver = new IntersectionObserver(function (entries) {
      var visible = entries.filter(function (entry) { return entry.isIntersecting; });
      if (visible.length) selectChapter(visible[0].target.id);
    }, { rootMargin: '-10% 0px -68% 0px', threshold: 0 });
    chapters.forEach(function (chapter) { chapterObserver.observe(chapter); });
  }
})();
</script>
""".strip()


def render_summary(lines: list[str], details: str, *,
                   labels: dict[str, str], version: str) -> str:
    if not lines:
        return ""

    sections = parse_detail_sections(details)
    change_count = sum(len(items) for _, items in sections)
    change_word = labels['change'] if change_count == 1 else labels['changes']
    chapter_count = len(sections)
    chapter_word = labels['chapter'] if chapter_count == 1 else labels['chapter_plural']

    summary_items = [
        '<li class="release-animate"><p>' + inline_md(line.strip()) + '</p></li>'
        for line in lines
    ]

    nav_items: list[str] = []
    chapters: list[str] = []
    for index, (heading, items) in enumerate(sections, start=1):
        chapter_id = f'qm-release-chapter-{index}'
        current = 'true' if index == 1 else 'false'
        nav_items.append(
            f'<button type="button" data-target="{chapter_id}" '
            f'aria-controls="{chapter_id}" aria-current="{current}">'
            f'<span>{esc(heading)}</span>'
            f'<span class="qm-release-nav-count">{len(items)}</span>'
            f'</button>'
        )
        change_items = '\n'.join(
            f'<li>{inline_md(item)}</li>' for item in items
        )
        chapters.append('\n'.join([
            f'<section class="qm-release-chapter release-animate" id="{chapter_id}">',
            '<div class="qm-release-chapter-heading">',
            f'<span class="qm-release-chapter-number">{index:02d}</span>',
            f'<h3>{esc(heading)}</h3>',
            f'<span class="qm-release-chapter-count">{len(items)} {esc(labels["changes"])}</span>',
            '</div>',
            '<ul class="qm-release-change-list">',
            change_items,
            '</ul>',
            '</section>',
        ]))

    atlas = ''
    if sections:
        atlas = '\n'.join([
            '<div class="qm-release-atlas">',
            '<nav class="qm-release-nav" aria-label="' + esc(labels['chapters']) + '">',
            f'<p class="qm-release-nav-label">{esc(labels["chapters"])}</p>',
            '\n'.join(nav_items),
            '</nav>',
            '<main class="qm-release-chapters">',
            '<header class="qm-release-chapters-header release-animate">',
            f'<h2 class="qm-release-section-title">{esc(labels["all_changes"])}</h2>',
            f'<p class="qm-release-section-hint">{esc(labels["all_changes_hint"])}</p>',
            '</header>',
            '\n'.join(chapters),
            '</main>',
            '</div>',
        ])

    return "\n".join([
        rich_summary_style(),
        '<section class="qm-release-page" aria-label="' + esc(labels['eyebrow']) + '">',
        '<header class="qm-release-hero release-animate">',
        '<div>',
        f'<p class="qm-release-eyebrow">{esc(labels["eyebrow"])}</p>',
        f'<h1 class="qm-release-title">{esc(labels["title"].format(version=version))}</h1>',
        f'<p class="qm-release-subtitle">{esc(labels["subtitle"])}</p>',
        '<div class="qm-release-metrics">',
        f'<span><strong>{change_count}</strong>{esc(change_word)}</span>',
        f'<span><strong>{chapter_count}</strong>{esc(chapter_word)}</span>',
        '</div>',
        '</div>',
        '<div class="qm-release-version">',
        f'<span>{esc(labels["version"])}</span>',
        f'<strong>{esc(version)}</strong>',
        '</div>',
        '</header>',
        '<section class="qm-release-overview">',
        f'<h2 class="qm-release-section-title">{esc(labels["overview"])}</h2>',
        f'<p class="qm-release-section-hint">{esc(labels["overview_hint"])}</p>',
        '<ol class="qm-release-summary">',
        '\n'.join(summary_items),
        '</ol>',
        '</section>',
        atlas,
        release_edition_script(),
        '</section>',
    ])


def render_full(section: str) -> str:
    """Render the full ### sections (original behaviour)."""
    lines = section.split('\n')
    out: list[str] = []
    in_ul = False
    li_buf: list[str] = []

    def flush_li() -> None:
        if li_buf:
            text = ' '.join(s.strip() for s in li_buf)
            out.append(f'<li>{inline_md(text)}</li>')
            li_buf.clear()

    for line in lines:
        if line.startswith('### '):
            flush_li()
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<h3>{esc(line[4:].strip())}</h3>')
        elif line.startswith('- '):
            flush_li()
            if not in_ul:
                out.append('<ul>')
                in_ul = True
            li_buf.append(line[2:])
        elif line.startswith('  ') and li_buf:
            li_buf.append(line)
        elif not line.strip():
            flush_li()

    flush_li()
    if in_ul:
        out.append('</ul>')

    return '\n'.join(out)


def main() -> int:
    fmt, version, changelog, lang = parse_args()
    labels = LABELS[resolve_lang(lang, changelog)]

    section = extract_section(changelog, version)
    if section is None:
        print(labels['fallback'].format(changelog=changelog, version=version))
        return 0

    # Detect whether we have a Summary block.
    summary_lines, remainder = split_summary(section)
    has_summary = len(summary_lines) > 0

    if fmt == 'summary':
        if has_summary:
            print(render_summary(
                summary_lines, remainder, labels=labels, version=version))
        else:
            # Fallback: render full as summary (first 3 bullets only).
            print(render_full(section))
        return 0

    if fmt == 'full':
        print(render_full(section))
        return 0

    # fmt == 'both'
    if has_summary:
        summary_html = render_bullets(summary_lines)
        details_html = render_full(remainder)
        print(
            '<div class="release-summary">\n'
            f'{summary_html}\n'
            '</div>\n'
            f'<button class="details-toggle" '
            f'data-show="{esc(labels["show"])}" '
            f'data-hide="{esc(labels["hide"])}">'
            f'{esc(labels["show"])} '
            '<span class="arrow">&#x25BE;</span>'
            '</button>\n'
            '<div class="release-details">\n'
            f'{details_html}\n'
            '</div>'
        )
    else:
        # No summary — just render the full content without the toggle.
        print(render_full(section))

    return 0


if __name__ == '__main__':
    sys.exit(main())
