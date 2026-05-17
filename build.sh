#!/usr/bin/env bash
# Build QuotaMonitor.app from SwiftPM output.
# Usage: ./build.sh [debug|release]   (default: debug)

set -euo pipefail

cd "$(dirname "$0")"

# Config can come from $1 (positional) OR $CONFIG (env). Env wins so callers
# like make-dmg.sh / release.sh can pipe a value through without juggling args.
CONFIG="${CONFIG:-${1:-debug}}"
APP_NAME="QuotaMonitor"
APP_BUNDLE=".build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BIN_PATH}" "${CONTENTS}/MacOS/${APP_NAME}"
cp Resources/Info.plist "${CONTENTS}/Info.plist"

# Inject version from Resources/VERSION (single source of truth) into the
# *copied* Info.plist. The source Info.plist now ships placeholder 0.0.0/0
# precisely so that an un-injected build is obviously wrong rather than
# silently shipping a stale "1.0" value.
if [[ ! -f Resources/VERSION ]]; then
    echo "error: Resources/VERSION missing — cannot inject version" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
if [[ -z "${VERSION}" ]]; then
    echo "error: Resources/VERSION is empty" >&2
    exit 1
fi
# CFBundleVersion: prefer short git SHA for traceability, fall back to "1".
BUILD_TAG="$(git -C "$(pwd)" rev-parse --short HEAD 2>/dev/null || true)"
BUILD_TAG="${BUILD_TAG:-1}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_TAG}" \
    "${CONTENTS}/Info.plist"
echo "    version=${VERSION} build=${BUILD_TAG}"

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"
else
    echo "warning: Resources/AppIcon.icns missing — run tools/make-icon.sh" >&2
fi

# Signing identity selection
# ---------------------------
# A stable self-signed identity keeps the Keychain ACL valid across rebuilds,
# so /usage credentials don't trigger a Keychain prompt every restart in dev.
# CI has no such identity in its login keychain and falls through to ad-hoc,
# which keeps the private key off GitHub Actions entirely (a CI cert leak
# would let an attacker sign a malicious QuotaMonitor that every end-user's
# Mac silently trusts — local-only is the safer trade).
#
# One-time setup on a dev Mac (skip if QM_CODESIGN_IDENTITY is already set
# to an existing identity):
#   1. Open Keychain Access → Keychain Access menu → Certificate Assistant
#      → Create a Certificate…
#   2. Name: "QuotaMonitor Dev"
#      Identity Type: Self Signed Root
#      Certificate Type: Code Signing
#   3. Continue → Done. Cert lands in the login keychain.
#   4. Verify: `security find-identity -v -p codesigning` shows the name.
SIGN_IDENTITY="${QM_CODESIGN_IDENTITY:-QuotaMonitor Dev}"
if security find-identity -v -p codesigning 2>/dev/null \
        | grep -q " \"${SIGN_IDENTITY}\""; then
    echo "==> codesign with '${SIGN_IDENTITY}'"
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "==> Ad-hoc codesign (identity '${SIGN_IDENTITY}' not found)"
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "==> Done: ${APP_BUNDLE}"
echo "Run with: open '${APP_BUNDLE}'"
