#!/usr/bin/env bash

qm_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

qm_require_command() {
    local name="$1"
    command -v "$name" >/dev/null 2>&1 || {
        echo "error: required command not found: $name" >&2
        return 127
    }
}

qm_app_version() {
    local root
    root="$(qm_repo_root)"
    tr -d '[:space:]' <"${root}/Resources/VERSION"
}

qm_write_defaults() {
    local home="$1"
    local domain="${2:-dev.tjzhou.QuotaMonitor.QA}"
    local version
    version="$(qm_app_version)"

    mkdir -p "$home/Library/Preferences"
    HOME="$home" defaults write "$domain" app.language -string en
    HOME="$home" defaults write "$domain" onboarding.providersDone -bool true
    HOME="$home" defaults write "$domain" onboarding.lastVersion -string "$version"
    HOME="$home" defaults write "$domain" discoverability.firstRunPresentationShown -bool true
    HOME="$home" defaults write "$domain" settings.developerModeEnabled -bool true
    HOME="$home" defaults write "$domain" settings.keychainPolicy -string never
    HOME="$home" defaults write "$domain" settings.showDockIconForWindows -bool true
    HOME="$home" defaults write "$domain" settings.enabledProviders -array codex claude
    HOME="$home" defaults write "$domain" settings.menuBarIconProviders -array codex claude
}

qm_seed_fixtures() {
    local home="$1"
    local root
    root="$(qm_repo_root)"

    local codex_dir="$home/.codex/sessions/qa"
    local claude_dir="$home/.claude/projects/-Volumes-SamsungDisk-Code-quota-monitor"
    local claude_config_dir="$home/.config/claude/projects/-Volumes-SamsungDisk-Code-quota-monitor"

    mkdir -p "$codex_dir" "$claude_dir" "$claude_config_dir" "$home/.codex/archived_sessions"

    cp "${root}/Tests/QuotaMonitorTests/Fixtures/Rollout/cli_0_40_with_cwd.jsonl" \
        "$codex_dir/rollout-2026-06-01T00-00-00-019aa0fd-1111-7000-8000-aaaaaaaaaaaa.jsonl"
    cp "${root}/qa/fixtures/qa-claude-session.jsonl" \
        "$claude_dir/qa-claude-session.jsonl"
    cp "${root}/qa/fixtures/qa-claude-session.jsonl" \
        "$claude_config_dir/qa-claude-config-session.jsonl"
}

qm_default_steps() {
    printf '%s\n' \
        "open-dashboard,open-settings,open-menubar-help,show-popover,refresh-all,exercise-settings,wait,snapshot"
}

qm_interactive_steps() {
    qm_default_steps
}

qm_app_artifacts_dir() {
    local home="$1"
    printf '%s\n' "$home/Library/Application Support/QuotaMonitor/QAArtifacts"
}

qm_write_interactive_cleanup() {
    local cleanup_path="$1"
    local work_root="$2"
    local qa_home="$3"
    local defaults_suite="$4"

    mkdir -p "$(dirname "$cleanup_path")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'WORK_ROOT=%q\n' "$work_root"
        printf 'QA_HOME=%q\n' "$qa_home"
        printf 'DEFAULTS_SUITE=%q\n' "$defaults_suite"
        printf 'pkill -x QuotaMonitor >/dev/null 2>&1 || true\n'
        printf 'HOME="$QA_HOME" defaults delete "$DEFAULTS_SUITE" >/dev/null 2>&1 || true\n'
        printf 'rm -rf "$WORK_ROOT"\n'
    } >"$cleanup_path"
    chmod +x "$cleanup_path"
}

qm_write_computer_qa_brief() {
    local brief_path="$1"
    local artifacts="$2"
    local qa_home="$3"
    local defaults_suite="$4"
    local repo_root="$5"

    mkdir -p "$(dirname "$brief_path")"
    {
        printf '# Computer Use QA Brief\n\n'
        printf 'Use this brief after the code-level QA harness has launched the isolated app.\n\n'
        printf '%s\n' "- Repo: \`$repo_root\`"
        printf '%s\n' "- Artifacts: \`$artifacts\`"
        printf '%s\n' "- QA home: \`$qa_home\`"
        printf '%s\n' "- Defaults suite: \`$defaults_suite\`"
        printf '%s\n\n' "- Cleanup: \`$artifacts/cleanup-interactive.sh\`"
        printf 'Do not use real Codex or Claude credentials. The app is running with fixture data, an isolated HOME, and an isolated UserDefaults suite.\n\n'
        printf '## Before Computer Use\n\n'
        printf '1. Confirm `app-state.json`, `db-counts.txt`, `quotamonitor-dev.log`, `screen.png`, and `ax-tree.txt` exist in the artifact directory.\n'
        printf '2. Read `app-state.json` to identify currently open windows and the QA settings snapshot.\n'
        printf '3. Use Computer Use only for local UI reading/clicking. Ask before destructive UI actions such as uninstall, deleting files, changing system settings, or transmitting credentials.\n\n'
        printf '## Walkthrough\n\n'
        printf '%s\n' '- Dashboard: verify Forecast, Trends, and Composition render with fixture data and no empty primary panels.'
        printf '%s\n' '- Sessions: switch to Sessions, search for the fixture session, change sort if available, open detail, and verify token/cost/event rows are visible.'
        printf '%s\n' '- History: switch to History, select a populated day, and verify rollups plus per-session details are readable.'
        printf '%s\n' '- Settings: inspect General and Advanced tabs. Verify language, provider toggles, quota display, Dock icon, poll interval, Developer Mode, database path, pricing catalog, export, and updater controls are visible. Do not run uninstall.'
        printf '%s\n' '- Menu bar: open the menu-bar popover, verify Codex and Claude fixture totals or the expected enabled-provider state, and test Open Dashboard / Settings navigation.'
        printf '%s\n' '- Menu-bar help: verify the help window is visible, readable, and can be closed without quitting the app.'
        printf '%s\n\n' '- Visual pass: note any clipped text, overlapping controls, blank charts, missing icons, or disabled controls that should be usable.'
        printf '## Report Format\n\n'
        printf '%s\n' '- Commands run'
        printf '%s\n' '- Artifact directory'
        printf '%s\n' '- Computer Use observations by area'
        printf '%s\n' '- Failures with screenshot or AX evidence'
        printf '%s\n' '- Untested areas and why'
    } >"$brief_path"
}

qm_json_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '"%s"' "$value"
}

qm_write_launch_config() {
    local config_path="$1"
    local home="$2"
    local defaults_suite="$3"
    local output_dir="$4"
    local steps="$5"
    local codex_home="$6"

    mkdir -p "$(dirname "$config_path")"
    {
        printf '{\n'
        printf '  "mode": true,\n'
        printf '  "home": '
        qm_json_string "$home"
        printf ',\n'
        printf '  "defaultsSuite": '
        qm_json_string "$defaults_suite"
        printf ',\n'
        printf '  "outputDirectory": '
        qm_json_string "$output_dir"
        printf ',\n'
        printf '  "codexHome": '
        qm_json_string "$codex_home"
        printf ',\n'
        printf '  "steps": ['

        local first=1
        local -a raw_steps
        local raw_step step
        IFS=',' read -r -a raw_steps <<<"$steps"
        for raw_step in "${raw_steps[@]}"; do
            step="$(printf '%s' "$raw_step" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -n "$step" ]] || continue
            if [[ "$first" == "1" ]]; then
                first=0
            else
                printf ','
            fi
            printf '\n    '
            qm_json_string "$step"
        done
        if [[ "$first" == "0" ]]; then
            printf '\n  '
        fi
        printf ']\n'
        printf '}\n'
    } >"$config_path"
}

qm_launch_config_base64() {
    local config_path="$1"
    base64 <"$config_path" | tr -d '\n'
}

qm_plutil_raw() {
    local key="$1"
    local file="$2"
    plutil -extract "$key" raw "$file" 2>/dev/null
}

qm_assert_plutil_equals() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(qm_plutil_raw "$key" "$file")" || {
        echo "error: missing JSON key '$key' in $file" >&2
        return 1
    }
    [[ "$actual" == "$expected" ]] || {
        echo "error: $key expected '$expected' but was '$actual'" >&2
        return 1
    }
}

qm_assert_nonempty_file_or_warning() {
    local file="$1"
    local warning="$2"
    local label="$3"
    if [[ -f "$file" ]]; then
        [[ "$(stat -f %z "$file")" -gt 0 ]] || {
            echo "error: $label exists but is empty: $file" >&2
            return 1
        }
        return 0
    fi
    [[ -f "$warning" ]] || {
        echo "error: missing $label and no warning file was written" >&2
        return 1
    }
}

qm_ax_snapshot_has_expected_windows() {
    local ax_tree="$1"
    [[ -f "$ax_tree" ]] || return 1
    grep -q 'Quota Monitor' "$ax_tree" || return 1
    grep -q 'Settings' "$ax_tree" || return 1
}

qm_warn_incomplete_ax_snapshot() {
    local artifacts="$1"
    local ax_tree="${artifacts}/ax-tree.txt"
    local ax_warning="${artifacts}/ax-dump-warning.txt"

    [[ -f "$ax_tree" ]] || return 0
    qm_ax_snapshot_has_expected_windows "$ax_tree" && return 0

    {
        printf 'AX snapshot did not expose expected windows.\n'
        printf 'Use app-state.json as the deterministic window contract; '
        printf 'AX output is environment-dependent when the app is not frontmost or runs as an accessory menu-bar app.\n'
    } >"$ax_warning"
}

qm_assert_artifact_contract() {
    local artifacts="$1"
    local state="${artifacts}/app-state.json"
    local db_counts="${artifacts}/db-counts.txt"
    local dev_log="${artifacts}/quotamonitor-dev.log"
    local screen="${artifacts}/screen.png"
    local screen_warning="${artifacts}/screen-capture-warning.txt"
    local ax_tree="${artifacts}/ax-tree.txt"
    local ax_warning="${artifacts}/ax-dump-warning.txt"

    [[ -f "$state" ]] || {
        echo "error: missing app state: $state" >&2
        return 1
    }
    plutil -convert json -o /dev/null "$state" >/dev/null

    grep -Eq '"title"[[:space:]]*:[[:space:]]*"Quota Monitor"' "$state" || {
        echo "error: dashboard window was not captured in QA state" >&2
        return 1
    }
    grep -Eq '"title"[[:space:]]*:[[:space:]]*"Settings"' "$state" || {
        echo "error: settings window was not captured in QA state" >&2
        return 1
    }
    grep -q '"exercise-settings"' "$state" || {
        echo "error: settings exercise step was not captured in QA state" >&2
        return 1
    }

    qm_assert_plutil_equals "$state" "settings.language" "en"
    qm_assert_plutil_equals "$state" "settings.quotaDisplayMode" "remaining"
    qm_assert_plutil_equals "$state" "settings.showDockIconForWindows" "false"
    qm_assert_plutil_equals "$state" "settings.developerModeEnabled" "true"
    qm_assert_plutil_equals "$state" "settings.pollIntervalSeconds" "900"
    qm_assert_plutil_equals "$state" "settings.enabledProviders.0" "claude"
    qm_assert_plutil_equals "$state" "settings.menuBarIconProviders.0" "claude"

    [[ -f "$db_counts" ]] || {
        echo "error: missing db-counts artifact: $db_counts" >&2
        return 1
    }
    grep -q 'claude' "$db_counts" || {
        echo "error: Claude fixture counts missing from db-counts.txt" >&2
        return 1
    }
    grep -q 'codex' "$db_counts" || {
        echo "error: Codex fixture counts missing from db-counts.txt" >&2
        return 1
    }
    grep -q 'jsonl.*primary' "$db_counts" || {
        echo "error: primary rate-limit sample missing from db-counts.txt" >&2
        return 1
    }
    grep -q 'jsonl.*secondary' "$db_counts" || {
        echo "error: secondary rate-limit sample missing from db-counts.txt" >&2
        return 1
    }

    [[ -f "$dev_log" ]] || {
        echo "error: missing Developer Mode log artifact: $dev_log" >&2
        return 1
    }
    grep -q '"event":"qa.settings.exercise"' "$dev_log" || {
        echo "error: settings exercise event missing from Developer Mode log" >&2
        return 1
    }
    grep -q '"event":"qa.snapshot.write"' "$dev_log" || {
        echo "error: snapshot write event missing from Developer Mode log" >&2
        return 1
    }

    qm_assert_nonempty_file_or_warning "$screen" "$screen_warning" "screen capture"
    qm_assert_nonempty_file_or_warning "$ax_tree" "$ax_warning" "AX tree"
    if [[ -f "$ax_tree" ]]; then
        if ! qm_ax_snapshot_has_expected_windows "$ax_tree"; then
            if [[ "${QM_QA_REQUIRE_AX:-0}" == "1" ]]; then
                echo "error: expected windows missing from AX tree" >&2
                return 1
            fi
            [[ -f "$ax_warning" ]] || {
                echo "error: expected windows missing from AX tree and no warning file was written" >&2
                return 1
            }
        fi
    fi
}

qm_retry_until() {
    local attempts="$1"
    local sleep_seconds="$2"
    shift 2

    local i
    for ((i = 1; i <= attempts; i++)); do
        if "$@"; then
            return 0
        fi
        sleep "$sleep_seconds"
    done
    return 1
}
