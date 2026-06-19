#!/usr/bin/env bash
# One-command release pipeline for QuotaMonitor distribution.
#
# Steps: pre-flight -> tests -> release build -> optional Developer ID
#        notarization -> DMG -> optional DMG notarization -> sha256
#        -> mount-and-verify self-check -> next-step checklist.
#
# Usage:
#   ./tools/release.sh                       # auto: Developer ID if configured, else local/ad-hoc
#   QM_RELEASE_SIGNING=developer-id ./tools/release.sh
#   QM_RELEASE_SIGNING=adhoc ./tools/release.sh
#   ./tools/release.sh --force               # overwrite an existing dist/<...>.dmg
#
# Version is read from Resources/VERSION (single source of truth).

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=tools/developer-id-common.sh
. tools/developer-id-common.sh

# Prefer the same user-installed Swiftly toolchain that build.sh uses. On some
# macOS CLT installs, the system SwiftPM manifest API can be out of sync with
# the compiler and fail before tests even start.
if [[ -f "${HOME}/.swiftly/env.sh" ]]; then
    # shellcheck disable=SC1090
    . "${HOME}/.swiftly/env.sh"
    hash -r 2>/dev/null || true
fi

# -------- pre-flight --------------------------------------------------------

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: release pipeline requires macOS (hdiutil/codesign/PlistBuddy)" >&2
    exit 1
fi

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "error: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -f Resources/VERSION ]]; then
    echo "error: Resources/VERSION missing" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
if [[ -z "${VERSION}" ]]; then
    echo "error: Resources/VERSION is empty" >&2
    exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo "error: Resources/VERSION value '${VERSION}' is not a valid semver" >&2
    exit 1
fi

# Branding — read from the single source of truth in Branding.swift.
BRAND_DISPLAY="$(grep 'appDisplayName = "' QuotaMonitor/Core/Branding.swift \
    | sed 's/.*= "//;s/".*//')"
BRAND_CODE="$(grep 'appCodeName = "' QuotaMonitor/Core/Branding.swift \
    | sed 's/.*= "//;s/".*//')"
if [[ -z "${BRAND_DISPLAY}" || -z "${BRAND_CODE}" ]]; then
    echo "error: could not extract branding from QuotaMonitor/Core/Branding.swift" >&2
    exit 1
fi

DMG_PATH="dist/${BRAND_CODE}-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

if [[ -f "${DMG_PATH}" && "${FORCE}" -eq 0 ]]; then
    echo "error: ${DMG_PATH} already exists." >&2
    echo "       Bump Resources/VERSION, delete the file, or rerun with --force." >&2
    exit 1
fi

echo "==> Releasing ${BRAND_CODE} v${VERSION}"

# -------- signing mode ------------------------------------------------------

RELEASE_SIGNING="${QM_RELEASE_SIGNING:-auto}"
case "${RELEASE_SIGNING}" in
    auto)
        if qm_developer_id_release_available; then
            RELEASE_SIGNING="developer-id"
        else
            RELEASE_SIGNING="adhoc"
        fi
        ;;
    developer-id|adhoc) ;;
    *)
        echo "error: QM_RELEASE_SIGNING must be auto, developer-id, or adhoc" >&2
        exit 2
        ;;
esac

if [[ "${RELEASE_SIGNING}" == "developer-id" ]]; then
    qm_resolve_developer_id_identity
    qm_set_notary_args
    echo "==> Signing mode: Developer ID (${QM_DEVELOPER_IDENTITY})"
else
    echo "==> Signing mode: local/ad-hoc (not for public distribution)"
fi

# -------- tests -------------------------------------------------------------

echo "==> swift test"
swift test --disable-keychain

# -------- build (release) ---------------------------------------------------

echo "==> CONFIG=release QM_DISTRIBUTION=developer-id ./build.sh"
CONFIG=release QM_DISTRIBUTION=developer-id ./build.sh

APP_BUNDLE=".build/QuotaMonitor.app"
if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} missing after build" >&2
    exit 1
fi

# -------- verify the bundle -------------------------------------------------

echo "==> codesign --verify ${APP_BUNDLE}"
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"

# Confirm the version we asked for actually landed in Info.plist (catches
# a regression in build.sh's PlistBuddy injection).
INSIDE_VERSION="$(defaults read "$PWD/${APP_BUNDLE}/Contents/Info" \
    CFBundleShortVersionString 2>/dev/null || echo "")"
if [[ "${INSIDE_VERSION}" != "${VERSION}" ]]; then
    echo "error: Info.plist version '${INSIDE_VERSION}' != Resources/VERSION '${VERSION}'" >&2
    exit 1
fi
echo "    Info.plist CFBundleShortVersionString = ${INSIDE_VERSION}  OK"

# -------- Developer ID app notarization -------------------------------------

if [[ "${RELEASE_SIGNING}" == "developer-id" ]]; then
    echo "==> tools/notarize.sh"
    APP_BUNDLE="${APP_BUNDLE}" tools/notarize.sh
fi

# -------- DMG ---------------------------------------------------------------

echo "==> tools/make-dmg.sh"
# Package the verified bundle. In Developer ID mode this is important:
# rebuilding here would throw away the stapled app we just produced.
CONFIG=release QM_DISTRIBUTION=developer-id VER="${VERSION}" QM_MAKE_DMG_SKIP_BUILD=1 tools/make-dmg.sh

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "error: expected ${DMG_PATH} after make-dmg.sh, not found" >&2
    exit 1
fi

if [[ "${RELEASE_SIGNING}" == "developer-id" ]]; then
    echo "==> tools/notarize-dmg.sh"
    tools/notarize-dmg.sh "${DMG_PATH}"
fi

# -------- SHA-256 -----------------------------------------------------------

echo "==> shasum -a 256 ${DMG_PATH}"
( cd dist && shasum -a 256 "${BRAND_CODE}-${VERSION}.dmg" > "${BRAND_CODE}-${VERSION}.dmg.sha256" )
echo "    $(cat "${SHA_PATH}")"

# -------- self-check: mount + verify ---------------------------------------

MOUNT_POINT="$(mktemp -d -t cm-release-check)"
cleanup() {
    if mount | grep -q "${MOUNT_POINT}"; then
        hdiutil detach "${MOUNT_POINT}" -quiet || true
    fi
    rm -rf "${MOUNT_POINT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Mounting ${DMG_PATH} for self-check"
hdiutil attach -nobrowse -readonly -mountpoint "${MOUNT_POINT}" "${DMG_PATH}" >/dev/null

INSIDE_APP="${MOUNT_POINT}/QuotaMonitor.app"
if [[ ! -d "${INSIDE_APP}" ]]; then
    echo "error: ${INSIDE_APP} missing inside DMG" >&2
    exit 1
fi

echo "==> codesign --verify (inside DMG)"
codesign --verify --strict --verbose=2 "${INSIDE_APP}"

if [[ "${RELEASE_SIGNING}" == "developer-id" ]]; then
    echo "==> spctl --assess (Developer ID app inside DMG)"
    spctl --assess --type execute --verbose=2 "${INSIDE_APP}"
else
    # Gatekeeper assessment WILL fail for an ad-hoc-signed bundle; that's
    # expected for local-only builds. We log it but don't abort.
    echo "==> spctl --assess (expected to reject local/ad-hoc signature)"
    if spctl --assess --type execute --verbose=2 "${INSIDE_APP}" 2>&1; then
        echo "    spctl: accepted (unusual for ad-hoc; not an error)"
    else
        echo "    spctl: rejected - expected for local/ad-hoc signing, not a release blocker."
    fi
fi

# -------- next-step checklist ----------------------------------------------

DMG_SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d '[:space:]')"

cat <<EOF

===========================================
 Release v${VERSION} ready
===========================================
DMG:    ${DMG_PATH}  (${DMG_SIZE})
SHA256: ${SHA_PATH}
Signing: ${RELEASE_SIGNING}

Next steps (manual):
  1. Land the release commit through a PR to main.
  2. git switch main && git pull
  3. git tag v${VERSION} && git push origin v${VERSION}
  4. Let release.yml publish the GitHub Release and open the appcast PR.

Do not run gh release create locally unless the workflow is unavailable;
the appcast signature must be computed over the exact DMG users download.
===========================================
EOF
