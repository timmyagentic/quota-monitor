#!/usr/bin/env bash
# Sign a DMG with the Sparkle Ed25519 private key and print a ready-to-
# paste appcast.xml <item> block.
#
# Why a separate script (not inline in make-dmg.sh): the signing key
# must NEVER live in the repo. This script reads it from a path you
# control (default ~/.config/sparkle/quotamonitor-ed25519.key, can be
# overridden) and shells out to `sign_update` from the resolved Sparkle
# SwiftPM artifact. make-dmg.sh stays unsigned-by-default so CI builds
# (which have no key) don't fail.
#
# Usage:
#   ./tools/release-sparkle.sh                       (uses dist/QuotaMonitor-<VERSION>.dmg)
#   ./tools/release-sparkle.sh path/to/some.dmg      (sign an arbitrary file)
#   QM_SPARKLE_KEY=~/keys/qm.key ./tools/release-sparkle.sh
#
# After running, paste the printed <item>...</item> block into the
# <channel> of appcast.xml, git commit + push, and Sparkle clients
# will see the new version on their next scheduled poll.

set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_UPDATE_BIN=".build/artifacts/sparkle/Sparkle/bin/sign_update"
KEY_PATH="${QM_SPARKLE_KEY:-$HOME/.config/sparkle/quotamonitor-ed25519.key}"

if [[ ! -x "${SIGN_UPDATE_BIN}" ]]; then
    echo "error: ${SIGN_UPDATE_BIN} not found." >&2
    echo "       Run 'swift package resolve' first." >&2
    exit 1
fi
if [[ ! -f "${KEY_PATH}" ]]; then
    echo "error: Ed25519 private key not found at ${KEY_PATH}." >&2
    echo "       Generate one with:" >&2
    echo "         .build/artifacts/sparkle/Sparkle/bin/generate_keys -p \\" >&2
    echo "             > \"${KEY_PATH}\".pub" >&2
    echo "         .build/artifacts/sparkle/Sparkle/bin/generate_keys -x \\" >&2
    echo "             \"${KEY_PATH}\"" >&2
    echo "       Then chmod 600 the .key file and paste the .pub contents" >&2
    echo "       into Resources/Info.plist under SUPublicEDKey." >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
DMG_PATH="${1:-dist/QuotaMonitor-${VERSION}.dmg}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "error: ${DMG_PATH} not found — run ./make-dmg.sh first." >&2
    exit 1
fi

# sign_update prints something like:
#   sparkle:edSignature="…base64…" length="3785729"
# We capture stdout and weave it into a full <item> block.
echo "==> Signing ${DMG_PATH} with key at ${KEY_PATH}"
SIG_LINE="$("${SIGN_UPDATE_BIN}" -f "${KEY_PATH}" "${DMG_PATH}")"

DMG_FILE="$(basename "${DMG_PATH}")"
DOWNLOAD_URL="https://github.com/systemoutprintlnnnn/quota-monitor/releases/download/v${VERSION}/${DMG_FILE}"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MIN_OS="14.0"

cat <<APPCAST_ITEM

==> Paste this into appcast.xml (under <channel>, newest at top):
---------------------------------------------------------------
        <item>
            <title>QuotaMonitor ${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <description><![CDATA[
                See CHANGELOG.md for what's new in ${VERSION}.
            ]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                type="application/octet-stream"
                ${SIG_LINE} />
        </item>
---------------------------------------------------------------
APPCAST_ITEM
