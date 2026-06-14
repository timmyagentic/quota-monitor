#!/usr/bin/env python3
"""Validate changelog sections used as user-facing release notes.

The Sparkle update window renders only the short ``#### Summary`` as a rich
card layout by default. Full ``###`` sections remain for GitHub Release notes.
This checker keeps the authoring format predictable before a release ships.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


ALLOWED_HEADINGS = {
    "en": {
        "Added",
        "Changed",
        "Fixed",
        "Removed",
        "Known limitation",
        "Known limitations",
    },
    "zh-Hans": {
        "新增",
        "变更",
        "修复",
        "移除",
        "已知限制",
    },
}

SUMMARY_INTERNAL_TERMS = [
    ("AppKit", re.compile(r"\bAppKit\b", re.I)),
    ("SwiftUI", re.compile(r"\bSwiftUI\b", re.I)),
    ("WebKit", re.compile(r"\bWebKit\b", re.I)),
    ("Sparkle", re.compile(r"\bSparkle\b", re.I)),
    ("appcast", re.compile(r"\bappcast\b", re.I)),
    ("PR", re.compile(r"\bPR\b", re.I)),
    ("QA", re.compile(r"\bQA\b", re.I)),
    ("CI", re.compile(r"\bCI\b", re.I)),
    ("Computer Use", re.compile(r"\bComputer Use\b", re.I)),
    ("artifact", re.compile(r"\bartifacts?\b", re.I)),
    ("harness", re.compile(r"\bharness\b", re.I)),
    ("workflow", re.compile(r"\bworkflow\b", re.I)),
    ("Developer ID", re.compile(r"\bDeveloper ID\b", re.I)),
    ("notarization", re.compile(r"\bnotari[sz](?:e|ation|ed|ing)\b", re.I)),
    ("codesign", re.compile(r"\bcodesign(?:ing)?\b", re.I)),
    ("构建", re.compile(r"构建")),
    ("工作流", re.compile(r"工作流")),
    ("制品", re.compile(r"制品")),
    ("公证", re.compile(r"公证")),
    ("签名", re.compile(r"签名")),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate bilingual changelog sections for release notes."
    )
    parser.add_argument("version", help="Version to validate, e.g. 0.2.31")
    parser.add_argument("english", nargs="?", default="CHANGELOG.md")
    parser.add_argument("chinese", nargs="?", default="CHANGELOG.zh-Hans.md")
    return parser.parse_args()


def read_text(path: pathlib.Path, issues: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        issues.append(f"{path.name}: file does not exist")
        return ""


def extract_section(text: str, version: str) -> str | None:
    pattern = (
        r"^##\s+\[" + re.escape(version) + r"\][^\n]*\n"
        r"(.*?)(?=^##\s+\[|\Z)"
    )
    match = re.search(pattern, text, re.S | re.M)
    if not match:
        return None
    return match.group(1).strip()


def summary_block(section: str) -> tuple[str | None, str]:
    match = re.search(r"^####\s+Summary\s*\n(.*?)(?=^###|\Z)", section, re.S | re.M)
    if not match:
        return None, section

    remainder_match = re.search(r"^###\s+", section[match.end():], re.M)
    if not remainder_match:
        return match.group(1).strip(), ""

    remainder_start = match.end() + remainder_match.start()
    return match.group(1).strip(), section[remainder_start:].strip()


def collect_bullets(
    text: str,
    *,
    file_name: str,
    lang: str,
    issues: list[str],
    context: str,
) -> list[str]:
    bullets: list[str] = []
    current = False

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            current = False
            continue

        if line.startswith("- "):
            bullets.append(line[2:].strip())
            current = True
            continue

        if line.startswith("  ") and current:
            if lang == "zh-Hans":
                issues.append(f"{file_name}: Chinese bullets must stay on one physical line")
            current = True
            continue

        issues.append(f"{file_name}: {context} only supports '- ' bullet lines")
        current = False

    return bullets


def validate_summary(
    block: str | None,
    *,
    file_name: str,
    version: str,
    lang: str,
    issues: list[str],
) -> None:
    if block is None:
        issues.append(f"{file_name}: {version} is missing #### Summary")
        return

    bullets = collect_bullets(
        block,
        file_name=file_name,
        lang=lang,
        issues=issues,
        context="#### Summary",
    )
    if not bullets:
        issues.append(f"{file_name}: Summary must contain at least one bullet")

    for bullet in bullets:
        if bullet.startswith("**"):
            issues.append(f"{file_name}: Summary bullets should be plain, not detailed bold entries")
        for term, pattern in SUMMARY_INTERNAL_TERMS:
            if pattern.search(bullet):
                issues.append(
                    f"{file_name}: Summary bullet uses internal term '{term}'; "
                    "write update-window copy for non-technical users"
                )


def validate_details(
    remainder: str,
    *,
    file_name: str,
    lang: str,
    issues: list[str],
) -> None:
    if not remainder.strip():
        issues.append(f"{file_name}: release notes need at least one ### detail section")
        return

    allowed = ALLOWED_HEADINGS[lang]
    current_heading: str | None = None
    detail_bullets = 0
    in_bullet = False

    for raw_line in remainder.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            in_bullet = False
            continue

        if line.startswith("### "):
            heading = line[4:].strip()
            if heading not in allowed:
                choices = ", ".join(sorted(allowed))
                issues.append(f"{file_name}: unsupported heading '{heading}' (use one of: {choices})")
            current_heading = heading
            in_bullet = False
            continue

        if line.startswith("- "):
            if current_heading is None:
                issues.append(f"{file_name}: detail bullet appears before a ### heading")
            if not re.match(r"- \*\*[^*]+?\*\*", line):
                issues.append(f"{file_name}: detail bullets must start with a bold title")
            detail_bullets += 1
            in_bullet = True
            continue

        if line.startswith("  ") and in_bullet:
            if lang == "zh-Hans":
                issues.append(f"{file_name}: Chinese bullets must stay on one physical line")
            continue

        issues.append(f"{file_name}: detail sections only support headings and '- ' bullets")
        in_bullet = False

    if detail_bullets == 0:
        issues.append(f"{file_name}: release notes need at least one detail bullet")


def validate_file(path: pathlib.Path, version: str, lang: str, issues: list[str]) -> None:
    text = read_text(path, issues)
    if not text:
        return

    section = extract_section(text, version)
    if section is None:
        issues.append(f"{path.name}: missing ## [{version}] section")
        return

    summary, remainder = summary_block(section)
    validate_summary(summary, file_name=path.name, version=version, lang=lang, issues=issues)
    validate_details(remainder, file_name=path.name, lang=lang, issues=issues)


def main() -> int:
    args = parse_args()
    issues: list[str] = []

    validate_file(pathlib.Path(args.english), args.version, "en", issues)
    validate_file(pathlib.Path(args.chinese), args.version, "zh-Hans", issues)

    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        return 1

    print(f"release notes ok: {args.version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
