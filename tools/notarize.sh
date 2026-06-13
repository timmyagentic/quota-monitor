#!/usr/bin/env bash
# Developer ID sign, notarize, and staple QuotaMonitor.app.
#
# Usage:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
#   NOTARYTOOL_PROFILE=quotamonitor-notary \
#       ./tools/notarize.sh
#
# CI can use APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD instead
# of a stored notarytool profile.

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=tools/developer-id-common.sh
. tools/developer-id-common.sh

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: notarization requires macOS" >&2
    exit 1
fi

APP_BUNDLE="${APP_BUNDLE:-.build/QuotaMonitor.app}"
ENTITLEMENTS="${ENTITLEMENTS:-Resources/QuotaMonitor.entitlements}"
NOTARYTOOL_TIMEOUT="${NOTARYTOOL_TIMEOUT:-30m}"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} missing; run CONFIG=release ./build.sh first" >&2
    exit 1
fi
if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "error: ${ENTITLEMENTS} missing" >&2
    exit 1
fi

qm_resolve_developer_id_identity
qm_set_notary_args
IDENTITY="${QM_DEVELOPER_IDENTITY}"

sign_code() {
    local path="$1"
    shift
    echo "==> codesign ${path}"
    codesign --force --options runtime --timestamp \
        --sign "${IDENTITY}" \
        "$@" \
        "${path}"
}

SPARKLE_FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE_FRAMEWORK}" ]]; then
    while IFS= read -r nested_app; do
        sign_code "${nested_app}"
    done < <(find "${SPARKLE_FRAMEWORK}" -type d -name '*.app' -prune -print | sort)

    while IFS= read -r xpc; do
        sign_code "${xpc}"
    done < <(find "${SPARKLE_FRAMEWORK}" -type d -name '*.xpc' -prune -print | sort)

    if [[ -f "${SPARKLE_FRAMEWORK}/Versions/B/Autoupdate" ]]; then
        sign_code "${SPARKLE_FRAMEWORK}/Versions/B/Autoupdate"
    fi

    sign_code "${SPARKLE_FRAMEWORK}"
else
    echo "warning: ${SPARKLE_FRAMEWORK} missing; Sparkle updates may not run" >&2
fi

echo "==> codesign ${APP_BUNDLE}"
codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${IDENTITY}" \
    "${APP_BUNDLE}"

echo "==> Verifying Developer ID signature"
codesign --verify --strict --deep --verbose=2 "${APP_BUNDLE}"
codesign -dvv --entitlements :- "${APP_BUNDLE}" >/dev/null

ZIP_PATH="${APP_BUNDLE%.app}-notarize.zip"
echo "==> Packaging ${ZIP_PATH}"
rm -f "${ZIP_PATH}"
/usr/bin/ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo "==> Submitting app to Apple notary service (timeout ${NOTARYTOOL_TIMEOUT})"
xcrun notarytool submit "${ZIP_PATH}" "${QM_NOTARY_ARGS[@]}" \
    --wait \
    --timeout "${NOTARYTOOL_TIMEOUT}"

echo "==> Stapling notarization ticket onto ${APP_BUNDLE}"
xcrun stapler staple "${APP_BUNDLE}"
xcrun stapler validate "${APP_BUNDLE}"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose=2 "${APP_BUNDLE}"

rm -f "${ZIP_PATH}"
echo "==> Done. ${APP_BUNDLE} is Developer ID signed, notarized, and stapled."
