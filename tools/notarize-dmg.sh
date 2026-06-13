#!/usr/bin/env bash
# Developer ID sign, notarize, and staple a release DMG.
#
# Usage:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
#   NOTARYTOOL_PROFILE=quotamonitor-notary \
#       ./tools/notarize-dmg.sh dist/QuotaMonitor-0.2.33.dmg

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=tools/developer-id-common.sh
. tools/developer-id-common.sh

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: DMG notarization requires macOS" >&2
    exit 1
fi

DMG_PATH="${1:-}"
NOTARYTOOL_TIMEOUT="${NOTARYTOOL_TIMEOUT:-30m}"

if [[ -z "${DMG_PATH}" ]]; then
    echo "usage: ./tools/notarize-dmg.sh path/to/QuotaMonitor-X.Y.Z.dmg" >&2
    exit 2
fi
if [[ ! -f "${DMG_PATH}" ]]; then
    echo "error: ${DMG_PATH} not found" >&2
    exit 1
fi

qm_resolve_developer_id_identity
qm_set_notary_args
IDENTITY="${QM_DEVELOPER_IDENTITY}"

echo "==> Signing ${DMG_PATH}"
codesign --force --timestamp --sign "${IDENTITY}" "${DMG_PATH}"

echo "==> Verifying DMG signature"
codesign --verify --verbose=2 "${DMG_PATH}"

echo "==> Submitting DMG to Apple notary service (timeout ${NOTARYTOOL_TIMEOUT})"
xcrun notarytool submit "${DMG_PATH}" "${QM_NOTARY_ARGS[@]}" \
    --wait \
    --timeout "${NOTARYTOOL_TIMEOUT}"

echo "==> Stapling notarization ticket onto ${DMG_PATH}"
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"

echo "==> Done. ${DMG_PATH} is Developer ID signed, notarized, and stapled."
