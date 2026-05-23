#!/usr/bin/env bash
# One-command release pipeline for ad-hoc-signed DMG distribution.
#
# Steps: pre-flight → tests → release build → bundle verify → DMG → sha256
#        → mount-and-verify self-check → next-step checklist.
#
# Usage:
#   ./tools/release.sh           # normal release
#   ./tools/release.sh --force   # overwrite an existing dist/<...>.dmg
#
# Version is read from Resources/VERSION (single source of truth).

set -euo pipefail
cd "$(dirname "$0")/.."

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

DMG_PATH="dist/QuotaMonitor-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

if [[ -f "${DMG_PATH}" && "${FORCE}" -eq 0 ]]; then
    echo "error: ${DMG_PATH} already exists." >&2
    echo "       Bump Resources/VERSION, delete the file, or rerun with --force." >&2
    exit 1
fi

echo "==> Releasing QuotaMonitor v${VERSION}"

# -------- tests -------------------------------------------------------------

echo "==> swift test"
swift test --disable-keychain

# -------- build (release) ---------------------------------------------------

echo "==> CONFIG=release ./build.sh"
CONFIG=release ./build.sh

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

# -------- DMG ---------------------------------------------------------------

echo "==> tools/make-dmg.sh"
# make-dmg.sh re-runs build.sh internally; tolerate that — it's cheap and
# guarantees the DMG payload matches what we just verified.
CONFIG=release VER="${VERSION}" tools/make-dmg.sh

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "error: expected ${DMG_PATH} after make-dmg.sh, not found" >&2
    exit 1
fi

# -------- SHA-256 -----------------------------------------------------------

echo "==> shasum -a 256 ${DMG_PATH}"
( cd dist && shasum -a 256 "QuotaMonitor-${VERSION}.dmg" > "QuotaMonitor-${VERSION}.dmg.sha256" )
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

# Gatekeeper assessment WILL fail for an ad-hoc-signed bundle; that's expected
# and is exactly why the README documents the right-click-Open dance. We log
# it but don't abort.
echo "==> spctl --assess (expected to reject ad-hoc signature)"
if spctl --assess --type execute --verbose=2 "${INSIDE_APP}" 2>&1; then
    echo "    spctl: accepted (unusual for ad-hoc; not an error)"
else
    echo "    spctl: rejected — expected for ad-hoc signing, not a release blocker."
fi

# -------- next-step checklist ----------------------------------------------

DMG_SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d '[:space:]')"

cat <<EOF

===========================================
 Release v${VERSION} ready
===========================================
DMG:    ${DMG_PATH}  (${DMG_SIZE})
SHA256: ${SHA_PATH}

Next steps (manual):
  1. git tag v${VERSION} && git push origin v${VERSION}
  2. gh release create v${VERSION} \\
        ${DMG_PATH} \\
        ${SHA_PATH} \\
        --title "QuotaMonitor ${VERSION}" \\
        --notes-file CHANGELOG.md   # or hand-pick the v${VERSION} block

Reminder: this is ad-hoc-signed. Users must right-click → Open
on first launch (see README "Install" section).
===========================================
EOF
