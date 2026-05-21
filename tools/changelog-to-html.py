#!/usr/bin/env python3
"""Extract one version's section from CHANGELOG.md and emit it as
inline HTML suitable for Sparkle's release-notes WebView (the
<description> CDATA block in an appcast item).

Usage: ./changelog-to-html.py 0.2.21

Lives as a standalone file rather than inline in release-sparkle.sh
because bash's $( ... <<'EOF' ... EOF ) command substitution still
parses backticks in the heredoc body as legacy command substitution
even with a quoted delimiter — and the regex for `code` spans needs
literal backticks. Putting it in a .py file sidesteps the issue.
"""
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


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: changelog-to-html.py <version>", file=sys.stderr)
        return 2
    version = sys.argv[1]
    try:
        with open('CHANGELOG.md', encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        print(f"See CHANGELOG.md for what's new in {version}.")
        return 0

    m = re.search(
        r'^##\s+\[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^##\s+\[|\Z)',
        text, re.S | re.M)
    if not m:
        print(f"See CHANGELOG.md for what's new in {version}.")
        return 0

    section = m.group(1).strip()
    lines = section.split('\n')
    out: list[str] = []
    in_ul = False
    li_buf: list[str] = []

    def flush_li() -> None:
        if li_buf:
            # CHANGELOG bullets are hard-wrapped at ~70 cols but should
            # render as one flowing paragraph in the dialog.
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

    print('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
