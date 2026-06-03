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

test_steps_include_quit_detects_exact_step() {
    qm_steps_include_quit "open-dashboard,snapshot,quit" \
        || fail "quit step was not detected"
    qm_steps_include_quit "open-dashboard, snapshot , quit " \
        || fail "quit step with whitespace was not detected"
    if qm_steps_include_quit "open-dashboard,acquit,snapshot"; then
        fail "substring containing quit was incorrectly detected"
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
    if grep -q 'pkill -x QuotaMonitor' "$cleanup"; then
        fail "cleanup script must not stop non-QA QuotaMonitor processes"
    fi
    grep -q -- '--quotamonitor-qa-config' "$cleanup" \
        || fail "cleanup script does not target QA-launched QuotaMonitor processes"
    grep -q 'defaults delete' "$cleanup" \
        || fail "cleanup script does not delete QA defaults"
    grep -q 'rm -rf' "$cleanup" \
        || fail "cleanup script does not remove the QA work root"
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
    qm_write_boundary_manifest \
        "$dir/qa-boundary.json" \
        "fixture" \
        "/tmp/qm" \
        "dev.tjzhou.QuotaMonitor.QA.Test" \
        "/tmp/qm/.codex" \
        "/tmp/qm/Library/Application Support/QuotaMonitor/QAArtifacts"

    qm_assert_artifact_contract "$dir"
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
        "$dir/home/Library/Application Support/QuotaMonitor/quotamonitor.sqlite"

    assert_file "$brief"
    grep -q 'Real Data Shadow QA Brief' "$brief" \
        || fail "real-data brief title missing"
    grep -q 'copied SQLite snapshot' "$brief" \
        || fail "real-data brief does not explain DB shadow copy"
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
  "qaSteps": ["open-dashboard", "open-settings", "exercise-settings", "snapshot"],
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
claude    10
TEXT
    {
        printf '{"event":"qa.settings.exercise","result":"success"}\n'
        printf '{"event":"qa.snapshot.write","result":"success"}\n'
    } >"$dir/quotamonitor-dev.log"
    printf 'PNGDATA' >"$dir/screen.png"
    printf 'Window: Quota Monitor\nWindow: Settings\n' >"$dir/ax-tree.txt"
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
test_seed_fixtures
test_write_launch_config
test_write_boundary_manifest_documents_fixture_policy
test_assert_boundary_manifest_contract_rejects_wrong_mode
test_launch_config_base64
test_default_steps_include_settings_exercise
test_interactive_steps_are_safe_for_computer_use
test_steps_include_quit_detects_exact_step
test_app_artifacts_dir_lives_under_qa_home
test_write_computer_qa_brief
test_write_interactive_cleanup_script
test_computer_qa_brief_includes_exact_app_target
test_real_data_computer_qa_brief_includes_exact_app_target
test_assert_artifact_contract
test_assert_artifact_contract_allows_incomplete_ax_with_warning
test_warns_when_ax_snapshot_is_incomplete
test_copy_sqlite_snapshot_preserves_source
test_write_real_data_computer_qa_brief_documents_shadow_boundary
test_assert_real_data_artifact_contract
test_rejects_real_provider_path_leak
test_rejects_external_data_source_events
test_rejects_live_pricing_refresh_events
echo "common_tests: ok"
