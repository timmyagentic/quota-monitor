#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONVERTER = REPO_ROOT / "tools" / "changelog-to-html.py"


class ChangelogToHTMLTests(unittest.TestCase):
    def run_converter(self, changelog: str, *args: str):
        with tempfile.TemporaryDirectory() as tmp:
            changelog_path = pathlib.Path(tmp) / "CHANGELOG.md"
            changelog_path.write_text(
                textwrap.dedent(changelog).strip() + "\n",
                encoding="utf-8",
            )

            return subprocess.run(
                [sys.executable, str(CONVERTER), *args, "1.2.3", str(changelog_path)],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_default_renders_rich_summary_page_without_details_toggle(self):
        result = self.run_converter(
            """
            # Changelog

            ## [1.2.3] - 2026-06-08

            #### Summary
            - Windows are easier to return to
            - Refresh is immediate when you click it

            ### Changed
            - **Window ownership.** Dashboard and Settings now share one window manager.
            """,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<style class="qm-release-style">', result.stdout)
        self.assertIn('<section class="qm-release-page"', result.stdout)
        self.assertIn("What's new in this update", result.stdout)
        self.assertIn("A quick look at the improvements included in this version.", result.stdout)
        self.assertIn('class="qm-release-highlight release-animate"', result.stdout)
        self.assertIn("Windows are easier to return to", result.stdout)
        self.assertIn("Refresh is immediate when you click it", result.stdout)
        self.assertNotIn("steadier windows", result.stdout)
        self.assertNotIn("quota refreshes", result.stdout)
        self.assertNotIn("qm-release-status", result.stdout)
        self.assertNotIn("qm-release-chip", result.stdout)
        self.assertNotIn("Verified before install", result.stdout)
        self.assertNotIn("details-toggle", result.stdout)
        self.assertNotIn("release-details", result.stdout)
        self.assertNotIn("Window ownership", result.stdout)

    def test_chinese_summary_uses_generic_hero_copy(self):
        result = self.run_converter(
            """
            # Changelog

            ## [1.2.3] - 2026-06-08

            #### Summary
            - 窗口打开和切换更稳定
            - 更新提示更清楚
            """,
            "--lang",
            "zh-Hans",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("这次更新带来了什么", result.stdout)
        self.assertIn("下面是这次版本里最值得留意的改进。", result.stdout)
        self.assertNotIn("窗口稳定性、更新提示和配额刷新", result.stdout)

    def test_cycles_tone_for_more_than_four_summary_cards(self):
        result = self.run_converter(
            """
            # Changelog

            ## [1.2.3] - 2026-06-08

            #### Summary
            - First improvement
            - Second improvement
            - Third improvement
            - Fourth improvement
            - Fifth improvement

            ### Changed
            - **Window ownership.** Dashboard and Settings share one window manager.
            """,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        for text in [
            "First improvement", "Second improvement", "Third improvement",
            "Fourth improvement", "Fifth improvement",
        ]:
            self.assertIn(text, result.stdout)
        # Tone palette cycles every four cards so the 5th still gets a defined --tone.
        self.assertIn(".qm-release-highlight:nth-child(4n+1)", result.stdout)
        self.assertIn(".qm-release-highlight:nth-child(4n)", result.stdout)


if __name__ == "__main__":
    unittest.main()
