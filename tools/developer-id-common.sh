#!/usr/bin/env bash
# Shared helpers for Developer ID signing and notarization scripts.

qm_developer_id_identity_available() {
    local requested="${IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
    if [[ -n "${requested}" ]]; then
        security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${requested}"
    else
        security find-identity -v -p codesigning 2>/dev/null | grep -q '"Developer ID Application'
    fi
}

qm_resolve_developer_id_identity() {
    local requested="${IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
    local identity="${requested}"

    if [[ -z "${identity}" ]]; then
        identity="$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
    fi

    if [[ -z "${identity}" ]]; then
        echo "error: no Developer ID Application identity found." >&2
        echo "       Install/import the certificate or set DEVELOPER_ID_APPLICATION." >&2
        return 1
    fi

    if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${identity}"; then
        echo "error: Developer ID identity not available in keychain: ${identity}" >&2
        return 1
    fi

    QM_DEVELOPER_IDENTITY="${identity}"
}

qm_notary_credentials_available() {
    local explicit_profile="${NOTARYTOOL_PROFILE:-${PROFILE:-}}"
    if [[ -n "${explicit_profile}" ]]; then
        return 0
    fi
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
        return 0
    fi

    local default_profile="${QM_DEFAULT_NOTARY_PROFILE:-quotamonitor-notary}"
    xcrun notarytool history --keychain-profile "${default_profile}" \
        --output-format json >/dev/null 2>&1
}

qm_set_notary_args() {
    QM_NOTARY_ARGS=()

    local profile="${NOTARYTOOL_PROFILE:-${PROFILE:-}}"
    if [[ -n "${profile}" ]]; then
        QM_NOTARY_ARGS=(--keychain-profile "${profile}")
        return 0
    fi

    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
        QM_NOTARY_ARGS=(
            --apple-id "${APPLE_ID}"
            --team-id "${APPLE_TEAM_ID}"
            --password "${APPLE_APP_SPECIFIC_PASSWORD}"
        )
        return 0
    fi

    local default_profile="${QM_DEFAULT_NOTARY_PROFILE:-quotamonitor-notary}"
    if xcrun notarytool history --keychain-profile "${default_profile}" \
        --output-format json >/dev/null 2>&1; then
        QM_NOTARY_ARGS=(--keychain-profile "${default_profile}")
        return 0
    fi

    echo "error: notarization credentials missing." >&2
    echo "       Set NOTARYTOOL_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD." >&2
    return 1
}

qm_developer_id_release_available() {
    qm_developer_id_identity_available && qm_notary_credentials_available
}
