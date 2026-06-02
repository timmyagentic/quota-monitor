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
        grep -q 'Quota Monitor' "$ax_tree" || {
            echo "error: dashboard window missing from AX tree" >&2
            return 1
        }
        grep -q 'Settings' "$ax_tree" || {
            echo "error: settings window missing from AX tree" >&2
            return 1
        }
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
