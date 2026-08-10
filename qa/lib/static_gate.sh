#!/usr/bin/env bash

QM_STATIC_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

qm_static_swift_fingerprint() {
    python3 "${QM_STATIC_GATE_LIB_DIR}/static_gate_fingerprint.py" "$1"
}

qm_static_stamp_value() {
    local stamp="$1"
    local key="$2"

    [[ -f "$stamp" ]] || return 1
    awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$stamp"
}

qm_static_cache_matches() {
    local stamp="$1"
    local fingerprint="$2"
    local cached_log

    [[ "$(qm_static_stamp_value "$stamp" schema || true)" == "1" ]] || return 1
    [[ "$(qm_static_stamp_value "$stamp" fingerprint || true)" == "$fingerprint" ]] || return 1
    cached_log="$(qm_static_stamp_value "$stamp" log || true)"
    [[ -n "$cached_log" && -f "$cached_log" ]] || return 1
    [[ -n "$(qm_static_stamp_value "$stamp" summary || true)" ]] || return 1
}

qm_static_write_success_stamp() {
    local stamp="$1"
    local fingerprint="$2"
    local completed_at="$3"
    local head="$4"
    local log="$5"
    local summary="$6"
    local temporary_stamp

    mkdir -p "$(dirname "$stamp")"
    temporary_stamp="${stamp}.$$"
    (
        umask 077
        {
            printf 'schema=1\n'
            printf 'fingerprint=%s\n' "$fingerprint"
            printf 'completed_at=%s\n' "$completed_at"
            printf 'head=%s\n' "$head"
            printf 'log=%s\n' "$log"
            printf 'summary=%s\n' "$summary"
        } >"$temporary_stamp"
    )
    mv "$temporary_stamp" "$stamp"
}

qm_static_swift_summary() {
    local log="$1"
    local summary

    summary="$(grep -E 'Test run with [0-9]+ tests?.*passed after' "$log" | tail -n 1 || true)"
    if [[ -n "$summary" ]]; then
        summary="${summary#*Test run with }"
        printf '%s\n' "$summary"
        return
    fi

    summary="$(grep -E 'Executed [0-9]+ tests?, with 0 failures' "$log" | tail -n 1 || true)"
    if [[ -n "$summary" ]]; then
        printf '%s\n' "$summary" | sed 's/^[[:space:]]*//'
        return
    fi

    printf 'passed; summary unavailable\n'
}
