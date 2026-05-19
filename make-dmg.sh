#!/usr/bin/env bash
# Package .build/QuotaMonitor.app into dist/QuotaMonitor-<version>.dmg
# with a styled drag-to-install layout (icon view, hidden toolbar,
# background image with arrow).
#
# Usage: ./make-dmg.sh         (calls build.sh release first)
#        SKIP_BUILD=1 ./make-dmg.sh    (skip rebuild, reuse existing .app)

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="QuotaMonitor"
APP_BUNDLE=".build/${APP_NAME}.app"
DIST_DIR="dist"
BG_SRC="Resources/dmg-background.png"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    CONFIG=release ./build.sh
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} not found — run ./build.sh release first" >&2
    exit 1
fi
if [[ ! -f "${BG_SRC}" ]]; then
    echo "error: ${BG_SRC} missing — run scripts/make-dmg-bg.py" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
VOL_NAME="${APP_NAME} ${VERSION}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
TMP_DMG="$(mktemp -t qm-dmg-XXXXXX).dmg"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

# Stage the .app, /Applications symlink, and a hidden .background dir
# holding the backdrop PNG. Finder picks up the background from any
# top-level `.background/*` file when AppleScript sets it below.
STAGE_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${STAGE_DIR}" "${TMP_DMG}"
    # Detach any leftover mount from a failed prior run.
    hdiutil detach "/Volumes/${VOL_NAME}" -quiet 2>/dev/null || true
}
trap cleanup EXIT

cp -R "${APP_BUNDLE}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"
mkdir "${STAGE_DIR}/.background"
cp "${BG_SRC}" "${STAGE_DIR}/.background/background.png"

# Writable DMG → mount → style via AppleScript → detach → compress.
# UDRW is required because UDZO mounts read-only and Finder can't
# write the .DS_Store that holds the window layout.
echo "==> hdiutil create (writable)"
hdiutil create \
    -volname "${VOL_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "${TMP_DMG}" >/dev/null

echo "==> Mount + style"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "${TMP_DMG}" \
       | awk '/Apple_HFS/ {print $1; exit}')"
# Give Finder a moment to register the mount before scripting it.
sleep 1

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    set bgAlias to (POSIX file "/Volumes/${VOL_NAME}/.background/background.png") as alias
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- Window content area becomes 540x380 to match the background.
        set the bounds of container window to {200, 200, 740, 580}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        set background picture of theViewOptions to bgAlias
        set position of item "${APP_NAME}.app" of container window to {150, 220}
        set position of item "Applications" of container window to {390, 220}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Force the .DS_Store to flush before unmount.
sync
hdiutil detach "${DEV}" -quiet

echo "==> hdiutil convert -> UDZO ${DMG_PATH}"
hdiutil convert "${TMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}" >/dev/null

( cd "${DIST_DIR}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256" )

echo "==> Done: ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"
echo "==> SHA256: $(cut -d' ' -f1 < "${DMG_PATH}.sha256")"
