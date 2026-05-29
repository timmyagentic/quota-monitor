#!/usr/bin/env bash
# Sign a DMG with the Sparkle Ed25519 private key (stored in macOS
# login Keychain) and print a ready-to-paste appcast.xml <item> block.
#
# Why a separate script (not inline in make-dmg.sh): the Keychain
# access happens here only, so CI / non-maintainer builds don't have
# to fight a Keychain ACL prompt or fail because the key isn't there.
# make-dmg.sh stays unsigned-by-default; this script signs after the
# fact, only on the maintainer's machine.
#
# Usage:
#   ./tools/release-sparkle.sh                       (uses dist/QuotaMonitor-<VERSION>.dmg)
#   ./tools/release-sparkle.sh path/to/some.dmg      (sign an arbitrary file)
#   QM_SPARKLE_ACCOUNT=myname ./tools/release-sparkle.sh
#
# After running, paste the printed <item>...</item> block into the
# <channel> of appcast.xml, git commit + push, and Sparkle clients
# will see the new version on their next scheduled poll.

set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_UPDATE_BIN=".build/artifacts/sparkle/Sparkle/bin/sign_update"
# Keychain account label. Must match what `generate_keys --account` was
# called with at one-time setup. Default matches docs/release.md.
ACCOUNT="${QM_SPARKLE_ACCOUNT:-quotamonitor}"

if [[ ! -x "${SIGN_UPDATE_BIN}" ]]; then
    echo "error: ${SIGN_UPDATE_BIN} not found." >&2
    echo "       Run 'swift package resolve' first." >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < Resources/VERSION)"
DMG_PATH="${1:-dist/QuotaMonitor-${VERSION}.dmg}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "error: ${DMG_PATH} not found — run ./make-dmg.sh first." >&2
    exit 1
fi

# sign_update reads the private key from the login Keychain under the
# account name passed via --account. macOS may pop a one-time access
# dialog the first time `sign_update` (vs. `generate_keys`) touches it;
# click "Always Allow" so subsequent releases don't prompt. Output:
#   sparkle:edSignature="…base64…" length="3785729"
echo "==> Signing ${DMG_PATH} using Keychain account '${ACCOUNT}'"
SIG_LINE="$("${SIGN_UPDATE_BIN}" --account "${ACCOUNT}" "${DMG_PATH}")"

DMG_FILE="$(basename "${DMG_PATH}")"
DOWNLOAD_URL="https://github.com/systemoutprintlnnnn/quota-monitor/releases/download/v${VERSION}/${DMG_FILE}"
# RSS pubDate must be RFC-822 (English month + weekday) regardless of
# the maintainer's system locale. `LC_ALL=C` pins the C locale just
# for this one invocation.
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MIN_OS="14.0"

# Pull the [X.Y.Z] section out of each changelog and convert its
# markdown to inline HTML for Sparkle's release-notes WebView.
# Sparkle renders the <description> CDATA block as HTML, so giving
# it bullet lists + headings + bold makes the "What's new" dialog
# usable instead of showing "See CHANGELOG.md for what's new" (which
# the user can't actually click on — Sparkle's WebView doesn't run
# JS or open file:// links inside an app-bundled dialog).
#
# Bilingual notes: we emit two <description xml:lang="…"> nodes — en
# from CHANGELOG.md, zh-Hans from CHANGELOG.zh-Hans.md. Sparkle picks
# the one matching the user's system language at appcast parse time
# (SUAppcast.m bestNodeInNodes → +[NSBundle preferredLocalizations-
# FromArray:]). Both nodes MUST carry an explicit xml:lang or Sparkle
# logs an error and defaults to "en".
#
# The conversion logic lives in tools/changelog-to-html.py rather
# than inline here because bash's $( ... <<'PY' ... PY ) parses
# backticks inside the heredoc body as legacy command substitution
# even with a quoted delimiter, and the regex for `code` spans
# needs literal backticks.
EN_NOTES_HTML="$(python3 tools/changelog-to-html.py "${VERSION}" CHANGELOG.md)"

# Hard-require the Simplified-Chinese section so a release can't
# silently ship English-only notes — fixed bilingual notes are the
# project standard. changelog-to-html.py prints a "See …" fallback
# (exit 0) when a section is missing, so detect the heading ourselves.
ZH_CHANGELOG="CHANGELOG.zh-Hans.md"
if [[ ! -f "${ZH_CHANGELOG}" ]] || \
   ! grep -qE "^##[[:space:]]+\[${VERSION//./\\.}\]" "${ZH_CHANGELOG}"; then
    echo "error: ${ZH_CHANGELOG} is missing a '## [${VERSION}]' section." >&2
    echo "       Add the Simplified-Chinese notes for ${VERSION} (parallel" >&2
    echo "       to CHANGELOG.md) before generating the appcast item." >&2
    exit 1
fi
ZH_NOTES_HTML="$(python3 tools/changelog-to-html.py "${VERSION}" "${ZH_CHANGELOG}")"

cat <<APPCAST_ITEM

==> Paste this into appcast.xml (under <channel>, newest at top):
---------------------------------------------------------------
        <item>
            <title>QuotaMonitor ${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <description xml:lang="en"><![CDATA[
${EN_NOTES_HTML}
            ]]></description>
            <description xml:lang="zh-Hans"><![CDATA[
${ZH_NOTES_HTML}
            ]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                type="application/octet-stream"
                ${SIG_LINE} />
        </item>
---------------------------------------------------------------
APPCAST_ITEM
