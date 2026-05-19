#!/usr/bin/env bash
# Package .build/QuotaMonitor.app into dist/QuotaMonitor-<version>.dmg.
# Usage: ./make-dmg.sh         (calls build.sh release first)
#        SKIP_BUILD=1 ./make-dmg.sh    (skip rebuild, reuse existing .app)

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="QuotaMonitor"
APP_BUNDLE=".build/${APP_NAME}.app"
DIST_DIR="dist"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    CONFIG=release ./build.sh
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} not found — run ./build.sh release first" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

# Stage the .app and an /Applications symlink in a temp dir so the mounted
# DMG presents the standard drag-to-install layout.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT
cp -R "${APP_BUNDLE}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

echo "==> hdiutil create ${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

( cd "${DIST_DIR}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256" )

echo "==> Done: ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"
echo "==> SHA256: $(cut -d' ' -f1 < "${DMG_PATH}.sha256")"
