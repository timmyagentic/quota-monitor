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
#   ./tools/release-sparkle.sh                       (uses dist/<BRAND_CODE>-<VERSION>.dmg)
#   ./tools/release-sparkle.sh path/to/some.dmg      (sign an arbitrary file)
#   QM_SPARKLE_ACCOUNT=myname ./tools/release-sparkle.sh
#   RELEASE_REPO=systemoutprintlnnnn/codex-monitor ./tools/release-sparkle.sh
#       (point the enclosure download URL at a different brand's repo)
#
# The <title> and default DMG name follow appCodeName in Branding.swift,
# so a rebranded build signs and titles its appcast item automatically.
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

# Branding — read from the single source of truth in Branding.swift.
BRAND_CODE="$(grep 'appCodeName = "' QuotaMonitor/Core/Branding.swift \
    | sed 's/.*= "//;s/".*//')"
if [[ -z "${BRAND_CODE}" ]]; then
    echo "error: could not extract branding from QuotaMonitor/Core/Branding.swift" >&2
    exit 1
fi

DMG_PATH="${1:-dist/${BRAND_CODE}-${VERSION}.dmg}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "error: ${DMG_PATH} not found — run ./make-dmg.sh first." >&2
    exit 1
fi

# Two signing backends, picked by environment:
#
#   1. CI / headless (SPARKLE_PRIVATE_KEY set): there is no login
#      Keychain on a GitHub Actions runner, so the private key arrives
#      as a repo secret. We write it to a temp file and sign via
#      --ed-key-file (the exact file format `generate_keys -x` exports,
#      so the secret is just that export pasted verbatim). The temp
#      file is removed on exit so the key never lingers on disk.
#   2. Local maintainer (default): the key lives in the login Keychain
#      under --account. macOS may pop a one-time access dialog the first
#      time `sign_update` (vs. `generate_keys`) touches it; click
#      "Always Allow" so subsequent releases don't prompt.
#
# Either way the output is the appcast enclosure attributes:
#   sparkle:edSignature="…base64…" length="3785729"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "==> Signing ${DMG_PATH} using SPARKLE_PRIVATE_KEY from environment"
    KEYFILE="$(mktemp)"
    trap 'rm -f "${KEYFILE}"' EXIT
    printf '%s' "${SPARKLE_PRIVATE_KEY}" > "${KEYFILE}"
    SIG_LINE="$("${SIGN_UPDATE_BIN}" --ed-key-file "${KEYFILE}" "${DMG_PATH}")"
else
    echo "==> Signing ${DMG_PATH} using Keychain account '${ACCOUNT}'"
    SIG_LINE="$("${SIGN_UPDATE_BIN}" --account "${ACCOUNT}" "${DMG_PATH}")"
fi

DMG_FILE="$(basename "${DMG_PATH}")"
# Which repo's Releases the enclosure URL points at. Defaults to this
# repo (Quota Monitor); the CodexMonitor release job overrides it to
# systemoutprintlnnnn/codex-monitor so the signed appcast points users
# at the DMG actually published under that brand.
RELEASE_REPO="${RELEASE_REPO:-timmyagentic/quota-monitor}"
DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/download/v${VERSION}/${DMG_FILE}"
# Base URL hosting the per-version release-notes HTML the appcast LINKS to
# (via sparkle:releaseNotesLink). Deliberately pinned to the primary Quota
# Monitor repo and NOT derived from RELEASE_REPO: the CodexMonitor feed push
# (release.yml) ships only appcast.xml, not ReleaseNotes/, so both brands'
# feeds must resolve their notes against this single, always-populated host.
NOTES_BASE_URL="${NOTES_BASE_URL:-https://raw.githubusercontent.com/timmyagentic/quota-monitor/main}"
# RSS pubDate must be RFC-822 (English month + weekday) regardless of
# the maintainer's system locale. `LC_ALL=C` pins the C locale just
# for this one invocation.
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MIN_OS="14.0"

# Ensure the per-version release-notes HTML exists on disk. The appcast
# LINKS to these files (sparkle:releaseNotesLink) instead of inlining them,
# so Sparkle downloads them lazily — only when a user opens an update —
# which keeps appcast.xml tiny (a few KB vs. hundreds) and off
# raw.githubusercontent.com's rate limiter (a bloated feed 429s on the
# frequent poll and surfaces "获取升级信息时出现错误"). release.yml commits
# these files alongside appcast.xml so the linked URLs resolve.
#
# Two sources per language, tried in order:
#   1. ReleaseNotes/<version>.{en,zh-Hans}.html — hand-authored, full
#      visual control (images, CSS animations, rich layouts).
#   2. Fallback: tools/changelog-to-html.py extracts the [X.Y.Z] section
#      from CHANGELOG.md / CHANGELOG.zh-Hans.md, converted to a styled HTML
#      page and WRITTEN to the ReleaseNotes file so the link resolves.
#
# Bilingual notes: we emit two <sparkle:releaseNotesLink xml:lang="…">
# nodes — en and zh-Hans. Sparkle downloads the one matching the user's
# system language. Both nodes MUST carry an explicit xml:lang or Sparkle
# logs an error and defaults to "en".

EN_HTML_FILE="ReleaseNotes/${VERSION}.en.html"
ZH_HTML_FILE="ReleaseNotes/${VERSION}.zh-Hans.html"
mkdir -p ReleaseNotes

if [[ -f "${EN_HTML_FILE}" ]]; then
    echo "==> Using ${EN_HTML_FILE} for English release notes"
else
    echo "==> No ${EN_HTML_FILE}, generating from CHANGELOG.md"
    python3 tools/changelog-to-html.py --lang en "${VERSION}" CHANGELOG.md \
        > "${EN_HTML_FILE}"
fi

if [[ -f "${ZH_HTML_FILE}" ]]; then
    echo "==> Using ${ZH_HTML_FILE} for Chinese release notes"
else
    # Hard-require the Simplified-Chinese section so a release can't
    # silently ship English-only notes — fixed bilingual notes are the
    # project standard. changelog-to-html.py prints a "See …" fallback
    # (exit 0) when a section is missing, so detect the heading ourselves.
    ZH_CHANGELOG="CHANGELOG.zh-Hans.md"
    if [[ ! -f "${ZH_CHANGELOG}" ]] || \
       ! grep -qE "^##[[:space:]]+\[${VERSION//./\\.}\]" "${ZH_CHANGELOG}"; then
        echo "error: ${ZH_CHANGELOG} is missing a '## [${VERSION}]' section," >&2
        echo "       and ${ZH_HTML_FILE} does not exist." >&2
        echo "       Provide one of the two before generating the appcast item." >&2
        exit 1
    fi
    echo "==> No ${ZH_HTML_FILE}, generating from ${ZH_CHANGELOG}"
    python3 tools/changelog-to-html.py --lang zh-Hans "${VERSION}" "${ZH_CHANGELOG}" \
        > "${ZH_HTML_FILE}"
fi

EN_NOTES_LINK="${NOTES_BASE_URL}/ReleaseNotes/${VERSION}.en.html"
ZH_NOTES_LINK="${NOTES_BASE_URL}/ReleaseNotes/${VERSION}.zh-Hans.html"

# Build the <item> block once, then both (a) write a clean, banner-free
# copy that automation (release.yml) can splice straight into
# appcast.xml, and (b) print it with a human banner for the local paste
# workflow.
ITEM_BLOCK="$(cat <<APPCAST_ITEM
        <item>
            <title>${BRAND_CODE} ${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink xml:lang="en">${EN_NOTES_LINK}</sparkle:releaseNotesLink>
            <sparkle:releaseNotesLink xml:lang="zh-Hans">${ZH_NOTES_LINK}</sparkle:releaseNotesLink>
            <enclosure
                url="${DOWNLOAD_URL}"
                type="application/octet-stream"
                ${SIG_LINE} />
        </item>
APPCAST_ITEM
)"

ITEM_FILE="dist/appcast-item-${VERSION}.xml"
printf '%s\n' "${ITEM_BLOCK}" > "${ITEM_FILE}"
echo "==> Wrote ${ITEM_FILE}"

cat <<APPCAST_BANNER

==> Paste this into appcast.xml (under <channel>, newest at top):
---------------------------------------------------------------
${ITEM_BLOCK}
---------------------------------------------------------------
==> Also commit the linked release notes so the URLs resolve:
      ${EN_HTML_FILE}
      ${ZH_HTML_FILE}
APPCAST_BANNER
