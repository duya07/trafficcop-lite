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

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
