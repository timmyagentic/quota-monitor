#!/usr/bin/env python3
"""Compute monotonically ordered Sparkle build numbers.

Each semantic version owns 10,000 build slots. Private Betas use 1...8,999;
the stable build uses 9,000, so the final stable always supersedes every Beta
for the same marketing version.
"""

from __future__ import annotations

import argparse
import re

VERSION_PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
STABLE_OFFSET = 9_000
MAX_BETA_SEQUENCE = STABLE_OFFSET - 1


def build_number(version: str, channel: str, beta_sequence: int | None = None) -> int:
    match = VERSION_PATTERN.fullmatch(version)
    if match is None:
        raise ValueError("version must be major.minor.patch")
    major, minor, patch = (int(part) for part in match.groups())
    if minor >= 1_000 or patch >= 1_000:
        raise ValueError("minor and patch must be below 1000")
    base = (major * 1_000_000 + minor * 1_000 + patch) * 10_000
    if channel == "stable":
        if beta_sequence is not None:
            raise ValueError("stable builds do not accept a beta sequence")
        return base + STABLE_OFFSET
    if channel != "private-beta":
        raise ValueError("channel must be stable or private-beta")
    if beta_sequence is None or not 1 <= beta_sequence <= MAX_BETA_SEQUENCE:
        raise ValueError(f"beta sequence must be 1...{MAX_BETA_SEQUENCE}")
    return base + beta_sequence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--channel", choices=("stable", "private-beta"), required=True)
    parser.add_argument("--beta-sequence", type=int)
    args = parser.parse_args()
    try:
        print(build_number(args.version, args.channel, args.beta_sequence))
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
