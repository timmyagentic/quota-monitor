#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/static_gate.sh
. "${ROOT_DIR}/qa/lib/static_gate.sh"

FORCE_SWIFT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_SWIFT=1
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./qa/run-static.sh [--force]

Runs the non-GUI static gate. Successful Swift test results are reused when
the code, tests, QA scripts, tool inputs, and Swift toolchain are unchanged.
Use --force for CI or when a fresh full Swift run is explicitly required.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 64
            ;;
    esac
    shift
done

if [[ -f "${HOME}/.swiftly/env.sh" ]]; then
    # shellcheck disable=SC1090
    . "${HOME}/.swiftly/env.sh"
fi

"${ROOT_DIR}/qa/tests/common_tests.sh"
(cd "$ROOT_DIR" && python3 -m unittest discover tools/tests)

VERSION="$(tr -d '[:space:]' <"${ROOT_DIR}/Resources/VERSION")"
(cd "$ROOT_DIR" && python3 tools/validate-release-notes.py "$VERSION" CHANGELOG.md CHANGELOG.zh-Hans.md)

(cd "$ROOT_DIR" && git diff --check HEAD --)

STATE_DIR="${ROOT_DIR}/.build/qa-state"
LOG_DIR="${ROOT_DIR}/.build/qa-logs"
SUCCESS_STAMP="${STATE_DIR}/swift-test-success.env"
mkdir -p "$STATE_DIR" "$LOG_DIR"

SWIFT_FINGERPRINT="$(qm_static_swift_fingerprint "$ROOT_DIR")"
FINGERPRINT_SHORT="${SWIFT_FINGERPRINT:0:12}"

if [[ "$FORCE_SWIFT" -eq 0 ]] && qm_static_cache_matches "$SUCCESS_STAMP" "$SWIFT_FINGERPRINT"; then
    CACHED_AT="$(qm_static_stamp_value "$SUCCESS_STAMP" completed_at)"
    CACHED_LOG="$(qm_static_stamp_value "$SUCCESS_STAMP" log)"
    CACHED_SUMMARY="$(qm_static_stamp_value "$SUCCESS_STAMP" summary)"
    printf 'Swift tests: reused passing result for unchanged inputs (%s; %s)\n' \
        "$FINGERPRINT_SHORT" "$CACHED_SUMMARY"
    printf 'Swift test log: %s (recorded %s)\n' "$CACHED_LOG" "$CACHED_AT"
    printf 'Static gate: passed\n'
    exit 0
fi

if [[ "$FORCE_SWIFT" -eq 1 ]]; then
    printf 'Swift tests: forcing a fresh full suite (%s)\n' "$FINGERPRINT_SHORT"
elif [[ -f "$SUCCESS_STAMP" ]]; then
    printf 'Swift tests: relevant inputs changed; running the full suite (%s)\n' "$FINGERPRINT_SHORT"
else
    printf 'Swift tests: no reusable result; running the full suite (%s)\n' "$FINGERPRINT_SHORT"
fi

rm -f "$SUCCESS_STAMP"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
SWIFT_LOG="${LOG_DIR}/swift-test-${RUN_ID}-${FINGERPRINT_SHORT}.log"

if (cd "$ROOT_DIR" && swift test --disable-keychain) >"$SWIFT_LOG" 2>&1; then
    SWIFT_SUMMARY="$(qm_static_swift_summary "$SWIFT_LOG")"
else
    SWIFT_STATUS=$?
    printf 'Swift tests: failed with exit %s; full log follows (saved at %s)\n' \
        "$SWIFT_STATUS" "$SWIFT_LOG" >&2
    cat "$SWIFT_LOG" >&2
    exit "$SWIFT_STATUS"
fi

POST_SWIFT_FINGERPRINT="$(qm_static_swift_fingerprint "$ROOT_DIR")"
if [[ "$POST_SWIFT_FINGERPRINT" != "$SWIFT_FINGERPRINT" ]]; then
    printf 'Swift tests: inputs changed during the run; result was not cached. Stabilize the worktree and rerun the final gate.\n' >&2
    exit 75
fi

COMPLETED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
HEAD_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
qm_static_write_success_stamp \
    "$SUCCESS_STAMP" \
    "$SWIFT_FINGERPRINT" \
    "$COMPLETED_AT" \
    "$HEAD_COMMIT" \
    "$SWIFT_LOG" \
    "$SWIFT_SUMMARY"

printf 'Swift tests: %s\n' "$SWIFT_SUMMARY"
printf 'Swift test log: %s\n' "$SWIFT_LOG"
printf 'Static gate: passed\n'
