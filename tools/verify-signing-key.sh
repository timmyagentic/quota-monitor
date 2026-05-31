#!/usr/bin/env bash
# Verify the Ed25519 signing key matches the app's embedded public key.
#
# The whole self-hosted-Sparkle scheme breaks silently if the key used
# to sign an update isn't the one whose public half is baked into the
# app as SUPublicEDKey: Sparkle downloads the DMG, checks the signature
# against SUPublicEDKey, and rejects it as "improperly signed." That is
# exactly how 0.2.26/0.2.27 broke. This script catches a wrong key
# *before* an appcast ships, by deriving the public key from whatever
# private key is in scope and comparing it to Resources/Info.plist.
#
# Key source, in priority order:
#   1. SPARKLE_PRIVATE_KEY env (CI): the base64 seed `generate_keys -x`
#      exports. Imported into a throwaway Keychain account so its public
#      half can be printed.
#   2. Login Keychain account --account (local maintainer), default
#      "quotamonitor" or $QM_SPARKLE_ACCOUNT.
#
# Exit 0 if they match, non-zero otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

GEN=".build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "${GEN}" ]]; then
    echo "error: ${GEN} not found — run 'swift package resolve' first." >&2
    exit 1
fi

EXPECTED="$(plutil -extract SUPublicEDKey raw Resources/Info.plist)"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "==> Deriving public key from SPARKLE_PRIVATE_KEY (env)"
    KEYF="$(mktemp -u)"
    trap 'rm -f "${KEYF}"' EXIT
    printf '%s' "${SPARKLE_PRIVATE_KEY}" > "${KEYF}"
    # Import into a throwaway account so we never touch the real one.
    # Runners are ephemeral, so the temp Keychain item needs no cleanup.
    ACCT="qm-verify-key-$$"
    "${GEN}" -f "${KEYF}" --account "${ACCT}" >/dev/null
    DERIVED="$("${GEN}" -p --account "${ACCT}")"
else
    ACCT="${QM_SPARKLE_ACCOUNT:-quotamonitor}"
    echo "==> Deriving public key from Keychain account '${ACCT}'"
    DERIVED="$("${GEN}" -p --account "${ACCT}")"
fi

echo "expected (Info.plist SUPublicEDKey): ${EXPECTED}"
echo "derived  (signing key public part):  ${DERIVED}"

if [[ "${DERIVED}" != "${EXPECTED}" ]]; then
    echo "error: signing key does NOT match SUPublicEDKey." >&2
    echo "       Updates signed with it would be rejected as improperly signed." >&2
    exit 1
fi
echo "OK: signing key matches SUPublicEDKey"
