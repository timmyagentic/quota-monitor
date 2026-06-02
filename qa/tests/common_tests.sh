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
    [[ "$keychain_policy" == "never" ]] || fail "keychain policy default was $keychain_policy"
    [[ "$providers_done" == "1" ]] || fail "provider onboarding default was $providers_done"
}

test_seed_fixtures() {
    local home
    home="$(mktemp -d "${TMPDIR:-/tmp}/qm-qa-fixtures.XXXXXX")"
    trap 'rm -rf "$home"' RETURN

    qm_seed_fixtures "$home"

    assert_file "$home/.codex/sessions/qa/rollout-2026-06-01T00-00-00-019aa0fd-1111-7000-8000-aaaaaaaaaaaa.jsonl"
    assert_file "$home/.claude/projects/-Volumes-SamsungDisk-Code-quota-monitor/qa-claude-session.jsonl"
    assert_file "$home/.config/claude/projects/-Volumes-SamsungDisk-Code-quota-monitor/qa-claude-config-session.jsonl"
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
        "$dir/home/.codex"

    plutil -convert json -o /dev/null "$config" >/dev/null
    grep -q '"mode": true' "$config" || fail "mode flag missing from launch config"
    grep -q '"home": "' "$config" || fail "home missing from launch config"
    grep -q '"defaultsSuite": "dev.tjzhou.QuotaMonitor.QATest"' "$config" \
        || fail "defaults suite missing from launch config"
    grep -q '"outputDirectory": "' "$config" || fail "output directory missing from launch config"
    grep -q '"codexHome": "' "$config" || fail "codex home missing from launch config"
    grep -q '"open-dashboard"' "$config" || fail "first QA step missing from launch config"
    grep -q '"snapshot"' "$config" || fail "snapshot QA step missing from launch config"
    grep -q '"quit"' "$config" || fail "quit QA step missing from launch config"
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

test_interactive_steps_are_safe_for_computer_use() {
    local steps
    steps="$(qm_interactive_steps)"

    [[ "$steps" == *"open-dashboard"* ]] \
        || fail "interactive QA steps do not open Dashboard: $steps"
    [[ "$steps" == *"open-settings"* ]] \
        || fail "interactive QA steps do not open Settings: $steps"
    [[ "$steps" == *"show-popover"* ]] \
        || fail "interactive QA steps do not show the popover: $steps"
    [[ "$steps" == *"snapshot"* ]] \
        || fail "interactive QA steps do not write a snapshot: $steps"
    [[ "$steps" != *"quit"* ]] \
        || fail "interactive QA steps must keep the app open: $steps"
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
}

test_write_interactive_cleanup_script() {
    local dir cleanup
    dir="$(mktemp -d "${TMPDIR:-/tmp}/qm-computer-qa-cleanup.XXXXXX")"
    cleanup="$dir/cleanup.sh"
    trap 'rm -rf "$dir"' RETURN

    qm_write_interactive_cleanup \
        "$cleanup" \
        "$dir/work" \
        "$dir/home" \
        "dev.tjzhou.QuotaMonitor.QA.Test"

    assert_file "$cleanup"
    [[ -x "$cleanup" ]] || fail "cleanup script is not executable"
    grep -q 'pkill -x QuotaMonitor' "$cleanup" \
        || fail "cleanup script does not stop QuotaMonitor"
    grep -q 'defaults delete' "$cleanup" \
        || fail "cleanup script does not delete QA defaults"
    grep -q 'rm -rf' "$cleanup" \
        || fail "cleanup script does not remove the QA work root"
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

    qm_assert_artifact_contract "$dir"
}

test_write_defaults
test_seed_fixtures
test_write_launch_config
test_launch_config_base64
test_default_steps_include_settings_exercise
test_interactive_steps_are_safe_for_computer_use
test_app_artifacts_dir_lives_under_qa_home
test_write_computer_qa_brief
test_write_interactive_cleanup_script
test_assert_artifact_contract
echo "common_tests: ok"
