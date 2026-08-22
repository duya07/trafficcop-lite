#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MONITOR_SCRIPT="$ROOT_DIR/trafficcop-lite-monitor.sh"
TELEGRAM_SCRIPT="$ROOT_DIR/trafficcop-lite-telegram.sh"
TEST_ROOT=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/*) rm -rf "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

extract_function() {
    local script_path="$1"
    local function_name="$2"

    awk -v target="$function_name" '
        $0 == target "() {" { found=1 }
        found { print }
        found && /^}$/ { exit }
        END { if (!found) exit 1 }
    ' "$script_path"
}

load_function() {
    local function_body

    function_body=$(extract_function "$1" "$2") || return 1
    # The source files are repository-controlled; evaluation keeps the function in this shell.
    # shellcheck disable=SC2294
    eval "$function_body"
}

assert_file_content() {
    local expected="$1"
    local path="$2"
    local actual

    [ -f "$path" ] || return 1
    actual=$(cat "$path")
    [ "$actual" = "$expected" ]
}

assert_absent() {
    [ ! -e "$1" ]
}

# Production functions are loaded with eval, so ShellCheck cannot see these mocks and variables.
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_period_reset_cancels_owned_shutdown() {
    local work
    work=$(mktemp -d "$TEST_ROOT/period-success.XXXXXX") || return 1
    PERIOD_STATE_FILE="$work/period"
    USAGE_STATE_FILE="$work/usage"
    SHUTDOWN_STATE_FILE="$work/shutdown"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    LOG_FILE="$work/log"

    printf '%s\n' '2026-01-01' > "$PERIOD_STATE_FILE"
    printf '%s\n' 'usage' > "$USAGE_STATE_FILE"
    printf '%s\n' 'owned' > "$SHUTDOWN_STATE_FILE"
    load_function "$MONITOR_SCRIPT" check_reset_limit || return 1
    get_period_start_date() { printf '%s\n' '2027-01-01'; }
    clear_owned_shutdown_schedule() {
        printf '%s\n' 'called' > "$work/shutdown-cancelled"
        rm -f "$SHUTDOWN_STATE_FILE"
    }
    clear_owned_tc_rules() { printf '%s\n' 'called' > "$work/tc-cleared"; }
    enforcement_state_value() { printf '%s\n' ''; }

    check_reset_limit >/dev/null || return 1
    assert_file_content 'called' "$work/shutdown-cancelled" || return 1
    assert_file_content 'called' "$work/tc-cleared" || return 1
    assert_file_content '2027-01-01' "$PERIOD_STATE_FILE" || return 1
    assert_absent "$USAGE_STATE_FILE" || return 1
    assert_absent "$SHUTDOWN_STATE_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_period_reset_stops_when_shutdown_cancel_fails() {
    local work
    work=$(mktemp -d "$TEST_ROOT/period-failure.XXXXXX") || return 1
    PERIOD_STATE_FILE="$work/period"
    USAGE_STATE_FILE="$work/usage"
    SHUTDOWN_STATE_FILE="$work/shutdown"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    LOG_FILE="$work/log"

    printf '%s\n' '2026-01-01' > "$PERIOD_STATE_FILE"
    printf '%s\n' 'usage' > "$USAGE_STATE_FILE"
    printf '%s\n' 'owned' > "$SHUTDOWN_STATE_FILE"
    load_function "$MONITOR_SCRIPT" check_reset_limit || return 1
    get_period_start_date() { printf '%s\n' '2027-01-01'; }
    clear_owned_shutdown_schedule() { return 1; }
    clear_owned_tc_rules() { printf '%s\n' 'unexpected' > "$work/tc-cleared"; }
    enforcement_state_value() { printf '%s\n' ''; }

    if check_reset_limit >/dev/null; then
        return 1
    fi
    assert_file_content '2026-01-01' "$PERIOD_STATE_FILE" || return 1
    assert_file_content 'usage' "$USAGE_STATE_FILE" || return 1
    assert_file_content 'owned' "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/tc-cleared"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shutdown_cleanup_respects_boot_ownership() {
    local work
    work=$(mktemp -d "$TEST_ROOT/shutdown-ownership.XXXXXX") || return 1
    LOG_FILE="$work/log"
    current_boot_id() { printf '%s\n' 'new-boot'; }
    has_pending_shutdown() { return 0; }
    lite_has_pending_shutdown() { return 0; }
    cat() {
        if [ "${1:-}" = "/proc/sys/kernel/random/boot_id" ]; then
            printf '%s\n' 'new-boot'
        else
            command cat "$@"
        fi
    }
    shutdown() { printf '%s\n' 'called' >> "$work/shutdown-called"; }

    load_function "$MONITOR_SCRIPT" shutdown_state_value || return 1
    load_function "$MONITOR_SCRIPT" clear_owned_shutdown_schedule || return 1
    SHUTDOWN_STATE_FILE="$work/monitor-state"
    printf '%s\n' 'BOOT_ID=old-boot' > "$SHUTDOWN_STATE_FILE"
    clear_owned_shutdown_schedule >/dev/null || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/shutdown-called" || return 1

    load_function "$ROOT_DIR/trafficcop-lite.sh" cancel_shutdown_interactive || return 1
    WORK_DIR="$work"
    RED=''
    NC=''
    SHUTDOWN_STATE_FILE="$work/main-state"
    printf '%s\n' 'BOOT_ID=old-boot' > "$SHUTDOWN_STATE_FILE"
    cancel_shutdown_interactive >/dev/null || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/shutdown-called" || return 1

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" cancel_owned_shutdown || return 1
    SHUTDOWN_STATE_FILE="$work/machine-state"
    printf '%s\n' 'BOOT_ID=old-boot' > "$SHUTDOWN_STATE_FILE"
    cancel_owned_shutdown >/dev/null || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/shutdown-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shutdown_cleanup_blocks_unverifiable_pending_task() {
    local work
    work=$(mktemp -d "$TEST_ROOT/shutdown-unknown.XXXXXX") || return 1
    LOG_FILE="$work/log"
    SHUTDOWN_STATE_FILE="$work/state"
    printf '%s\n' 'PERIOD_START=2026-01-01' > "$SHUTDOWN_STATE_FILE"

    load_function "$MONITOR_SCRIPT" shutdown_state_value || return 1
    load_function "$MONITOR_SCRIPT" clear_owned_shutdown_schedule || return 1
    current_boot_id() { printf '%s\n' 'new-boot'; }
    has_pending_shutdown() { return 0; }
    shutdown() { printf '%s\n' 'called' > "$work/shutdown-called"; }

    if clear_owned_shutdown_schedule >/dev/null; then
        return 1
    fi
    assert_file_content 'PERIOD_START=2026-01-01' "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/shutdown-called"
}

mock_bc() {
    local expression
    expression=$(cat)
    case "$expression" in
        *' > 0'|*' < '*) printf '%s\n' '1' ;;
        *) printf '%s\n' '0' ;;
    esac
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_config_restores_previous_state() {
    local work input
    work=$(mktemp -d "$TEST_ROOT/config-restore.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    LOG_FILE="$work/log"
    printf '%s\n' 'old-config' > "$CONFIG_FILE"
    printf '%s\n' 'old-enforcement' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    get_main_interface() { printf '%s\n' 'eth0'; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() { printf '%s\n' 'new-config' > "$CONFIG_FILE"; }
    configure_post_save_enforcement() {
        rm -f "$ENFORCEMENT_STATE_FILE"
        return 1
    }

    input=$'3\nm\n1\n1\n100\n10\n1\n100\n10\n'
    if printf '%s' "$input" | initial_config >/dev/null; then
        return 1
    fi
    assert_file_content 'old-config' "$CONFIG_FILE" || return 1
    assert_file_content 'old-enforcement' "$ENFORCEMENT_STATE_FILE" || return 1
    ! find "$work" -name '*.before-config.*' -print -quit | grep -q .
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_config_removes_failed_first_config() {
    local work input
    work=$(mktemp -d "$TEST_ROOT/config-first.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    LOG_FILE="$work/log"

    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    get_main_interface() { printf '%s\n' 'eth0'; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() { printf '%s\n' 'new-config' > "$CONFIG_FILE"; }
    configure_post_save_enforcement() {
        printf '%s\n' 'new-enforcement' > "$ENFORCEMENT_STATE_FILE"
        return 1
    }

    input=$'3\nm\n1\n1\n100\n10\n1\n100\n10\n'
    if printf '%s' "$input" | initial_config >/dev/null; then
        return 1
    fi
    assert_absent "$CONFIG_FILE" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_config_rolls_back_when_writer_reports_failure() {
    local work input
    work=$(mktemp -d "$TEST_ROOT/config-write-failure.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    LOG_FILE="$work/log"
    printf '%s\n' 'old-config' > "$CONFIG_FILE"
    printf '%s\n' 'old-enforcement' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    get_main_interface() { printf '%s\n' 'eth0'; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() {
        printf '%s\n' 'new-config' > "$CONFIG_FILE"
        return 1
    }
    configure_post_save_enforcement() { return 0; }

    input=$'3\nm\n1\n1\n100\n10\n1\n100\n10\n'
    if printf '%s' "$input" | initial_config >/dev/null; then
        return 1
    fi
    assert_file_content 'old-config' "$CONFIG_FILE" || return 1
    assert_file_content 'old-enforcement' "$ENFORCEMENT_STATE_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_rollback_preserves_backup_on_restore_failure() {
    local work config_backup enforcement_backup
    work=$(mktemp -d "$TEST_ROOT/config-rollback-failure.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    config_backup="$work/config.backup"
    enforcement_backup="$work/enforcement.backup"
    printf '%s\n' 'new-config' > "$CONFIG_FILE"
    printf '%s\n' 'old-config' > "$config_backup"
    printf '%s\n' 'old-enforcement' > "$enforcement_backup"

    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    mv() {
        if [ "${*: -1}" = "$CONFIG_FILE" ]; then
            return 1
        fi
        command mv "$@"
    }

    if restore_monitor_config_snapshot "$config_backup" true "$enforcement_backup" true; then
        return 1
    fi
    assert_file_content 'old-config' "$config_backup" || return 1
    assert_file_content 'new-config' "$CONFIG_FILE" || return 1
    assert_file_content 'old-enforcement' "$ENFORCEMENT_STATE_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_marker_rolls_back_when_config_commit_fails() {
    local work config_tmp marker_tmp config_path
    work=$(mktemp -d "$TEST_ROOT/vnstat-rollback.XXXXXX") || return 1
    config_path="$work/vnstat.conf"
    config_tmp="$work/vnstat.conf.tmp"
    RETENTION_STATE_FILE="$work/coverage"
    marker_tmp="$work/coverage.tmp"
    printf '%s\n' 'DailyDays 30' > "$config_path"
    printf '%s\n' 'DailyDays 400' > "$config_tmp"
    printf '%s\n' '2026-01-01' > "$RETENTION_STATE_FILE"
    printf '%s\n' '2026-08-11' > "$marker_tmp"

    load_function "$MONITOR_SCRIPT" commit_vnstat_retention_update || return 1
    mv() {
        local destination="${*: -1}"
        if [ "$destination" = "$config_path" ]; then
            return 1
        fi
        command mv "$@"
    }

    if commit_vnstat_retention_update "$config_path" "$config_tmp" "$marker_tmp"; then
        return 1
    fi
    assert_file_content 'DailyDays 30' "$config_path" || return 1
    assert_file_content '2026-01-01' "$RETENTION_STATE_FILE" || return 1
    assert_absent "$config_tmp" || return 1
    assert_absent "$marker_tmp"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_config_and_marker_commit_together() {
    local work config_tmp marker_tmp config_path
    work=$(mktemp -d "$TEST_ROOT/vnstat-success.XXXXXX") || return 1
    config_path="$work/vnstat.conf"
    config_tmp="$work/vnstat.conf.tmp"
    RETENTION_STATE_FILE="$work/coverage"
    marker_tmp="$work/coverage.tmp"
    printf '%s\n' 'DailyDays 30' > "$config_path"
    printf '%s\n' 'DailyDays 400' > "$config_tmp"
    printf '%s\n' '2026-01-01' > "$RETENTION_STATE_FILE"
    printf '%s\n' '2026-08-11' > "$marker_tmp"

    load_function "$MONITOR_SCRIPT" commit_vnstat_retention_update || return 1
    commit_vnstat_retention_update "$config_path" "$config_tmp" "$marker_tmp" || return 1
    assert_file_content 'DailyDays 400' "$config_path" || return 1
    assert_file_content '2026-08-11' "$RETENTION_STATE_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_menu_does_not_hold_cron_lock() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg-menu.XXXXXX") || return 1
    CRON_LOG="$work/log"
    CRON_LOG_MAX_LINES=100
    TG_DISABLED=true
    MACHINE_NAME='test'
    DAILY_REPORT_TIME=08:00
    REPORT_TIMEZONE=UTC
    BOT_TOKEN=1234567890abcdef
    CHAT_ID=1

    load_function "$TELEGRAM_SCRIPT" main || return 1
    debug_log() { return 0; }
    check_runtime_dependencies() { return 0; }
    check_running() { printf '%s\n' 'called' > "$work/lock-called"; }
    read_config() { TG_DISABLED=true; return 0; }
    remove_telegram_cron() { return 0; }
    clear() { return 0; }

    (printf '%s\n' '0' | main >/dev/null) || return 1
    assert_absent "$work/lock-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_cron_still_takes_lock() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg-cron.XXXXXX") || return 1
    CRON_LOG="$work/log"
    TG_DISABLED=true

    load_function "$TELEGRAM_SCRIPT" main || return 1
    debug_log() { return 0; }
    log_cron() { return 0; }
    check_runtime_dependencies() { return 0; }
    check_running() { printf '%s\n' 'called' > "$work/lock-called"; }
    read_config() { TG_DISABLED=true; return 0; }

    main -cron || return 1
    assert_file_content 'called' "$work/lock-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_action_releases_lock_after_failure() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg-release.XXXXXX") || return 1
    load_function "$TELEGRAM_SCRIPT" run_with_telegram_lock || return 1
    check_running() { printf '%s\n' "$1" > "$work/acquired"; }
    release_running_lock() { printf '%s\n' 'called' > "$work/released"; }
    fail_action() { return 1; }

    if run_with_telegram_lock fail_action; then
        return 1
    fi
    assert_file_content '15' "$work/acquired" || return 1
    assert_file_content 'called' "$work/released"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_real_lock_contention_and_release() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg-real-lock.XXXXXX") || return 1
    TG_LOCK_FILE="$work/telegram.lock"
    CRON_LOG="$work/log"
    CRON_LOG_MAX_LINES=100

    load_function "$TELEGRAM_SCRIPT" check_running || return 1
    load_function "$TELEGRAM_SCRIPT" release_running_lock || return 1
    trim_log_file() { return 0; }

    exec 7>"$TG_LOCK_FILE"
    flock -n 7 || return 1
    if check_running 1 >/dev/null; then
        return 1
    fi
    flock -u 7 || return 1
    exec 7>&-

    check_running >/dev/null || return 1
    release_running_lock
    exec 7>"$TG_LOCK_FILE"
    flock -n 7 || return 1
    flock -u 7 || return 1
    exec 7>&-
}

# shellcheck disable=SC2034,SC2317,SC2329
test_update_rejects_older_candidate() {
    local work
    work=$(mktemp -d "$TEST_ROOT/update-downgrade.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    RED=''
    NC=''
    mkdir -p "$WORK_DIR"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.3"' > "$WORK_DIR/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.2"' > "$work/candidate.sh"

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" validate_update_candidate || return 1

    if validate_update_candidate trafficcop-lite.sh "$work/candidate.sh" >/dev/null; then
        return 1
    fi
    assert_file_content "$(printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.3"')" "$WORK_DIR/trafficcop-lite.sh"
}

# shellcheck disable=SC2034,SC2317,SC2329
test_single_file_install_refreshes_all_scripts() {
    local work
    work=$(mktemp -d "$TEST_ROOT/single-install.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    SCRIPT_DIR="$work/download"
    SOURCE_PATH="$SCRIPT_DIR/trafficcop-lite.sh"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'
    RAW_BASE='https://example.invalid/release'
    CYAN=''
    NC=''
    mkdir -p "$SCRIPT_DIR"
    : > "$SOURCE_PATH"

    load_function "$ROOT_DIR/trafficcop-lite.sh" source_has_complete_bundle || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_from_entrypoint || return 1
    update_scripts() { printf '%s\n' "$1" > "$work/update-called"; }
    install_shortcut() { printf '%s\n' 'unexpected' > "$work/local-install-called"; }

    install_from_entrypoint >/dev/null || return 1
    assert_file_content "$RAW_BASE" "$work/update-called" || return 1
    assert_absent "$work/local-install-called"
}

# shellcheck disable=SC2034,SC2317,SC2329
test_complete_bundle_install_stays_local() {
    local work script_name
    work=$(mktemp -d "$TEST_ROOT/bundle-install.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    SCRIPT_DIR="$work/bundle"
    SOURCE_PATH="$SCRIPT_DIR/trafficcop-lite.sh"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'
    CYAN=''
    NC=''
    mkdir -p "$SCRIPT_DIR"
    for script_name in trafficcop-lite.sh "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
        : > "$SCRIPT_DIR/$script_name"
    done

    load_function "$ROOT_DIR/trafficcop-lite.sh" source_has_complete_bundle || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_from_entrypoint || return 1
    update_scripts() { printf '%s\n' 'unexpected' > "$work/update-called"; }
    install_shortcut() { printf '%s\n' 'called' > "$work/local-install-called"; }

    install_from_entrypoint >/dev/null || return 1
    assert_file_content 'called' "$work/local-install-called" || return 1
    assert_absent "$work/update-called"
}

# shellcheck disable=SC2034,SC2317,SC2329
test_update_replaces_full_release_and_preserves_state() {
    local work script_name backup_main
    work=$(mktemp -d "$TEST_ROOT/update-release.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    local remote_dir="$work/remote"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
    mkdir -p "$WORK_DIR" "$remote_dir"

    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.2"' > "$WORK_DIR/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.0"' > "$WORK_DIR/$MONITOR_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.0"' > "$WORK_DIR/$TELEGRAM_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop Lite Machine Limit v2.0' > "$WORK_DIR/$MACHINE_LIMIT_SCRIPT"
    printf '%s\n' 'CONFIG=keep-me' > "$WORK_DIR/traffic_monitor_config.txt"

    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.7"' > "$remote_dir/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.5"' > "$remote_dir/$MONITOR_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.3"' > "$remote_dir/$TELEGRAM_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop Lite Machine Limit v2.7' > "$remote_dir/$MACHINE_LIMIT_SCRIPT"

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" validate_update_candidate || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" verify_installed_scripts || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" rollback_script_update || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" update_scripts || return 1
    ensure_work_dir() { mkdir -p "$WORK_DIR"; }
    download_url_to_file() { cp "$remote_dir/$(basename "$1")" "$2"; }
    install_shortcut_link() { printf '%s\n' 'called' > "$work/shortcut-called"; }

    update_scripts 'https://example.invalid/release' >/dev/null || return 1
    grep -Fqx 'SCRIPT_VERSION="1.1.7"' "$WORK_DIR/trafficcop-lite.sh" || return 1
    grep -Fqx 'SCRIPT_VERSION="1.1.5"' "$WORK_DIR/$MONITOR_SCRIPT" || return 1
    grep -Fqx 'SCRIPT_VERSION="1.1.3"' "$WORK_DIR/$TELEGRAM_SCRIPT" || return 1
    grep -Fqx '# TrafficCop Lite Machine Limit v2.7' "$WORK_DIR/$MACHINE_LIMIT_SCRIPT" || return 1
    assert_file_content 'CONFIG=keep-me' "$WORK_DIR/traffic_monitor_config.txt" || return 1
    backup_main=$(find "$WORK_DIR/backups" -type f -name trafficcop-lite.sh -print -quit) || return 1
    [ -n "$backup_main" ] || return 1
    grep -Fqx 'SCRIPT_VERSION="1.0.2"' "$backup_main" || return 1
    [ "$UPDATE_PREVIOUS_VERSION" = '1.0.2' ] || return 1
    [ "$UPDATE_NEW_VERSION" = '1.1.7' ] || return 1
    assert_file_content 'called' "$work/shortcut-called"
}

# shellcheck disable=SC2034
test_update_rollback_requires_backup_evidence() {
    local work
    work=$(mktemp -d "$TEST_ROOT/update-rollback.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    local backup_dir="$work/backup"
    mkdir -p "$WORK_DIR" "$backup_dir"

    printf '%s\n' 'old-main' > "$backup_dir/trafficcop-lite.sh"
    : > "$backup_dir/.absent-trafficcop-lite-monitor.sh"
    printf '%s\n' 'new-main' > "$WORK_DIR/trafficcop-lite.sh"
    printf '%s\n' 'new-monitor' > "$WORK_DIR/trafficcop-lite-monitor.sh"
    printf '%s\n' 'new-telegram' > "$WORK_DIR/trafficcop-lite-telegram.sh"

    load_function "$ROOT_DIR/trafficcop-lite.sh" rollback_script_update || return 1
    if rollback_script_update \
        "$backup_dir" \
        trafficcop-lite.sh \
        trafficcop-lite-monitor.sh \
        trafficcop-lite-telegram.sh; then
        return 1
    fi

    assert_file_content 'old-main' "$WORK_DIR/trafficcop-lite.sh" || return 1
    assert_absent "$WORK_DIR/trafficcop-lite-monitor.sh" || return 1
    assert_file_content 'new-telegram' "$WORK_DIR/trafficcop-lite-telegram.sh"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_retention_decline_aborts_configuration() {
    TRAFFIC_PERIOD='yearly'

    load_function "$MONITOR_SCRIPT" ensure_vnstat_daily_retention || return 1
    vnstat_config_value() { printf '%s\n' '30'; }

    if printf '%s\n' 'n' | ensure_vnstat_daily_retention >/dev/null; then
        return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_history_read_error_aborts_configuration() {
    local work
    work=$(mktemp -d "$TEST_ROOT/history-read-error.XXXXXX") || return 1
    RETENTION_STATE_FILE="$work/coverage"

    load_function "$MONITOR_SCRIPT" history_incomplete_for_current_period || return 1
    load_function "$MONITOR_SCRIPT" configure_history_policy || return 1
    get_period_start_date() { printf '%s\n' '2026-01-01'; }
    get_vnstat_available_start() { return 1; }
    vnstat_config_value() { printf '%s\n' '1'; }

    if configure_history_policy >/dev/null; then
        return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_read_error_preserves_runtime_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/post-save-read-error.XXXXXX") || return 1
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    printf '%s\n' 'MODE=paused' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" configure_post_save_enforcement || return 1
    get_traffic_usage() { return 1; }
    clear_owned_shutdown_schedule() { printf '%s\n' 'called' > "$work/shutdown-cleared"; }
    clear_owned_tc_rules() { printf '%s\n' 'called' > "$work/tc-cleared"; }

    if configure_post_save_enforcement >/dev/null; then
        return 1
    fi
    assert_file_content 'MODE=paused' "$ENFORCEMENT_STATE_FILE" || return 1
    assert_absent "$work/shutdown-cleared" || return 1
    assert_absent "$work/tc-cleared"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_change_requires_prepared_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-prewrite.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    MAIN_INTERFACE='eth0'
    TC_BIN='mock_tc'
    local lock_held=false

    load_function "$MONITOR_SCRIPT" apply_tc_limit || return 1
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc fq_codel 0: root'; }
    tc_state_interface() { return 0; }
    tc_root_is_unified_compatible() { return 1; }
    tc_legacy_tbf_is_owned() { return 1; }
    is_default_qdisc_line() { return 0; }
    write_tc_state() {
        printf '%s\n' 'called' > "$work/state-prewrite"
        return 1
    }
    mock_tc() { printf '%s\n' 'called' > "$work/tc-called"; }

    if apply_tc_limit 100 >/dev/null; then
        return 1
    fi
    assert_file_content 'called' "$work/state-prewrite" || return 1
    assert_absent "$work/tc-called" || return 1
    [ "$lock_held" = "false" ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_builds_unified_htb_directly() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-direct-htb.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    MAIN_INTERFACE='eth0'
    TC_BIN='mock_tc'
    local lock_held=false

    load_function "$MONITOR_SCRIPT" apply_tc_limit || return 1
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc fq_codel 0: root'; }
    tc_state_interface() { return 0; }
    tc_root_is_unified_compatible() { return 1; }
    tc_legacy_tbf_is_owned() { return 1; }
    is_default_qdisc_line() { return 0; }
    mock_tc() {
        [ "$lock_held" = "true" ] || return 1
        printf '%s\n' "$*" >> "$work/tc-called"
    }
    write_tc_state() { printf '%s\n' "$1|$2" > "$4"; }
    tc_replace_base_classes() {
        [ "$lock_held" = "true" ] || return 1
        printf '%s\n' "$1|$2" > "$work/base-classes"
    }
    tc_verify_unified_hierarchy() { return 0; }

    apply_tc_limit 90 >/dev/null || return 1
    grep -Fq 'qdisc replace dev eth0 root handle 1: htb default 30' "$work/tc-called" || return 1
    assert_file_content 'eth0|90kbit' "$work/base-classes" || return 1
    assert_file_content 'eth0|90' "$TC_STATE_FILE" || return 1
    [ "$lock_held" = "false" ] || return 1
    ! grep -Eq 'dog_tc_manager|--apply-global-tc-limit|--remove-global-tc-limit' "$MONITOR_SCRIPT"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_refuses_foreign_root_without_mutation() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-foreign-root.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    MAIN_INTERFACE='eth0'
    TC_BIN='mock_tc'
    local lock_held=false

    load_function "$MONITOR_SCRIPT" apply_tc_limit || return 1
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc htb 1: root default 10'; }
    tc_state_interface() { return 0; }
    tc_root_is_unified_compatible() { return 1; }
    tc_legacy_tbf_is_owned() { return 1; }
    is_default_qdisc_line() { return 1; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }
    write_tc_state() { printf '%s\n' 'unexpected' > "$work/state-written"; }

    if apply_tc_limit 90 >/dev/null; then
        return 1
    fi
    assert_absent "$work/tc-called" || return 1
    assert_absent "$work/state-written" || return 1
    [ "$lock_held" = "false" ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_legacy_tbf_requires_matching_numeric_speed() {
    TC_STATE_PROVIDER='trafficcop-lite'
    local mock_state_speed='invalid'

    load_function "$MONITOR_SCRIPT" tc_legacy_tbf_is_owned || return 1
    tc_state_interface() { printf '%s\n' 'eth0'; }
    tc_state_value() {
        case "$1" in
            SCHEMA) return 0 ;;
            PROVIDER) printf '%s\n' 'trafficcop-lite' ;;
            QDISC_LINE) printf '%s\n' 'qdisc tbf 8001: root rate 5Mbit burst 32Kb lat 400ms' ;;
            LIMIT_SPEED) printf '%s\n' "$mock_state_speed" ;;
        esac
    }
    normalize_tc_rate_to_bps() {
        case "${1,,}" in
            5mbit) printf '%s\n' '5000000' ;;
            *) return 1 ;;
        esac
    }

    if tc_legacy_tbf_is_owned eth0 'qdisc tbf 8001: root rate 5Mbit burst 32Kb lat 400ms'; then
        return 1
    fi
    mock_state_speed='5000'
    tc_legacy_tbf_is_owned eth0 'qdisc tbf 8001: root rate 5Mbit burst 32Kb lat 400ms'
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_invalid_dog_config_cannot_authorize_adoption() {
    local work
    work=$(mktemp -d "$TEST_ROOT/invalid-dog-config.XXXXXX") || return 1
    DOG_CONFIG_FILE="$work/config.json"
    printf '%s\n' '{"ports":' > "$DOG_CONFIG_FILE"

    load_function "$MONITOR_SCRIPT" dog_configured_class_ids || return 1
    if dog_configured_class_ids >/dev/null; then
        return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_unified_hierarchy_verification_requires_full_contract() {
    TC_DEFAULT_CLASS_RATE='1kbit'
    load_function "$MONITOR_SCRIPT" tc_verify_unified_hierarchy || return 1
    tc_root_is_htb_handle_one() { return 0; }
    tc_root_has_default_30() { return 1; }
    tc_root_has_parent_class() { return 0; }
    tc_class_line() { printf '%s\n' 'class htb 1:30 parent 1:1'; }
    tc_class_rate_matches() { return 0; }
    if tc_verify_unified_hierarchy eth0 90kbit; then
        return 1
    fi

    tc_root_has_default_30() { return 0; }
    tc_root_has_parent_class() { return 1; }
    if tc_verify_unified_hierarchy eth0 90kbit; then
        return 1
    fi

    tc_root_has_parent_class() { return 0; }
    tc_class_line() { printf '%s\n' 'class htb 1:30 parent 1:2'; }
    if tc_verify_unified_hierarchy eth0 90kbit; then
        return 1
    fi

    tc_class_line() { printf '%s\n' 'class htb 1:30 parent 1:1'; }
    tc_verify_unified_hierarchy eth0 90kbit
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_crontab_update_holds_project_lock() {
    local work
    work=$(mktemp -d "$TEST_ROOT/root-cron-lock.XXXXXX") || return 1
    LOG_FILE="$work/log"
    SCRIPT_PATH='/etc/trafficcop-lite/trafficcop-lite-monitor.sh'
    ROOT_CRONTAB_LOCK_FILE="$work/root-crontab.lock"
    local lock_held=false

    load_function "$MONITOR_SCRIPT" setup_crontab || return 1
    acquire_root_crontab_lock() { lock_held=true; }
    release_root_crontab_lock() { lock_held=false; }
    read_current_crontab() {
        [ "$lock_held" = "true" ] || return 1
        printf '%s\n' '17 * * * * /usr/local/bin/unrelated-job'
    }
    crontab() {
        [ "$lock_held" = "true" ] || return 1
        [ "$1" = "-" ] || return 1
        cat > "$work/crontab"
    }

    setup_crontab >/dev/null || return 1
    [ "$lock_held" = "false" ] || return 1
    grep -Fq '/usr/local/bin/unrelated-job' "$work/crontab" || return 1
    grep -Fq "$SCRIPT_PATH --run" "$work/crontab" || return 1
    for script in trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh; do
        grep -Fq '$WORK_DIR/root-crontab.lock' "$ROOT_DIR/$script" || return 1
        ! grep -Fq '/run/lock/traffic-tools-root-crontab.lock' "$ROOT_DIR/$script" || return 1
        grep -Fq 'read_root_crontab_locked()' "$ROOT_DIR/$script" || return 1
        [ "$(grep -c 'crontab -l' "$ROOT_DIR/$script")" -eq 1 ] || return 1
    done
    grep -Fq '/run/lock/traffic-tools-tc.lock' "$MONITOR_SCRIPT"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shutdown_requires_prepared_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/shutdown-prewrite.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TC_STATE_FILE="$work/tc-state"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    TRAFFIC_UNIT='decimal'
    TRAFFIC_LIMIT='100'
    TRAFFIC_TOLERANCE='0'
    LIMIT_MODE='shutdown'

    load_function "$MONITOR_SCRIPT" check_and_limit_traffic || return 1
    get_traffic_usage() { printf '%s\n' '100.000'; }
    bc() {
        local expression
        expression=$(cat)
        case "$expression" in
            *' - '*) printf '%s\n' '100' ;;
            *' <= 0') printf '%s\n' '0' ;;
            *' >= '*) printf '%s\n' '1' ;;
            *) printf '%s\n' '0' ;;
        esac
    }
    shutdown_reboot_guard_active() { return 1; }
    enforcement_guard_active() { return 1; }
    has_pending_shutdown() { return 1; }
    write_shutdown_state() {
        printf '%s\n' 'called' > "$work/state-prewrite"
        return 1
    }
    shutdown() { printf '%s\n' 'called' > "$work/shutdown-called"; }
    write_usage_state() { return 0; }
    clear_owned_tc_rules() { return 0; }

    if check_and_limit_traffic >/dev/null; then
        return 1
    fi
    assert_file_content 'called' "$work/state-prewrite" || return 1
    assert_absent "$work/shutdown-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_config_does_not_reuse_stale_secret() {
    local work
    work=$(mktemp -d "$TEST_ROOT/telegram-stale.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    BOT_TOKEN='stale-secret'
    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_FORMAT=plain-v2
CHAT_ID=12345
DAILY_REPORT_TIME=08:00
REPORT_TIMEZONE=UTC
MACHINE_NAME=test
TG_DISABLED=false
EOF

    load_function "$TELEGRAM_SCRIPT" decode_legacy_config_value || return 1
    load_function "$TELEGRAM_SCRIPT" read_config || return 1
    is_valid_timezone() { return 0; }

    if read_config >/dev/null; then
        return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_legacy_config_is_parsed_without_execution() {
    local work marker
    work=$(mktemp -d "$TEST_ROOT/telegram-legacy.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    marker="$work/executed"
    cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN=\$(touch "$marker"; printf token)
CHAT_ID=12345
DAILY_REPORT_TIME=08:00
REPORT_TIMEZONE=UTC
MACHINE_NAME=legacy\\ server
EOF

    load_function "$TELEGRAM_SCRIPT" decode_legacy_config_value || return 1
    load_function "$TELEGRAM_SCRIPT" read_config || return 1
    is_valid_timezone() { return 0; }

    read_config >/dev/null || return 1
    assert_absent "$marker" || return 1
    [ "$MACHINE_NAME" = 'legacy server' ] || return 1
    [ "$TG_DISABLED" = 'false' ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_plain_config_round_trip() {
    local work expected_name
    work=$(mktemp -d "$TEST_ROOT/telegram-round-trip.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    BOT_TOKEN='123456:test-token'
    CHAT_ID='-10012345'
    DAILY_REPORT_TIME='09:30'
    REPORT_TIMEZONE='UTC'
    expected_name='edge node\primary=1'
    MACHINE_NAME="$expected_name"
    TG_DISABLED='true'

    load_function "$TELEGRAM_SCRIPT" decode_legacy_config_value || return 1
    load_function "$TELEGRAM_SCRIPT" read_config || return 1
    load_function "$TELEGRAM_SCRIPT" write_config_value || return 1
    load_function "$TELEGRAM_SCRIPT" write_config || return 1
    is_valid_timezone() { return 0; }

    write_config >/dev/null || return 1
    grep -Fqx 'CONFIG_FORMAT=plain-v2' "$CONFIG_FILE" || return 1
    read_config >/dev/null || return 1
    [ "$MACHINE_NAME" = "$expected_name" ] || return 1
    [ "$TG_DISABLED" = 'true' ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_token_is_not_in_curl_arguments() {
    local work
    work=$(mktemp -d "$TEST_ROOT/telegram-curl.XXXXXX") || return 1
    BOT_TOKEN='123456:top-secret-token'
    CHAT_ID='12345'

    load_function "$TELEGRAM_SCRIPT" telegram_send_message || return 1
    curl() {
        printf '%s\n' "$@" > "$work/curl-args"
        cat > "$work/curl-stdin"
        printf '%s\n' '{"ok":true}'
    }

    telegram_send_message 'test message' || return 1
    ! grep -Fq "$BOT_TOKEN" "$work/curl-args" || return 1
    grep -Fq "$BOT_TOKEN" "$work/curl-stdin"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_component_download_rejects_versionless_body() {
    local work
    work=$(mktemp -d "$TEST_ROOT/component-version.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    RAW_BASE='https://example.invalid/release'
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
    mkdir -p "$WORK_DIR"

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" validate_update_candidate || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" download_component || return 1
    download_url_to_file() { printf '%s\n' 'upstream temporarily unavailable' > "$2"; }

    if download_component trafficcop-lite-monitor.sh >/dev/null; then
        return 1
    fi
    assert_absent "$WORK_DIR/trafficcop-lite-monitor.sh"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_period_date_boundaries() {
    local CURRENT_DATE='2026-01-01'

    load_function "$MONITOR_SCRIPT" is_leap_year || return 1
    load_function "$MONITOR_SCRIPT" days_in_month || return 1
    load_function "$MONITOR_SCRIPT" get_anchor_date || return 1
    load_function "$MONITOR_SCRIPT" date_to_num || return 1
    load_function "$MONITOR_SCRIPT" shift_month || return 1
    load_function "$MONITOR_SCRIPT" previous_day || return 1
    load_function "$MONITOR_SCRIPT" get_period_start_date || return 1
    load_function "$MONITOR_SCRIPT" get_period_end_date || return 1
    date() {
        case "${1:-}" in
            +%Y-%m-%d) printf '%s\n' "$CURRENT_DATE" ;;
            +%Y) printf '%s\n' "${CURRENT_DATE:0:4}" ;;
            +%m) printf '%s\n' "${CURRENT_DATE:5:2}" ;;
            *) command date "$@" ;;
        esac
    }
    check_case() {
        local expected_start="$5"
        local expected_end="$6"
        CURRENT_DATE="$1"
        TRAFFIC_PERIOD="$2"
        PERIOD_START_MONTH="$3"
        PERIOD_START_DAY="$4"
        [ "$(get_period_start_date)" = "$expected_start" ] \
            && [ "$(get_period_end_date)" = "$expected_end" ]
    }

    check_case 2026-07-22 yearly 7 23 2025-07-23 2026-07-22 || return 1
    check_case 2026-07-23 yearly 7 23 2026-07-23 2027-07-22 || return 1
    check_case 2026-02-28 monthly 1 31 2026-02-28 2026-03-30 || return 1
    check_case 2026-03-30 monthly 1 31 2026-02-28 2026-03-30 || return 1
    check_case 2026-04-30 quarterly 1 31 2026-04-30 2026-07-30 || return 1
    check_case 2024-02-29 yearly 2 31 2024-02-29 2025-02-27
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_traffic_accounting_modes() {
    command -v jq >/dev/null 2>&1 || return 1
    MAIN_INTERFACE='eth0'
    TRAFFIC_PERIOD='monthly'
    TRAFFIC_UNIT='decimal'
    ALLOW_PARTIAL_HISTORY='false'
    WORK_DIR="$TEST_ROOT/nonexistent"
    RETENTION_STATE_FILE="$WORK_DIR/coverage"

    load_function "$MONITOR_SCRIPT" get_traffic_usage || return 1
    get_period_start_date() { printf '%s\n' '2026-07-01'; }
    get_period_end_date() { printf '%s\n' '2026-07-31'; }
    date_num_to_iso() { printf '%s\n' "$1"; }
    vnstat_config_value() {
        case "$1" in
            DailyDays) printf '%s\n' '-1' ;;
            TrafficlessEntries) printf '%s\n' '0' ;;
        esac
    }
    vnstat() {
        cat <<'JSON'
{"interfaces":[{"created":{"date":{"year":2025,"month":1,"day":1}},"traffic":{"day":[{"date":{"year":2026,"month":6,"day":30},"rx":10000000000,"tx":10000000000},{"date":{"year":2026,"month":7,"day":1},"rx":1000000000,"tx":2000000000},{"date":{"year":2026,"month":7,"day":2},"rx":3000000000,"tx":1000000000}]}}]}
JSON
    }
    check_mode() {
        TRAFFIC_MODE="$1"
        [ "$(get_traffic_usage 2>/dev/null)" = "$2" ]
    }

    check_mode out 3.000 || return 1
    check_mode in 4.000 || return 1
    check_mode total 7.000 || return 1
    check_mode max 4.000
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_invalid_limit_speed_is_rejected() {
    local work
    work=$(mktemp -d "$TEST_ROOT/invalid-speed.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TRAFFIC_MODE='total'
    TRAFFIC_PERIOD='monthly'
    TRAFFIC_LIMIT='100'
    TRAFFIC_TOLERANCE='0'
    TRAFFIC_UNIT='decimal'
    PERIOD_START_DAY='1'
    PERIOD_START_MONTH='1'
    TC_BOOT_GRACE_MINUTES='10'
    ALLOW_PARTIAL_HISTORY='false'
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'

    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    load_function "$MONITOR_SCRIPT" validate_config || return 1
    command_exists() { return 1; }

    LIMIT_SPEED='corrupt'
    if validate_config >/dev/null; then
        return 1
    fi
    [ "$LIMIT_SPEED" = 'corrupt' ] || return 1

    unset LIMIT_SPEED
    validate_config >/dev/null || return 1
    [ "$LIMIT_SPEED" = '20' ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_runtime_rejects_invalid_limit_speed() {
    local work
    work=$(mktemp -d "$TEST_ROOT/runtime-invalid-speed.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TRAFFIC_UNIT='decimal'
    TRAFFIC_LIMIT='100'
    TRAFFIC_TOLERANCE='0'
    LIMIT_MODE='tc'
    LIMIT_SPEED='corrupt'

    load_function "$MONITOR_SCRIPT" check_and_limit_traffic || return 1
    get_traffic_usage() { printf '%s\n' '100.000'; }
    bc() {
        local expression
        expression=$(cat)
        case "$expression" in
            *' - '*) printf '%s\n' '100' ;;
            *' <= 0') printf '%s\n' '0' ;;
            *' >= '*) printf '%s\n' '1' ;;
            *) printf '%s\n' '0' ;;
        esac
    }
    enforcement_guard_active() { return 1; }
    tc_boot_grace_active() { return 1; }
    apply_tc_limit() { printf '%s\n' 'called' > "$work/tc-called"; }
    write_usage_state() { return 0; }

    if check_and_limit_traffic >/dev/null; then
        return 1
    fi
    assert_absent "$work/tc-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_legacy_shutdown_cancel_failure_is_reported() {
    local work
    work=$(mktemp -d "$TEST_ROOT/legacy-shutdown.XXXXXX") || return 1
    WORK_DIR="$work"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    RED=''
    YELLOW=''
    NC=''
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$work/traffic_monitor_config.txt"

    load_function "$ROOT_DIR/trafficcop-lite.sh" cancel_shutdown_interactive || return 1
    shutdown() { return 1; }
    lite_has_pending_shutdown() { return 1; }
    if cancel_shutdown_interactive <<< 'y' >/dev/null; then
        return 1
    fi

    shutdown() { return 0; }
    lite_has_pending_shutdown() { return 0; }
    if cancel_shutdown_interactive <<< 'y' >/dev/null; then
        return 1
    fi

    lite_has_pending_shutdown() { return 1; }
    cancel_shutdown_interactive <<< 'y' >/dev/null
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_machine_legacy_shutdown_cancel_failure_is_reported() {
    local work
    work=$(mktemp -d "$TEST_ROOT/machine-legacy-shutdown.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    BACKUP_CONFIG_FILE="$work/config.disabled.backup"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    ENFORCEMENT_STATE_FILE="$work/enforcement-state"
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$CONFIG_FILE"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" disable_machine_limit || return 1
    remove_cron_job() { return 0; }
    stop_monitor_process() { return 0; }
    acquire_monitor_cleanup_lock() { return 0; }
    clear_tc_rules() { return 0; }
    release_monitor_cleanup_lock() { return 0; }
    cancel_owned_shutdown() { return 0; }
    shutdown() { return 1; }
    has_pending_shutdown() { return 1; }

    if disable_machine_limit <<< 'y' >/dev/null; then
        return 1
    fi
    [ -f "$BACKUP_CONFIG_FILE" ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_machine_tc_clear_always_uses_lock() {
    local work
    work=$(mktemp -d "$TEST_ROOT/machine-clear-lock.XXXXXX") || return 1

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" clear_tc_rules_with_lock || return 1
    acquire_monitor_cleanup_lock() { printf '%s\n' 'acquire' >> "$work/order"; }
    clear_tc_rules() { printf '%s\n' 'clear' >> "$work/order"; return 1; }
    release_monitor_cleanup_lock() { printf '%s\n' 'release' >> "$work/order"; }

    if clear_tc_rules_with_lock >/dev/null; then
        return 1
    fi
    assert_file_content $'acquire\nclear\nrelease' "$work/order" || return 1

    : > "$work/order"
    acquire_monitor_cleanup_lock() { printf '%s\n' 'acquire' >> "$work/order"; return 1; }
    clear_tc_rules_with_lock >/dev/null 2>&1 && return 1
    assert_file_content 'acquire' "$work/order"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shortcut_conflicts_are_preserved() {
    local work broken_target
    work=$(mktemp -d "$TEST_ROOT/shortcut-conflict.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    SHORTCUT_PATH="$work/bin/ntc"
    LEGACY_NCL_SHORTCUT_PATH="$work/bin/ncl"
    LEGACY_TC_SHORTCUT_PATH="$work/bin/tc"
    TC_BIN=''
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
    mkdir -p "$WORK_DIR" "$(dirname "$SHORTCUT_PATH")"
    printf '%s\n' '#!/bin/bash' > "$WORK_DIR/trafficcop-lite.sh"

    load_function "$ROOT_DIR/trafficcop-lite.sh" install_shortcut_link || return 1
    printf '%s\n' 'foreign-command' > "$SHORTCUT_PATH"
    if install_shortcut_link >/dev/null; then
        return 1
    fi
    assert_file_content 'foreign-command' "$SHORTCUT_PATH" || return 1

    rm -f "$SHORTCUT_PATH"
    broken_target="$work/missing-target"
    if ln -s "$broken_target" "$SHORTCUT_PATH" 2>/dev/null && [ -L "$SHORTCUT_PATH" ]; then
        if install_shortcut_link >/dev/null; then
            return 1
        fi
        [ "$(readlink "$SHORTCUT_PATH")" = "$broken_target" ] || return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_main_copy_failure_preserves_installed_script() {
    local work expected
    work=$(mktemp -d "$TEST_ROOT/main-copy-failure.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    SOURCE_PATH="$work/source.sh"
    SCRIPT_VERSION='1.1.6'
    RED=''
    YELLOW=''
    NC=''
    mkdir -p "$WORK_DIR"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.6"' > "$SOURCE_PATH"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.5"' > "$WORK_DIR/trafficcop-lite.sh"
    expected=$(cat "$WORK_DIR/trafficcop-lite.sh")

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" copy_self_if_needed || return 1
    cp() { return 1; }

    if copy_self_if_needed >/dev/null; then
        return 1
    fi
    assert_file_content "$expected" "$WORK_DIR/trafficcop-lite.sh" || return 1
    assert_absent "$WORK_DIR/trafficcop-lite.sh.install.$$"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_restore_failure_restores_previous_config() {
    local work
    work=$(mktemp -d "$TEST_ROOT/restore-rollback.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    BACKUP_CONFIG_FILE="$work/config.disabled.backup"
    RED=''
    YELLOW=''
    NC=''
    printf '%s\n' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' 'LIMIT_MODE=tc' > "$BACKUP_CONFIG_FILE"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" restore_machine_limit || return 1
    enable_machine_limit() { return 1; }

    if restore_machine_limit >/dev/null; then
        return 1
    fi
    assert_file_content 'DISABLED=true' "$CONFIG_FILE" || return 1

    rm -f "$CONFIG_FILE"
    if restore_machine_limit >/dev/null; then
        return 1
    fi
    assert_absent "$CONFIG_FILE"
}

run_test() {
    local name="$1"
    local test_function="$2"

    if ("$test_function"); then
        printf 'ok - %s\n' "$name"
        PASSED=$((PASSED + 1))
    else
        printf 'not ok - %s\n' "$name" >&2
        FAILED=$((FAILED + 1))
    fi
}

run_test 'period reset cancels owned shutdown' test_period_reset_cancels_owned_shutdown
run_test 'period reset aborts safely on cancellation failure' test_period_reset_stops_when_shutdown_cancel_fails
run_test 'shutdown cleanup respects boot ownership' test_shutdown_cleanup_respects_boot_ownership
run_test 'shutdown cleanup blocks unverifiable pending task' test_shutdown_cleanup_blocks_unverifiable_pending_task
run_test 'monitor config restores previous state' test_monitor_config_restores_previous_state
run_test 'monitor first config is removed after post-save failure' test_monitor_config_removes_failed_first_config
run_test 'monitor config rolls back when writer reports failure' test_monitor_config_rolls_back_when_writer_reports_failure
run_test 'monitor rollback preserves backup after restore failure' test_monitor_rollback_preserves_backup_on_restore_failure
run_test 'vnStat marker rolls back after config commit failure' test_vnstat_marker_rolls_back_when_config_commit_fails
run_test 'vnStat config and marker commit together' test_vnstat_config_and_marker_commit_together
run_test 'Telegram menu does not hold cron lock' test_telegram_menu_does_not_hold_cron_lock
run_test 'Telegram cron still takes lock' test_telegram_cron_still_takes_lock
run_test 'Telegram action releases lock after failure' test_telegram_action_releases_lock_after_failure
run_test 'Telegram real lock contention and release' test_telegram_real_lock_contention_and_release
run_test 'update rejects an older candidate' test_update_rejects_older_candidate
run_test 'single-file install refreshes every script' test_single_file_install_refreshes_all_scripts
run_test 'complete bundle install remains local' test_complete_bundle_install_stays_local
run_test 'update replaces full release and preserves state' test_update_replaces_full_release_and_preserves_state
run_test 'update rollback requires backup evidence' test_update_rollback_requires_backup_evidence
run_test 'declining vnStat retention aborts configuration' test_retention_decline_aborts_configuration
run_test 'vnStat history read errors abort configuration' test_vnstat_history_read_error_aborts_configuration
run_test 'post-save read errors preserve runtime state' test_post_save_read_error_preserves_runtime_state
run_test 'TC changes require a prepared ownership state' test_tc_change_requires_prepared_state
run_test 'TC builds the unified HTB directly without invoking Dog' test_tc_builds_unified_htb_directly
run_test 'TC refuses an unrecognized root qdisc without mutation' test_tc_refuses_foreign_root_without_mutation
run_test 'legacy TBF adoption requires a matching numeric speed' test_legacy_tbf_requires_matching_numeric_speed
run_test 'invalid Dog config cannot authorize HTB adoption' test_invalid_dog_config_cannot_authorize_adoption
run_test 'unified HTB verification requires the full root and class contract' test_unified_hierarchy_verification_requires_full_contract
run_test 'root crontab updates hold the TrafficCop project lock' test_monitor_crontab_update_holds_project_lock
run_test 'shutdown scheduling requires a prepared ownership state' test_shutdown_requires_prepared_state
run_test 'Telegram config does not reuse stale secrets' test_telegram_config_does_not_reuse_stale_secret
run_test 'Telegram legacy config is parsed without execution' test_telegram_legacy_config_is_parsed_without_execution
run_test 'Telegram plain config round-trips special values' test_telegram_plain_config_round_trip
run_test 'Telegram token is absent from curl arguments' test_telegram_token_is_not_in_curl_arguments
run_test 'component download rejects versionless responses' test_component_download_rejects_versionless_body
run_test 'period date boundaries remain correct' test_period_date_boundaries
run_test 'traffic accounting modes remain correct' test_traffic_accounting_modes
run_test 'invalid limit speed is rejected while missing values stay compatible' test_invalid_limit_speed_is_rejected
run_test 'runtime rejects an invalid limit speed' test_runtime_rejects_invalid_limit_speed
run_test 'legacy shutdown cancellation failures are reported' test_legacy_shutdown_cancel_failure_is_reported
run_test 'machine disable reports legacy shutdown cancellation failures' test_machine_legacy_shutdown_cancel_failure_is_reported
run_test 'manual TC cleanup always uses the monitor lock' test_machine_tc_clear_always_uses_lock
run_test 'foreign shortcut paths are preserved' test_shortcut_conflicts_are_preserved
run_test 'main script copy failures preserve the installed version' test_main_copy_failure_preserves_installed_script
run_test 'restore failures recover the previous config' test_restore_failure_restores_previous_config

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
