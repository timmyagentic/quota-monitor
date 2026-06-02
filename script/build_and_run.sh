#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="QuotaMonitor"
BUNDLE_ID="dev.tjzhou.QuotaMonitor"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/.build/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

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

open_app() {
    local open_args=(-n)
    local app_args=()
    if [[ -n "${QUOTAMONITOR_QA_CONFIG:-}" ]]; then
        app_args+=(--quotamonitor-qa-config "$QUOTAMONITOR_QA_CONFIG")
    fi
    if [[ "${#app_args[@]}" -gt 0 ]]; then
        /usr/bin/open "${open_args[@]}" "$APP_BUNDLE" --args "${app_args[@]}"
    else
        /usr/bin/open "${open_args[@]}" "$APP_BUNDLE"
    fi
}

verify_process() {
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
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
        stop_running_app
        build_app
        open_app
        verify_process
        ;;
    *)
        usage
        exit 2
        ;;
esac
