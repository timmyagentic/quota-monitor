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

qm_assert_qa_defaults_suite() {
    local domain="$1"
    case "$domain" in
        dev.tjzhou.QuotaMonitor) ;;
        dev.tjzhou.QuotaMonitor.*) return 0 ;;
    esac

    echo "error: refusing QA defaults suite '$domain'; use a dev.tjzhou.QuotaMonitor.* isolated suite, not the installed app domain" >&2
    return 1
}

qm_delete_qa_defaults_suite() {
    local home="$1"
    local domain="$2"
    qm_assert_qa_defaults_suite "$domain" || return 1
    HOME="$home" defaults delete "$domain" >/dev/null 2>&1 || true
    defaults delete "$domain" >/dev/null 2>&1 || true
}

qm_write_defaults() {
    local home="$1"
    local domain="${2:-dev.tjzhou.QuotaMonitor.QA}"
    local version
    version="$(qm_app_version)"
    local language="${QM_QA_LANGUAGE:-en}"

    qm_assert_qa_defaults_suite "$domain" || return 1

    mkdir -p "$home/Library/Preferences"
    HOME="$home" defaults write "$domain" app.language -string "$language"
    HOME="$home" defaults write "$domain" onboarding.providersDone -bool true
    HOME="$home" defaults write "$domain" onboarding.lastVersion -string "$version"
    HOME="$home" defaults write "$domain" discoverability.firstRunPresentationShown -bool true
    HOME="$home" defaults write "$domain" settings.developerModeEnabled -bool true
    HOME="$home" defaults write "$domain" settings.keychainPolicy -string fallback
    HOME="$home" defaults write "$domain" settings.showDockIconForWindows -bool true
    HOME="$home" defaults write "$domain" settings.enabledProviders -array codex claude
    HOME="$home" defaults write "$domain" settings.menuBarIconProviders -array codex claude
}

qm_copy_user_defaults_to_qa_suite() {
    local source_home="$1"
    local target_home="$2"
    local source_domain="$3"
    local target_domain="$4"
    local source_plist tmp_plist

    qm_assert_qa_defaults_suite "$target_domain" || return 1

    mkdir -p "$target_home/Library/Preferences"
    source_plist="$(qm_user_defaults_plist_path "$source_home" "$source_domain")"
    if [[ -f "$source_plist" ]]; then
        plutil -lint "$source_plist" >/dev/null 2>&1 || return 1
        qm_plist_has_any_key "$source_plist" || return 1
        HOME="$target_home" defaults import "$target_domain" "$source_plist" >/dev/null 2>&1
        return $?
    fi

    tmp_plist="$(mktemp "${TMPDIR:-/tmp}/qm-user-defaults.XXXXXX.plist")"
    if ! HOME="$source_home" defaults export "$source_domain" "$tmp_plist" >/dev/null 2>&1; then
        rm -f "$tmp_plist"
        return 1
    fi
    if ! qm_plist_has_any_key "$tmp_plist"; then
        rm -f "$tmp_plist"
        return 1
    fi
    if ! HOME="$target_home" defaults import "$target_domain" "$tmp_plist" >/dev/null 2>&1; then
        rm -f "$tmp_plist"
        return 1
    fi
    rm -f "$tmp_plist"
}

qm_user_defaults_plist_path() {
    local home="$1"
    local domain="$2"
    printf '%s\n' "$home/Library/Preferences/${domain}.plist"
}

qm_plist_has_key() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" >/dev/null 2>&1
}

qm_plist_has_any_key() {
    local plist="$1"
    local compact

    compact="$(plutil -p "$plist" 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$compact" != "{}" ]]
}

qm_defaults_domain_has_product_preferences() {
    local home="$1"
    local domain="$2"
    local plist key

    plist="$(qm_user_defaults_plist_path "$home" "$domain")"
    [[ -f "$plist" ]] || return 1
    plutil -lint "$plist" >/dev/null 2>&1 || return 1

    for key in \
        app.language \
        onboarding.providersDone \
        settings.enabledProviders \
        settings.menuBarIconProviders; do
        qm_plist_has_key "$plist" "$key" && return 0
    done

    return 1
}

qm_defaults_domain_exists() {
    local home="$1"
    local domain="$2"
    local plist

    plist="$(qm_user_defaults_plist_path "$home" "$domain")"
    [[ -f "$plist" ]] || return 1
    plutil -lint "$plist" >/dev/null 2>&1
}

qm_select_real_data_defaults_domain() {
    local source_home="$1"
    local domain
    local candidates=(
        "dev.tjzhou.QuotaMonitor"
        "QuotaMonitor"
        "dev.tjzhou.CodexMonitor"
        "CodexMonitor"
    )

    for domain in "${candidates[@]}"; do
        if qm_defaults_domain_has_product_preferences "$source_home" "$domain"; then
            printf '%s\n' "$domain"
            return 0
        fi
    done

    for domain in "${candidates[@]}"; do
        if qm_defaults_domain_exists "$source_home" "$domain"; then
            printf '%s\n' "$domain"
            return 0
        fi
    done

    printf '%s\n' "dev.tjzhou.QuotaMonitor"
}

qm_write_real_data_defaults() {
    local home="$1"
    local domain="$2"
    local source_home="$3"
    local source_domain="$4"
    local report_path="$5"
    local copied="false"
    local qa_overrides="none"

    qm_assert_qa_defaults_suite "$domain" || return 1

    if qm_copy_user_defaults_to_qa_suite \
        "$source_home" \
        "$home" \
        "$source_domain" \
        "$domain"; then
        copied="true"
    fi

    if [[ "$copied" == "true" && -n "${QM_QA_LANGUAGE:-}" ]]; then
        HOME="$home" defaults write "$domain" app.language -string "$QM_QA_LANGUAGE"
        qa_overrides="app.language=${QM_QA_LANGUAGE}"
    fi

    {
        printf 'source_home=%s\n' "$source_home"
        printf 'source_domain=%s\n' "$source_domain"
        printf 'target_home=%s\n' "$home"
        printf 'target_domain=%s\n' "$domain"
        printf 'copy_requested=1\n'
        printf 'copied_user_defaults=%s\n' "$copied"
        printf 'qa_overrides=%s\n' "$qa_overrides"
        printf 'safety_overrides=none\n'
    } >"$report_path"

    [[ "$copied" == "true" ]]
}

qm_seed_fixtures() {
    local home="$1"
    local root
    root="$(qm_repo_root)"

    local codex_dir="$home/.codex/sessions/qa"
    local claude_dir="$home/.claude/projects/-Volumes-SamsungDisk-Code-quota-monitor"
    local claude_fallback_dir="$home/.claude/projects/-Volumes-SamsungDisk-Code-billing-api"
    local claude_config_dir="$home/.config/claude/projects/-Volumes-SamsungDisk-Code-quota-monitor"

    mkdir -p "$codex_dir" "$claude_dir" "$claude_fallback_dir" "$claude_config_dir" "$home/.codex/archived_sessions"

    cp "${root}/qa/fixtures/qa-codex-session.jsonl" \
        "$codex_dir/rollout-2026-06-01T00-00-00-019aa0fd-1111-7000-8000-aaaaaaaaaaaa.jsonl"
    cp "${root}/qa/fixtures/qa-codex-project-only.jsonl" \
        "$codex_dir/rollout-2026-06-01T00-03-00-019aa0fd-2222-7000-8000-bbbbbbbbbbbb.jsonl"
    cat >"$home/.codex/session_index.jsonl" <<'JSON'
{"id":"019aa0fd-1111-7000-8000-aaaaaaaaaaaa","thread_name":"Show Codex reset cards in the menu bar","updated_at":"2026-06-20T10:16:03Z"}
JSON
    cp "${root}/qa/fixtures/qa-claude-session.jsonl" \
        "$claude_dir/qa-claude-session.jsonl"
    cp "${root}/qa/fixtures/qa-claude-project-only.jsonl" \
        "$claude_fallback_dir/qa-claude-project-only.jsonl"
    cp "${root}/qa/fixtures/qa-claude-session.jsonl" \
        "$claude_config_dir/qa-claude-config-session.jsonl"
}

qm_default_steps() {
    printf '%s\n' \
        "open-dashboard,open-settings,open-menubar-help,show-popover,refresh-all,exercise-settings,wait,snapshot"
}

qm_computer_use_steps() {
    qm_default_steps
}

qm_real_data_computer_use_steps() {
    printf '%s\n' \
        "open-dashboard,open-settings,open-menubar-help,show-popover,refresh-all,wait,snapshot"
}

qm_steps_include() {
    local steps="$1"
    local wanted="$2"
    local part trimmed
    local -a parts
    IFS=',' read -r -a parts <<<"$steps"
    for part in "${parts[@]}"; do
        trimmed="${part#"${part%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ "$trimmed" == "$wanted" ]] && return 0
    done
    return 1
}

qm_steps_include_quit() {
    qm_steps_include "$1" "quit"
}

qm_app_artifacts_dir() {
    local home="$1"
    printf '%s\n' "$home/Library/Application Support/QuotaMonitor/QAArtifacts"
}

qm_default_real_database_path() {
    local home="${1:-$HOME}"
    printf '%s\n' "$home/Library/Application Support/QuotaMonitor/quotamonitor.sqlite"
}

qm_file_fingerprint() {
    local file="$1"
    [[ -f "$file" ]] || {
        echo "error: cannot fingerprint missing file: $file" >&2
        return 1
    }
    stat -f 'size=%z mtime=%m inode=%i' "$file"
    shasum -a 256 "$file" | awk '{ print "sha256="$1 }'
}

qm_sqlite_dot_quote() {
    local value="$1"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

qm_copy_sqlite_snapshot() {
    local source="$1"
    local destination="$2"

    [[ -f "$source" ]] || {
        echo "error: real-data source DB does not exist: $source" >&2
        return 1
    }
    mkdir -p "$(dirname "$destination")"

    local quoted_source quoted_destination
    quoted_source="$(qm_sqlite_dot_quote "$source")"
    quoted_destination="$(qm_sqlite_dot_quote "$destination")"
    sqlite3 <<SQL
.open --readonly $quoted_source
.timeout 5000
.backup $quoted_destination
.quit
SQL
}

qm_copy_codex_metadata_snapshot() {
    local source_codex_home="$1"
    local target_codex_home="$2"

    mkdir -p "$target_codex_home"

    if [[ -f "${source_codex_home}/session_index.jsonl" ]]; then
        cp "${source_codex_home}/session_index.jsonl" \
            "${target_codex_home}/session_index.jsonl"
    fi

    local copied_root_state=false
    if [[ -f "${source_codex_home}/state_5.sqlite" ]]; then
        qm_copy_sqlite_snapshot \
            "${source_codex_home}/state_5.sqlite" \
            "${target_codex_home}/state_5.sqlite"
        copied_root_state=true
    fi

    if [[ -f "${source_codex_home}/sqlite/state_5.sqlite" ]]; then
        qm_copy_sqlite_snapshot \
            "${source_codex_home}/sqlite/state_5.sqlite" \
            "${target_codex_home}/sqlite/state_5.sqlite"
    elif [[ "$copied_root_state" == "true" ]]; then
        qm_copy_sqlite_snapshot \
            "${source_codex_home}/state_5.sqlite" \
            "${target_codex_home}/sqlite/state_5.sqlite"
    fi
}

qm_installed_app_bundle() {
    printf '%s\n' "${QM_QA_INSTALLED_APP_BUNDLE:-/Applications/QuotaMonitor.app}"
}

qm_installed_app_running() {
    local bundle="${1:-$(qm_installed_app_bundle)}"
    local binary="${bundle}/Contents/MacOS/QuotaMonitor"
    local pid command

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$binary"* ]] \
            && [[ "$command" != *"--quotamonitor-qa-config"* ]]; then
            return 0
        fi
    done < <(/usr/bin/pgrep -x QuotaMonitor 2>/dev/null || true)
    return 1
}

qm_installed_app_was_running() {
    local bundle="${1:-$(qm_installed_app_bundle)}"
    if qm_installed_app_running "$bundle"; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

qm_restore_installed_app_if_needed() {
    local was_running="${1:-0}"
    local bundle="${2:-$(qm_installed_app_bundle)}"

    [[ "$was_running" == "1" ]] || return 0
    [[ -d "$bundle" ]] || {
        echo "warning: installed QuotaMonitor app not found for restore: $bundle" >&2
        return 0
    }
    qm_installed_app_running "$bundle" && return 0

    /usr/bin/open -g "$bundle" >/dev/null 2>&1 || {
        echo "warning: failed to restore installed QuotaMonitor app: $bundle" >&2
        return 0
    }
}

qm_write_computer_use_cleanup() {
    local cleanup_path="$1"
    local work_root="$2"
    local qa_home="$3"
    local defaults_suite="$4"
    local state_json="${5:-}"
    local installed_app_bundle="${6:-$(qm_installed_app_bundle)}"
    local installed_app_was_running="${7:-0}"
    local repo_root
    repo_root="$(qm_repo_root)"

    qm_assert_qa_defaults_suite "$defaults_suite" || return 1

    mkdir -p "$(dirname "$cleanup_path")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'ROOT_DIR=%q\n' "$repo_root"
        printf 'WORK_ROOT=%q\n' "$work_root"
        printf 'QA_HOME=%q\n' "$qa_home"
        printf 'DEFAULTS_SUITE=%q\n' "$defaults_suite"
        printf 'STATE_JSON=%q\n' "$state_json"
        printf 'INSTALLED_APP_BUNDLE=%q\n' "$installed_app_bundle"
        printf 'INSTALLED_APP_WAS_RUNNING=%q\n' "$installed_app_was_running"
        printf '# QA process cleanup is scoped to --quotamonitor-qa-config launches.\n'
        printf '. "$ROOT_DIR/qa/lib/common.sh"\n'
        printf 'qm_stop_local_qa_process_from_state "$STATE_JSON"\n'
        printf 'qm_delete_qa_defaults_suite "$QA_HOME" "$DEFAULTS_SUITE" || true\n'
        printf 'rm -rf "$WORK_ROOT"\n'
        printf 'qm_restore_installed_app_if_needed "$INSTALLED_APP_WAS_RUNNING" "$INSTALLED_APP_BUNDLE"\n'
    } >"$cleanup_path"
    chmod +x "$cleanup_path"
}

qm_wait_for_no_local_qa_processes() {
    local attempts="${1:-25}"
    local delay="${2:-0.2}"
    local i

    for ((i = 0; i < attempts; i++)); do
        if ! qm_local_qa_process_running; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

qm_stop_local_qa_processes() {
    /usr/bin/pkill -f '[Q]uotaMonitor .*--quotamonitor-qa-config' >/dev/null 2>&1 || true
    if ! qm_wait_for_no_local_qa_processes; then
        /usr/bin/pkill -9 -f '[Q]uotaMonitor .*--quotamonitor-qa-config' >/dev/null 2>&1 || true
        qm_wait_for_no_local_qa_processes 10 0.1 >/dev/null 2>&1 || true
    fi
}

qm_stop_local_qa_process_from_state() {
    local state_json="$1"
    if [[ -f "$state_json" ]]; then
        local pid command
        pid="$(/usr/bin/plutil -extract pid raw "$state_json" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
            if [[ "$command" == *"--quotamonitor-qa-config"* ]]; then
                /bin/kill "$pid" >/dev/null 2>&1 || true
            fi
        fi
    fi
    qm_stop_local_qa_processes
}

qm_local_qa_process_running() {
    /usr/bin/pgrep -f '[Q]uotaMonitor .*--quotamonitor-qa-config' >/dev/null 2>&1
}

qm_computer_use_app_target() {
    local repo_root="$1"
    printf '%s\n' "${QUOTAMONITOR_QA_APP_BUNDLE:-${repo_root}/.build/QuotaMonitor.app}"
}

qm_write_computer_qa_brief() {
    local brief_path="$1"
    local artifacts="$2"
    local qa_home="$3"
    local defaults_suite="$4"
    local repo_root="$5"
    local app_target
    app_target="$(qm_computer_use_app_target "$repo_root")"

    mkdir -p "$(dirname "$brief_path")"
    {
        printf '# Computer Use QA Brief\n\n'
        printf 'Use this brief after the code-level QA harness has launched the isolated app.\n\n'
        printf '%s\n' "- Repo: \`$repo_root\`"
        printf '%s\n' "- Computer Use app target: \`$app_target\`"
        printf '%s\n' "- Artifacts: \`$artifacts\`"
        printf '%s\n' "- QA home: \`$qa_home\`"
        printf '%s\n' "- Defaults suite: \`$defaults_suite\`"
        printf '%s\n' "- Boundary manifest: \`$artifacts/qa-boundary.json\`"
        printf '%s\n\n' "- Cleanup: \`$artifacts/cleanup-computer-use.sh\`"
        printf 'Do not use real Codex or Claude credentials. The app is running with fixture data, an isolated HOME, and an isolated UserDefaults suite.\n\n'
        printf '## Before Computer Use\n\n'
        printf '1. Confirm `qa-boundary.json`, `app-state.json`, `db-counts.txt`, `quotamonitor-dev.log`, `screen.png`, and `ax-tree.txt` exist in the artifact directory.\n'
        printf '2. Read `app-state.json` to identify currently open windows and the QA settings snapshot.\n'
        printf '3. Use Computer Use only for local UI reading/clicking. Ask before destructive UI actions such as uninstall, deleting files, changing system settings, or transmitting credentials.\n\n'
        printf '## Walkthrough\n\n'
        printf '%s\n' '- Dashboard: verify Forecast, Trends, and Composition render with fixture data and no empty primary panels.'
        printf '%s\n' '- Sessions: switch to Sessions, search "Show Codex reset cards" to see real session titles, then search "billing-api" to see the project-name fallback row without an "Untitled session" label.'
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

qm_write_real_data_computer_qa_brief() {
    local brief_path="$1"
    local artifacts="$2"
    local qa_home="$3"
    local defaults_suite="$4"
    local repo_root="$5"
    local source_db="$6"
    local shadow_db="$7"
    local user_defaults_report="${8:-}"
    local app_target
    app_target="$(qm_computer_use_app_target "$repo_root")"

    mkdir -p "$(dirname "$brief_path")"
    {
        printf '# Real Data Shadow QA Brief\n\n'
        printf 'Use this brief after launching the isolated app with a copied SQLite snapshot of real QuotaMonitor data.\n\n'
        printf '%s\n' "- Repo: \`$repo_root\`"
        printf '%s\n' "- Computer Use app target: \`$app_target\`"
        printf '%s\n' "- Artifacts: \`$artifacts\`"
        printf '%s\n' "- QA home: \`$qa_home\`"
        printf '%s\n' "- Defaults suite: \`$defaults_suite\`"
        printf '%s\n' "- Source DB: \`$source_db\`"
        printf '%s\n' "- Shadow DB: \`$shadow_db\`"
        if [[ -n "$user_defaults_report" ]]; then
            printf '%s\n' "- User defaults shadow: \`$user_defaults_report\`"
        fi
        printf '%s\n' "- Boundary manifest: \`$artifacts/qa-boundary.json\`"
        printf '%s\n\n' "- Cleanup: \`$artifacts/cleanup-computer-use.sh\`"
        printf 'The app is running against the shadow DB under the isolated QA home. The original DB path is never passed to the app.\n\n'
        printf '## Data Boundary\n\n'
        printf '%s\n' '- The source database was copied with a SQLite backup into the QA home before launch.'
        printf '%s\n' '- QuotaMonitor UserDefaults are copied into the isolated QA suite without changing product-visible preferences.'
        printf '%s\n' '- Do not copy real Codex or Claude credentials into this profile.'
        printf '%s\n' '- CODEX_HOME points at the QA home, not the real ~/.codex directory.'
        printf '%s\n' '- Live external sources are disabled in Local QA, so the app should not request real Claude credentials.'
        printf '%s\n\n' '- After QA, verify the source DB fingerprint did not change.'
        printf '## Walkthrough\n\n'
        printf '%s\n' '- Dashboard: verify real-data Forecast, Trends, Activity, and Composition render without blank primary panels.'
        printf '%s\n' '- Sessions: search real session titles/models, switch sort modes, open details, and inspect token/cost/event rows.'
        printf '%s\n' '- History: select populated days and inspect rollups plus per-session details.'
        printf '%s\n' '- Settings: inspect General and Advanced controls, but do not run uninstall, export, reveal, updater, or pricing sync actions.'
        printf '%s\n' '- Visual pass: note clipped text, overlapping controls, blank charts, missing icons, and mixed-language formatting.'
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
    local mock_codex_reset_credits="${7:-false}"

    qm_assert_qa_defaults_suite "$defaults_suite" || return 1

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
        printf '  "mockCodexResetCredits": %s,\n' "$mock_codex_reset_credits"
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

qm_write_boundary_manifest() {
    local manifest_path="$1"
    local mode="$2"
    local qa_home="$3"
    local defaults_suite="$4"
    local codex_home="$5"
    local app_artifacts="$6"
    local source_db="${7:-}"
    local shadow_db="${8:-}"
    local user_defaults_policy="${9:-deterministic-qa-defaults}"
    local source_defaults_domain="${10:-}"
    local db_policy="fixture-db"
    if [[ "$mode" == "real-data-shadow" ]]; then
        db_policy="shadow-copy"
    fi

    mkdir -p "$(dirname "$manifest_path")"
    {
        printf '{\n'
        printf '  "schemaVersion": 1,\n'
        printf '  "mode": '
        qm_json_string "$mode"
        printf ',\n'
        printf '  "qaHome": '
        qm_json_string "$qa_home"
        printf ',\n'
        printf '  "defaultsSuite": '
        qm_json_string "$defaults_suite"
        printf ',\n'
        printf '  "codexHome": '
        qm_json_string "$codex_home"
        printf ',\n'
        printf '  "appArtifactsDirectory": '
        qm_json_string "$app_artifacts"
        printf ',\n'
        printf '  "liveExternalSourcesAllowed": false,\n'
        printf '  "dataBoundary": {\n'
        printf '    "appWrites": "qa-home-only",\n'
        printf '    "quotaMonitorDatabase": '
        qm_json_string "$db_policy"
        printf ',\n'
        printf '    "userDefaults": '
        qm_json_string "$user_defaults_policy"
        printf ',\n'
        printf '    "codexSource": "qa-codex-home",\n'
        printf '    "claudeSource": "qa-home",\n'
        printf '    "credentials": "not-copied"'
        if [[ -n "$source_defaults_domain" ]]; then
            printf ',\n'
            printf '    "sourceDefaultsDomain": '
            qm_json_string "$source_defaults_domain"
        fi
        if [[ -n "$source_db" || -n "$shadow_db" ]]; then
            printf ',\n'
            printf '    "sourceDatabase": '
            qm_json_string "$source_db"
            printf ',\n'
            printf '    "shadowDatabase": '
            qm_json_string "$shadow_db"
            printf '\n'
        else
            printf '\n'
        fi
        printf '  },\n'
        printf '  "computerUsePolicy": {\n'
        printf '    "allowed": [\n'
        printf '      "read local UI",\n'
        printf '      "navigate app windows",\n'
        printf '      "toggle non-destructive QA settings",\n'
        printf '      "inspect copied database rendering"\n'
        printf '    ],\n'
        printf '    "requiresApproval": [\n'
        printf '      "uninstall",\n'
        printf '      "export CSV",\n'
        printf '      "reveal files",\n'
        printf '      "sync pricing",\n'
        printf '      "check for updates",\n'
        printf '      "change system settings",\n'
        printf '      "transmit credentials"\n'
        printf '    ]\n'
        printf '  },\n'
        printf '  "forbiddenDeveloperEvents": [\n'
        printf '    "appserver.*",\n'
        printf '    "ratelimits.poll*",\n'
        printf '    "claude_usage.poll*",\n'
        printf '    "claude_credentials*",\n'
        printf '    "claude_cli*",\n'
        printf '    "pricing.refresh_if_stale.refresh",\n'
        printf '    "pricing.litellm_refresh"\n'
        printf '  ]\n'
        printf '}\n'
    } >"$manifest_path"
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

qm_assert_boundary_manifest_contract() {
    local artifacts="$1"
    local expected_mode="$2"
    local manifest="${artifacts}/qa-boundary.json"

    [[ -f "$manifest" ]] || {
        echo "error: missing QA boundary manifest: $manifest" >&2
        return 1
    }
    plutil -convert json -o /dev/null "$manifest" >/dev/null
    qm_assert_plutil_equals "$manifest" "schemaVersion" "1"
    qm_assert_plutil_equals "$manifest" "mode" "$expected_mode"
    qm_assert_plutil_equals "$manifest" "liveExternalSourcesAllowed" "false"
    qm_assert_plutil_equals "$manifest" "dataBoundary.appWrites" "qa-home-only"
    qm_assert_plutil_equals "$manifest" "dataBoundary.codexSource" "qa-codex-home"
    qm_assert_plutil_equals "$manifest" "dataBoundary.claudeSource" "qa-home"
    qm_assert_plutil_equals "$manifest" "dataBoundary.credentials" "not-copied"

    local qa_home codex_home app_artifacts
    qa_home="$(qm_plutil_raw qaHome "$manifest")"
    codex_home="$(qm_plutil_raw codexHome "$manifest")"
    app_artifacts="$(qm_plutil_raw appArtifactsDirectory "$manifest")"
    [[ "$codex_home" == "$qa_home/"* ]] || {
        echo "error: QA codexHome is outside qaHome: $codex_home" >&2
        return 1
    }
    [[ "$app_artifacts" == "$qa_home/"* ]] || {
        echo "error: QA appArtifactsDirectory is outside qaHome: $app_artifacts" >&2
        return 1
    }

    grep -q '"uninstall"' "$manifest" || {
        echo "error: Computer Use uninstall approval boundary missing" >&2
        return 1
    }
    grep -q '"sync pricing"' "$manifest" || {
        echo "error: Computer Use pricing approval boundary missing" >&2
        return 1
    }
    grep -q '"pricing.litellm_refresh"' "$manifest" || {
        echo "error: forbidden pricing event missing from boundary manifest" >&2
        return 1
    }

    if [[ "$expected_mode" == "real-data-shadow" ]]; then
        qm_assert_plutil_equals "$manifest" "dataBoundary.quotaMonitorDatabase" "shadow-copy"
        local source_db shadow_db
        source_db="$(qm_plutil_raw dataBoundary.sourceDatabase "$manifest")"
        shadow_db="$(qm_plutil_raw dataBoundary.shadowDatabase "$manifest")"
        [[ -n "$source_db" && -n "$shadow_db" && "$source_db" != "$shadow_db" ]] || {
            echo "error: real-data boundary must define distinct source and shadow DBs" >&2
            return 1
        }
        [[ "$shadow_db" == "$qa_home/"* ]] || {
            echo "error: shadow DB is outside qaHome: $shadow_db" >&2
            return 1
        }
    else
        qm_assert_plutil_equals "$manifest" "dataBoundary.quotaMonitorDatabase" "fixture-db"
    fi
}

qm_ax_snapshot_has_expected_windows() {
    local ax_tree="$1"
    [[ -f "$ax_tree" ]] || return 1
    grep -q 'Quota Monitor' "$ax_tree" || return 1
    grep -Eq 'Settings|设置' "$ax_tree" || return 1
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
    local expected_language="${2:-en}"
    local qa_steps="${3:-exercise-settings}"
    local state="${artifacts}/app-state.json"
    local db_counts="${artifacts}/db-counts.txt"
    local dev_log="${artifacts}/quotamonitor-dev.log"
    local screen="${artifacts}/screen.png"
    local screen_warning="${artifacts}/screen-capture-warning.txt"
    local ax_tree="${artifacts}/ax-tree.txt"
    local ax_warning="${artifacts}/ax-dump-warning.txt"

    qm_assert_boundary_manifest_contract "$artifacts" "fixture"

    [[ -f "$state" ]] || {
        echo "error: missing app state: $state" >&2
        return 1
    }
    plutil -convert json -o /dev/null "$state" >/dev/null

    grep -Eq '"title"[[:space:]]*:[[:space:]]*"Quota Monitor"' "$state" || {
        echo "error: dashboard window was not captured in QA state" >&2
        return 1
    }
    grep -Eq '"title"[[:space:]]*:[[:space:]]*"(Settings|设置)"' "$state" || {
        echo "error: settings window was not captured in QA state" >&2
        return 1
    }

    qm_assert_plutil_equals "$state" "settings.language" "$expected_language"
    qm_assert_plutil_equals "$state" "settings.menuBarLabelStyle" "emphasis"
    qm_assert_plutil_equals "$state" "settings.developerModeEnabled" "true"
    if qm_steps_include "$qa_steps" "exercise-settings"; then
        grep -q '"exercise-settings"' "$state" || {
            echo "error: settings exercise step was not captured in QA state" >&2
            return 1
        }
        qm_assert_plutil_equals "$state" "settings.quotaDisplayMode" "remaining"
        qm_assert_plutil_equals "$state" "settings.showDockIconForWindows" "false"
        qm_assert_plutil_equals "$state" "settings.pollIntervalSeconds" "900"
        qm_assert_plutil_equals "$state" "settings.enabledProviders.0" "claude"
        qm_assert_plutil_equals "$state" "settings.menuBarIconProviders.0" "claude"
    fi

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
    if qm_steps_include "$qa_steps" "exercise-settings"; then
        grep -q '"event":"qa.settings.exercise"' "$dev_log" || {
            echo "error: settings exercise event missing from Developer Mode log" >&2
            return 1
        }
    fi
    grep -q '"event":"qa.snapshot.write"' "$dev_log" || {
        echo "error: snapshot write event missing from Developer Mode log" >&2
        return 1
    }
    qm_assert_no_external_data_source_events "$artifacts"

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

qm_assert_real_data_artifact_contract() {
    local artifacts="$1"
    local state="${artifacts}/app-state.json"
    local db_counts="${artifacts}/db-counts.txt"
    local dev_log="${artifacts}/quotamonitor-dev.log"
    local protection="${artifacts}/real-data-protection.txt"
    local screen="${artifacts}/screen.png"
    local screen_warning="${artifacts}/screen-capture-warning.txt"
    local ax_tree="${artifacts}/ax-tree.txt"
    local ax_warning="${artifacts}/ax-dump-warning.txt"

    qm_assert_boundary_manifest_contract "$artifacts" "real-data-shadow"

    [[ -f "$state" ]] || {
        echo "error: missing app state: $state" >&2
        return 1
    }
    plutil -convert json -o /dev/null "$state" >/dev/null

    grep -Eq '"identifier"[[:space:]]*:[[:space:]]*"dashboard"' "$state" || {
        echo "error: dashboard window was not captured in real-data QA state" >&2
        return 1
    }
    grep -Eq '"identifier"[[:space:]]*:[[:space:]]*"settings"' "$state" || {
        echo "error: settings window was not captured in real-data QA state" >&2
        return 1
    }
    qm_plutil_raw "settings.menuBarLabelStyle" "$state" >/dev/null || {
        echo "error: menu-bar label style missing from real-data QA state" >&2
        return 1
    }

    [[ -f "$db_counts" ]] || {
        echo "error: missing real-data db-counts artifact: $db_counts" >&2
        return 1
    }
    [[ "$(stat -f %z "$db_counts")" -gt 0 ]] || {
        echo "error: real-data db-counts artifact is empty: $db_counts" >&2
        return 1
    }

    qm_assert_no_external_data_source_events "$artifacts"
    qm_assert_no_real_provider_paths_leaked "$artifacts"

    [[ -f "$protection" ]] || {
        echo "error: missing real-data protection artifact: $protection" >&2
        return 1
    }
    grep -q '^source_unchanged=true$' "$protection" || {
        echo "error: real-data source DB protection check did not pass" >&2
        return 1
    }

    qm_assert_nonempty_file_or_warning "$screen" "$screen_warning" "screen capture"
    qm_assert_nonempty_file_or_warning "$ax_tree" "$ax_warning" "AX tree"
    if [[ -f "$ax_tree" ]]; then
        if ! qm_ax_snapshot_has_expected_windows "$ax_tree"; then
            if [[ "${QM_QA_REQUIRE_AX:-0}" == "1" ]]; then
                echo "error: expected windows missing from real-data AX tree" >&2
                return 1
            fi
            [[ -f "$ax_warning" ]] || {
                echo "error: expected windows missing from real-data AX tree and no warning file was written" >&2
                return 1
            }
        fi
    fi
}

qm_assert_no_external_data_source_events() {
    local artifacts="$1"
    local dev_log="${artifacts}/quotamonitor-dev.log"
    [[ -f "$dev_log" ]] || return 0

    if grep -E '"event":"(appserver\.|ratelimits\.poll|claude_usage\.poll|claude_credentials|claude_cli|pricing\.refresh_if_stale\.refresh|pricing\.litellm_refresh")' "$dev_log" >&2; then
        echo "error: QA run touched live external data sources" >&2
        return 1
    fi
}

qm_assert_no_real_provider_paths_leaked() {
    local artifacts="$1"
    local source_home="${QM_QA_SOURCE_HOME:-${QM_QA_REAL_SOURCE_HOME:-$HOME}}"
    local real_codex="${source_home}/.codex"
    local real_claude="${source_home}/.claude"
    local real_claude_config="${source_home}/.config/claude"
    local file path

    for file in \
        "${artifacts}/app-state.json" \
        "${artifacts}/qa-config.json" \
        "${artifacts}/quotamonitor-dev.log"; do
        [[ -f "$file" ]] || continue
        for path in "$real_codex" "$real_claude" "$real_claude_config"; do
            if grep -F "$path" "$file" >&2; then
                echo "error: real provider path leaked into QA artifact: $path in $file" >&2
                return 1
            fi
        done
    done
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
