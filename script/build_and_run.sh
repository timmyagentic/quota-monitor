#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="QuotaMonitor"
BUNDLE_ID="dev.tjzhou.QuotaMonitor"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/.build/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
# shellcheck source=../qa/lib/common.sh
. "${ROOT_DIR}/qa/lib/common.sh"

usage() {
    cat >&2 <<EOF
usage: $0 [run|--debug|--logs|--telemetry|--verify|--qa]
EOF
}

stop_running_app() {
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
    (cd "$ROOT_DIR" && ./build.sh debug)
}

prepare_qa_launch_bundle() {
    local qa_bundle="${QUOTAMONITOR_QA_APP_BUNDLE:-}"
    [[ -n "$qa_bundle" ]] || return 0
    [[ "$qa_bundle" != "$APP_BUNDLE" ]] || return 0

    rm -rf "$qa_bundle"
    mkdir -p "$(dirname "$qa_bundle")"
    /usr/bin/ditto "$APP_BUNDLE" "$qa_bundle"
}

open_app() {
    local open_args=(-n)
    local app_args=()
    local launch_bundle="${QUOTAMONITOR_QA_APP_BUNDLE:-$APP_BUNDLE}"
    if [[ -n "${QUOTAMONITOR_QA_CONFIG:-}" ]]; then
        local config_payload
        config_payload="$(base64 <"$QUOTAMONITOR_QA_CONFIG" | tr -d '\n')"
        app_args+=(--quotamonitor-qa-config-base64 "$config_payload")
    fi
    if [[ "${#app_args[@]}" -gt 0 ]]; then
        /usr/bin/open "${open_args[@]}" "$launch_bundle" --args "${app_args[@]}"
    else
        /usr/bin/open "${open_args[@]}" "$launch_bundle"
    fi
}

verify_process() {
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
}

verify_qa_process() {
    sleep 2
    qm_local_qa_process_running
}

qa_launch_requests_quit() {
    if [[ -n "${QUOTAMONITOR_QA_STEPS:-}" ]] \
        && qm_steps_include_quit "$QUOTAMONITOR_QA_STEPS"; then
        return 0
    fi
    [[ -f "${QUOTAMONITOR_QA_CONFIG:-}" ]] || return 1
    /usr/bin/plutil -extract steps json -o - "$QUOTAMONITOR_QA_CONFIG" 2>/dev/null \
        | grep -q '"quit"'
}

case "$MODE" in
    run)
        stop_running_app
        build_app
        open_app
        ;;
    --debug|debug)
        stop_running_app
        build_app
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        stop_running_app
        build_app
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"${APP_NAME}\""
        ;;
    --telemetry|telemetry)
        stop_running_app
        build_app
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
        ;;
    --verify|verify)
        stop_running_app
        build_app
        open_app
        verify_process
        ;;
    --qa|qa)
        : "${QUOTAMONITOR_QA_CONFIG:?QUOTAMONITOR_QA_CONFIG is required for --qa}"
        [[ -f "$QUOTAMONITOR_QA_CONFIG" ]] || {
            echo "error: QA config not found: $QUOTAMONITOR_QA_CONFIG" >&2
            exit 1
        }
        qm_stop_local_qa_processes
        build_app
        prepare_qa_launch_bundle
        open_app
        if ! qa_launch_requests_quit; then
            verify_qa_process
        fi
        ;;
    *)
        usage
        exit 2
        ;;
esac
