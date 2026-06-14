#!/usr/bin/env bash
# Generate Resources/AppIcon.icns from Resources/AppIcon.png.
#
# Run once whenever the source icon changes. The generated .icns is committed
# so build.sh can copy it into the app bundle without requiring icon generation
# during every build.
#
# Requires: macOS command line tools with sips and iconutil.

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-Resources/AppIcon.png}"
OUT="Resources/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "error: source icon not found: $SOURCE" >&2
    exit 1
fi

width="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')"
height="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')"
if [[ "$width" != "$height" ]]; then
    echo "error: source icon must be square, got ${width}x${height}: $SOURCE" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"

echo "==> Preparing 1024x1024 source PNG from $SOURCE"
sips -s format png -z 1024 1024 "$SOURCE" --out "$MASTER" >/dev/null

echo "==> Generating .iconset"
mkdir -p "$ICONSET"
# Apple iconset spec: 10 PNGs covering 16/32/128/256/512 @1x and @2x.
for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    set -- $spec
    sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null
done

echo "==> iconutil -> $OUT"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"

ls -lh "$OUT"
