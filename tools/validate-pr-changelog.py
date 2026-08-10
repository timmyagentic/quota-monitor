#!/usr/bin/env python3
"""Require PRs to carry user-facing changelog entries.

Normal feature/fix PRs update ``## [Unreleased]`` in both changelog files.
Release PRs bump ``Resources/VERSION`` and move those entries into the
versioned section, so they validate that version instead. A late release-page
refresh may instead add both localized ``ReleaseNotes/<version>`` HTML files;
that explicit pair validates the already-selected current version without a
second version bump. Generated Appcast publication PRs remain exempt.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys


REQUIRED_CHANGELOGS = {"CHANGELOG.md", "CHANGELOG.zh-Hans.md"}
APPCAST_FILE = "appcast.xml"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate changelog coverage for a PR.")
    parser.add_argument("--repo", default=".", help="Repository path (default: current directory)")
    parser.add_argument("--base", default=None, help="Base git ref (default: origin/$GITHUB_BASE_REF or origin/main)")
    parser.add_argument("--head", default=None, help="Head git ref (default: $GITHUB_SHA or HEAD)")
    return parser.parse_args()


def default_base() -> str:
    base_ref = os.environ.get("GITHUB_BASE_REF")
    if base_ref:
        return f"origin/{base_ref}"
    return "origin/main"


def default_head() -> str:
    return os.environ.get("GITHUB_SHA") or "HEAD"


def run_git(repo: pathlib.Path, args: list[str]) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return result.stdout


def changed_files(repo: pathlib.Path, base: str, head: str) -> set[str]:
    output = run_git(repo, ["diff", "--name-only", f"{base}...{head}"])
    return {line.strip() for line in output.splitlines() if line.strip()}


def current_version(repo: pathlib.Path) -> str:
    version = (repo / "Resources" / "VERSION").read_text(encoding="utf-8").strip()
    if not version:
        print("Resources/VERSION is empty", file=sys.stderr)
        raise SystemExit(1)
    return version


def release_note_files(version: str) -> set[str]:
    return {
        f"ReleaseNotes/{version}.en.html",
        f"ReleaseNotes/{version}.zh-Hans.html",
    }


def is_appcast_publication(files: set[str]) -> bool:
    return APPCAST_FILE in files and all(
        path == APPCAST_FILE or path.startswith("ReleaseNotes/")
        for path in files
    )


def target_version(repo: pathlib.Path, files: set[str]) -> str:
    version = current_version(repo)
    if (
        "Resources/VERSION" in files
        or release_note_files(version).issubset(files)
    ):
        return version
    return "Unreleased"


def validate_release_notes(repo: pathlib.Path, version: str) -> None:
    validator = pathlib.Path(__file__).resolve().with_name("validate-release-notes.py")
    result = subprocess.run(
        [
            sys.executable,
            str(validator),
            version,
            str(repo / "CHANGELOG.md"),
            str(repo / "CHANGELOG.zh-Hans.md"),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)


def main() -> int:
    args = parse_args()
    repo = pathlib.Path(args.repo).resolve()
    base = args.base or default_base()
    head = args.head or default_head()

    files = changed_files(repo, base, head)
    if not files:
        print("No changed files detected; changelog check skipped")
        return 0

    if is_appcast_publication(files):
        print("appcast publication PR; changelog check skipped")
        return 0

    missing = sorted(REQUIRED_CHANGELOGS - files)
    if missing:
        print(
            "PR must update CHANGELOG.md and CHANGELOG.zh-Hans.md "
            f"(missing: {', '.join(missing)})",
            file=sys.stderr,
        )
        return 1

    version = target_version(repo, files)
    validate_release_notes(repo, version)
    print(f"PR changelog ok: {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
