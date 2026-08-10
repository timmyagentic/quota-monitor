#!/usr/bin/env python3
"""Hash the current Swift-test inputs without depending on Git staging state."""

from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import sys


TEST_INPUT_PATHS = (
    "Package.swift",
    "Package.resolved",
    "QuotaMonitor",
    "Resources",
    "Tests",
    "qa",
    "script",
    "scripts",
    "tools",
)


def add_field(digest, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def command_state(root: str, *command: str) -> bytes:
    result = subprocess.run(
        command,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return b"exit=" + str(result.returncode).encode() + b"\n" + result.stdout


def current_paths(root: str) -> list[bytes]:
    result = subprocess.run(
        (
            "git",
            "-C",
            root,
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            *TEST_INPUT_PATHS,
        ),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return sorted(set(path for path in result.stdout.split(b"\0") if path))


def add_path_state(digest: hashlib._Hash, root: bytes, relative_path: bytes) -> None:
    full_path = os.path.join(root, relative_path)
    try:
        metadata = os.lstat(full_path)
    except FileNotFoundError:
        # A tracked deletion and the same deletion after commit must hash alike.
        return

    add_field(digest, b"path")
    add_field(digest, relative_path)

    if stat.S_ISLNK(metadata.st_mode):
        add_field(digest, b"symlink")
        add_field(digest, os.readlink(full_path))
        return

    if stat.S_ISREG(metadata.st_mode):
        add_field(digest, b"file")
        add_field(digest, b"executable" if metadata.st_mode & 0o111 else b"regular")
        file_digest = hashlib.sha256()
        with open(full_path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                file_digest.update(chunk)
        add_field(digest, file_digest.digest())
        return

    if stat.S_ISDIR(metadata.st_mode):
        add_field(digest, b"directory")
        add_field(digest, command_state(os.fsdecode(full_path), "git", "rev-parse", "HEAD"))
        add_field(digest, command_state(os.fsdecode(full_path), "git", "status", "--porcelain=v1"))
        return

    add_field(digest, b"other")
    add_field(digest, str(stat.S_IFMT(metadata.st_mode)).encode())


def fingerprint(root: str) -> str:
    digest = hashlib.sha256()
    add_field(digest, b"quota-monitor-swift-test-inputs-v1")

    root_bytes = os.fsencode(os.path.realpath(root))
    for relative_path in current_paths(root):
        add_path_state(digest, root_bytes, relative_path)

    add_field(digest, b"python")
    add_field(digest, sys.version.encode())
    for command in (
        ("swift", "--version"),
        ("xcodebuild", "-version"),
        ("sw_vers",),
        ("uname", "-m"),
    ):
        add_field(digest, " ".join(command).encode())
        add_field(digest, command_state(root, *command))

    environment_keys = {
        "DEVELOPER_DIR",
        "HOME",
        "LANG",
        "LC_ALL",
        "SDKROOT",
        "SWIFT_EXEC",
        "SWIFTPM_BUILD_DIR",
        "SWIFTPM_MODULECACHE_OVERRIDE",
        "TZ",
    }
    environment_keys.update(
        key
        for key in os.environ
        if (key.startswith("QM_") and not key.startswith("QM_STATIC_"))
        or key.startswith("QUOTAMONITOR_")
    )
    for key in sorted(environment_keys):
        add_field(digest, key.encode())
        add_field(digest, os.environ.get(key, "").encode())

    return digest.hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: static_gate_fingerprint.py <repository-root>", file=sys.stderr)
        return 64
    try:
        print(fingerprint(sys.argv[1]))
    except (OSError, RuntimeError) as error:
        print(f"error: cannot fingerprint Swift test inputs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
