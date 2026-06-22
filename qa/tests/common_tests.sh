#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "${ROOT_DIR}/qa/lib/common.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

test_write_defaults() {
    local home
    home="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-defaults.XXXXXX")"
    local domain="dev.tjzhou.QuotaMonitor.QATest.$RANDOM.$$"
    trap 'HOME="$home" defaults delete "$domain" >/dev/null 2>&1 || true; rm -rf "$home"' RETURN

    qm_write_defaults "$home" "$domain"

    local language developer_mode keychain_policy providers_done
    language="$(HOME="$home" defaults read "$domain" app.language)"
    developer_mode="$(HOME="$home" defaults read "$domain" settings.developerModeEnabled)"
    keychain_policy="$(HOME="$home" defaults read "$domain" settings.keychainPolicy)"
    providers_done="$(HOME="$home" defaults read "$domain" onboarding.providersDone)"

    [[ "$language" == "en" ]] || fail "language default was $language"
    [[ "$developer_mode" == "1" ]] || fail "developer mode default was $developer_mode"
    [[ "$keychain_policy" == "fallback" ]] || fail "keychain policy default was $keychain_policy"
    [[ "$providers_done" == "1" ]] || fail "provider onboarding default was $providers_done"
}

test_refuses_installed_app_defaults_suite() {
    local source_home target_home source_domain report cleanup
    source_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-source-prod-guard.XXXXXX")"
    target_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-target-prod-guard.XXXXXX")"
    source_domain="dev.tjzhou.QuotaMonitor.SourceTest.$RANDOM.$$"
    report="$target_home/user-defaults-shadow.txt"
    cleanup="$target_home/cleanup.sh"
    trap 'HOME="$source_home" defaults delete "$source_domain" >/dev/null 2>&1 || true; HOME="$target_home" defaults delete dev.tjzhou.QuotaMonitor >/dev/null 2>&1 || true; rm -rf "$source_home" "$target_home"' RETURN

    HOME="$source_home" defaults write "$source_domain" app.language -string en

    if qm_write_defaults "$target_home" "dev.tjzhou.QuotaMonitor" >/dev/null 2>&1; then
        fail "qm_write_defaults accepted the installed app defaults suite"
    fi
    if qm_copy_user_defaults_to_qa_suite \
        "$source_home" \
        "$target_home" \
        "$source_domain" \
        "dev.tjzhou.QuotaMonitor" >/dev/null 2>&1; then
        fail "qm_copy_user_defaults_to_qa_suite accepted the installed app defaults suite"
    fi
    if qm_write_real_data_defaults \
        "$target_home" \
        "dev.tjzhou.QuotaMonitor" \
        "$source_home" \
        "$source_domain" \
        "$report" >/dev/null 2>&1; then
        fail "qm_write_real_data_defaults accepted the installed app defaults suite"
    fi
    if [[ -f "$report" ]]; then
        fail "qm_write_real_data_defaults wrote a report after rejecting the installed app defaults suite"
    fi
    if qm_write_computer_use_cleanup \
        "$cleanup" \
        "$target_home/work" \
        "$target_home/home" \
        "dev.tjzhou.QuotaMonitor" >/dev/null 2>&1; then
        fail "qm_write_computer_use_cleanup accepted the installed app defaults suite"
    fi
    if [[ -f "$cleanup" ]]; then
        fail "qm_write_computer_use_cleanup wrote a cleanup script for the installed app defaults suite"
    fi
}

test_accepts_custom_qa_defaults_suite() {
    local home domain
    home="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-custom-suite.XXXXXX")"
    domain="dev.tjzhou.QuotaMonitor.LocalQA.$RANDOM.$$"
    trap 'HOME="$home" defaults delete "$domain" >/dev/null 2>&1 || true; rm -rf "$home"' RETURN

    qm_write_defaults "$home" "$domain"

    local language
    language="$(HOME="$home" defaults read "$domain" app.language)"
    [[ "$language" == "en" ]] || fail "custom QA defaults suite was not written: $language"
}

test_write_defaults_accepts_language_override() {
    local home domain
    home="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-language.XXXXXX")"
    domain="dev.tjzhou.QuotaMonitor.LanguageQA.$RANDOM.$$"
    trap 'HOME="$home" defaults delete "$domain" >/dev/null 2>&1 || true; rm -rf "$home"' RETURN

    QM_QA_LANGUAGE=zh-Hans qm_write_defaults "$home" "$domain"

    local language
    language="$(HOME="$home" defaults read "$domain" app.language)"
    [[ "$language" == "zh-Hans" ]] || fail "language override was $language"
}

test_write_real_data_defaults_copies_user_preferences_without_overrides() {
    local source_home target_home source_domain target_domain report
    source_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-source-defaults.XXXXXX")"
    target_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-target-defaults.XXXXXX")"
    source_domain="dev.tjzhou.QuotaMonitor.SourceTest.$RANDOM.$$"
    target_domain="dev.tjzhou.QuotaMonitor.TargetTest.$RANDOM.$$"
    report="$target_home/user-defaults-shadow.txt"
    trap 'HOME="$source_home" defaults delete "$source_domain" >/dev/null 2>&1 || true; HOME="$target_home" defaults delete "$target_domain" >/dev/null 2>&1 || true; rm -rf "$source_home" "$target_home"' RETURN

    HOME="$source_home" defaults write "$source_domain" app.language -string zh-Hans
    HOME="$source_home" defaults write "$source_domain" settings.enabledProviders -array codex
    HOME="$source_home" defaults write "$source_domain" settings.menuBarIconProviders -array codex
    HOME="$source_home" defaults write "$source_domain" settings.keychainPolicy -string fallback
    HOME="$source_home" defaults write "$source_domain" settings.developerModeEnabled -bool false
    HOME="$source_home" defaults write "$source_domain" settings.mirrorClaudeKeychainToFile -bool true

    qm_write_real_data_defaults \
        "$target_home" \
        "$target_domain" \
        "$source_home" \
        "$source_domain" \
        "$report" \
        1

    local language keychain_policy developer_mode mirror_to_file providers icons
    language="$(HOME="$target_home" defaults read "$target_domain" app.language)"
    keychain_policy="$(HOME="$target_home" defaults read "$target_domain" settings.keychainPolicy)"
    developer_mode="$(HOME="$target_home" defaults read "$target_domain" settings.developerModeEnabled)"
    mirror_to_file="$(HOME="$target_home" defaults read "$target_domain" settings.mirrorClaudeKeychainToFile)"
    providers="$(HOME="$target_home" defaults read "$target_domain" settings.enabledProviders)"
    icons="$(HOME="$target_home" defaults read "$target_domain" settings.menuBarIconProviders)"

    [[ "$language" == "zh-Hans" ]] || fail "copied language was $language"
    grep -q 'codex' <<<"$providers" || fail "copied enabled provider missing: $providers"
    grep -q 'codex' <<<"$icons" || fail "copied menu-bar icon provider missing: $icons"
    [[ "$keychain_policy" == "fallback" ]] || fail "copied keychain policy was $keychain_policy"
    [[ "$developer_mode" == "0" ]] || fail "copied developer mode was $developer_mode"
    [[ "$mirror_to_file" == "1" ]] || fail "copied mirror-to-file was $mirror_to_file"
    grep -q '^copied_user_defaults=true$' "$report" \
        || fail "user defaults report did not record copied_user_defaults=true"
    grep -q '^qa_overrides=none$' "$report" \
        || fail "real-data defaults should not record QA overrides"
    grep -q '^safety_overrides=none$' "$report" \
        || fail "real-data defaults should not apply product-setting overrides"
}

test_write_real_data_defaults_accepts_language_override() {
    local source_home target_home source_domain target_domain report
    source_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-source-language-override.XXXXXX")"
    target_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-target-language-override.XXXXXX")"
    source_domain="dev.tjzhou.QuotaMonitor.SourceLanguageTest.$RANDOM.$$"
    target_domain="dev.tjzhou.QuotaMonitor.TargetLanguageTest.$RANDOM.$$"
    report="$target_home/user-defaults-shadow.txt"
    trap 'HOME="$source_home" defaults delete "$source_domain" >/dev/null 2>&1 || true; HOME="$target_home" defaults delete "$target_domain" >/dev/null 2>&1 || true; rm -rf "$source_home" "$target_home"' RETURN

    HOME="$source_home" defaults write "$source_domain" app.language -string en
    HOME="$source_home" defaults write "$source_domain" settings.enabledProviders -array codex

    QM_QA_LANGUAGE=zh-Hans qm_write_real_data_defaults \
        "$target_home" \
        "$target_domain" \
        "$source_home" \
        "$source_domain" \
        "$report"

    local language providers
    language="$(HOME="$target_home" defaults read "$target_domain" app.language)"
    providers="$(HOME="$target_home" defaults read "$target_domain" settings.enabledProviders)"

    [[ "$language" == "zh-Hans" ]] || fail "real-data language override was $language"
    grep -q 'codex' <<<"$providers" || fail "copied enabled provider missing after override: $providers"
    grep -q '^copied_user_defaults=true$' "$report" \
        || fail "language override report did not record copied_user_defaults=true"
    grep -q '^qa_overrides=app.language=zh-Hans$' "$report" \
        || fail "language override report did not record app.language override"
    grep -q '^safety_overrides=none$' "$report" \
        || fail "language override should not change safety overrides"
}

test_write_real_data_defaults_fails_when_user_preferences_cannot_be_copied() {
    local source_home target_home source_domain target_domain report
    source_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-source-defaults-missing.XXXXXX")"
    target_home="$(mktemp -d "${TMPDIR:-/tmp}/qm-target-defaults-missing.XXXXXX")"
    source_domain="dev.tjzhou.QuotaMonitor.MissingSourceTest.$RANDOM.$$"
    target_domain="dev.tjzhou.QuotaMonitor.MissingTargetTest.$RANDOM.$$"
    report="$target_home/user-defaults-shadow.txt"
    trap 'HOME="$target_home" defaults delete "$target_domain" >/dev/null 2>&1 || true; rm -rf "$source_home" "$target_home"' RETURN

    if qm_write_real_data_defaults \
        "$target_home" \
        "$target_domain" \
        "$source_home" \
        "$source_domain" \
        "$report"; then
        fail "real-data defaults silently fell back when user preferences were missing"
    fi

    grep -q '^copied_user_defaults=false$' "$report" \
        || fail "failed copy report did not record copied_user_defaults=false"
    if HOME="$target_home" defaults read "$target_domain" settings.developerModeEnabled >/dev/null 2>&1; then
        fail "real-data defaults wrote fallback QA settings after copy failure"
    fi
}

test_seed_fixtures() {
    local home
    home="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-fixtures.XXXXXX")"
    trap 'rm -rf "$home"' RETURN

    qm_seed_fixtures "$home"

    assert_file "$home/.codex/session_index.jsonl"
    assert_file "$home/.codex/sessions/qa/rollout-2026-06-01T00-00-00-019aa0fd-1111-7000-8000-aaaaaaaaaaaa.jsonl"
    assert_file "$home/.codex/sessions/qa/rollout-2026-06-01T00-03-00-019aa0fd-2222-7000-8000-bbbbbbbbbbbb.jsonl"
    assert_file "$home/.claude/projects/-Volumes-SamsungDisk-Code-quota-monitor/qa-claude-session.jsonl"
    assert_file "$home/.claude/projects/-Volumes-SamsungDisk-Code-billing-api/qa-claude-project-only.jsonl"
    assert_file "$home/.config/claude/projects/-Volumes-SamsungDisk-Code-quota-monitor/qa-claude-config-session.jsonl"
    grep -q 'Show Codex reset cards in the menu bar' "$home/.codex/session_index.jsonl" \
        || fail "Codex fixture metadata title missing from session_index"
}

test_write_launch_config() {
    local dir config
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-config.XXXXXX")"
    config="$dir/qa-config.json"
    trap 'rm -rf "$dir"' RETURN

    qm_write_launch_config \
        "$config" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QATest" \
        "$dir/artifacts" \
        "open-dashboard,snapshot,quit" \
        "$dir/home/.codex" \
        "true"

    plutil -convert json -o /dev/null "$config" >/dev/null
    grep -q '"mode": true' "$config" || fail "mode flag missing from launch config"
    grep -q '"home": "' "$config" || fail "home missing from launch config"
    grep -q '"defaultsSuite": "dev.tjzhou.QuotaMonitor.QATest"' "$config" \
        || fail "defaults suite missing from launch config"
    grep -q '"outputDirectory": "' "$config" || fail "output directory missing from launch config"
    grep -q '"codexHome": "' "$config" || fail "codex home missing from launch config"
    grep -q '"mockCodexResetCredits": true' "$config" \
        || fail "mock Codex reset credits flag missing from launch config"
    grep -q '"open-dashboard"' "$config" || fail "first QA step missing from launch config"
    grep -q '"snapshot"' "$config" || fail "snapshot QA step missing from launch config"
    grep -q '"quit"' "$config" || fail "quit QA step missing from launch config"
}

test_write_launch_config_rejects_installed_app_defaults_suite() {
    local dir config
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-prod-launch-guard.XXXXXX")"
    config="$dir/qa-config.json"
    trap 'rm -rf "$dir"' RETURN

    if qm_write_launch_config \
        "$config" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor" \
        "$dir/artifacts" \
        "snapshot" \
        "$dir/home/.codex" >/dev/null 2>&1; then
        fail "qm_write_launch_config accepted the installed app defaults suite"
    fi
}

test_write_boundary_manifest_documents_fixture_policy() {
    local dir manifest
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-boundary.XXXXXX")"
    manifest="$dir/qa-boundary.json"
    trap 'rm -rf "$dir"' RETURN

    qm_write_boundary_manifest \
        "$manifest" \
        "fixture" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "$dir/home/.codex" \
        "$dir/home/Library/Application Support/QuotaMonitor/QAArtifacts"

    assert_file "$manifest"
    plutil -convert json -o /dev/null "$manifest" >/dev/null
    qm_assert_plutil_equals "$manifest" "mode" "fixture"
    qm_assert_plutil_equals "$manifest" "liveExternalSourcesAllowed" "false"
    qm_assert_plutil_equals "$manifest" "dataBoundary.quotaMonitorDatabase" "fixture-db"
    grep -q '"pricing.litellm_refresh"' "$manifest" \
        || fail "pricing live source guard missing from boundary manifest"
    grep -q '"sync pricing"' "$manifest" \
        || fail "Computer Use pricing approval boundary missing from manifest"
}

test_assert_boundary_manifest_contract_rejects_wrong_mode() {
    local dir manifest
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-boundary-wrong-mode.XXXXXX")"
    manifest="$dir/qa-boundary.json"
    trap 'rm -rf "$dir"' RETURN

    qm_write_boundary_manifest \
        "$manifest" \
        "fixture" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "$dir/home/.codex" \
        "$dir/home/Library/Application Support/QuotaMonitor/QAArtifacts"

    if qm_assert_boundary_manifest_contract "$dir" "real-data-shadow" >/dev/null 2>&1; then
        fail "boundary manifest with wrong mode was accepted"
    fi
}

test_launch_config_base64() {
    local dir config encoded decoded
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-config-b64.XXXXXX")"
    config="$dir/qa-config.json"
    trap 'rm -rf "$dir"' RETURN

    qm_write_launch_config \
        "$config" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QATest" \
        "$dir/artifacts" \
        "exercise-settings,snapshot" \
        "$dir/home/.codex"

    encoded="$(qm_launch_config_base64 "$config")"
    [[ -n "$encoded" ]] || fail "base64 launch config was empty"
    [[ "$encoded" != *$'\n'* ]] || fail "base64 launch config contained a newline"
    decoded="$(printf '%s' "$encoded" | base64 -D)"
    printf '%s' "$decoded" | grep -q '"exercise-settings"' \
        || fail "decoded base64 launch config did not contain QA steps"
}

test_default_steps_include_settings_exercise() {
    local steps
    steps="$(qm_default_steps)"

    [[ "$steps" == *"exercise-settings"* ]] \
        || fail "default QA steps do not exercise settings: $steps"
}

test_computer_use_steps_keep_app_open() {
    local steps
    steps="$(qm_computer_use_steps)"

    [[ "$steps" == *"open-dashboard"* ]] \
        || fail "Computer Use setup steps do not open Dashboard: $steps"
    [[ "$steps" == *"open-settings"* ]] \
        || fail "Computer Use setup steps do not open Settings: $steps"
    [[ "$steps" == *"show-popover"* ]] \
        || fail "Computer Use setup steps do not show the popover: $steps"
    [[ "$steps" == *"snapshot"* ]] \
        || fail "Computer Use setup steps do not write a snapshot: $steps"
    [[ "$steps" != *"quit"* ]] \
        || fail "Computer Use setup steps must keep the app open: $steps"
}

test_real_data_computer_use_steps_preserve_user_settings() {
    local steps
    steps="$(qm_real_data_computer_use_steps)"

    [[ "$steps" == *"open-dashboard"* ]] \
        || fail "real-data steps do not open Dashboard: $steps"
    [[ "$steps" == *"open-settings"* ]] \
        || fail "real-data steps do not open Settings: $steps"
    [[ "$steps" == *"snapshot"* ]] \
        || fail "real-data steps do not write a snapshot: $steps"
    [[ "$steps" != *"exercise-settings"* ]] \
        || fail "real-data steps must not overwrite copied user settings: $steps"
}

test_steps_include_quit_detects_exact_step() {
    qm_steps_include_quit "open-dashboard,snapshot,quit" \
        || fail "quit step was not detected"
    qm_steps_include_quit "open-dashboard, snapshot , quit " \
        || fail "quit step with whitespace was not detected"
    if qm_steps_include_quit "open-dashboard,acquit,snapshot"; then
        fail "substring containing quit was incorrectly detected"
    fi
}

test_steps_include_detects_named_step() {
    qm_steps_include "open-dashboard, show-popover ,snapshot" "show-popover" \
        || fail "named step with whitespace was not detected"
    if qm_steps_include "open-dashboard,not-show-popover,snapshot" "show-popover"; then
        fail "substring containing named step was incorrectly detected"
    fi
}

test_app_artifacts_dir_lives_under_qa_home() {
    local home app_artifacts
    home="/tmp/qm-qa-home"
    app_artifacts="$(qm_app_artifacts_dir "$home")"

    [[ "$app_artifacts" == "$home/"* ]] \
        || fail "app artifact dir must live under QA home: $app_artifacts"
    [[ "$app_artifacts" == *"QAArtifacts" ]] \
        || fail "app artifact dir should be identifiable: $app_artifacts"
}

test_static_entrypoint_does_not_launch_app() {
    assert_file "$ROOT_DIR/qa/run-static.sh"
    grep -q 'qa/run-static.sh' "$ROOT_DIR/qa/run-all.sh" \
        || fail "run-all should delegate to run-static"
    if grep -q 'qa/run-local.sh' "$ROOT_DIR/qa/run-all.sh"; then
        fail "run-all must not launch a QA app instance"
    fi
    grep -q 'swift test --disable-keychain' "$ROOT_DIR/qa/run-static.sh" \
        || fail "run-static should include the Swift test suite"
    grep -q 'python3 -m unittest discover tools/tests' "$ROOT_DIR/qa/run-static.sh" \
        || fail "run-static should include Python tool tests"
}

test_obsolete_local_e2e_entrypoint_is_removed() {
    if [[ -e "$ROOT_DIR/qa/run-local.sh" ]]; then
        fail "obsolete app E2E entrypoint should be removed: qa/run-local.sh"
    fi
}

test_computer_use_setup_entrypoints_are_role_named() {
    assert_file "$ROOT_DIR/qa/prepare-computer-use-fixture-smoke.sh"
    assert_file "$ROOT_DIR/qa/prepare-computer-use-fixture.sh"
    assert_file "$ROOT_DIR/qa/prepare-computer-use-real-data.sh"
    grep -q 'prepare-computer-use-fixture-smoke.sh' "$ROOT_DIR/qa/prepare-computer-use-fixture.sh" \
        || fail "legacy fixture entrypoint should delegate to fixture-smoke"
    for obsolete in \
        "$ROOT_DIR/qa/run-interactive.sh" \
        "$ROOT_DIR/qa/run-real-data-interactive.sh"; do
        if [[ -e "$obsolete" ]]; then
            fail "Computer Use setup entrypoint should be role-named, not interactive: $obsolete"
        fi
    done
}

test_computer_use_setup_language_is_consistent() {
    if grep -q \
        -e 'qm_interactive_steps' \
        -e 'Interactive QA app' \
        -e 'interactive setup' \
        -e 'interactive harness' \
        -e '-interactive' \
        -- \
        "$ROOT_DIR/qa/prepare-computer-use-fixture-smoke.sh" \
        "$ROOT_DIR/qa/prepare-computer-use-fixture.sh" \
        "$ROOT_DIR/qa/prepare-computer-use-real-data.sh" \
        "$ROOT_DIR/qa/lib/common.sh" \
        "$ROOT_DIR/docs/local-qa.md" \
        "$ROOT_DIR/docs/computer-qa.md" \
        "$ROOT_DIR/.codex/skills/quota-monitor-computer-qa/SKILL.md"; then
        fail "Computer Use setup should not retain old interactive naming"
    fi
}

test_standard_test_circuit_is_documented() {
    local doc="$ROOT_DIR/docs/local-qa.md"
    assert_file "$doc"

    grep -q '## Standard Test Circuit' "$doc" \
        || fail "testing doc should define the standard test circuit"
    for phrase in \
        'Static gate' \
        'Computer Use setup' \
        'Computer Use walkthrough' \
        'Artifact replay'; do
        grep -q "$phrase" "$doc" \
            || fail "testing doc missing responsibility: $phrase"
    done
    if grep -q \
        -e 'run-local' \
        -e 'Diagnostic-only' \
        -e 'run-interactive' \
        -e 'run-real-data-interactive' \
        "$doc" "$ROOT_DIR/.github/workflows/tests.yml"; then
        fail "standard test circuit must not mention removed local E2E entrypoints"
    fi
    grep -q './qa/prepare-computer-use-fixture-smoke.sh' "$doc" \
        || fail "testing doc should name fixture smoke Computer Use setup entrypoint"
    grep -q './qa/prepare-computer-use-real-data.sh' "$doc" \
        || fail "testing doc should name real-data Computer Use setup entrypoint"
}

test_real_data_qa_does_not_offer_deterministic_defaults_fallback() {
    if grep -q 'QM_QA_COPY_USER_DEFAULTS' \
        "$ROOT_DIR/qa/prepare-computer-use-real-data.sh" \
        "$ROOT_DIR/docs/local-qa.md" \
        "$ROOT_DIR/docs/computer-qa.md" \
        "$ROOT_DIR/.codex/skills/quota-monitor-computer-qa/SKILL.md"; then
        fail "real-data QA should not offer a deterministic-defaults fallback"
    fi
    if sed -n '/qm_write_real_data_defaults()/,/^}/p' "$ROOT_DIR/qa/lib/common.sh" \
        | grep -q 'qm_write_defaults'; then
        fail "real-data defaults should not fall back to fixture defaults"
    fi
}

test_standard_qa_docs_do_not_recommend_run_local() {
    for file in \
        "$ROOT_DIR/.codex/skills/quota-monitor-computer-qa/SKILL.md" \
        "$ROOT_DIR/docs/computer-qa.md"; do
        if grep -q -e 'run-local' -e 'run-interactive' -e 'run-real-data-interactive' "$file"; then
            fail "standard QA flow should not mention removed or unclear QA entrypoints: $file"
        fi
    done
}

test_write_computer_qa_brief() {
    local dir brief
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-computer-qa-brief.XXXXXX")"
    brief="$dir/computer-use-qa.md"
    trap 'rm -rf "$dir"' RETURN

    qm_write_computer_qa_brief \
        "$brief" \
        "$dir/artifacts" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "/Volumes/SamsungDisk/Code/quota-monitor"

    assert_file "$brief"
    grep -q 'Computer Use QA Brief' "$brief" \
        || fail "brief title missing"
    grep -q 'Dashboard' "$brief" \
        || fail "Dashboard walkthrough missing from brief"
    grep -q 'Sessions' "$brief" \
        || fail "Sessions walkthrough missing from brief"
    grep -q 'History' "$brief" \
        || fail "History walkthrough missing from brief"
    grep -q 'Settings' "$brief" \
        || fail "Settings walkthrough missing from brief"
    grep -q 'Do not use real Codex or Claude credentials' "$brief" \
        || fail "credential safety warning missing from brief"
    grep -q 'cleanup-computer-use.sh' "$brief" \
        || fail "Computer Use cleanup command missing from brief"
}

test_write_computer_use_cleanup_script() {
    local dir cleanup
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-computer-qa-cleanup.XXXXXX")"
    cleanup="$dir/cleanup.sh"
    trap 'rm -rf "$dir"' RETURN

    qm_write_computer_use_cleanup \
        "$cleanup" \
        "$dir/work" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test"

    assert_file "$cleanup"
    [[ -x "$cleanup" ]] || fail "cleanup script is not executable"
    if grep -q 'pkill -x QuotaMonitor' "$cleanup"; then
        fail "cleanup script must not stop non-QA QuotaMonitor processes"
    fi
    grep -q -- '--quotamonitor-qa-config' "$cleanup" \
        || fail "cleanup script does not target QA-launched QuotaMonitor processes"
    grep -q 'qm_delete_qa_defaults_suite "$QA_HOME" "$DEFAULTS_SUITE"' "$cleanup" \
        || fail "cleanup script does not delete QA defaults"
    grep -q 'rm -rf' "$cleanup" \
        || fail "cleanup script does not remove the QA work root"
}

test_write_computer_use_cleanup_script_restores_installed_app() {
    local dir cleanup
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-computer-qa-restore.XXXXXX")"
    cleanup="$dir/cleanup.sh"
    trap 'rm -rf "$dir"' RETURN

    qm_write_computer_use_cleanup \
        "$cleanup" \
        "$dir/work" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "$dir/artifacts/app-state.json" \
        "/Applications/QuotaMonitor.app" \
        "1"

    assert_file "$cleanup"
    grep -q 'INSTALLED_APP_BUNDLE=/Applications/QuotaMonitor.app' "$cleanup" \
        || fail "cleanup script does not remember the installed app bundle"
    grep -q 'qm_restore_installed_app_if_needed "$INSTALLED_APP_WAS_RUNNING" "$INSTALLED_APP_BUNDLE"' "$cleanup" \
        || fail "cleanup script does not restore a previously running installed app"
}

test_computer_qa_brief_includes_exact_app_target() {
    local dir brief
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-computer-qa-target.XXXXXX")"
    brief="$dir/computer-use-qa.md"
    trap 'rm -rf "$dir"' RETURN

    qm_write_computer_qa_brief \
        "$brief" \
        "$dir/artifacts" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "/Volumes/SamsungDisk/Code/quota-monitor"

    grep -q 'Computer Use app target' "$brief" \
        || fail "Computer Use app target missing from brief"
    grep -q '/Volumes/SamsungDisk/Code/quota-monitor/.build/QuotaMonitor.app' "$brief" \
        || fail "Computer Use brief must use the exact QA app path"
    grep -q 'cleanup-computer-use.sh' "$brief" \
        || fail "Computer Use cleanup command missing from target brief"
}

test_real_data_computer_qa_brief_includes_exact_app_target() {
    local dir brief
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-real-data-qa-target.XXXXXX")"
    brief="$dir/computer-use-qa.md"
    trap 'rm -rf "$dir"' RETURN

    qm_write_real_data_computer_qa_brief \
        "$brief" \
        "$dir/artifacts" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.RealDataQA.Test" \
        "/Volumes/SamsungDisk/Code/quota-monitor" \
        "$HOME/Library/Application Support/QuotaMonitor/quotamonitor.sqlite" \
        "$dir/home/Library/Application Support/QuotaMonitor/quotamonitor.sqlite"

    grep -q 'Computer Use app target' "$brief" \
        || fail "real-data Computer Use app target missing from brief"
    grep -q '/Volumes/SamsungDisk/Code/quota-monitor/.build/QuotaMonitor.app' "$brief" \
        || fail "real-data Computer Use brief must use the exact QA app path"
    grep -q 'cleanup-computer-use.sh' "$brief" \
        || fail "real-data Computer Use cleanup command missing from brief"
}

test_assert_artifact_contract() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-artifacts.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    cat >"$dir/app-state.json" <<'JSON'
{
  "bundleIdentifier": "dev.tjzhou.QuotaMonitor",
  "databasePath": "/tmp/qm/quotamonitor.sqlite",
  "developerLogPath": "/tmp/qm/quotamonitor-dev.log",
  "generatedAt": "2026-06-02T00:00:00Z",
  "menuBar": {
    "claudeEvents": 1,
    "claudeSessions": 1,
    "claudeTokens": 1740,
    "codexEvents": 2,
    "codexSessions": 1,
    "codexTokens": 290
  },
  "pid": 123,
  "qaSteps": ["open-settings", "exercise-settings", "snapshot"],
  "settings": {
    "developerModeEnabled": true,
    "enabledProviders": ["claude"],
    "language": "en",
    "menuBarIconProviders": ["claude"],
    "menuBarLabelStyle": "emphasis",
    "pollIntervalSeconds": 900,
    "quotaDisplayMode": "remaining",
    "showDockIconForWindows": false
  },
  "statusItemVisibility": "visible",
  "windows": [
    {"identifier": "dashboard", "isKeyWindow": false, "isVisible": true, "title": "Quota Monitor"},
    {"identifier": "settings", "isKeyWindow": true, "isVisible": true, "title": "Settings"}
  ]
}
JSON
    cat >"$dir/db-counts.txt" <<'TEXT'
provider  sessions
--------  --------
claude    1
codex     1
provider  events  tokens
--------  ------  ------
claude    1       1740
codex     2       290
source_kind  bucket     samples
-----------  ---------  -------
jsonl        primary    1
jsonl        secondary  1
TEXT
    {
        printf '{"event":"qa.settings.exercise","result":"success"}\n'
        printf '{"event":"qa.snapshot.write","result":"success"}\n'
    } >"$dir/quotamonitor-dev.log"
    printf 'PNGDATA' >"$dir/screen.png"
    printf 'Window: Quota Monitor\nWindow: Settings\n' >"$dir/ax-tree.txt"
    qm_write_boundary_manifest \
        "$dir/qa-boundary.json" \
        "fixture" \
        "/tmp/qm" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "/tmp/qm/.codex" \
        "/tmp/qm/Library/Application Support/QuotaMonitor/QAArtifacts"

    qm_assert_artifact_contract "$dir"
}

test_assert_artifact_contract_accepts_visual_fixture_steps() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-visual-artifacts.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    cat >"$dir/app-state.json" <<'JSON'
{
  "bundleIdentifier": "dev.tjzhou.QuotaMonitor",
  "databasePath": "/tmp/qm/quotamonitor.sqlite",
  "developerLogPath": "/tmp/qm/quotamonitor-dev.log",
  "generatedAt": "2026-06-02T00:00:00Z",
  "menuBar": {
    "claudeEvents": 1,
    "claudeSessions": 1,
    "claudeTokens": 1740,
    "codexEvents": 2,
    "codexSessions": 1,
    "codexTokens": 290
  },
  "pid": 123,
  "qaSteps": ["open-settings", "show-popover", "snapshot"],
  "settings": {
    "developerModeEnabled": true,
    "enabledProviders": ["claude", "codex"],
    "language": "zh-Hans",
    "menuBarIconProviders": ["claude", "codex"],
    "menuBarLabelStyle": "emphasis",
    "pollIntervalSeconds": 300,
    "quotaDisplayMode": "used",
    "showDockIconForWindows": true
  },
  "statusItemVisibility": "visible",
  "windows": [
    {"identifier": "dashboard", "isKeyWindow": false, "isVisible": true, "title": "Quota Monitor"},
    {"identifier": "settings", "isKeyWindow": true, "isVisible": true, "title": "设置"}
  ]
}
JSON
    cat >"$dir/db-counts.txt" <<'TEXT'
provider  sessions
--------  --------
claude    1
codex     1
provider  events  tokens
--------  ------  ------
claude    1       1740
codex     2       290
source_kind  bucket     samples
-----------  ---------  -------
jsonl        primary    1
jsonl        secondary  1
TEXT
    printf '{"event":"qa.snapshot.write","result":"success"}\n' >"$dir/quotamonitor-dev.log"
    printf 'PNGDATA' >"$dir/screen.png"
    printf 'Window: Quota Monitor\nWindow: 设置\n' >"$dir/ax-tree.txt"
    qm_write_boundary_manifest \
        "$dir/qa-boundary.json" \
        "fixture" \
        "/tmp/qm" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "/tmp/qm/.codex" \
        "/tmp/qm/Library/Application Support/QuotaMonitor/QAArtifacts"

    qm_assert_artifact_contract "$dir" "zh-Hans" "open-settings,show-popover,snapshot"
}

test_assert_artifact_contract_allows_incomplete_ax_with_warning() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-artifacts-ax-warning.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    cat >"$dir/app-state.json" <<'JSON'
{
  "bundleIdentifier": "dev.tjzhou.QuotaMonitor",
  "databasePath": "/tmp/qm/quotamonitor.sqlite",
  "developerLogPath": "/tmp/qm/quotamonitor-dev.log",
  "generatedAt": "2026-06-02T00:00:00Z",
  "menuBar": {
    "claudeEvents": 1,
    "claudeSessions": 1,
    "claudeTokens": 1740,
    "codexEvents": 2,
    "codexSessions": 1,
    "codexTokens": 290
  },
  "pid": 123,
  "qaSteps": ["open-settings", "exercise-settings", "snapshot"],
  "settings": {
    "developerModeEnabled": true,
    "enabledProviders": ["claude"],
    "language": "en",
    "menuBarIconProviders": ["claude"],
    "menuBarLabelStyle": "emphasis",
    "pollIntervalSeconds": 900,
    "quotaDisplayMode": "remaining",
    "showDockIconForWindows": false
  },
  "statusItemVisibility": "visible",
  "windows": [
    {"identifier": "dashboard", "isKeyWindow": false, "isVisible": true, "title": "Quota Monitor"},
    {"identifier": "settings", "isKeyWindow": true, "isVisible": true, "title": "Settings"}
  ]
}
JSON
    cat >"$dir/db-counts.txt" <<'TEXT'
provider  sessions
--------  --------
claude    1
codex     1
provider  events  tokens
--------  ------  ------
claude    1       1740
codex     2       290
source_kind  bucket     samples
-----------  ---------  -------
jsonl        primary    1
jsonl        secondary  1
TEXT
    {
        printf '{"event":"qa.settings.exercise","result":"success"}\n'
        printf '{"event":"qa.snapshot.write","result":"success"}\n'
    } >"$dir/quotamonitor-dev.log"
    printf 'PNGDATA' >"$dir/screen.png"
    printf '# QuotaMonitor AX snapshot\nfrontmost=false\n' >"$dir/ax-tree.txt"
    printf 'AX snapshot did not expose expected windows.\n' >"$dir/ax-dump-warning.txt"
    qm_write_boundary_manifest \
        "$dir/qa-boundary.json" \
        "fixture" \
        "/tmp/qm" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "/tmp/qm/.codex" \
        "/tmp/qm/Library/Application Support/QuotaMonitor/QAArtifacts"

    qm_assert_artifact_contract "$dir"
}

test_warns_when_ax_snapshot_is_incomplete() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-ax-incomplete.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf '# QuotaMonitor AX snapshot\nfrontmost=false\n' >"$dir/ax-tree.txt"

    qm_warn_incomplete_ax_snapshot "$dir"

    assert_file "$dir/ax-dump-warning.txt"
    grep -q 'did not expose expected windows' "$dir/ax-dump-warning.txt" \
        || fail "AX warning did not explain incomplete window capture"
}

test_ax_snapshot_accepts_localized_settings_title() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-ax-localized.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf 'Window: Quota Monitor\nWindow: 设置\n' >"$dir/ax-tree.txt"

    qm_ax_snapshot_has_expected_windows "$dir/ax-tree.txt" \
        || fail "localized Settings title was rejected"
}

test_copy_sqlite_snapshot_preserves_source() {
    local dir source copy before after source_count copy_count
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-real-db-shadow.XXXXXX")"
    source="$dir/source.sqlite"
    copy="$dir/shadow/quotamonitor.sqlite"
    trap 'rm -rf "$dir"' RETURN

    sqlite3 "$source" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY);
INSERT INTO sessions (id) VALUES ('real-session');
SQL

    before="$(qm_file_fingerprint "$source")"
    qm_copy_sqlite_snapshot "$source" "$copy"
    after="$(qm_file_fingerprint "$source")"

    [[ "$before" == "$after" ]] || fail "source DB fingerprint changed"
    assert_file "$copy"
    source_count="$(sqlite3 "$source" 'SELECT COUNT(*) FROM sessions;')"
    copy_count="$(sqlite3 "$copy" 'SELECT COUNT(*) FROM sessions;')"
    [[ "$source_count" == "1" ]] || fail "source DB count changed: $source_count"
    [[ "$copy_count" == "1" ]] || fail "shadow DB did not receive copied rows: $copy_count"
}

test_copy_codex_metadata_snapshot_copies_only_safe_metadata() {
    local dir source_home target_home
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-codex-metadata-shadow.XXXXXX")"
    source_home="$dir/source"
    target_home="$dir/target"
    trap 'rm -rf "$dir"' RETURN

    mkdir -p "$source_home/.codex" "$target_home"
    printf '{"id":"s1","thread_name":"梳理未合并PR"}\n' \
        >"$source_home/.codex/session_index.jsonl"
    sqlite3 "$source_home/.codex/state_5.sqlite" <<'SQL'
CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, cwd TEXT NOT NULL);
INSERT INTO threads (id, title, cwd)
VALUES ('s1', '梳理未合并PR', '/Volumes/SamsungDisk/Code/quota-monitor');
SQL
    printf 'secret-token' >"$source_home/.codex/auth.json"

    qm_copy_codex_metadata_snapshot "$source_home/.codex" "$target_home/.codex"

    assert_file "$target_home/.codex/session_index.jsonl"
    assert_file "$target_home/.codex/state_5.sqlite"
    assert_file "$target_home/.codex/sqlite/state_5.sqlite"
    [[ ! -e "$target_home/.codex/auth.json" ]] \
        || fail "credential file was copied into real-data shadow"

    local title root_count compat_count
    title="$(sqlite3 "$target_home/.codex/state_5.sqlite" "SELECT title FROM threads WHERE id='s1';")"
    root_count="$(sqlite3 "$target_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')"
    compat_count="$(sqlite3 "$target_home/.codex/sqlite/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')"
    [[ "$title" == "梳理未合并PR" ]] || fail "root state title copy failed: $title"
    [[ "$root_count" == "1" ]] || fail "root state row count was $root_count"
    [[ "$compat_count" == "1" ]] || fail "compat state row count was $compat_count"
}

test_write_real_data_computer_qa_brief_documents_shadow_boundary() {
    local dir brief
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-real-data-qa-brief.XXXXXX")"
    brief="$dir/computer-use-qa.md"
    trap 'rm -rf "$dir"' RETURN

    qm_write_real_data_computer_qa_brief \
        "$brief" \
        "$dir/artifacts" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.RealDataQA.Test" \
        "/Volumes/SamsungDisk/Code/quota-monitor" \
        "$HOME/Library/Application Support/QuotaMonitor/quotamonitor.sqlite" \
        "$dir/home/Library/Application Support/QuotaMonitor/quotamonitor.sqlite" \
        "$dir/artifacts/user-defaults-shadow.txt"

    assert_file "$brief"
    grep -q 'Real Data Shadow QA Brief' "$brief" \
        || fail "real-data brief title missing"
    grep -q 'copied SQLite snapshot' "$brief" \
        || fail "real-data brief does not explain DB shadow copy"
    grep -q 'UserDefaults are copied into the isolated QA suite' "$brief" \
        || fail "real-data brief does not explain copied user defaults"
    grep -q 'Do not copy real Codex or Claude credentials' "$brief" \
        || fail "real-data brief credential boundary missing"
    grep -q 'source DB fingerprint' "$brief" \
        || fail "real-data brief source protection check missing"
}

test_assert_real_data_artifact_contract() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-real-data-artifacts.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    cat >"$dir/app-state.json" <<'JSON'
{
  "bundleIdentifier": "dev.tjzhou.QuotaMonitor",
  "databasePath": "/tmp/qm-shadow/home/Library/Application Support/QuotaMonitor/quotamonitor.sqlite",
  "developerLogPath": "/tmp/qm-shadow/home/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log",
  "generatedAt": "2026-06-02T00:00:00Z",
  "pid": 123,
  "qaSteps": ["open-dashboard", "open-settings", "snapshot"],
  "settings": {
    "developerModeEnabled": false,
    "enabledProviders": ["codex", "claude"],
    "language": "zh-Hans",
    "menuBarIconProviders": ["codex"],
    "menuBarLabelStyle": "emphasis",
    "pollIntervalSeconds": 300,
    "quotaDisplayMode": "used",
    "showDockIconForWindows": true
  },
  "statusItemVisibility": "visible",
  "windows": [
    {"identifier": "dashboard", "isKeyWindow": false, "isVisible": true, "title": "Quota Monitor"},
    {"identifier": "settings", "isKeyWindow": true, "isVisible": true, "title": "Settings"}
  ]
}
JSON
    cat >"$dir/db-counts.txt" <<'TEXT'
provider  sessions
--------  --------
claude    10
TEXT
    printf 'PNGDATA' >"$dir/screen.png"
    printf 'Window: Quota Monitor\nWindow: 设置\n' >"$dir/ax-tree.txt"
    printf 'source_unchanged=true\n' >"$dir/real-data-protection.txt"
    qm_write_boundary_manifest \
        "$dir/qa-boundary.json" \
        "real-data-shadow" \
        "/tmp/qm-shadow/home" \
        "dev.tjzhou.QuotaMonitor.RealDataQA.Test" \
        "/tmp/qm-shadow/home/.codex" \
        "/tmp/qm-shadow/home/Library/Application Support/QuotaMonitor/QAArtifacts" \
        "/Users/example/Library/Application Support/QuotaMonitor/quotamonitor.sqlite" \
        "/tmp/qm-shadow/home/Library/Application Support/QuotaMonitor/quotamonitor.sqlite"

    qm_assert_real_data_artifact_contract "$dir"
}

test_rejects_real_provider_path_leak() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-real-provider-leak.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf '{"codexHome":"/Users/example/.codex"}\n' >"$dir/app-state.json"

    if QM_QA_REAL_SOURCE_HOME="/Users/example" \
        qm_assert_no_real_provider_paths_leaked "$dir" >/dev/null 2>&1; then
        fail "real provider path leak was accepted"
    fi
}

test_rejects_source_home_provider_path_leak() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-source-home-leak.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf '{"codexHome":"/Users/source-user/.codex"}\n' >"$dir/app-state.json"

    if QM_QA_SOURCE_HOME="/Users/source-user" \
        qm_assert_no_real_provider_paths_leaked "$dir" >/dev/null 2>&1; then
        fail "QM_QA_SOURCE_HOME provider path leak was accepted"
    fi
}

test_source_home_takes_precedence_for_provider_path_leak() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-source-home-precedence.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf '{"codexHome":"/Users/source-user/.claude"}\n' >"$dir/app-state.json"

    if QM_QA_SOURCE_HOME="/Users/source-user" \
        QM_QA_REAL_SOURCE_HOME="/Users/legacy-user" \
        qm_assert_no_real_provider_paths_leaked "$dir" >/dev/null 2>&1; then
        fail "QM_QA_SOURCE_HOME did not take precedence over legacy source home"
    fi
}

test_rejects_external_data_source_events() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-live-source-artifacts.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf '{"event":"appserver.launch","result":"success"}\n' >"$dir/quotamonitor-dev.log"

    if qm_assert_no_external_data_source_events "$dir" >/dev/null 2>&1; then
        fail "external data source event was accepted"
    fi
}

test_rejects_live_pricing_refresh_events() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-live-pricing-artifacts.XXXXXX")"
    trap 'rm -rf "$dir"' RETURN

    printf '{"event":"pricing.litellm_refresh","result":"success"}\n' >"$dir/quotamonitor-dev.log"

    if qm_assert_no_external_data_source_events "$dir" >/dev/null 2>&1; then
        fail "live pricing refresh event was accepted"
    fi

    printf '{"event":"pricing.litellm_refresh.skip","result":"skipped"}\n' >"$dir/quotamonitor-dev.log"
    qm_assert_no_external_data_source_events "$dir" \
        || fail "local QA pricing skip event should be accepted"
}

test_write_defaults
test_refuses_installed_app_defaults_suite
test_accepts_custom_qa_defaults_suite
test_write_real_data_defaults_copies_user_preferences_without_overrides
test_write_real_data_defaults_fails_when_user_preferences_cannot_be_copied
test_write_defaults_accepts_language_override
test_seed_fixtures
test_write_launch_config
test_write_launch_config_rejects_installed_app_defaults_suite
test_write_boundary_manifest_documents_fixture_policy
test_assert_boundary_manifest_contract_rejects_wrong_mode
test_launch_config_base64
test_default_steps_include_settings_exercise
test_computer_use_steps_keep_app_open
test_real_data_computer_use_steps_preserve_user_settings
test_steps_include_quit_detects_exact_step
test_steps_include_detects_named_step
test_app_artifacts_dir_lives_under_qa_home
test_static_entrypoint_does_not_launch_app
test_obsolete_local_e2e_entrypoint_is_removed
test_computer_use_setup_entrypoints_are_role_named
test_computer_use_setup_language_is_consistent
test_standard_test_circuit_is_documented
test_real_data_qa_does_not_offer_deterministic_defaults_fallback
test_standard_qa_docs_do_not_recommend_run_local
test_write_computer_qa_brief
test_write_computer_use_cleanup_script
test_write_computer_use_cleanup_script_restores_installed_app
test_computer_qa_brief_includes_exact_app_target
test_real_data_computer_qa_brief_includes_exact_app_target
test_assert_artifact_contract
test_assert_artifact_contract_accepts_visual_fixture_steps
test_assert_artifact_contract_allows_incomplete_ax_with_warning
test_warns_when_ax_snapshot_is_incomplete
test_ax_snapshot_accepts_localized_settings_title
test_copy_sqlite_snapshot_preserves_source
test_copy_codex_metadata_snapshot_copies_only_safe_metadata
test_write_real_data_computer_qa_brief_documents_shadow_boundary
test_assert_real_data_artifact_contract
test_rejects_real_provider_path_leak
test_rejects_source_home_provider_path_leak
test_source_home_takes_precedence_for_provider_path_leak
test_rejects_external_data_source_events
test_rejects_live_pricing_refresh_events
echo "common_tests: ok"
