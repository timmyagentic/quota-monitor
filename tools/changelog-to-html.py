#!/usr/bin/env python3
"""Extract one version's section from a changelog and emit it as
inline HTML suitable for Sparkle's release-notes WebView (the
<description> CDATA block in an appcast item).

Usage:
  ./changelog-to-html.py [--format summary|full|both] [--lang en|zh-Hans]
                         <version> [CHANGELOG.md]

The second positional argument is the changelog file to read from; it
defaults to CHANGELOG.md. Pass CHANGELOG.zh-Hans.md to render the
Simplified-Chinese release notes — release-sparkle.sh calls this twice
(once per language) to emit the bilingual <description xml:lang="…">
nodes Sparkle selects between at parse time.

The few user-visible labels (the ``both`` details toggle and the
missing-section fallback line) are localized via ``--lang``. When omitted,
the language is inferred from the changelog filename (e.g.
CHANGELOG.zh-Hans.md → zh-Hans), so the Chinese notes don't ship an English
"Show full details" toggle.

--format controls the output structure:
  summary  – a rich, self-styled update page built from the ``#### Summary``
             bullets. This is the default for the update window.
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
        'title': "What's new in this update",
        'subtitle': 'A quick look at the improvements included in this version.',
        'fallback': "See {changelog} for what's new in {version}.",
    },
    'zh-Hans': {
        # Match L10n.updateShowDetails / updateHideDetails so the appcast
        # toggle reads the same as the in-app one.
        'show': '查看完整变更',
        'hide': '收起详情',
        'eyebrow': '更新亮点',
        'title': '这次更新带来了什么',
        'subtitle': '下面是这次版本里最值得留意的改进。',
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
  --release-border: color-mix(in srgb, var(--release-accent), transparent 78%);
  --release-panel: color-mix(in srgb, Canvas, var(--release-accent) 5%);
  --release-panel-strong: color-mix(in srgb, Canvas, white 22%);
  --release-green: #2fbf71;
  --release-amber: #d39b20;
  --release-coral: #e26d5a;
  position: relative;
  overflow: hidden;
  color: var(--release-ink);
  padding: 2px;
}
.qm-release-page::before {
  content: "";
  position: absolute;
  inset: 0 0 auto 0;
  height: 84px;
  pointer-events: none;
  background:
    linear-gradient(90deg,
      color-mix(in srgb, var(--release-accent), transparent 78%),
      color-mix(in srgb, var(--release-green), transparent 82%),
      transparent);
  opacity: 0.7;
  transform: translateY(-52px) skewY(-8deg);
}
.qm-release-hero,
.qm-release-highlight {
  position: relative;
  border: 1px solid var(--release-border);
  border-radius: 8px;
  background: color-mix(in srgb, var(--release-panel), transparent 8%);
  box-shadow: 0 12px 28px rgba(0, 0, 0, 0.08);
  overflow: hidden;
}
.qm-release-hero {
  padding: 10px 12px 9px;
  margin-bottom: 8px;
  background:
    linear-gradient(135deg,
      color-mix(in srgb, var(--release-accent), transparent 82%),
      color-mix(in srgb, var(--release-green), transparent 88%) 46%,
      color-mix(in srgb, var(--release-amber), transparent 90%)),
    var(--release-panel-strong);
}
.qm-release-hero::after {
  content: "";
  position: absolute;
  inset: 0;
  background: linear-gradient(110deg, transparent 0 36%,
    rgba(255, 255, 255, 0.32) 48%,
    transparent 61% 100%);
  transform: translateX(-120%);
  animation: qm-release-sheen 3.8s ease-in-out infinite;
}
.qm-release-hero-content {
  position: relative;
  z-index: 1;
}
.qm-release-eyebrow {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  margin: 0 0 5px;
  color: var(--release-accent);
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
}
.qm-release-eyebrow::before {
  content: "";
  width: 18px;
  height: 3px;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--release-accent), var(--release-green));
}
.qm-release-title {
  margin: 0;
  font-size: 17px;
  line-height: 1.15;
  letter-spacing: 0;
}
.qm-release-subtitle {
  max-width: 34em;
  margin: 5px 0 0;
  color: var(--release-muted);
  font-size: 11.5px;
  line-height: 1.4;
}
.qm-release-rhythm {
  display: grid;
  grid-template-columns: 1.4fr 0.8fr 1.1fr 0.55fr;
  gap: 4px;
  margin-top: 8px;
  max-width: 210px;
}
.qm-release-rhythm span {
  height: 3px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--release-accent), transparent 25%);
  animation: qm-release-pulse 1.8s ease-in-out infinite;
  animation-delay: calc(var(--i) * 120ms);
}
.qm-release-rhythm span:nth-child(2) { background: var(--release-green); }
.qm-release-rhythm span:nth-child(3) { background: var(--release-amber); }
.qm-release-rhythm span:nth-child(4) { background: var(--release-coral); }
.qm-release-highlights {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 7px;
}
.qm-release-highlight {
  min-height: 70px;
  padding: 8px 9px;
}
.qm-release-highlight::before {
  content: "";
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  height: 3px;
  background: linear-gradient(90deg, var(--tone), transparent);
}
/* Tone palette cycles every four cards so Summary lists longer than four
   still get a defined --tone after the upper bullet cap was removed. */
.qm-release-highlight:nth-child(4n+1) { --tone: var(--release-accent); }
.qm-release-highlight:nth-child(4n+2) { --tone: var(--release-green); }
.qm-release-highlight:nth-child(4n+3) { --tone: var(--release-amber); }
.qm-release-highlight:nth-child(4n) { --tone: var(--release-coral); }
.qm-release-number {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  margin-bottom: 5px;
  border-radius: 7px;
  color: white;
  background: var(--tone);
  font-size: 10.5px;
  font-weight: 700;
}
.qm-release-highlight p {
  margin: 0;
  color: var(--release-ink);
  font-size: 11.5px;
  line-height: 1.38;
}
.release-animate {
  opacity: 0;
  transform: translateY(10px);
  animation: qm-release-enter 520ms cubic-bezier(.2, .8, .2, 1) forwards;
  animation-delay: calc(var(--i) * 80ms);
}
@keyframes qm-release-enter {
  to { opacity: 1; transform: translateY(0); }
}
@keyframes qm-release-sheen {
  0%, 55% { transform: translateX(-120%); }
  100% { transform: translateX(120%); }
}
@keyframes qm-release-pulse {
  0%, 100% { transform: scaleX(0.72); opacity: 0.55; }
  45% { transform: scaleX(1); opacity: 1; }
}
@media (prefers-color-scheme: dark) {
  .qm-release-page {
    --release-panel: rgba(34, 34, 38, 0.74);
    --release-panel-strong: rgba(45, 45, 51, 0.86);
  }
  .qm-release-hero,
  .qm-release-highlight {
    box-shadow: 0 12px 30px rgba(0, 0, 0, 0.22);
  }
}
@media (prefers-reduced-motion: reduce) {
  .qm-release-hero::after,
  .qm-release-rhythm span,
  .release-animate {
    animation: none;
    opacity: 1;
    transform: none;
  }
}
</style>
""".strip()


def render_summary(lines: list[str], *, labels: dict[str, str], version: str) -> str:
    cards = []
    for idx, line in enumerate(lines, start=1):
        cards.append(
            f'<article class="qm-release-highlight release-animate" '
            f'style="--i:{idx}">\n'
            f'<span class="qm-release-number">{idx}</span>\n'
            f'<p>{inline_md(line.strip())}</p>\n'
            f'</article>'
        )

    if not cards:
        return ""

    return "\n".join([
        rich_summary_style(),
        '<section class="qm-release-page" aria-label="Release highlights">',
        '<div class="qm-release-hero release-animate" style="--i:0">',
        '<div class="qm-release-hero-content">',
        f'<p class="qm-release-eyebrow">{esc(labels["eyebrow"])}</p>',
        f'<h2 class="qm-release-title">{esc(labels["title"])}</h2>',
        f'<p class="qm-release-subtitle">{esc(labels["subtitle"])}</p>',
        '<div class="qm-release-rhythm" aria-hidden="true">',
        '<span style="--i:0"></span><span style="--i:1"></span>'
        '<span style="--i:2"></span><span style="--i:3"></span>',
        '</div>',
        '</div>',
        '</div>',
        '<div class="qm-release-highlights">',
        "\n".join(cards),
        '</div>',
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
            print(render_summary(summary_lines, labels=labels, version=version))
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
