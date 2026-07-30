#!/usr/bin/env bash
# Build QuotaMonitor.app from SwiftPM output.
# Usage: ./build.sh [debug|release]   (default: debug)

set -euo pipefail

cd "$(dirname "$0")"

# Prefer a user-installed Swiftly toolchain when present. On this macOS 26
# machine the Command Line Tools SwiftPM manifest API is mismatched and cannot
# compile Package.swift, while the Swiftly 6.3.2 toolchain works.
if [[ -f "${HOME}/.swiftly/env.sh" ]]; then
    # shellcheck disable=SC1090
    . "${HOME}/.swiftly/env.sh"
    hash -r 2>/dev/null || true
fi

# Config can come from $1 (positional) OR $CONFIG (env). Env wins so callers
# like make-dmg.sh / release.sh can pipe a value through without juggling args.
CONFIG="${CONFIG:-${1:-debug}}"
QM_DISTRIBUTION="${QM_DISTRIBUTION:-developer-id}"
case "${QM_DISTRIBUTION}" in
    developer-id|app-store) ;;
    *)
        echo "error: QM_DISTRIBUTION must be developer-id or app-store" >&2
        exit 2
        ;;
esac
APP_NAME="QuotaMonitor"
APP_BUNDLE=".build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
PRIVACY_MANIFEST_SOURCE="Resources/PrivacyInfo.xcprivacy"
APP_PRIVACY_MANIFEST="${CONTENTS}/Resources/PrivacyInfo.xcprivacy"
WHATS_NEW_RESOURCES="Resources/WhatsNew"
THIRD_PARTY_NOTICES="THIRD_PARTY_NOTICES.md"
OPSAIL_LICENSE="LICENSES/Opsail-Apache-2.0.txt"
OPSAIL_HELPER_FETCHER="tools/fetch-opsail-helper.sh"
OPSAIL_RENDERER_ASSETS="Vendor/Opsail/Renderer"
ENTITLEMENTS="Resources/QuotaMonitor.entitlements"
if [[ "${QM_DISTRIBUTION}" == "app-store" ]]; then
    ENTITLEMENTS="Resources/QuotaMonitor-AppStore.entitlements"
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
# All package dependencies are public. Disabling SwiftPM's macOS keychain
# credential lookup avoids securityd stalls during binary artifact downloads.
SWIFT_BUILD_FLAGS=(--disable-keychain)

echo "==> swift build -c ${CONFIG} (${QM_DISTRIBUTION})"
swift build -c "${CONFIG}" "${SWIFT_BUILD_FLAGS[@]}"

BIN_DIR="$(swift build -c "${CONFIG}" "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
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

if [[ ! -f "${WHATS_NEW_RESOURCES}/catalog.json" ]]; then
    echo "error: ${WHATS_NEW_RESOURCES}/catalog.json missing" >&2
    exit 1
fi
echo "==> Embedding What's New media"
cp -R "${WHATS_NEW_RESOURCES}" "${CONTENTS}/Resources/WhatsNew"

if [[ ! -f "${THIRD_PARTY_NOTICES}" || ! -f "${OPSAIL_LICENSE}" ]]; then
    echo "error: third-party notices or Opsail license missing" >&2
    exit 1
fi
echo "==> Embedding third-party notices"
mkdir -p "${CONTENTS}/Resources/Licenses"
cp "${THIRD_PARTY_NOTICES}" "${CONTENTS}/Resources/THIRD_PARTY_NOTICES.md"
cp "${OPSAIL_LICENSE}" "${CONTENTS}/Resources/Licenses/Opsail-Apache-2.0.txt"

if [[ "${QM_DISTRIBUTION}" == "developer-id" ]]; then
    if [[ ! -x "${OPSAIL_HELPER_FETCHER}" ]]; then
        echo "error: ${OPSAIL_HELPER_FETCHER} missing or not executable" >&2
        exit 1
    fi
    echo "==> Embedding verified Opsail helper"
    OPSAIL_HELPER_SOURCE="$("${OPSAIL_HELPER_FETCHER}")"
    if [[ ! -x "${OPSAIL_HELPER_SOURCE}" ]]; then
        echo "error: verified Opsail helper is unavailable" >&2
        exit 1
    fi
    mkdir -p "${CONTENTS}/Helpers"
    cp "${OPSAIL_HELPER_SOURCE}" "${CONTENTS}/Helpers/opsail"
    chmod 755 "${CONTENTS}/Helpers/opsail"
    if [[ ! -f "${OPSAIL_RENDERER_ASSETS}/manifest.json" ]]; then
        echo "error: ${OPSAIL_RENDERER_ASSETS}/manifest.json missing" >&2
        exit 1
    fi
    echo "==> Embedding QuotaMonitor Opsail renderer assets"
    cp -R "${OPSAIL_RENDERER_ASSETS}" "${CONTENTS}/Resources/OpsailRenderer"
fi

echo "==> Verifying and embedding PrivacyInfo.xcprivacy"
python3 tools/verify-privacy-manifest.py "${PRIVACY_MANIFEST_SOURCE}"
cp "${PRIVACY_MANIFEST_SOURCE}" "${APP_PRIVACY_MANIFEST}"
python3 tools/verify-privacy-manifest.py "${APP_PRIVACY_MANIFEST}"
if ! cmp -s "${PRIVACY_MANIFEST_SOURCE}" "${APP_PRIVACY_MANIFEST}"; then
    echo "error: bundled privacy manifest differs from source" >&2
    exit 1
fi

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
QM_RELEASE_CHANNEL="${QM_RELEASE_CHANNEL:-stable}"
if [[ "${QM_DISTRIBUTION}" == "app-store" \
      && "${QM_RELEASE_CHANNEL}" != "stable" ]]; then
    echo "error: App Store builds support only the stable release channel" >&2
    exit 1
fi
if [[ "${QM_RELEASE_CHANNEL}" == "private-beta" ]]; then
    if [[ -z "${QM_BETA_SEQUENCE:-}" ]]; then
        echo "error: QM_BETA_SEQUENCE is required for private-beta builds" >&2
        exit 1
    fi
    BUILD_NUMBER="$(python3 tools/build-number.py "${VERSION}" \
        --channel private-beta --beta-sequence "${QM_BETA_SEQUENCE}")"
    DISPLAY_VERSION="${VERSION}-beta.${QM_BETA_SEQUENCE}"
elif [[ "${QM_RELEASE_CHANNEL}" == "stable" ]]; then
    BUILD_NUMBER="$(python3 tools/build-number.py "${VERSION}" --channel stable)"
    DISPLAY_VERSION="${VERSION}"
else
    echo "error: QM_RELEASE_CHANNEL must be stable or private-beta" >&2
    exit 1
fi
if [[ "${QM_DISTRIBUTION}" == "app-store" ]]; then
    # Apple's first CFBundleVersion component is limited to four digits.
    # The App Store owns update ordering, so retain the existing conforming
    # dotted semantic build number instead of Sparkle's single integer.
    BUILD_NUMBER="${VERSION}"
fi
# CFBundleShortVersionString remains the user-facing semantic version.
# CFBundleVersion is an independent numeric Sparkle ordering key computed by
# tools/build-number.py for Developer ID builds. A stable build reserves offset
# 9000, so it always supersedes every Private Beta (1...8999) for the same
# semantic version. App Store builds retain a conforming dotted value.
#
# Git SHA traceability is preserved separately under the custom key
# `BuildCommit` (see below) — readable via `defaults read` or
# PlistBuddy without leaking into Sparkle's comparison path.
BUILD_TAG="$(git -C "$(pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${DISPLAY_VERSION}" \
    "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
    "${CONTENTS}/Info.plist"
# Add or overwrite the BuildCommit key. `Add` errors out if the key
# already exists (e.g. when re-running build.sh against the same
# Info.plist), so fall through to `Set` in that case.
/usr/libexec/PlistBuddy -c "Add :BuildCommit string ${BUILD_TAG}" \
    "${CONTENTS}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :BuildCommit ${BUILD_TAG}" \
    "${CONTENTS}/Info.plist"
echo "    version=${DISPLAY_VERSION} build=${BUILD_NUMBER} commit=${BUILD_TAG}"

/usr/libexec/PlistBuddy -c "Add :QMDistributionChannel string ${QM_DISTRIBUTION}" \
    "${CONTENTS}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :QMDistributionChannel ${QM_DISTRIBUTION}" \
    "${CONTENTS}/Info.plist"

if [[ "${QM_DISTRIBUTION}" == "app-store" ]]; then
    # The Mac App Store must deliver updates through the store. Keep the
    # self-hosted Sparkle identity in the source plist for Developer ID builds,
    # but remove it from this assembled smoke artifact.
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" \
        "${CONTENTS}/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" \
        "${CONTENTS}/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" \
        "${CONTENTS}/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUScheduledCheckInterval" \
        "${CONTENTS}/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUEnableInstallerLauncherService" \
        "${CONTENTS}/Info.plist" 2>/dev/null || true
fi
echo "    distribution=${QM_DISTRIBUTION}"

# Inject branding display name and code name from Branding.swift.
# Mirrors the version injection pattern above — the source Info.plist
# ships placeholders that are obviously wrong if this step is skipped.
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${BRAND_DISPLAY}" \
    "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${BRAND_CODE}" \
    "${CONTENTS}/Info.plist"
echo "    brand=${BRAND_DISPLAY} (${BRAND_CODE})"

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"
else
    echo "warning: Resources/AppIcon.icns missing — run tools/make-icon.sh" >&2
fi

# Binary rpath fixup
# ------------------
# SwiftPM's executable target ships with `@loader_path` as its only
# LC_RPATH, which dyld resolves to Contents/MacOS/ at runtime. That's
# wrong for our manual bundle layout where frameworks live in
# Contents/Frameworks/. Without this fixup the app SIGABRTs on launch
# with `Library not loaded: @rpath/Sparkle.framework/...`. We add the
# standard `@executable_path/../Frameworks` rpath so dyld can resolve
# embedded frameworks (Sparkle today, anything else we add later).
#
# Must happen BEFORE codesign — install_name_tool rewrites a Mach-O
# load command, which invalidates the existing signature; codesign
# below stamps a fresh one over the modified binary.
echo "==> install_name_tool: add @executable_path/../Frameworks rpath"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${CONTENTS}/MacOS/${APP_NAME}" 2>/dev/null || true

# Sparkle.framework embedding
# ----------------------------
# SwiftPM links the Sparkle dylib at build time but won't place the
# framework's runtime payload (Autoupdate.app, XPCServices/) inside our
# .app bundle — that's an Xcode-target thing. We do it by hand: copy
# the resolved xcframework's macos slice into Contents/Frameworks/.
# Without this, Sparkle crashes the moment it tries to spawn its
# installer subprocess (the user clicks "Install Update" and nothing
# happens, or worse, the app SIGABRTs).
#
# `swift package resolve` must have run first so the xcframework is on
# disk. `build.sh` runs `swift build` above, which implies a resolve.
SPARKLE_XCFW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework"
SPARKLE_SLICE="${SPARKLE_XCFW}/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "${SPARKLE_SLICE}" ]]; then
    echo "==> Embedding Sparkle.framework"
    if [[ "${QM_DISTRIBUTION}" == "app-store" ]]; then
        echo "    app-store: Sparkle runtime is disabled by QMDistributionChannel"
    fi
    mkdir -p "${CONTENTS}/Frameworks"
    rm -rf "${CONTENTS}/Frameworks/Sparkle.framework"
    # -R preserves the framework's internal symlinks (Versions/B/...).
    cp -R "${SPARKLE_SLICE}" "${CONTENTS}/Frameworks/Sparkle.framework"
else
    echo "warning: ${SPARKLE_SLICE} not found — Sparkle.framework will" >&2
    echo "         be missing from the .app. Auto-update will crash on first use." >&2
    echo "         Did 'swift build' finish without resolving Sparkle?" >&2
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
CODESIGN_ARGS=(--force --deep)
if [[ "${QM_DISTRIBUTION}" == "app-store" ]]; then
    CODESIGN_ARGS+=(--options runtime --entitlements "${ENTITLEMENTS}")
fi
if security find-identity -v -p codesigning 2>/dev/null \
        | grep -q " \"${SIGN_IDENTITY}\""; then
    echo "==> codesign with '${SIGN_IDENTITY}'"
    codesign "${CODESIGN_ARGS[@]}" --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "==> Ad-hoc codesign (identity '${SIGN_IDENTITY}' not found)"
    codesign "${CODESIGN_ARGS[@]}" --sign - "${APP_BUNDLE}"
fi

echo "==> Done: ${APP_BUNDLE}"
echo "Run with: open '${APP_BUNDLE}'"
