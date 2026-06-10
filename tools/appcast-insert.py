#!/usr/bin/env python3
"""Splice a generated <item> block into appcast.xml, newest-first.

Used by .github/workflows/release.yml after CI signs the published DMG:
release-sparkle.sh writes dist/appcast-item-<VERSION>.xml, and this
script inserts it just above the first existing <item> (i.e. at the top
of the feed). Idempotent — if an <item> for the same sparkle:version is
already present, it does nothing and exits 0, so re-running a release
job can't create duplicate entries.

If the feed has no <item> yet — or the target file doesn't exist at all
(a newly branded variant whose repo has never hosted an appcast) — the
item is inserted before </channel> (synthesizing a minimal channel when
the file is absent), so the first release still produces a valid feed.

    tools/appcast-insert.py dist/appcast-item-0.2.28.xml appcast.xml

Exit codes:
    0  inserted, or already present (no-op)
    1  malformed input (missing <sparkle:version>, or neither an
       <item> nor a </channel> anchor to insert against)
"""
import pathlib
import re
import sys

# Minimal valid Sparkle feed used when the target appcast.xml doesn't exist
# yet (a newly branded repo's first release). Mirrors the committed
# appcast.xml header; the indented </channel> gives the insert path below a
# line-anchored anchor so the first <item> lands inside the channel.
EMPTY_CHANNEL_FEED = (
    '<?xml version="1.0" standalone="yes"?>\n'
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"\n'
    '     xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
    '     version="2.0">\n'
    "    <channel>\n"
    "        <title>Auto-update feed</title>\n"
    "    </channel>\n"
    "</rss>\n"
)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <item-file> <appcast.xml>", file=sys.stderr)
        return 1

    item_path = pathlib.Path(sys.argv[1])
    appcast_path = pathlib.Path(sys.argv[2])

    item = item_path.read_text().rstrip("\n") + "\n"
    # A brand-new branded repo may not host an appcast.xml yet. Treat a missing
    # file as an empty channel so the first release still lands in a well-formed
    # feed (via the </channel> fallback below), instead of dying with a raw
    # FileNotFoundError traceback.
    feed = appcast_path.read_text() if appcast_path.exists() else EMPTY_CHANNEL_FEED

    m = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", item)
    if not m:
        print("error: item block has no <sparkle:version>", file=sys.stderr)
        return 1
    version = m.group(1).strip()

    if f"<sparkle:version>{version}</sparkle:version>" in feed:
        print(f"appcast already contains {version}; nothing to do")
        return 0

    # Anchor on the first <item> that begins its own line (whitespace
    # only before it). The channel's lead-in comment contains the words
    # "Append a new <item>", and a plain substring search would splice
    # the new entry *inside* that comment — silently commenting it out.
    # A line-anchored match skips prose occurrences.
    anchor_match = re.search(r"^[ \t]*<item>", feed, re.MULTILINE)
    if anchor_match:
        line_start = anchor_match.start()
        spliced = feed[:line_start] + item + feed[line_start:]
        appcast_path.write_text(spliced)
        print(f"inserted {version} above existing items")
        return 0

    # Empty channel (no <item> yet) — e.g. a freshly-seeded appcast for a
    # newly-branded variant's first release. Fall back to inserting just
    # before the channel's closing tag so the first item still lands inside
    # <channel>…</channel>.
    close_match = re.search(r"^[ \t]*</channel>", feed, re.MULTILINE)
    if not close_match:
        print("error: appcast.xml has no <item> and no </channel> anchor", file=sys.stderr)
        return 1

    line_start = close_match.start()
    spliced = feed[:line_start] + item + feed[line_start:]
    appcast_path.write_text(spliced)
    print(f"inserted {version} into empty channel")
    return 0


if __name__ == "__main__":
    sys.exit(main())
