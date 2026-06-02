#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "${ROOT_DIR}/qa/lib/common.sh"

qm_require_command defaults
qm_require_command sqlite3
qm_require_command plutil

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_ROOT="${QM_QA_WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/quotamonitor-computer-qa.XXXXXX")}"
QA_HOME="${WORK_ROOT}/home"
ARTIFACTS="${QM_QA_ARTIFACTS:-${ROOT_DIR}/.build/qa-artifacts/${RUN_ID}-interactive}"
APP_ARTIFACTS="$(qm_app_artifacts_dir "$QA_HOME")"
DEFAULTS_SUITE="${QM_QA_DEFAULTS_SUITE:-dev.tjzhou.QuotaMonitor.ComputerQA.${RUN_ID}.$$}"
STATE_JSON="${APP_ARTIFACTS}/app-state.json"
DB_PATH="${QA_HOME}/Library/Application Support/QuotaMonitor/quotamonitor.sqlite"
DEV_LOG="${QA_HOME}/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log"
QA_CONFIG="${ARTIFACTS}/qa-config.json"
QA_STEPS="${QUOTAMONITOR_QA_STEPS:-$(qm_interactive_steps)}"
BRIEF="${ARTIFACTS}/computer-use-qa.md"
CLEANUP_SCRIPT="${ARTIFACTS}/cleanup-interactive.sh"

mkdir -p "$QA_HOME" "$ARTIFACTS" "$APP_ARTIFACTS"
qm_write_interactive_cleanup "$CLEANUP_SCRIPT" "$WORK_ROOT" "$QA_HOME" "$DEFAULTS_SUITE"
qm_write_defaults "$QA_HOME" "$DEFAULTS_SUITE"
qm_seed_fixtures "$QA_HOME"

export CODEX_HOME="$QA_HOME/.codex"
qm_write_launch_config \
    "$QA_CONFIG" \
    "$QA_HOME" \
    "$DEFAULTS_SUITE" \
    "$APP_ARTIFACTS" \
    "$QA_STEPS" \
    "$CODEX_HOME"
plutil -convert json -o /dev/null "$QA_CONFIG" >/dev/null

export QUOTAMONITOR_QA_CONFIG="$QA_CONFIG"

"${ROOT_DIR}/script/build_and_run.sh" --qa

qm_retry_until 30 1 test -f "$STATE_JSON" || {
    echo "error: QA state was not written: $STATE_JSON" >&2
    exit 1
}
cp "$STATE_JSON" "${ARTIFACTS}/app-state.json"

db_has_usage() {
    [[ -f "$DB_PATH" ]] || return 1
    local counts
    counts="$(sqlite3 "$DB_PATH" "SELECT (SELECT COUNT(*) FROM sessions), (SELECT COUNT(*) FROM usage_events), (SELECT COUNT(*) FROM rate_limit_samples);")"
    IFS='|' read -r sessions events samples <<<"$counts"
    [[ "${sessions:-0}" -gt 0 && "${events:-0}" -gt 0 && "${samples:-0}" -gt 0 ]]
}

qm_retry_until 30 1 db_has_usage || {
    echo "error: QA database did not import expected fixture data: $DB_PATH" >&2
    exit 1
}

sqlite3 "$DB_PATH" <<SQL >"${ARTIFACTS}/db-counts.txt"
.headers on
.mode column
SELECT provider, COUNT(*) AS sessions FROM sessions GROUP BY provider ORDER BY provider;
SELECT provider, COUNT(*) AS events, SUM(total_tokens) AS tokens FROM usage_events GROUP BY provider ORDER BY provider;
SELECT source_kind, bucket, COUNT(*) AS samples FROM rate_limit_samples GROUP BY source_kind, bucket ORDER BY source_kind, bucket;
SQL

dev_log_has_qa_events() {
    [[ -f "$DEV_LOG" ]] || return 1
    grep -q '"event":"qa.settings.exercise"' "$DEV_LOG" || return 1
    grep -q '"event":"qa.snapshot.write"' "$DEV_LOG" || return 1
}

qm_retry_until 20 0.5 dev_log_has_qa_events || {
    echo "error: QA Developer Mode log did not record expected QA events: $DEV_LOG" >&2
    exit 1
}

if [[ -f "$DEV_LOG" ]]; then
    cp "$DEV_LOG" "${ARTIFACTS}/quotamonitor-dev.log"
fi

if command -v screencapture >/dev/null 2>&1; then
    screencapture -x "${ARTIFACTS}/screen.png" >/dev/null 2>&1 || {
        echo "warning: screencapture failed; Screen Recording permission may be missing" \
            >"${ARTIFACTS}/screen-capture-warning.txt"
    }
fi

if command -v osascript >/dev/null 2>&1; then
    if ! osascript "${ROOT_DIR}/qa/dump-ui.applescript" "${ARTIFACTS}/ax-tree.txt" \
        >"${ARTIFACTS}/ax-dump.stdout" 2>"${ARTIFACTS}/ax-dump.stderr"; then
        if [[ "${QM_QA_REQUIRE_AX:-0}" == "1" ]]; then
            echo "error: Accessibility AX dump failed; grant Terminal/Codex Accessibility access" >&2
            cat "${ARTIFACTS}/ax-dump.stderr" >&2 || true
            exit 1
        fi
        echo "warning: AX dump failed; set QM_QA_REQUIRE_AX=1 to make this fatal" \
            >"${ARTIFACTS}/ax-dump-warning.txt"
    else
        qm_warn_incomplete_ax_snapshot "$ARTIFACTS"
    fi
fi

qm_assert_artifact_contract "$ARTIFACTS"
qm_write_computer_qa_brief "$BRIEF" "$ARTIFACTS" "$QA_HOME" "$DEFAULTS_SUITE" "$ROOT_DIR"

cat <<EOF
Interactive QA app is running.
QA artifacts: $ARTIFACTS
Computer Use brief: $BRIEF
Cleanup command: $CLEANUP_SCRIPT
EOF
