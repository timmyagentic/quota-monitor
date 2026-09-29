#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT_DIR}/qa/lib/static_gate.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }


test_static_swift_fingerprint_uses_current_relevant_content() {
    local dir baseline unchanged docs_changed source_changed committed restored tests_changed qa_changed
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-static-fingerprint.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    mkdir -p "$dir/QuotaMonitor" "$dir/Tests" "$dir/qa" "$dir/docs"
    printf '// package\n' >"$dir/Package.swift"
    printf '// source v1\n' >"$dir/QuotaMonitor/Feature.swift"
    printf '// test v1\n' >"$dir/Tests/FeatureTests.swift"
    printf '#!/usr/bin/env bash\n' >"$dir/qa/check.sh"
    chmod +x "$dir/qa/check.sh"
    printf 'documentation v1\n' >"$dir/docs/note.md"

    git init -q "$dir"
    git -C "$dir" config user.email qa@example.invalid
    git -C "$dir" config user.name "QA Test"
    git -C "$dir" add .
    git -C "$dir" commit -q -m baseline

    baseline="$(qm_static_swift_fingerprint "$dir")"
    unchanged="$(qm_static_swift_fingerprint "$dir")"
    [[ "$unchanged" == "$baseline" ]] \
        || fail "unchanged Swift inputs changed fingerprint"

    printf 'documentation v2\n' >"$dir/docs/note.md"
    docs_changed="$(qm_static_swift_fingerprint "$dir")"
    [[ "$docs_changed" == "$baseline" ]] \
        || fail "documentation-only edit invalidated Swift result"

    printf '// source v2\n' >"$dir/QuotaMonitor/Feature.swift"
    source_changed="$(qm_static_swift_fingerprint "$dir")"
    [[ "$source_changed" != "$baseline" ]] \
        || fail "source edit did not invalidate Swift result"

    git -C "$dir" add QuotaMonitor/Feature.swift
    git -C "$dir" commit -q -m source-v2
    committed="$(qm_static_swift_fingerprint "$dir")"
    [[ "$committed" == "$source_changed" ]] \
        || fail "staging or committing unchanged content invalidated Swift result"

    printf '// source v1\n' >"$dir/QuotaMonitor/Feature.swift"
    restored="$(qm_static_swift_fingerprint "$dir")"
    [[ "$restored" == "$baseline" ]] \
        || fail "restoring exact source content did not restore fingerprint"

    printf '// test v2\n' >"$dir/Tests/FeatureTests.swift"
    tests_changed="$(qm_static_swift_fingerprint "$dir")"
    [[ "$tests_changed" != "$baseline" ]] \
        || fail "test edit did not invalidate Swift result"
    printf '// test v1\n' >"$dir/Tests/FeatureTests.swift"

    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/qa/new-check.sh"
    chmod +x "$dir/qa/new-check.sh"
    qa_changed="$(qm_static_swift_fingerprint "$dir")"
    [[ "$qa_changed" != "$baseline" ]] \
        || fail "untracked QA script did not invalidate Swift result"
}

test_static_success_cache_round_trip() {
    local dir stamp log fingerprint summary
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-static-cache.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN
    stamp="$dir/state/swift-test-success.env"
    log="$dir/swift-test.log"
    fingerprint="abc123"
    summary="12 tests in 3 suites passed after 0.2 seconds."
    printf 'full Swift output\n' >"$log"

    qm_static_write_success_stamp \
        "$stamp" \
        "$fingerprint" \
        "2026-08-10T00:00:00Z" \
        "deadbeef" \
        "$log" \
        "$summary"

    qm_static_cache_matches "$stamp" "$fingerprint" \
        || fail "matching Swift success cache was not reusable"
    [[ "$(qm_static_stamp_value "$stamp" summary)" == "$summary" ]] \
        || fail "cached Swift summary was not preserved"
    if qm_static_cache_matches "$stamp" "different"; then
        fail "different fingerprint reused Swift success cache"
    fi

    mv "$log" "$log.moved"
    if qm_static_cache_matches "$stamp" "$fingerprint"; then
        fail "missing full Swift log still reused success cache"
    fi
}

test_static_swift_summary_extracts_concise_result() {
    local dir log summary
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-static-summary.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN
    log="$dir/swift-test.log"
    {
        printf 'thousands of build lines omitted\n'
        printf '✔ Test run with 897 tests in 116 suites passed after 10.335 seconds.\n'
    } >"$log"

    summary="$(qm_static_swift_summary "$log")"
    [[ "$summary" == "897 tests in 116 suites passed after 10.335 seconds." ]] \
        || fail "unexpected Swift summary: $summary"
}

test_static_swift_fingerprint_uses_current_relevant_content
test_static_success_cache_round_trip
test_static_swift_summary_extracts_concise_result
echo "static_gate_tests: ok"
