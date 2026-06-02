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
