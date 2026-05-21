#!/usr/bin/env bash
# Wrap .build/QuotaMonitor.app into a distributable .dmg with a custom
# install-window layout (background image + icon positions + /Applications
# alias). Pure shell + AppleScript — no homebrew dependencies.
#
# Flow:
#   1. ./build.sh CONFIG=$CONFIG    (assemble + ad-hoc sign the .app)
#   2. Stage: copy .app + symlink /Applications + copy background PNG
#      into a hidden .background folder
#   3. hdiutil create -format UDRW   (read-WRITE shadow image we can mutate)
#   4. Mount it, run osascript that sets icon coords / view options /
#      background, eject
#   5. hdiutil convert UDRW → UDZO   (read-only, compressed, what we ship)
#
# Why not the simpler one-shot UDZO from a folder: that path produces a flat
# DMG with no Finder-window metadata, so the icons land in a default grid.
# The two-stage UDRW→UDZO dance is the canonical way to bake a layout in.
#
# Usage:
#   tools/make-dmg.sh                # release build, dist/QuotaMonitor-<ver>.dmg
#   CONFIG=debug tools/make-dmg.sh   # debug bundle
#   VER=0.2.0-rc1 tools/make-dmg.sh  # override version

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
APP=".build/QuotaMonitor.app"
DIST="dist"

# Version: caller may override via VER=..., otherwise read Resources/VERSION.
# We deliberately do NOT fall back to a fake "0.0.0" — that path silently
# shipped mismatched DMGs in the past. If VERSION is missing/empty, fail loud.
if [[ -n "${VER:-}" ]]; then
    :  # explicit override wins
elif [[ -f Resources/VERSION ]]; then
    VER="$(tr -d '[:space:]' < Resources/VERSION)"
    if [[ -z "${VER}" ]]; then
        echo "error: Resources/VERSION is empty" >&2
        exit 1
    fi
else
    echo "error: Resources/VERSION missing and no VER= override given" >&2
    exit 1
fi

NAME="QuotaMonitor-${VER}.dmg"
VOLNAME="Install QuotaMonitor ${VER}"
BG_PATH="Resources/dmg-background.png"

STAGING=$(mktemp -d)
RW_DMG=$(mktemp -u)-rw.dmg
MOUNT_POINT="/Volumes/${VOLNAME}"

cleanup() {
    if mount | grep -q "${MOUNT_POINT}"; then
        hdiutil detach "${MOUNT_POINT}" -quiet || true
    fi
    rm -rf "${STAGING}" 2>/dev/null || true
    rm -f "${RW_DMG}" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Build first.
echo "==> ./build.sh (CONFIG=$CONFIG)"
CONFIG="$CONFIG" ./build.sh >/dev/null

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found after build" >&2
    exit 1
fi

if [[ ! -f "${BG_PATH}" ]]; then
    echo "error: ${BG_PATH} missing — run swift tools/make-dmg-bg.swift ${BG_PATH}" >&2
    exit 1
fi

mkdir -p "$DIST"
rm -f "${DIST}/${NAME}"

# 2. Stage: app + Applications alias + hidden .background folder.
echo "==> Staging in ${STAGING}"
cp -R "$APP" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
mkdir "${STAGING}/.background"
cp "${BG_PATH}" "${STAGING}/.background/background.png"

# 3. Build a writable DMG so we can configure Finder window state.
#    Size = staging size + 20 % slack, min 32M (Apple gets cranky on tiny RW images).
RAW_KB=$(du -sk "${STAGING}" | awk '{print $1}')
SIZE_KB=$(( RAW_KB + RAW_KB / 5 + 32768 ))
echo "==> hdiutil create -format UDRW (${SIZE_KB}K)"
hdiutil create \
    -volname "${VOLNAME}" \
    -srcfolder "${STAGING}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    "${RW_DMG}" >/dev/null

echo "==> Mounting ${RW_DMG}"
hdiutil attach "${RW_DMG}" -mountpoint "${MOUNT_POINT}" -nobrowse -noautoopen >/dev/null

# 4. AppleScript to position icons + apply background.
#    Window is 540×380 — must match the PNG dimensions or icons will float.
echo "==> Configuring Finder window"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 740, 500}

        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"

        -- Coordinates are within the window's CONTENT area (540×380).
        -- App icon left of center, /Applications alias to the right —
        -- aligned with the arrow drawn on the PNG (y ≈ 200 from top).
        set position of item "QuotaMonitor.app" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}

        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Belt-and-suspenders: the AppleScript above sometimes races with mds.
# A short pause lets .DS_Store sync to disk before we eject.
sync
sleep 2

echo "==> Detaching"
hdiutil detach "${MOUNT_POINT}" -quiet

# 5. Convert RW → compressed read-only.
echo "==> hdiutil convert UDRW → UDZO ${DIST}/${NAME}"
hdiutil convert "${RW_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "${DIST}/${NAME}" >/dev/null

echo "==> ${DIST}/${NAME}"
ls -lh "${DIST}/${NAME}"
