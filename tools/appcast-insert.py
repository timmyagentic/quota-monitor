#!/usr/bin/env python3
"""Splice a generated <item> block into appcast.xml, newest-first.

Used by .github/workflows/release.yml after CI signs the published DMG:
release-sparkle.sh writes dist/appcast-item-<VERSION>.xml, and this
script inserts it just above the first existing <item> (i.e. at the top
of the feed). Idempotent — if an <item> for the same sparkle:version is
already present, it does nothing and exits 0, so re-running a release
job can't create duplicate entries.

    tools/appcast-insert.py dist/appcast-item-0.2.28.xml appcast.xml

Exit codes:
    0  inserted, or already present (no-op)
    1  malformed input (missing <sparkle:version>, no <item> anchor)
"""
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <item-file> <appcast.xml>", file=sys.stderr)
        return 1

    item_path = pathlib.Path(sys.argv[1])
    appcast_path = pathlib.Path(sys.argv[2])

    item = item_path.read_text().rstrip("\n") + "\n"
    feed = appcast_path.read_text()

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
    if not anchor_match:
        print("error: no <item> element found in appcast.xml", file=sys.stderr)
        return 1

    line_start = anchor_match.start()
    spliced = feed[:line_start] + item + feed[line_start:]
    appcast_path.write_text(spliced)
    print(f"inserted {version} above existing items")
    return 0


if __name__ == "__main__":
    sys.exit(main())
