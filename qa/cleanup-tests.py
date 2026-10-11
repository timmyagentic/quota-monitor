#!/usr/bin/env python3
"""Remove only journaled Swift-test resources after their owner has exited."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

PREFIX = "quotamonitor-tests-"


def is_test_suite(suite):
    if not isinstance(suite, str) or len(suite) <= 36 or "/" in suite or "\\" in suite:
        return False
    try:
        return str(uuid.UUID(suite[-36:])).lower() == suite[-36:].lower()
    except ValueError:
        return False


def cleanup(root: Path, wait: bool = False) -> bool:
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        return False
    if not root.name.startswith(PREFIX):
        return False
    try:
        uuid.UUID(root.name.removeprefix(PREFIX))
    except ValueError:
        return False
    journal = root / "preferences.json"
    lock = root / "lock"
    if journal.is_symlink() or lock.is_symlink():
        return False
    try:
        with lock.open("r+") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
            except BlockingIOError:
                return False
            # The watcher may have completed while we were acquiring the lock.
            if not root.exists():
                return True
            suites = json.loads(journal.read_text())
            if not isinstance(suites, list) or not all(is_test_suite(s) for s in suites):
                return False
            preferences = Path.home() / "Library/Preferences"
            for suite in suites:
                subprocess.run(["/usr/bin/defaults", "delete", suite], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                # This runs AFTER the test process has fully exited, so its CF
                # finalizers cannot rewrite the empty plist after we unlink it.
                (preferences / f"{suite}.plist").unlink(missing_ok=True)
            shutil.rmtree(root)
            return True
    except FileNotFoundError:
        return not root.exists()
    except (ValueError, TypeError):
        # A malformed/foreign journal is not deletion authority.
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--root", type=Path)
    target.add_argument("--parent", type=Path)
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--wait", action="store_true")
    args = parser.parse_args()
    if args.watch:
        if args.root is None:
            parser.error("--watch requires --root")
        sys.stdin.buffer.read()  # Pipe EOF, followed by the owner's lifetime lock.
    roots = [args.root] if args.root else list(args.parent.glob(f"{PREFIX}*"))
    try:
        for root in roots:
            cleanup(root, wait=args.wait or args.watch)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"test cleanup failed; journal retained: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
