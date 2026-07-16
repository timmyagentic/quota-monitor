#!/usr/bin/env python3
"""Fail closed unless a privacy manifest matches QuotaMonitor's declaration."""

import pathlib
import plistlib
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
        with path.open("rb") as manifest_file:
            manifest = plistlib.load(manifest_file)
    except FileNotFoundError:
        print("error: privacy manifest is missing", file=sys.stderr)
        return 1
    except (OSError, plistlib.InvalidFileException, ValueError):
        print("error: privacy manifest is unreadable or malformed", file=sys.stderr)
        return 1

    if not is_expected_manifest(manifest):
        print("error: privacy manifest does not match the required schema", file=sys.stderr)
        return 1

    print("privacy manifest: valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
