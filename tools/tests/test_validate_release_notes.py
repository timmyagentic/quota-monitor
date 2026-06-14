#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = REPO_ROOT / "tools" / "validate-release-notes.py"


class ValidateReleaseNotesTests(unittest.TestCase):
    def run_validator(self, en_text: str, zh_text: str, version: str = "1.2.3"):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            en_path = tmp_path / "CHANGELOG.md"
            zh_path = tmp_path / "CHANGELOG.zh-Hans.md"
            en_path.write_text(textwrap.dedent(en_text).strip() + "\n", encoding="utf-8")
            zh_path.write_text(textwrap.dedent(zh_text).strip() + "\n", encoding="utf-8")

            return subprocess.run(
                [sys.executable, str(VALIDATOR), version, str(en_path), str(zh_path)],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_accepts_concise_bilingual_release_notes(self):
        result = self.run_validator(
            """
            # Changelog

            ## [1.2.3] - 2026-06-03

            #### Summary
            - Dashboard totals are easier to scan at a glance
            - Settings now opens the matching detail view directly

            ### Added
            - **Dashboard scan summary.** The dashboard now groups daily totals and provider status into one short row.
            """,
            """
            # 更新日志

            ## [1.2.3] - 2026-06-03

            #### Summary
            - 仪表盘总览现在更容易快速扫读
            - 设置现在会直接打开对应详情视图

            ### 新增
            - **仪表盘扫描摘要。** 仪表盘现在会把每日总量和供应商状态合并到一行中展示。
            """,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release notes ok", result.stdout)

    def test_rejects_missing_summary(self):
        result = self.run_validator(
            """
            # Changelog

            ## [1.2.3] - 2026-06-03

            ### Fixed
            - **Updater details.** Release notes now load reliably.
            """,
            """
            # 更新日志

            ## [1.2.3] - 2026-06-03

            #### Summary
            - 更新窗口现在可以稳定加载说明

            ### 修复
            - **更新说明。** 发布说明现在可以稳定加载。
            """,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CHANGELOG.md: 1.2.3 is missing #### Summary", result.stderr)

    def test_accepts_long_summary_list(self):
        result = self.run_validator(
            """
            # Changelog

            ## [1.2.3] - 2026-06-03

            #### Summary
            - One
            - Two
            - Three
            - Four
            - Five

            ### Changed
            - **Release notes.** The update copy is now shorter.
            """,
            """
            # 更新日志

            ## [1.2.3] - 2026-06-03

            #### Summary
            - 一
            - 二
            - 三
            - 四
            - 五

            ### 变更
            - **发布说明。** 更新文案现在更短。
            """,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release notes ok", result.stdout)

    def test_rejects_empty_summary(self):
        result = self.run_validator(
            """
            # Changelog

            ## [1.2.3] - 2026-06-03

            #### Summary

            ### Changed
            - **Release notes.** The update copy is now shorter.
            """,
            """
            # 更新日志

            ## [1.2.3] - 2026-06-03

            #### Summary
            - 更新说明现在更清晰

            ### 变更
            - **发布说明。** 更新文案现在更短。
            """,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Summary must contain at least one bullet", result.stderr)

    def test_rejects_internal_jargon_in_summary(self):
        result = self.run_validator(
            """
            # Changelog

            ## [1.2.3] - 2026-06-03

            #### Summary
            - AppKit window ownership and QA artifact replay are stricter

            ### Changed
            - **Window handling.** Windows now open more consistently.
            """,
            """
            # 更新日志

            ## [1.2.3] - 2026-06-03

            #### Summary
            - 窗口打开和切换更稳定

            ### 变更
            - **窗口处理。** 窗口现在打开得更稳定。
            """,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Summary bullet uses internal term 'AppKit'", result.stderr)
        self.assertIn("Summary bullet uses internal term 'QA'", result.stderr)
        self.assertIn("Summary bullet uses internal term 'artifact'", result.stderr)

    def test_rejects_wrapped_chinese_bullets(self):
        result = self.run_validator(
            """
            # Changelog

            ## [1.2.3] - 2026-06-03

            #### Summary
            - Release notes are clearer

            ### Changed
            - **Release notes.** The update copy is now shorter.
            """,
            """
            # 更新日志

            ## [1.2.3] - 2026-06-03

            #### Summary
            - 更新说明现在更清晰

            ### 变更
            - **发布说明。** 更新文案现在更短，
              并且不再把中文 bullet 硬换行。
            """,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Chinese bullets must stay on one physical line", result.stderr)


if __name__ == "__main__":
    unittest.main()
