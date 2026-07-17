#!/usr/bin/env python3
"""Fail closed unless a privacy manifest matches QuotaMonitor's declaration."""

import os
import pathlib
import plistlib
import stat
import sys


DEFAULT_MANIFEST = pathlib.Path("Resources/PrivacyInfo.xcprivacy")

TOP_LEVEL_KEYS = {
    "NSPrivacyTracking",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyAccessedAPITypes",
}
COLLECTED_TYPE_KEYS = {
    "NSPrivacyCollectedDataType",
    "NSPrivacyCollectedDataTypeLinked",
    "NSPrivacyCollectedDataTypeTracking",
    "NSPrivacyCollectedDataTypePurposes",
}


class UnsafeManifestInput(Exception):
    pass


def load_regular_manifest(path: pathlib.Path):
    no_follow = getattr(os, "O_NOFOLLOW", None)
    non_block = getattr(os, "O_NONBLOCK", None)
    if (
        type(no_follow) is not int
        or no_follow == 0
        or type(non_block) is not int
        or non_block == 0
    ):
        raise UnsafeManifestInput

    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | no_follow | non_block)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise UnsafeManifestInput

        manifest_file = os.fdopen(descriptor, "rb")
        descriptor = None
        with manifest_file:
            return plistlib.load(manifest_file)
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _is_bool(value, expected: bool) -> bool:
    return type(value) is bool and value is expected


def is_expected_manifest(manifest) -> bool:
    if type(manifest) is not dict or set(manifest) != TOP_LEVEL_KEYS:
        return False
    if not _is_bool(manifest["NSPrivacyTracking"], False):
        return False

    accessed_apis = manifest["NSPrivacyAccessedAPITypes"]
    if type(accessed_apis) is not list or accessed_apis:
        return False

    collected_types = manifest["NSPrivacyCollectedDataTypes"]
    if type(collected_types) is not list or len(collected_types) != 1:
        return False
    collected = collected_types[0]
    if type(collected) is not dict or set(collected) != COLLECTED_TYPE_KEYS:
        return False

    data_type = collected["NSPrivacyCollectedDataType"]
    if (
        type(data_type) is not str
        or data_type != "NSPrivacyCollectedDataTypeProductInteraction"
    ):
        return False
    if not _is_bool(collected["NSPrivacyCollectedDataTypeLinked"], False):
        return False
    if not _is_bool(collected["NSPrivacyCollectedDataTypeTracking"], False):
        return False

    purposes = collected["NSPrivacyCollectedDataTypePurposes"]
    if type(purposes) is not list or len(purposes) != 1:
        return False
    purpose = purposes[0]
    return (
        type(purpose) is str
        and purpose == "NSPrivacyCollectedDataTypePurposeAnalytics"
    )


def main(arguments: list[str]) -> int:
    if len(arguments) > 1:
        print(
            "usage: verify-privacy-manifest.py [manifest]",
            file=sys.stderr,
        )
        return 2

    path = pathlib.Path(arguments[0]) if arguments else DEFAULT_MANIFEST
    try:
        manifest = load_regular_manifest(path)
    except (
        OSError,
        UnsafeManifestInput,
        plistlib.InvalidFileException,
        ValueError,
    ):
        print("error: privacy manifest is unreadable or malformed", file=sys.stderr)
        return 1

    if not is_expected_manifest(manifest):
        print("error: privacy manifest does not match the required schema", file=sys.stderr)
        return 1

    print("privacy manifest: valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
