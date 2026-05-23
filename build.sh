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
APP_NAME="QuotaMonitor"
APP_BUNDLE=".build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
# All package dependencies are public. Disabling SwiftPM's macOS keychain
# credential lookup avoids securityd stalls during binary artifact downloads.
SWIFT_BUILD_FLAGS=(--disable-keychain)

echo "==> swift build -c ${CONFIG}"
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
# Both CFBundleShortVersionString AND CFBundleVersion get set to
# VERSION (the dotted semver). Sparkle uses CFBundleVersion as the
# "is this newer?" key and compares it against the appcast's
# `sparkle:version` element — if the two don't match exactly, every
# launch shows a spurious "update available" prompt to users who
# already have the latest. We used to stuff the git short SHA into
# CFBundleVersion for traceability, but Sparkle's version comparator
# can't make sense of a hex string vs a dotted version and ends up
# claiming the same release is newer than itself.
#
# Git SHA traceability is preserved separately under the custom key
# `BuildCommit` (see below) — readable via `defaults read` or
# PlistBuddy without leaking into Sparkle's comparison path.
BUILD_TAG="$(git -C "$(pwd)" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" \
    "${CONTENTS}/Info.plist"
# Add or overwrite the BuildCommit key. `Add` errors out if the key
# already exists (e.g. when re-running build.sh against the same
# Info.plist), so fall through to `Set` in that case.
/usr/libexec/PlistBuddy -c "Add :BuildCommit string ${BUILD_TAG}" \
    "${CONTENTS}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :BuildCommit ${BUILD_TAG}" \
    "${CONTENTS}/Info.plist"
echo "    version=${VERSION} commit=${BUILD_TAG}"

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
