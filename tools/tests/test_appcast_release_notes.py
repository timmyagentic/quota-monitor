#!/usr/bin/env python3
"""Guardrails for the slim, link-based appcast.

The feed used to inline full HTML+CSS release notes into every <item>,
which bloated appcast.xml to ~600 KB. raw.githubusercontent.com rate-limits
a file that large on the frequent update poll (HTTP 429), which Sparkle
surfaces as "获取升级信息时出现错误 / An error occurred in retrieving update
information". Notes are now linked via sparkle:releaseNotesLink and
downloaded lazily. These tests keep it that way.
"""
import pathlib
import re
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
APPCAST = REPO_ROOT / "appcast.xml"
NOTES_PREFIX = "https://raw.githubusercontent.com/timmyagentic/quota-monitor/main/"
LINK_RE = re.compile(
    r"<sparkle:releaseNotesLink[^>]*>([^<]+)</sparkle:releaseNotesLink>"
)


class AppcastReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.appcast = APPCAST.read_text(encoding="utf-8")

    def test_appcast_does_not_inline_release_notes(self):
        # Inline <![CDATA[…]]> notes are exactly what bloated the feed and got
        # it 429-rate-limited. Linking keeps the polled file tiny.
        self.assertNotIn(
            "<![CDATA[",
            self.appcast,
            "appcast.xml must not inline release notes; use sparkle:releaseNotesLink",
        )

    def test_appcast_stays_small(self):
        size = len(self.appcast.encode("utf-8"))
        self.assertLess(
            size,
            100_000,
            f"appcast.xml is {size} bytes; keep it small so raw.githubusercontent "
            "does not rate-limit (429) the update feed",
        )

    def test_every_release_notes_link_resolves_to_a_committed_file(self):
        links = LINK_RE.findall(self.appcast)
        self.assertTrue(links, "expected sparkle:releaseNotesLink entries in appcast.xml")
        for url in links:
            with self.subTest(url=url):
                self.assertTrue(
                    url.startswith(NOTES_PREFIX + "ReleaseNotes/"),
                    f"notes link must be hosted under {NOTES_PREFIX}ReleaseNotes/: {url}",
                )
                rel = url[len(NOTES_PREFIX):]
                self.assertTrue(
                    (REPO_ROOT / rel).is_file(),
                    f"linked release notes file is not committed: {rel}",
                )

    def test_multi_language_links_carry_explicit_xml_lang(self):
        # Sparkle errors out (and defaults to en) if multiple same-named nodes
        # exist and any is missing xml:lang.
        for item in re.findall(r"<item>.*?</item>", self.appcast, re.DOTALL):
            attrs = re.findall(r"<sparkle:releaseNotesLink([^>]*)>", item)
            if len(attrs) > 1:
                for attr in attrs:
                    self.assertIn(
                        "xml:lang",
                        attr,
                        "every releaseNotesLink in a multi-language item needs xml:lang",
                    )

    def test_release_sparkle_generates_links_not_inline(self):
        script = (REPO_ROOT / "tools" / "release-sparkle.sh").read_text(encoding="utf-8")
        self.assertIn("sparkle:releaseNotesLink", script)
        self.assertNotIn('<description xml:lang="en"><![CDATA[', script)


if __name__ == "__main__":
    unittest.main()
