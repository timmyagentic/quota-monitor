#!/usr/bin/env python3
"""Extract one version's section from a changelog and emit it as
inline HTML suitable for Sparkle's release-notes WebView (the
<description> CDATA block in an appcast item).

Usage:
  ./changelog-to-html.py [--format summary|full|both] <version> [CHANGELOG.md]

The second positional argument is the changelog file to read from; it
defaults to CHANGELOG.md. Pass CHANGELOG.zh-Hans.md to render the
Simplified-Chinese release notes — release-sparkle.sh calls this twice
(once per language) to emit the bilingual <description xml:lang="…">
nodes Sparkle selects between at parse time.

--format controls the output structure:
  summary  – only the ``#### Summary`` bullets (no detail sections).
  full     – the original behaviour (all ``###`` sections, no summary).
  both     – ``#### Summary`` items wrapped in
             ``<div class="release-summary">``, a toggle button, and
             the full sections wrapped in
             ``<div class="release-details">``.
             This is the default.

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
import argparse
import re
import sys


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


def parse_args() -> tuple[str, str, str]:
    """Return (format, version, changelog_path)."""
    ap = argparse.ArgumentParser(
        description='Convert a changelog section to Sparkle HTML.')
    ap.add_argument('--format', choices=['summary', 'full', 'both'],
                    default='both',
                    help='Output format (default: both)')
    ap.add_argument('version', help='Version string, e.g. 0.2.25')
    ap.add_argument('changelog', nargs='?', default='CHANGELOG.md',
                    help='Path to changelog file (default: CHANGELOG.md)')
    args = ap.parse_args()
    return args.format, args.version, args.changelog


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
    fmt, version, changelog = parse_args()

    section = extract_section(changelog, version)
    if section is None:
        fallback = f'See {changelog} for what\'s new in {version}.'
        print(fallback)
        return 0

    # Detect whether we have a Summary block.
    summary_lines, remainder = split_summary(section)
    has_summary = len(summary_lines) > 0

    if fmt == 'summary':
        if has_summary:
            print(render_bullets(summary_lines))
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
            f'data-show="{esc("Show full details")}" '
            f'data-hide="{esc("Hide details")}">'
            f'{esc("Show full details")} '
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
