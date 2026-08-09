#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "validate-pr-changelog.py"


BASE_CHANGELOG_EN = """
# Changelog

## [Unreleased]

#### Summary
- Baseline release notes are concise

### Changed
- **Baseline notes.** The baseline changelog is valid for tests.
"""

BASE_CHANGELOG_ZH = """
# 更新日志

## [Unreleased]

#### Summary
- 基线发布说明保持简洁

### 变更
- **基线说明。** 测试用基线更新日志是有效的。
"""


class ValidatePRChangelogTests(unittest.TestCase):
    def make_repo(self):
        tmp = tempfile.TemporaryDirectory()
        repo = pathlib.Path(tmp.name)
        subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
        (repo / "CHANGELOG.md").write_text(textwrap.dedent(BASE_CHANGELOG_EN).strip() + "\n", encoding="utf-8")
        (repo / "CHANGELOG.zh-Hans.md").write_text(textwrap.dedent(BASE_CHANGELOG_ZH).strip() + "\n", encoding="utf-8")
        (repo / "Resources").mkdir()
        (repo / "Resources" / "VERSION").write_text("1.2.2\n", encoding="utf-8")
        (repo / "README.md").write_text("Baseline\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-m", "baseline"], cwd=repo, check=True, capture_output=True)
        base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        return tmp, repo, base

    def run_checker(self, repo: pathlib.Path, base: str):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(repo), "--base", base, "--head", "HEAD"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_rejects_pr_without_changelog_updates(self):
        tmp, repo, base = self.make_repo()
        with tmp:
            (repo / "README.md").write_text("Changed\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "docs change"], cwd=repo, check=True, capture_output=True)

            result = self.run_checker(repo, base)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PR must update CHANGELOG.md and CHANGELOG.zh-Hans.md", result.stderr)

    def test_accepts_regular_pr_with_valid_unreleased_notes(self):
        tmp, repo, base = self.make_repo()
        with tmp:
            (repo / "README.md").write_text("Changed\n", encoding="utf-8")
            (repo / "CHANGELOG.md").write_text(
                textwrap.dedent(
                    """
                    # Changelog

                    ## [Unreleased]

                    #### Summary
                    - Dashboard totals are easier to scan

                    ### Changed
                    - **Dashboard totals.** The dashboard summary now groups related totals together.
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )
            (repo / "CHANGELOG.zh-Hans.md").write_text(
                textwrap.dedent(
                    """
                    # 更新日志

                    ## [Unreleased]

                    #### Summary
                    - 仪表盘总量现在更容易扫读

                    ### 变更
                    - **仪表盘总量。** 仪表盘摘要现在会把相关总量组合展示。
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "feature"], cwd=repo, check=True, capture_output=True)

            result = self.run_checker(repo, base)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PR changelog ok: Unreleased", result.stdout)

    def test_accepts_release_pr_with_valid_versioned_notes(self):
        tmp, repo, base = self.make_repo()
        with tmp:
            (repo / "Resources" / "VERSION").write_text("1.2.3\n", encoding="utf-8")
            (repo / "CHANGELOG.md").write_text(
                textwrap.dedent(
                    """
                    # Changelog

                    ## [Unreleased]

                    ## [1.2.3] - 2026-06-03

                    #### Summary
                    - Release notes are validated before publishing

                    ### Added
                    - **Release note validation.** Release builds now fail early when update notes are missing.
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )
            (repo / "CHANGELOG.zh-Hans.md").write_text(
                textwrap.dedent(
                    """
                    # 更新日志

                    ## [Unreleased]

                    ## [1.2.3] - 2026-06-03

                    #### Summary
                    - 发布说明会在发布前完成校验

                    ### 新增
                    - **发布说明校验。** 更新说明缺失时，发布构建会提前失败。
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "release"], cwd=repo, check=True, capture_output=True)

            result = self.run_checker(repo, base)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PR changelog ok: 1.2.3", result.stdout)

    def test_accepts_release_page_refresh_without_second_version_bump(self):
        tmp, repo, base = self.make_repo()
        with tmp:
            (repo / "README.md").write_text("Release page refresh\n", encoding="utf-8")
            (repo / "CHANGELOG.md").write_text(
                textwrap.dedent(
                    """
                    # Changelog

                    ## [Unreleased]

                    #### Summary

                    ## [1.2.2] - 2026-06-04

                    #### Summary
                    - The release page explains the most important changes

                    ### Added
                    - **Release page.** A replayable product tour now introduces this version.
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )
            (repo / "CHANGELOG.zh-Hans.md").write_text(
                textwrap.dedent(
                    """
                    # 更新日志

                    ## [Unreleased]

                    #### Summary

                    ## [1.2.2] - 2026-06-04

                    #### Summary
                    - 版本页面会介绍最重要的变化

                    ### 新增
                    - **版本页面。** 可重看的产品导览现在会介绍这个版本。
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )
            notes = repo / "ReleaseNotes"
            notes.mkdir()
            (notes / "1.2.2.en.html").write_text("<p>English</p>\n", encoding="utf-8")
            (notes / "1.2.2.zh-Hans.html").write_text("<p>中文</p>\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-m", "refresh release pages"],
                cwd=repo,
                check=True,
                capture_output=True,
            )

            result = self.run_checker(repo, base)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PR changelog ok: 1.2.2", result.stdout)

    def test_allows_appcast_only_pr(self):
        tmp, repo, base = self.make_repo()
        with tmp:
            (repo / "appcast.xml").write_text("<rss />\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "appcast"], cwd=repo, check=True, capture_output=True)

            result = self.run_checker(repo, base)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("appcast publication PR; changelog check skipped", result.stdout)

    def test_allows_generated_appcast_pr_with_release_note_pages(self):
        tmp, repo, base = self.make_repo()
        with tmp:
            (repo / "appcast.xml").write_text("<rss />\n", encoding="utf-8")
            notes = repo / "ReleaseNotes"
            notes.mkdir()
            (notes / "1.2.2.en.html").write_text("<p>English</p>\n", encoding="utf-8")
            (notes / "1.2.2.zh-Hans.html").write_text("<p>中文</p>\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-m", "publish appcast"],
                cwd=repo,
                check=True,
                capture_output=True,
            )

            result = self.run_checker(repo, base)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("appcast publication PR; changelog check skipped", result.stdout)


if __name__ == "__main__":
    unittest.main()
