#!/usr/bin/env bash

set -uo pipefail
# ui_* 只在终端或设置了 COLUMNS 时折行；用例按不折行断言，所以先清掉调用环境导出的 COLUMNS。
unset COLUMNS

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MONITOR_SCRIPT="$ROOT_DIR/trafficcop-lite-monitor.sh"
TELEGRAM_SCRIPT="$ROOT_DIR/trafficcop-lite-telegram.sh"
TEST_ROOT=$(mktemp -d)
WORK_DIR="$TEST_ROOT/default-audit"
PASSED=0
FAILED=0
SKIPPED=0

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

# 2.0：界面、输入、状态读取这几个共享模块（src/common，经 tools/sync-common.sh 写入）在四个脚本里都有，
# 被测函数可能调用它们，所以每次加载函数前先从同一脚本里取出这些区块。
load_common_blocks() {
    local block
    block=$(awk '
        /^# >>> ntc-common:(ui|input|report) >>>$/ { on = 1; next }
        /^# <<< ntc-common:(ui|input|report) <<<$/ { on = 0; next }
        on { print }
    ' "$1") || return 1
    [ -z "$block" ] && return 0
    # shellcheck disable=SC2294
    eval "$block"
}

load_function() {
    local function_body
    local helper
    load_common_blocks "$1" || return 1
    if [ "$2" != ntc_operation_log ]; then
        function_body=$(extract_function "$1" ntc_operation_log) || return 1
        # shellcheck disable=SC2294
        eval "$function_body"
    fi
    case "$2" in
        apply_tc_limit|clear_owned_tc_rules_locked|recover_owned_tc_hierarchy|tc_self_check|owned_tc_limit_active)
            for helper in tc_file_is_secure dog_ingress_redirect_complete tc_dog_ifb_device \
                tc_base_class_snapshot tc_restore_base_snapshot tc_update_dog_ifb tc_verify_dog_ifb; do
                load_function "$1" "$helper" || return 1
            done
            ;;
        dog_configured_class_records|dog_config_reserves_default_class)
            for helper in dog_bandwidth_to_tc tc_file_is_secure dog_tc_manifest_file dog_config_schema \
                dog_legacy_class_records dog_manifest_class_records; do
                load_function "$1" "$helper" || return 1
            done
            ;;
        update_scripts|download_component)
            for helper in fetch_release_sums verify_release_file; do
                load_function "$1" "$helper" || return 1
            done
            ;;
        manage_tc_recovery)
            load_function "$1" tc_recovery_action || return 1
            ;;
        initial_config)
            # 只有 monitor 的向导有这些辅助函数；Telegram 脚本里的 initial_config 是另一套。
            if [[ "$1" == *trafficcop-lite-monitor.sh ]]; then
                for helper in cancel_config_on_eof config_wizard_collect config_prepare_vnstat config_ask_exceed_policy \
                    config_summary_rows config_show_summary config_commit config_oneline config_threshold \
                    normalize_decimal default_tolerance is_decimal compare_decimal; do
                    load_function "$1" "$helper" || return 1
                done
            fi
            ;;
        tc_boot_grace_active)
            load_function "$1" boot_grace_window_active || return 1
            ;;
        check_and_limit_traffic)
            for helper in shutdown_state_value shutdown_task_token_from_state pending_shutdown_matches_owned_state; do
                load_function "$1" "$helper" || return 1
            done
            ;;
        machine_grace|machine_pause|machine_resume|machine_set_boot_grace|machine_grace_interactive|machine_boot_grace_interactive)
            # 2.0：这些动作先检查配置是否存在、是否已停用；换回旧版脚本做红绿对照时没有这个函数，加载失败就忽略。
            if [[ "$1" == *trafficcop-lite-machine-limit.sh ]]; then
                load_function "$1" machine_require_active_config 2> /dev/null || true
            fi
            ;;
        enable_machine_limit)
            if [[ "$1" == *trafficcop-lite-machine-limit.sh ]]; then
                load_function "$1" enable_rollback_state_text 2> /dev/null || true
            fi
            ;;
        disable_machine_limit)
            if [[ "$1" == *trafficcop-lite-machine-limit.sh ]]; then
                load_function "$1" disable_restore_cron 2> /dev/null || true
            fi
            ;;
        configure_post_save_enforcement)
            # 2.0：保存流程里旧运行函数的说明行先写进临时文件，失败时才显示；换回旧版做红绿对照时没有这个函数，忽略。
            if [[ "$1" == *trafficcop-lite-monitor.sh ]]; then
                load_function "$1" config_show_step_output 2> /dev/null || true
            fi
            ;;
    esac

    function_body=$(extract_function "$1" "$2") || return 1
    # The source files are repository-controlled; evaluation keeps the function in this shell.
    # shellcheck disable=SC2294
    eval "$function_body"
    # 开机宽限判断依赖本机 uptime（CI 刚开机的机器可能仍在宽限期内）。恢复类用例默认按「不在宽限期」运行；
    # 需要宽限期的用例在加载之后自行定义 boot_grace_window_active。
    if [ "$2" = recover_owned_tc_hierarchy ] && ! declare -F boot_grace_window_active > /dev/null; then
        # shellcheck disable=SC2317,SC2329
        boot_grace_window_active() { return 1; }
    fi
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

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shutdown_cleanup_requires_exact_task_identity_in_all_entrypoints() {
    local work pending wall_message cancel_count=0
    work=$(mktemp -d "$TEST_ROOT/shutdown-task-identity.XXXXXX") || return 1
    LOG_FILE="$work/log"
    RED=''
    NC=''
    WORK_DIR="$work"

    cat() {
        if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then
            printf '%s\n' boot-a
        else
            command cat "$@"
        fi
    }
    command_exists() { [ "$1" = busctl ]; }
    busctl() { printf 's "%s"\n' "$wall_message"; }
    has_pending_shutdown() { [ "$pending" = true ]; }
    lite_has_pending_shutdown() { [ "$pending" = true ]; }
    shutdown() {
        [ "${1:-}" = -c ] || return 1
        cancel_count=$((cancel_count + 1))
        pending=false
    }
    write_shutdown_marker() {
        printf '%s\n' \
            'PERIOD_START=2026-08-01' \
            'BOOT_ID=boot-a' \
            "TASK_TOKEN=$2" \
            'SCHEDULED_EPOCH=1787900000' > "$1"
    }

    load_function "$MONITOR_SCRIPT" shutdown_state_value || return 1
    load_function "$MONITOR_SCRIPT" shutdown_task_token_from_state || return 1
    load_function "$MONITOR_SCRIPT" pending_shutdown_matches_owned_state || return 1
    load_function "$MONITOR_SCRIPT" clear_owned_shutdown_schedule || return 1
    SHUTDOWN_STATE_FILE="$work/monitor-owned"
    write_shutdown_marker "$SHUTDOWN_STATE_FILE" trafficcop-lite-monitor-12345678
    pending=true
    wall_message='TrafficCop-Lite[trafficcop-lite-monitor-12345678] owned task'
    clear_owned_shutdown_schedule >/dev/null || return 1
    [ "$cancel_count" -eq 1 ] || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1

    SHUTDOWN_STATE_FILE="$work/monitor-foreign"
    write_shutdown_marker "$SHUTDOWN_STATE_FILE" trafficcop-lite-monitor-87654321
    pending=true
    wall_message='external maintenance shutdown'
    if clear_owned_shutdown_schedule >/dev/null; then
        return 1
    fi
    [ "$cancel_count" -eq 1 ] || return 1
    [ -f "$SHUTDOWN_STATE_FILE" ] || return 1

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" shutdown_task_token_from_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" pending_shutdown_matches_owned_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" cancel_owned_shutdown || return 1
    SHUTDOWN_STATE_FILE="$work/machine-owned"
    write_shutdown_marker "$SHUTDOWN_STATE_FILE" trafficcop-lite-machine-12345678
    pending=true
    wall_message='TrafficCop-Lite[trafficcop-lite-machine-12345678] owned task'
    cancel_owned_shutdown >/dev/null || return 1
    [ "$cancel_count" -eq 2 ] || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1

    SHUTDOWN_STATE_FILE="$work/machine-foreign"
    write_shutdown_marker "$SHUTDOWN_STATE_FILE" trafficcop-lite-machine-87654321
    pending=true
    wall_message='external maintenance shutdown'
    if cancel_owned_shutdown >/dev/null; then
        return 1
    fi
    [ "$cancel_count" -eq 2 ] || return 1
    [ -f "$SHUTDOWN_STATE_FILE" ] || return 1

    load_function "$ROOT_DIR/trafficcop-lite.sh" lite_shutdown_task_token_from_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" lite_pending_shutdown_matches_owned_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" cancel_shutdown_interactive || return 1
    SHUTDOWN_STATE_FILE="$work/main-owned"
    write_shutdown_marker "$SHUTDOWN_STATE_FILE" trafficcop-lite-main-12345678
    pending=true
    wall_message='TrafficCop-Lite[trafficcop-lite-main-12345678] owned task'
    cancel_shutdown_interactive >/dev/null || return 1
    [ "$cancel_count" -eq 3 ] || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1

    SHUTDOWN_STATE_FILE="$work/main-foreign"
    write_shutdown_marker "$SHUTDOWN_STATE_FILE" trafficcop-lite-main-87654321
    pending=true
    wall_message='external maintenance shutdown'
    if cancel_shutdown_interactive >/dev/null; then
        return 1
    fi
    [ "$cancel_count" -eq 3 ] || return 1
    [ -f "$SHUTDOWN_STATE_FILE" ]
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
test_tc_dependency_package_mapping() {
    local PACKAGE_MANAGER expected
    local packages_to_install=()

    load_function "$MONITOR_SCRIPT" add_package_once || return 1
    load_function "$MONITOR_SCRIPT" add_package_for_command || return 1

    for PACKAGE_MANAGER in apt apk pacman; do
        packages_to_install=()
        add_package_for_command tc
        [ "${packages_to_install[*]}" = iproute2 ] || return 1
    done
    for PACKAGE_MANAGER in dnf yum; do
        packages_to_install=()
        add_package_for_command tc
        [ "${packages_to_install[*]}" = iproute ] || return 1
    done
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_dependency_check_rejects_missing_tc_after_install() {
    local work
    work=$(mktemp -d "$TEST_ROOT/dependency-missing-tc.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TC_BIN='/stale/tc'

    load_function "$MONITOR_SCRIPT" add_package_once || return 1
    load_function "$MONITOR_SCRIPT" add_package_for_command || return 1
    load_function "$MONITOR_SCRIPT" required_command_available || return 1
    load_function "$MONITOR_SCRIPT" check_and_install_packages || return 1
    find_tc_bin() { return 0; }
    command_exists() { return 0; }
    detect_package_manager() { printf '%s\n' apt; }
    install_packages() { printf '%s\n' "$*" > "$work/packages"; }
    ensure_service_running() { printf '%s\n' unexpected > "$work/service"; }
    ensure_vnstat_daemon_running() { printf '%s\n' unexpected > "$work/vnstat"; }

    if check_and_install_packages >/dev/null; then
        return 1
    fi
    [ -z "$TC_BIN" ] || return 1
    assert_file_content iproute2 "$work/packages" || return 1
    assert_absent "$work/service" || return 1
    assert_absent "$work/vnstat" || return 1
    grep -Fq '安装后仍缺少命令：tc' "$LOG_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_cron_service_start_failure_propagates_to_dependency_check() {
    local work
    work=$(mktemp -d "$TEST_ROOT/cron-service-failure.XXXXXX") || return 1
    LOG_FILE="$work/log"

    load_function "$MONITOR_SCRIPT" ensure_service_running || return 1
    command_exists() { [ "$1" = systemctl ]; }
    systemctl() {
        if [ "${1:-}" = list-unit-files ]; then
            printf '%s\n' 'cron.service enabled'
        fi
    }
    run_privileged() { return 42; }
    if ensure_service_running cron cron > "$work/output"; then
        return 1
    fi
    grep -Fq '无法自动确认 cron 服务状态' "$work/output" || return 1

    load_function "$MONITOR_SCRIPT" check_and_install_packages || return 1
    find_tc_bin() { printf '%s\n' /sbin/tc; }
    required_command_available() { return 0; }
    ensure_service_running() { return 1; }
    ensure_vnstat_daemon_running() { printf '%s\n' unexpected > "$work/vnstat"; }
    if check_and_install_packages >/dev/null; then
        return 1
    fi
    assert_absent "$work/vnstat"
}

# initial_config 的文件事务由下方定向测试单独覆盖；这些旧用例只隔离验证配置文件回滚语义。
# These functions are invoked by production functions loaded through eval.
# shellcheck disable=SC2317,SC2329  # 新版 shellcheck 对间接调用的报告编号
setup_initial_config_transaction_mocks() {
    begin_initial_vnstat_transaction() { return 0; }
    rollback_initial_vnstat_transaction() { return 0; }
    commit_initial_vnstat_transaction() { return 0; }
    snapshot_monitor_config_state() {
        local config_backup="$1"
        local enforcement_backup="$2"

        CONFIG_SNAPSHOT_HAD_CONFIG=false
        CONFIG_SNAPSHOT_HAD_ENFORCEMENT=false
        CONFIG_SNAPSHOT_HAD_TC=false
        CONFIG_SNAPSHOT_HAD_SHUTDOWN=false
        if [ -f "$CONFIG_FILE" ]; then
            cp -p "$CONFIG_FILE" "$config_backup" || return 1
            CONFIG_SNAPSHOT_HAD_CONFIG=true
        fi
        if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
            cp -p "$ENFORCEMENT_STATE_FILE" "$enforcement_backup" || return 1
            CONFIG_SNAPSHOT_HAD_ENFORCEMENT=true
        fi
    }
    rollback_monitor_config_transaction() {
        [ "${CONFIG_TC_CLEAR_ATTEMPTED:-false}" = false ] || return 1
        [ "${CONFIG_SHUTDOWN_CLEAR_ATTEMPTED:-false}" = false ] || return 1
        restore_monitor_config_snapshot "$1" "$CONFIG_SNAPSHOT_HAD_CONFIG" \
            "$2" "$CONFIG_SNAPSHOT_HAD_ENFORCEMENT" || return 1
        rm -f "$1" "$2" "$3" "$4"
    }
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_config_restores_previous_state() {
    local work input
    work=$(mktemp -d "$TEST_ROOT/config-restore.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    LOG_FILE="$work/log"
    printf '%s\n' 'old-config' > "$CONFIG_FILE"
    printf '%s\n' 'old-enforcement' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    setup_initial_config_transaction_mocks
    detect_main_interface() { printf '%s\n' 'eth0'; }
    interface_exists() { return 0; }
    get_traffic_usage() { printf '%s\n' 1; }
    ensure_vnstat_runtime_config() { return 0; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() { printf '%s\n' 'new-config' > "$CONFIG_FILE"; }
    configure_post_save_enforcement() {
        rm -f "$ENFORCEMENT_STATE_FILE"
        return 1
    }

    input=$'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n\n'
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
    TC_STATE_FILE="$work/tc-state"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    LOG_FILE="$work/log"

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    setup_initial_config_transaction_mocks
    detect_main_interface() { printf '%s\n' 'eth0'; }
    interface_exists() { return 0; }
    get_traffic_usage() { printf '%s\n' 1; }
    ensure_vnstat_runtime_config() { return 0; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() { printf '%s\n' 'new-config' > "$CONFIG_FILE"; }
    configure_post_save_enforcement() {
        printf '%s\n' 'new-enforcement' > "$ENFORCEMENT_STATE_FILE"
        return 1
    }

    input=$'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n\n'
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
    TC_STATE_FILE="$work/tc-state"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    LOG_FILE="$work/log"
    printf '%s\n' 'old-config' > "$CONFIG_FILE"
    printf '%s\n' 'old-enforcement' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    setup_initial_config_transaction_mocks
    detect_main_interface() { printf '%s\n' 'eth0'; }
    interface_exists() { return 0; }
    get_traffic_usage() { printf '%s\n' 1; }
    ensure_vnstat_runtime_config() { return 0; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() {
        printf '%s\n' 'new-config' > "$CONFIG_FILE"
        return 1
    }
    configure_post_save_enforcement() { return 0; }

    input=$'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n\n'
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

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
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
test_vnstat_modern_config_is_idempotent_and_preserves_custom_values() {
    local work source first second
    work=$(mktemp -d "$TEST_ROOT/vnstat-modern.XXXXXX") || return 1
    source="$work/vnstat.conf"
    first="$work/first.conf"
    second="$work/second.conf"
    VNSTAT_MAX_BANDWIDTH=50000
    VNSTAT_SAVE_INTERVAL=1
    cat > "$source" <<'EOF'
; SaveInterval 5
UpdateInterval 300
; MaxBandwidth 7777
# MaxBWeth0 1000
DailyDays 30
CustomSetting keep-me
EOF

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    build_vnstat_config_candidate "$source" "$first" eth0 false 60 400 || return 1
    build_vnstat_config_candidate "$first" "$second" eth0 false 60 400 || return 1
    cmp -s "$first" "$second" || return 1
    [ "$(grep -c '^SaveInterval ' "$first")" -eq 1 ] || return 1
    [ "$(grep -c '^MaxBWeth0 ' "$first")" -eq 1 ] || return 1
    grep -Fxq 'SaveInterval 1' "$first" || return 1
    grep -Fxq 'UpdateInterval 60' "$first" || return 1
    grep -Fxq 'MaxBWeth0 50000' "$first" || return 1
    grep -Fxq 'DailyDays 400' "$first" || return 1
    grep -Fxq '; MaxBandwidth 7777' "$first" || return 1
    grep -Fxq 'CustomSetting keep-me' "$first"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_legacy_config_disables_detection_at_50000_mbit() {
    local work source candidate
    work=$(mktemp -d "$TEST_ROOT/vnstat-legacy.XXXXXX") || return 1
    source="$work/vnstat.conf"
    candidate="$work/candidate.conf"
    VNSTAT_MAX_BANDWIDTH=50000
    VNSTAT_SAVE_INTERVAL=1
    cat > "$source" <<'EOF'
; BandwidthDetection 1
# MaxBandwidth 1000
; MaxBWens5 1000
UpdateInterval 30
EOF

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    build_vnstat_config_candidate "$source" "$candidate" ens5 true '' '' || return 1
    grep -Fxq 'BandwidthDetection 0' "$candidate" || return 1
    grep -Fxq 'MaxBandwidth 50000' "$candidate" || return 1
    grep -Fxq 'MaxBWens5 50000' "$candidate" || return 1
    grep -Fxq 'SaveInterval 1' "$candidate" || return 1
    grep -Fxq 'UpdateInterval 30' "$candidate"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_zero_disables_max_bandwidth_check() {
    local work source modern legacy
    work=$(mktemp -d "$TEST_ROOT/vnstat-zero.XXXXXX") || return 1
    source="$work/vnstat.conf"
    modern="$work/modern.conf"
    legacy="$work/legacy.conf"
    VNSTAT_MAX_BANDWIDTH=0
    VNSTAT_SAVE_INTERVAL=1
    cat > "$source" <<'EOF'
SaveInterval 5
UpdateInterval 30
MaxBandwidth 1000
MaxBWens5 1000
EOF

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    build_vnstat_config_candidate "$source" "$modern" ens5 false '' '' || return 1
    build_vnstat_config_candidate "$source" "$legacy" ens5 true '' '' || return 1
    grep -Fxq 'MaxBWens5 0' "$modern" || return 1
    grep -Fxq 'MaxBandwidth 1000' "$modern" || return 1
    grep -Fxq 'BandwidthDetection 0' "$legacy" || return 1
    grep -Fxq 'MaxBandwidth 0' "$legacy" || return 1
    grep -Fxq 'MaxBWens5 0' "$legacy"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_bandwidth_prompt_defaults_to_zero_and_accepts_custom_value() {
    load_function "$MONITOR_SCRIPT" vnstat_max_bandwidth_valid || return 1
    load_function "$MONITOR_SCRIPT" prompt_vnstat_max_bandwidth || return 1

    VNSTAT_MAX_BANDWIDTH=0
    prompt_vnstat_max_bandwidth <<< '' >/dev/null || return 1
    [ "$VNSTAT_MAX_BANDWIDTH" -eq 0 ] || return 1

    prompt_vnstat_max_bandwidth <<< '2405' >/dev/null || return 1
    [ "$VNSTAT_MAX_BANDWIDTH" -eq 2405 ] || return 1

    prompt_vnstat_max_bandwidth <<< '' >/dev/null || return 1
    [ "$VNSTAT_MAX_BANDWIDTH" -eq 2405 ] || return 1

    prompt_vnstat_max_bandwidth <<< $'invalid\n50001\n01000' >/dev/null || return 1
    [ "$VNSTAT_MAX_BANDWIDTH" -eq 1000 ] || return 1

    ! vnstat_max_bandwidth_valid 50001 && ! vnstat_max_bandwidth_valid -1
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_old_monitor_config_defaults_vnstat_bandwidth_check_to_zero() {
    local work
    work=$(mktemp -d "$TEST_ROOT/vnstat-old-config.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    LOG_FILE="$work/log"
    cat > "$CONFIG_FILE" <<'EOF'
TRAFFIC_MODE=total
TRAFFIC_PERIOD=monthly
TRAFFIC_LIMIT=1000
TRAFFIC_TOLERANCE=0
TRAFFIC_UNIT=decimal
PERIOD_START_DAY=1
PERIOD_START_MONTH=1
LIMIT_SPEED=20
MAIN_INTERFACE=eth0
LIMIT_MODE=tc
ALLOW_PARTIAL_HISTORY=false
TC_BOOT_GRACE_MINUTES=10
EOF

    load_function "$MONITOR_SCRIPT" vnstat_max_bandwidth_valid || return 1
    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    load_function "$MONITOR_SCRIPT" validate_config || return 1
    load_function "$MONITOR_SCRIPT" read_config || return 1
    load_function "$MONITOR_SCRIPT" write_config || return 1
    command_exists() { return 1; }

    VNSTAT_MAX_BANDWIDTH=50000
    read_config >/dev/null || return 1
    [ "$VNSTAT_MAX_BANDWIDTH" -eq 0 ] || return 1
    write_config >/dev/null || return 1
    grep -Fxq 'VNSTAT_MAX_BANDWIDTH=0' "$CONFIG_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_custom_daemon_config_path_is_preserved_idempotently() {
    local work config_path
    work=$(mktemp -d "$TEST_ROOT/vnstat-custom-path.XXXXXX") || return 1
    WORK_DIR="$work/state"
    mkdir -p "$WORK_DIR"
    VNSTAT_CONFIG_PATH_FILE="$WORK_DIR/vnstat_config_path"
    config_path="$work/custom-vnstat.conf"
    printf '%s\n' 'SaveInterval 1' > "$config_path"
    printf '%s\n' "$config_path" > "$VNSTAT_CONFIG_PATH_FILE"

    load_function "$MONITOR_SCRIPT" canonical_config_path || return 1
    load_function "$MONITOR_SCRIPT" resolve_vnstat_config_path || return 1
    vnstat_daemon_config_path() { printf '%s\n' "$config_path"; }
    mv() { printf '%s\n' unexpected > "$work/mv-called"; return 1; }

    resolve_vnstat_config_path || return 1
    [ "$VNSTAT_CONFIG_PATH" = "$config_path" ] || return 1
    assert_file_content "$config_path" "$VNSTAT_CONFIG_PATH_FILE" || return 1
    assert_absent "$work/mv-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_default_config_requires_matching_install_prefixes() {
    local work config_path
    work=$(mktemp -d "$TEST_ROOT/vnstat-prefix-mismatch.XXXXXX") || return 1
    WORK_DIR="$work/state"
    mkdir -p "$WORK_DIR"
    VNSTAT_CONFIG_PATH_FILE="$WORK_DIR/vnstat_config_path"
    unset VNSTAT_CONFIG_PATH

    load_function "$MONITOR_SCRIPT" canonical_config_path || return 1
    load_function "$MONITOR_SCRIPT" resolve_vnstat_config_path || return 1
    vnstat_daemon_config_path() { return 1; }
    vnstat_daemon_install_prefix() { printf '%s\n' /usr; }
    vnstat_cli_install_prefix() { printf '%s\n' /usr/local; }
    vnstat() { printf '%s\n' called > "$work/vnstat-called"; return 0; }

    if resolve_vnstat_config_path; then
        return 1
    fi
    assert_absent "$work/vnstat-called" || return 1
    assert_absent "$VNSTAT_CONFIG_PATH_FILE" || return 1

    config_path="$work/vnstat.conf"
    printf '%s\n' 'SaveInterval 1' > "$config_path"
    vnstat_cli_install_prefix() { printf '%s\n' /usr; }
    vnstat() { printf 'Config file: %s\n' "$config_path"; }
    resolve_vnstat_config_path || return 1
    [ "$VNSTAT_CONFIG_PATH" = "$config_path" ] || return 1
    assert_file_content "$config_path" "$VNSTAT_CONFIG_PATH_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_runtime_starts_daemon_before_resolving_custom_config() {
    local work expected
    work=$(mktemp -d "$TEST_ROOT/vnstat-start-before-resolve.XXXXXX") || return 1
    expected="$work/expected"
    printf '%s\n' start resolve align 'apply:/custom/vnstat.conf:60' > "$expected"

    VNSTAT_MAX_BANDWIDTH=0
    load_function "$MONITOR_SCRIPT" vnstat_max_bandwidth_valid || return 1
    load_function "$MONITOR_SCRIPT" ensure_vnstat_runtime_config || return 1
    ensure_vnstat_daemon_running() { printf '%s\n' start >> "$work/events"; }
    resolve_vnstat_config_path() {
        printf '%s\n' resolve >> "$work/events"
        VNSTAT_CONFIG_PATH=/custom/vnstat.conf
    }
    align_timezone_with_vnstat() { printf '%s\n' align >> "$work/events"; }
    vnstat_version_parts() { printf '%s\n' '2 10'; }
    vnstat_config_value() { printf '%s\n' 300; }
    apply_vnstat_config_update() {
        printf 'apply:%s:%s\n' "$1" "$4" >> "$work/events"
    }

    ensure_vnstat_runtime_config eth0 || return 1
    cmp -s "$expected" "$work/events"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_unchanged_config_does_not_reload_daemon() {
    local work config_path
    work=$(mktemp -d "$TEST_ROOT/vnstat-no-reload.XXXXXX") || return 1
    WORK_DIR="$work/state"
    mkdir -p "$WORK_DIR"
    config_path="$work/vnstat.conf"
    RETENTION_STATE_FILE="$WORK_DIR/coverage"
    VNSTAT_MAX_BANDWIDTH=50000
    VNSTAT_SAVE_INTERVAL=1
    cat > "$config_path" <<'EOF'
SaveInterval 1
UpdateInterval 60
MaxBWeth0 50000
EOF

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    load_function "$MONITOR_SCRIPT" canonical_config_path || return 1
    load_function "$MONITOR_SCRIPT" select_vnstat_backup_path || return 1
    load_function "$MONITOR_SCRIPT" apply_vnstat_config_update || return 1
    vnstat_config_candidate_valid() { return 0; }
    ensure_vnstat_daemon_running() { printf '%s\n' started > "$work/daemon"; }
    reload_vnstat_daemon() { printf '%s\n' reloaded > "$work/reload"; }

    apply_vnstat_config_update "$config_path" eth0 false '' '' false >/dev/null || return 1
    assert_file_content 'started' "$work/daemon" || return 1
    assert_absent "$work/reload" || return 1
    assert_absent "$WORK_DIR/vnstat.conf.before-trafficcop-lite"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_reload_failure_restores_config_and_marker() {
    local work config_path old_config reload_count=0
    work=$(mktemp -d "$TEST_ROOT/vnstat-reload-rollback.XXXXXX") || return 1
    WORK_DIR="$work/state"
    mkdir -p "$WORK_DIR"
    config_path="$work/vnstat.conf"
    RETENTION_STATE_FILE="$WORK_DIR/coverage"
    VNSTAT_MAX_BANDWIDTH=50000
    VNSTAT_SAVE_INTERVAL=1
    cat > "$config_path" <<'EOF'
SaveInterval 5
UpdateInterval 300
MaxBWeth0 1000
DailyDays 30
EOF
    old_config=$(cat "$config_path")
    printf '%s\n' '2026-01-01' > "$RETENTION_STATE_FILE"

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    load_function "$MONITOR_SCRIPT" rollback_vnstat_config_update || return 1
    load_function "$MONITOR_SCRIPT" canonical_config_path || return 1
    load_function "$MONITOR_SCRIPT" select_vnstat_backup_path || return 1
    load_function "$MONITOR_SCRIPT" apply_vnstat_config_update || return 1
    vnstat_config_candidate_valid() { return 0; }
    reload_vnstat_daemon() {
        reload_count=$((reload_count + 1))
        [ "$reload_count" -gt 1 ]
    }
    chown() { return 0; }

    if apply_vnstat_config_update "$config_path" eth0 false 60 400 true >/dev/null 2>&1; then
        return 1
    fi
    assert_file_content "$old_config" "$config_path" || return 1
    assert_file_content '2026-01-01' "$RETENTION_STATE_FILE" || return 1
    assert_file_content "$old_config" "$WORK_DIR/vnstat.conf.before-trafficcop-lite" || return 1
    [ "$reload_count" -eq 2 ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_config_and_marker_commit_together() {
    local work config_path old_config reload_count=0 today
    work=$(mktemp -d "$TEST_ROOT/vnstat-config-success.XXXXXX") || return 1
    WORK_DIR="$work/state"
    mkdir -p "$WORK_DIR"
    config_path="$work/vnstat.conf"
    RETENTION_STATE_FILE="$WORK_DIR/coverage"
    VNSTAT_MAX_BANDWIDTH=50000
    VNSTAT_SAVE_INTERVAL=1
    cat > "$config_path" <<'EOF'
SaveInterval 5
UpdateInterval 300
MaxBWeth0 1000
DailyDays 30
EOF
    old_config=$(cat "$config_path")
    printf '%s\n' '2026-01-01' > "$RETENTION_STATE_FILE"
    today=$(date +%Y-%m-%d) || return 1

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    load_function "$MONITOR_SCRIPT" rollback_vnstat_config_update || return 1
    load_function "$MONITOR_SCRIPT" canonical_config_path || return 1
    load_function "$MONITOR_SCRIPT" select_vnstat_backup_path || return 1
    load_function "$MONITOR_SCRIPT" apply_vnstat_config_update || return 1
    vnstat_config_candidate_valid() { return 0; }
    reload_vnstat_daemon() { reload_count=$((reload_count + 1)); }
    chown() { return 0; }

    apply_vnstat_config_update "$config_path" eth0 false 60 400 true >/dev/null || return 1
    grep -Fxq 'SaveInterval 1' "$config_path" || return 1
    grep -Fxq 'UpdateInterval 60' "$config_path" || return 1
    grep -Fxq 'MaxBWeth0 50000' "$config_path" || return 1
    grep -Fxq 'DailyDays 400' "$config_path" || return 1
    assert_file_content "$today" "$RETENTION_STATE_FILE" || return 1
    assert_file_content "$old_config" "$WORK_DIR/vnstat.conf.before-trafficcop-lite" || return 1
    [ "$reload_count" -eq 1 ] || return 1
    ! find "$work" -name '*.trafficcop-lite.*' -print -quit | grep -q .
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_backups_are_bound_to_canonical_config_paths() {
    local work first_config second_config first_original second_original
    work=$(mktemp -d "$TEST_ROOT/vnstat-backup-paths.XXXXXX") || return 1
    WORK_DIR="$work/state"
    mkdir -p "$WORK_DIR"
    first_config="$work/first-vnstat.conf"
    second_config="$work/second-vnstat.conf"
    mkdir -p "$work/sub"
    RETENTION_STATE_FILE="$WORK_DIR/coverage"
    VNSTAT_MAX_BANDWIDTH=50000
    VNSTAT_SAVE_INTERVAL=1
    printf '%s\n' 'SaveInterval 5' 'UpdateInterval 300' 'MaxBWeth0 1000' > "$first_config"
    printf '%s\n' 'SaveInterval 10' 'UpdateInterval 120' 'MaxBWeth0 2000' > "$second_config"
    first_original=$(cat "$first_config")
    second_original=$(cat "$second_config")

    load_function "$MONITOR_SCRIPT" build_vnstat_config_candidate || return 1
    load_function "$MONITOR_SCRIPT" canonical_config_path || return 1
    load_function "$MONITOR_SCRIPT" select_vnstat_backup_path || return 1
    load_function "$MONITOR_SCRIPT" apply_vnstat_config_update || return 1
    vnstat_config_candidate_valid() { return 0; }
    reload_vnstat_daemon() { return 0; }
    chown() { return 0; }

    apply_vnstat_config_update "$first_config" eth0 false 60 '' false >/dev/null || return 1
    [ "$(select_vnstat_backup_path "$work/sub/../first-vnstat.conf")" = \
        "$WORK_DIR/vnstat.conf.before-trafficcop-lite" ] || return 1
    apply_vnstat_config_update "$second_config" eth0 false 60 '' false >/dev/null || return 1

    assert_file_content "$first_original" "$WORK_DIR/vnstat.conf.before-trafficcop-lite" || return 1
    assert_file_content "$first_config" "$WORK_DIR/vnstat.conf.before-trafficcop-lite.source-path" || return 1
    assert_file_content "$second_original" "$WORK_DIR/vnstat.conf.before-trafficcop-lite.1" || return 1
    assert_file_content "$second_config" "$WORK_DIR/vnstat.conf.before-trafficcop-lite.1.source-path"
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
    # 2.0：菜单从 main 移到 telegram_menu / telegram_menu_render，打开时改由 sync_telegram_cron 核对定时任务，
    # 一并加载与替换；断言不变（打开菜单不取 Telegram 运行锁）。
    load_function "$TELEGRAM_SCRIPT" telegram_menu || return 1
    load_function "$TELEGRAM_SCRIPT" telegram_menu_render || return 1
    load_function "$TELEGRAM_SCRIPT" warn_percents_label || return 1
    debug_log() { return 0; }
    check_runtime_dependencies() { return 0; }
    check_running() { printf '%s\n' 'called' > "$work/lock-called"; }
    read_config() { TG_DISABLED=true; return 0; }
    remove_telegram_cron() { return 0; }
    sync_telegram_cron() { return 0; }
    read_current_traffic_state() { return 1; }
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

    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.9"' > "$remote_dir/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.7"' > "$remote_dir/$MONITOR_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.1.3"' > "$remote_dir/$TELEGRAM_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop Lite Machine Limit v2.7' > "$remote_dir/$MACHINE_LIMIT_SCRIPT"
    (cd "$remote_dir" && sha256sum trafficcop-lite*.sh > SHA256SUMS) || return 1

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" validate_update_candidate || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" verify_installed_scripts || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" rollback_script_update || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" update_scripts || return 1
    ensure_work_dir() { mkdir -p "$WORK_DIR"; }
    download_url_to_file() { cp "$remote_dir/$(basename "$1")" "$2"; }
    install_shortcut_link() { printf '%s\n' 'called' > "$work/shortcut-called"; }
    install_tc_recovery_service_files() { :; }

    update_scripts 'https://example.invalid/release' >/dev/null || return 1
    grep -Fqx 'SCRIPT_VERSION="1.1.9"' "$WORK_DIR/trafficcop-lite.sh" || return 1
    grep -Fqx 'SCRIPT_VERSION="1.1.7"' "$WORK_DIR/$MONITOR_SCRIPT" || return 1
    grep -Fqx 'SCRIPT_VERSION="1.1.3"' "$WORK_DIR/$TELEGRAM_SCRIPT" || return 1
    grep -Fqx '# TrafficCop Lite Machine Limit v2.7' "$WORK_DIR/$MACHINE_LIMIT_SCRIPT" || return 1
    assert_file_content 'CONFIG=keep-me' "$WORK_DIR/traffic_monitor_config.txt" || return 1
    backup_main=$(find "$WORK_DIR/backups" -type f -name trafficcop-lite.sh -print -quit) || return 1
    [ -n "$backup_main" ] || return 1
    grep -Fqx 'SCRIPT_VERSION="1.0.2"' "$backup_main" || return 1
    [ "$UPDATE_PREVIOUS_VERSION" = '1.0.2' ] || return 1
    [ "$UPDATE_NEW_VERSION" = '1.1.9' ] || return 1
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
test_vnstat_freshness_rejects_dead_and_stale_daemon_data() {
    local now fresh_json stale_json daemon_running=true
    command -v jq >/dev/null 2>&1 || return 1
    now=$(date +%s) || return 1
    fresh_json=$(printf '{"interfaces":[{"updated":{"timestamp":%s}}]}' "$((now - 30))")
    stale_json=$(printf '{"interfaces":[{"updated":{"timestamp":%s}}]}' "$((now - 1000))")

    load_function "$MONITOR_SCRIPT" vnstat_data_is_fresh || return 1
    vnstat_daemon_is_running() { "$daemon_running"; }
    vnstat_config_value() {
        case "$1" in
            SaveInterval) printf '%s\n' '1' ;;
            UpdateInterval) printf '%s\n' '60' ;;
        esac
    }

    vnstat_data_is_fresh "$fresh_json" || return 1
    if vnstat_data_is_fresh "$stale_json"; then
        return 1
    fi
    daemon_running=false
    if vnstat_data_is_fresh "$fresh_json"; then
        return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_json_is_normalized_for_the_requested_interface() {
    local valid_json missing_tx_json invalid_date_json leap_day_json normalized
    command -v jq >/dev/null 2>&1 || return 1
    valid_json=$(cat <<'JSON'
{"jsonversion":"2","interfaces":[{"name":"eth1","created":{"date":{"year":2025,"month":1,"day":1}},"updated":{"timestamp":1},"traffic":{"day":[]}},{"name":"eth0","created":{"date":{"year":2025,"month":1,"day":1}},"updated":{"timestamp":1},"traffic":{"day":[{"date":{"year":2026,"month":8,"day":24},"rx":123,"tx":456}]}}]}
JSON
)
    missing_tx_json=$(cat <<'JSON'
{"jsonversion":"2","interfaces":[{"name":"eth0","created":{"date":{"year":2025,"month":1,"day":1}},"updated":{"timestamp":1},"traffic":{"day":[{"date":{"year":2026,"month":8,"day":24},"rx":123}]}}]}
JSON
)
    invalid_date_json=$(printf '%s' "$valid_json" | jq -c '
        (.interfaces[] | select(.name == "eth0").traffic.day[0].date) =
        {year: 2026, month: 2, day: 31}
    ') || return 1
    leap_day_json=$(printf '%s' "$valid_json" | jq -c '
        (.interfaces[] | select(.name == "eth0").traffic.day[0].date) =
        {year: 2024, month: 2, day: 29}
    ') || return 1

    load_function "$MONITOR_SCRIPT" normalize_vnstat_json_for_interface || return 1
    normalized=$(normalize_vnstat_json_for_interface "$valid_json" eth0) || return 1
    [ "$(printf '%s' "$normalized" | jq -r '.interfaces | length')" = 1 ] || return 1
    [ "$(printf '%s' "$normalized" | jq -r '.interfaces[0].name')" = eth0 ] || return 1
    [ "$(printf '%s' "$normalized" | jq -r '.interfaces[0].traffic.day[0].tx')" = 456 ] || return 1
    normalize_vnstat_json_for_interface "$leap_day_json" eth0 >/dev/null || return 1
    if normalize_vnstat_json_for_interface "$missing_tx_json" eth0 >/dev/null; then
        return 1
    fi
    if normalize_vnstat_json_for_interface "$invalid_date_json" eth0 >/dev/null; then
        return 1
    fi
    if normalize_vnstat_json_for_interface "$valid_json" ens5 >/dev/null; then
        return 1
    fi
    if normalize_vnstat_json_for_interface "${valid_json/\"jsonversion\":\"2\"/\"jsonversion\":\"3\"}" eth0 >/dev/null; then
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
test_post_save_prepares_enforcement_before_runtime_mutation() {
    local work
    work=$(mktemp -d "$TEST_ROOT/post-save-prepare.XXXXXX") || return 1
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TRAFFIC_UNIT=decimal
    TRAFFIC_LIMIT=100
    TRAFFIC_TOLERANCE=10
    printf '%s\n' 'MODE=old' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" configure_post_save_enforcement || return 1
    get_traffic_usage() { printf '%s\n' 100; }
    bc() { cat >/dev/null; printf '%s\n' 90; }
    is_decimal() { return 0; }
    compare_decimal() { return 0; }
    write_enforcement_state_file() {
        printf '%s\n' called > "$work/candidate-attempted"
        return 1
    }
    clear_owned_tc_rules() { printf '%s\n' called > "$work/tc-cleared"; }
    clear_owned_shutdown_schedule() { printf '%s\n' called > "$work/shutdown-cleared"; }

    if configure_post_save_enforcement <<< 3 >/dev/null; then
        return 1
    fi
    assert_file_content called "$work/candidate-attempted" || return 1
    assert_file_content 'MODE=old' "$ENFORCEMENT_STATE_FILE" || return 1
    assert_absent "$work/tc-cleared" || return 1
    assert_absent "$work/shutdown-cleared"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_clears_tc_before_shutdown_and_keeps_old_state_on_failure() {
    local work
    work=$(mktemp -d "$TEST_ROOT/post-save-order.XXXXXX") || return 1
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TRAFFIC_UNIT=decimal
    TRAFFIC_LIMIT=100
    TRAFFIC_TOLERANCE=10
    printf '%s\n' 'MODE=old' > "$ENFORCEMENT_STATE_FILE"

    load_function "$MONITOR_SCRIPT" configure_post_save_enforcement || return 1
    get_traffic_usage() { printf '%s\n' 100; }
    bc() { cat >/dev/null; printf '%s\n' 90; }
    is_decimal() { return 0; }
    compare_decimal() { return 0; }
    write_enforcement_state_file() { printf '%s\n' candidate > "$4"; }
    clear_owned_tc_rules() { printf '%s\n' tc >> "$work/events"; }
    clear_owned_shutdown_schedule() {
        printf '%s\n' shutdown >> "$work/events"
        return 1
    }

    if configure_post_save_enforcement <<< 3 >/dev/null; then
        return 1
    fi
    assert_file_content $'tc\nshutdown' "$work/events" || return 1
    assert_file_content 'MODE=old' "$ENFORCEMENT_STATE_FILE" || return 1
    [ "$CONFIG_TC_CLEAR_ATTEMPTED" = true ] || return 1
    [ "$CONFIG_SHUTDOWN_CLEAR_ATTEMPTED" = true ] || return 1
    ! find "$work" -name '*.config-candidate.*' -print -quit | grep -q .
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_transaction_rolls_back_config_marker_interface_and_daemon() {
    local work
    work=$(mktemp -d "$TEST_ROOT/vnstat-transaction.XXXXXX") || return 1
    VNSTAT_TRANSACTION_DIR="$work/transaction"
    mkdir -p "$VNSTAT_TRANSACTION_DIR"
    VNSTAT_TRANSACTION_CONFIG_PATH="$work/vnstat.conf"
    VNSTAT_TRANSACTION_INTERFACE=eth0
    VNSTAT_TRANSACTION_INTERFACE_ADDED=true
    VNSTAT_TRANSACTION_DAEMON_WAS_RUNNING=false
    VNSTAT_TRANSACTION_HAD_RETENTION=true
    VNSTAT_TRANSACTION_HAD_CONFIG_PATH_FILE=true
    VNSTAT_CONFIG_TRANSACTION_ACTIVE=true
    RETENTION_STATE_FILE="$work/coverage"
    VNSTAT_CONFIG_PATH_FILE="$work/config-path"
    VNSTAT_CONFIG_PATH="$VNSTAT_TRANSACTION_CONFIG_PATH"

    printf '%s\n' new-config > "$VNSTAT_TRANSACTION_CONFIG_PATH"
    printf '%s\n' old-config > "$VNSTAT_TRANSACTION_DIR/vnstat.conf"
    printf '%s\n' new-marker > "$RETENTION_STATE_FILE"
    printf '%s\n' old-marker > "$VNSTAT_TRANSACTION_DIR/retention-state"
    printf '%s\n' /new/vnstat.conf > "$VNSTAT_CONFIG_PATH_FILE"
    printf '%s\n' /old/vnstat.conf > "$VNSTAT_TRANSACTION_DIR/config-path-file"

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" cleanup_initial_vnstat_transaction_files || return 1
    load_function "$MONITOR_SCRIPT" rollback_initial_vnstat_transaction || return 1
    vnstat_cmd() { printf '%s\n' "$*" > "$work/vnstat-command"; }
    stop_transaction_vnstat_daemon() { printf '%s\n' stopped > "$work/daemon"; }
    reload_vnstat_daemon() { printf '%s\n' unexpected > "$work/reload"; }

    rollback_initial_vnstat_transaction >/dev/null || return 1
    assert_file_content 'old-config' "$VNSTAT_TRANSACTION_CONFIG_PATH" || return 1
    assert_file_content 'old-marker' "$RETENTION_STATE_FILE" || return 1
    assert_file_content '/old/vnstat.conf' "$VNSTAT_CONFIG_PATH_FILE" || return 1
    assert_file_content '--remove -i eth0' "$work/vnstat-command" || return 1
    assert_file_content stopped "$work/daemon" || return 1
    assert_absent "$work/reload" || return 1
    assert_absent "$work/transaction"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_config_rollback_compensates_live_tc_and_shutdown() {
    local work pending=false
    work=$(mktemp -d "$TEST_ROOT/config-runtime-rollback.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    local config_backup="$work/config.backup"
    local enforcement_backup="$work/enforcement.backup"
    local tc_backup="$work/tc.backup"
    local shutdown_backup="$work/shutdown.backup"
    printf '%s\n' old-config > "$config_backup"
    printf '%s\n' old-enforcement > "$enforcement_backup"
    printf '%s\n' old-tc-state > "$tc_backup"
    printf '%s\n' 'TASK_TOKEN=trafficcop-lite-rollback-12345678' > "$shutdown_backup"
    printf '%s\n' new-config > "$CONFIG_FILE"
    printf '%s\n' new-enforcement > "$ENFORCEMENT_STATE_FILE"

    CONFIG_SNAPSHOT_HAD_CONFIG=true
    CONFIG_SNAPSHOT_HAD_ENFORCEMENT=true
    CONFIG_SNAPSHOT_HAD_TC=true
    CONFIG_SNAPSHOT_HAD_SHUTDOWN=true
    CONFIG_SNAPSHOT_OLD_TC_ACTIVE=true
    CONFIG_SNAPSHOT_OLD_TC_INTERFACE=eth0
    CONFIG_SNAPSHOT_OLD_TC_SPEED=90
    CONFIG_SNAPSHOT_OLD_SHUTDOWN_PENDING=true
    CONFIG_TC_CLEAR_ATTEMPTED=true
    CONFIG_SHUTDOWN_CLEAR_ATTEMPTED=true
    MAIN_INTERFACE=ens5

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_owned_tc_after_config_failure || return 1
    load_function "$MONITOR_SCRIPT" restore_owned_shutdown_after_config_failure || return 1
    load_function "$MONITOR_SCRIPT" rollback_monitor_config_transaction || return 1
    owned_tc_limit_active() { return 1; }
    apply_tc_limit() {
        [ "$1" = 90 ] && [ "$MAIN_INTERFACE" = eth0 ] || return 1
        printf '%s\n' restored > "$TC_STATE_FILE"
        printf '%s\n' applied > "$work/tc-applied"
    }
    has_pending_shutdown() { [ "$pending" = true ]; }
    local submitted_message=''
    shutdown_task_token_from_state() { printf '%s\n' trafficcop-lite-rollback-12345678; }
    pending_shutdown_matches_owned_state() {
        [ "$pending" = true ] && [[ "$submitted_message" == *trafficcop-lite-rollback-12345678* ]]
    }
    shutdown() {
        submitted_message="$*"
        pending=true
        printf '%s\n' submitted > "$work/shutdown-submitted"
    }
    rollback_initial_vnstat_transaction() { return 0; }
    read_config() { return 0; }

    rollback_monitor_config_transaction "$config_backup" "$enforcement_backup" \
        "$tc_backup" "$shutdown_backup" || return 1
    assert_file_content old-config "$CONFIG_FILE" || return 1
    assert_file_content old-enforcement "$ENFORCEMENT_STATE_FILE" || return 1
    assert_file_content applied "$work/tc-applied" || return 1
    assert_file_content submitted "$work/shutdown-submitted" || return 1
    [[ "$submitted_message" == *trafficcop-lite-rollback-12345678* ]] || return 1
    [ "$MAIN_INTERFACE" = ens5 ] || return 1
    assert_absent "$config_backup" || return 1
    assert_absent "$tc_backup"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_config_rollback_reports_failed_runtime_compensation() {
    local work
    work=$(mktemp -d "$TEST_ROOT/config-runtime-rollback-fail.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    local config_backup="$work/config.backup"
    local enforcement_backup="$work/enforcement.backup"
    local tc_backup="$work/tc.backup"
    local shutdown_backup="$work/shutdown.backup"
    printf '%s\n' old-config > "$config_backup"
    printf '%s\n' old-enforcement > "$enforcement_backup"
    printf '%s\n' old-tc-state > "$tc_backup"

    CONFIG_SNAPSHOT_HAD_CONFIG=true
    CONFIG_SNAPSHOT_HAD_ENFORCEMENT=true
    CONFIG_SNAPSHOT_HAD_TC=true
    CONFIG_SNAPSHOT_HAD_SHUTDOWN=false
    CONFIG_SNAPSHOT_OLD_TC_ACTIVE=true
    CONFIG_SNAPSHOT_OLD_TC_INTERFACE=eth0
    CONFIG_SNAPSHOT_OLD_TC_SPEED=90
    CONFIG_SNAPSHOT_OLD_SHUTDOWN_PENDING=false
    CONFIG_TC_CLEAR_ATTEMPTED=true
    CONFIG_SHUTDOWN_CLEAR_ATTEMPTED=false
    MAIN_INTERFACE=ens5

    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_owned_tc_after_config_failure || return 1
    load_function "$MONITOR_SCRIPT" restore_owned_shutdown_after_config_failure || return 1
    load_function "$MONITOR_SCRIPT" rollback_monitor_config_transaction || return 1
    owned_tc_limit_active() { return 1; }
    apply_tc_limit() { return 1; }
    rollback_initial_vnstat_transaction() { return 0; }
    read_config() { return 0; }

    if rollback_monitor_config_transaction "$config_backup" "$enforcement_backup" \
        "$tc_backup" "$shutdown_backup"; then
        return 1
    fi
    [ -f "$config_backup" ] || return 1
    [ -f "$tc_backup" ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_vnstat_interface_addition_is_recorded_before_reload() {
    local work call_count=0
    work=$(mktemp -d "$TEST_ROOT/vnstat-interface-transaction.XXXXXX") || return 1
    LOG_FILE="$work/log"
    VNSTAT_CONFIG_TRANSACTION_ACTIVE=true
    VNSTAT_TRANSACTION_INTERFACE=eth0
    VNSTAT_TRANSACTION_INTERFACE_ADDED=false

    load_function "$MONITOR_SCRIPT" ensure_vnstat_interface || return 1
    vnstat_cmd() {
        call_count=$((call_count + 1))
        [ "$call_count" -eq 2 ]
    }
    ensure_vnstat_daemon_running() { return 0; }
    reload_vnstat_daemon() { return 1; }

    if ensure_vnstat_interface eth0 >/dev/null; then
        return 1
    fi
    [ "$VNSTAT_TRANSACTION_INTERFACE_ADDED" = true ]
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
test_tc_query_helpers_preserve_command_errors() {
    TC_BIN='mock_tc'
    load_function "$MONITOR_SCRIPT" tc_root_qdisc || return 1
    load_function "$MONITOR_SCRIPT" tc_class_line || return 1
    load_function "$MONITOR_SCRIPT" tc_class_output || return 1
    load_function "$MONITOR_SCRIPT" tc_filter_output || return 1
    mock_tc() { return 42; }

    tc_root_qdisc eth0 >/dev/null 2>&1
    [ "$?" -eq 2 ] || return 1
    tc_class_line eth0 1:1 >/dev/null 2>&1
    [ "$?" -eq 2 ] || return 1
    tc_class_output eth0 >/dev/null 2>&1
    [ "$?" -eq 2 ] || return 1
    tc_filter_output eth0 >/dev/null 2>&1
    [ "$?" -eq 2 ] || return 1

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" tc_root_qdisc || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" tc_class_output || return 1
    tc_root_qdisc eth0 >/dev/null 2>&1
    [ "$?" -eq 2 ] || return 1
    tc_class_output eth0 >/dev/null 2>&1
    [ "$?" -eq 2 ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_apply_query_failure_is_zero_mutation() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-apply-query-error.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    MAIN_INTERFACE='eth0'
    TC_BIN='mock_tc'

    load_function "$MONITOR_SCRIPT" apply_tc_limit || return 1
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_state_interface() { return 1; }
    tc_root_qdisc() { return 2; }
    write_tc_state() { printf '%s\n' unexpected > "$work/state-written"; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    if apply_tc_limit 90 >/dev/null; then
        return 1
    fi
    assert_absent "$work/tc-called" || return 1
    assert_absent "$work/state-written" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    [ "$lock_held" = "false" ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_clear_query_failure_preserves_rules_and_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-clear-query-error.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    TC_BIN='mock_tc'
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" clear_owned_tc_rules_locked || return 1
    tc_state_interface() { printf '%s\n' eth0; }
    tc_state_value() {
        case "$1" in
            LIMIT_SPEED) printf '%s\n' 90 ;;
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
        esac
    }
    tc_root_qdisc() { printf '%s\n' 'qdisc htb 1: root default 30'; }
    is_default_qdisc_line() { return 1; }
    tc_root_is_unified_compatible() { return 0; }
    tc_verify_unified_hierarchy() { return 0; }
    tc_has_other_consumers() { return 2; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    if clear_owned_tc_rules_locked test >/dev/null; then
        return 1
    fi
    assert_file_content state "$TC_STATE_FILE" || return 1
    assert_absent "$work/tc-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_existing_htb_rollback_requires_default_class_delete() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-rollback-delete.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    MAIN_INTERFACE=eth0
    TC_BIN=mock_tc

    load_function "$MONITOR_SCRIPT" apply_tc_limit || return 1
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_state_interface() { return 1; }
    tc_root_qdisc() { printf '%s\n' 'qdisc htb 1: root default 30'; }
    tc_root_is_unified_compatible() { return 0; }
    tc_state_is_unified_for_interface() { return 1; }
    tc_class_value() {
        case "$2:$3" in
            1:1:rate|1:1:ceil) printf '%s\n' 100gbit ;;
            *) return 1 ;;
        esac
    }
    normalize_tc_rate_to_bps() { printf '%s\n' 100000000000; }
    tc_class_line() { [ "$2" = 1:30 ] && return 1; return 2; }
    write_tc_state() { printf '%s\n' prepared > "$4"; }
    tc_replace_base_classes() { return 0; }
    tc_verify_unified_hierarchy() { return 1; }
    mock_tc() {
        printf '%s\n' "$*" >> "$work/tc-calls"
        case "$*" in
            'class replace dev eth0 parent 1: classid 1:1 '*) return 0 ;;
            'class del dev eth0 classid 1:30') return 55 ;;
            *) return 0 ;;
        esac
    }

    if apply_tc_limit 900 > "$work/output" 2>&1; then
        return 1
    fi
    grep -Fxq 'class del dev eth0 classid 1:30' "$work/tc-calls" || return 1
    grep -Fq '严重错误：统一 HTB 回滚失败' "$work/output" || return 1
    if grep -Fq '已恢复修改前的 TC 状态' "$work/output"; then
        return 1
    fi
    [ -f "${TC_STATE_FILE}.prepared.$$" ] || return 1
    [ "$lock_held" = false ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_default_qdisc_state_delete_failure_is_reported() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-state-delete.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    TC_STATE_SCHEMA=traffic-tools-unified-htb-v1
    TC_STATE_PROVIDER=trafficcop-lite
    TC_BIN=mock_tc
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" clear_owned_tc_rules_locked || return 1
    tc_state_interface() { printf '%s\n' eth0; }
    tc_root_qdisc() { printf '%s\n' 'qdisc fq_codel 0: root'; }
    tc_state_value() {
        case "$1" in
            LIMIT_SPEED) printf '%s\n' 900 ;;
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
        esac
    }
    is_default_qdisc_line() { return 0; }
    rm() {
        local last_arg="${!#}"
        if [ "$last_arg" = "$TC_STATE_FILE" ]; then
            return 55
        fi
        command rm "$@"
    }
    mock_tc() { return 0; }

    if clear_owned_tc_rules_locked audit > "$work/output" 2>&1; then
        return 1
    fi
    assert_file_content state "$TC_STATE_FILE" || return 1
    grep -Fq '状态文件删除失败' "$work/output" || return 1
    if grep -Fq '仅清理本脚本状态' "$work/output"; then
        return 1
    fi
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_recovery_query_failure_is_zero_mutation() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-recover-query-error.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    TC_BIN='mock_tc'
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    DISABLED='false'
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" recover_owned_tc_hierarchy || return 1
    trafficcop_config_is_disabled() { return 1; }
    tc_state_file_is_interpretable() { return 0; }
    tc_state_interface() { printf '%s\n' eth0; }
    tc_state_value() {
        case "$1" in
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
            LIMIT_SPEED) printf '%s\n' 90 ;;
        esac
    }
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { return 2; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    if recover_owned_tc_hierarchy --manual >/dev/null 2>&1; then
        return 1
    fi
    assert_file_content state "$TC_STATE_FILE" || return 1
    assert_absent "$work/tc-called" || return 1
    [ "$lock_held" = "false" ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_self_check_reports_query_error() {
    local work status=0 lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-self-query-error.XXXXXX") || return 1
    TC_BIN='mock_tc'
    TC_STATE_FILE="$work/tc-state"

    load_function "$MONITOR_SCRIPT" tc_self_check || return 1
    trafficcop_config_is_disabled() { return 1; }
    resolve_tc_self_check_interface() { printf '%s\n' eth0; }
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { return 2; }

    tc_self_check eth0 > "$work/output" || status=$?
    [ "$status" -eq 1 ] || return 1
    assert_file_content 'TC_SELF_CHECK=ERROR INTERFACE=eth0 REASON=tc-query-failed' "$work/output" || return 1
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
test_self_check_flags_legacy_state_after_dog_migration() {
    local work status=0
    work=$(mktemp -d "$TEST_ROOT/self-check-legacy-state.XXXXXX") || return 1
    TC_BIN='mock_tc'
    TC_STATE_FILE="$work/tc-state"
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    printf '%s\n' \
        'INTERFACE=eth0' \
        'LIMIT_SPEED=5000' \
        'PROVIDER=trafficcop-lite' > "$TC_STATE_FILE"
    local lock_held=false

    load_function "$MONITOR_SCRIPT" tc_self_check || return 1
    trafficcop_config_is_disabled() { return 1; }
    tc_state_file_is_interpretable() { return 0; }
    resolve_tc_self_check_interface() { printf '%s\n' "${1:-eth0}"; }
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc htb 1: root default 30'; }
    is_default_qdisc_line() { return 1; }
    tc_root_is_unified_compatible() { return 0; }
    tc_default_class_is_safe() { return 0; }
    tc_state_is_unified_for_interface() { return 1; }
    tc_state_interface() { printf '%s\n' 'eth0'; }
    tc_state_value() {
        case "$1" in
            SCHEMA) return 0 ;;
            LIMIT_SPEED) printf '%s\n' '5000' ;;
            PROVIDER) printf '%s\n' 'trafficcop-lite' ;;
        esac
    }
    tc_class_line() { printf '%s\n' 'class htb 1:30 parent 1:1 rate 1Kbit ceil 5Mbit'; }

    tc_self_check eth0 > "$work/output" || status=$?
    [ "$status" -eq 1 ] || return 1
    assert_file_content \
        'TC_SELF_CHECK=DRIFT INTERFACE=eth0 REASON=legacy-trafficcop-state-with-unified-htb ACTION=reapply-trafficcop-limit' \
        "$work/output" || return 1
    [ "$lock_held" = "false" ]
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

    load_function "$MONITOR_SCRIPT" dog_bandwidth_to_tc || return 1
    load_function "$MONITOR_SCRIPT" dog_configured_class_records || return 1
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

# shellcheck disable=SC2016,SC2034,SC2209,SC2317,SC2329
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
        [ -f "$1" ] || return 1
        cat "$1" > "$work/crontab"
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

# shellcheck disable=SC2016,SC2034,SC2209,SC2317,SC2329
test_all_crontab_writers_build_candidates_before_installing() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/root-cron-candidate.XXXXXX") || return 1
    LOG_FILE="$work/log"
    RED=''
    NC=''

    load_function "$MONITOR_SCRIPT" setup_crontab || return 1
    load_function "$TELEGRAM_SCRIPT" setup_cron || return 1
    load_function "$TELEGRAM_SCRIPT" remove_telegram_cron || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" add_cron_job || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" remove_cron_job || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" remove_lite_cron || return 1

    SCRIPT_PATH=/etc/trafficcop-lite/component.sh
    CRON_COMMENT='# TrafficCop-Lite Machine Limit'
    WORK_DIR=/etc/trafficcop-lite
    MONITOR_SCRIPT=trafficcop-lite-monitor.sh
    TELEGRAM_SCRIPT=trafficcop-lite-telegram.sh
    acquire_root_crontab_lock() { lock_held=true; }
    release_root_crontab_lock() { lock_held=false; }
    read_current_crontab() {
        [ "$lock_held" = true ] || return 1
        printf '%s\n' \
            '17 3 * * * /usr/local/bin/unrelated-backup' \
            '23 4 * * * /usr/local/bin/another-job'
    }
    awk() { return 55; }
    crontab() { printf '%s\n' "$*" > "$work/crontab-called"; }
    expect_candidate_failure_without_install() {
        lock_held=false
        rm -f "$work/crontab-called"
        if "$1" >/dev/null 2>&1; then
            return 1
        fi
        [ "$lock_held" = false ] || return 1
        assert_absent "$work/crontab-called"
    }

    expect_candidate_failure_without_install setup_crontab || return 1
    expect_candidate_failure_without_install setup_cron || return 1
    expect_candidate_failure_without_install remove_telegram_cron || return 1
    expect_candidate_failure_without_install add_cron_job || return 1
    expect_candidate_failure_without_install remove_cron_job || return 1
    expect_candidate_failure_without_install remove_lite_cron
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

    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
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
    # 2.0：curl 不再用 -f，改由 -w 在最后一行输出 HTTP 状态码（用来区分 Token 无效、限流等失败原因）。
    curl() {
        printf '%s\n' "$@" > "$work/curl-args"
        cat > "$work/curl-stdin"
        printf '%s\n%s' '{"ok":true}' 200
    }

    telegram_send_message 'test message' || return 1
    ! grep -Fq "$BOT_TOKEN" "$work/curl-args" || return 1
    grep -Fq "$BOT_TOKEN" "$work/curl-stdin"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_update_rejects_checksum_mismatch_and_missing_sums() {
    local work remote_dir script_name
    work=$(mktemp -d "$TEST_ROOT/update-sums.XXXXXX") || return 1
    WORK_DIR="$work/installed"; remote_dir="$work/remote"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'; TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'; RAW_BASE='https://example.invalid/direct'
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
    mkdir -p "$WORK_DIR" "$remote_dir"
    for script_name in trafficcop-lite.sh "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT"; do
        printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.0"' > "$WORK_DIR/$script_name"
        printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.2.0"' > "$remote_dir/$script_name"
    done
    printf '%s\n' '#!/bin/bash' '# TrafficCop Lite Machine Limit v2.0' > "$WORK_DIR/$MACHINE_LIMIT_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop Lite Machine Limit v2.12' > "$remote_dir/$MACHINE_LIMIT_SCRIPT"
    (cd "$remote_dir" && sha256sum trafficcop-lite*.sh > SHA256SUMS) || return 1
    printf '%s\n' '# tampered' >> "$remote_dir/$MONITOR_SCRIPT"

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" validate_update_candidate || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" verify_installed_scripts || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" rollback_script_update || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" update_scripts || return 1
    ensure_work_dir() { mkdir -p "$WORK_DIR"; }
    download_url_to_file() { [ -f "$remote_dir/$(basename "$1")" ] && cp "$remote_dir/$(basename "$1")" "$2"; }
    install_shortcut_link() { :; }
    install_tc_recovery_service_files() { :; }

    # 篡改：任何文件都不得替换。
    if update_scripts 'https://example.invalid/proxy' >/dev/null 2>&1; then return 1; fi
    for script_name in trafficcop-lite.sh "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT"; do
        grep -Fqx 'SCRIPT_VERSION="1.0.0"' "$WORK_DIR/$script_name" || return 1
    done
    # 缺少 SHA256SUMS：同样拒绝。
    rm -f "$remote_dir/SHA256SUMS"
    if update_scripts 'https://example.invalid/proxy' >/dev/null 2>&1; then return 1; fi
    grep -Fqx 'SCRIPT_VERSION="1.0.0"' "$WORK_DIR/$MONITOR_SCRIPT" || return 1
    # 不留临时文件。
    [ -z "$(find "$WORK_DIR" -maxdepth 1 -name '.*' -type f -print -quit)" ]
}

# 监控健康：异常提醒限频、恢复通知、禁用与“未知”不提醒、日报不再每分钟重试。
# shellcheck disable=SC2034,SC2317,SC2329
test_telegram_monitor_health_alerts() {
    local work now
    work=$(mktemp -d "$TEST_ROOT/tg-health.XXXXXX") || return 1
    WORK_DIR="$work"; MACHINE_NAME='test-host'
    MONITOR_HEALTH_FILE="$work/monitor_health"; MONITOR_ALERT_STATE_FILE="$work/last_monitor_alert"
    MONITOR_ALERT_INTERVAL=21600; MONITOR_STALE_SECONDS=600
    USAGE_STATE_FILE="$work/usage"; PERIOD_STATE_FILE="$work/period"; CRON_LOG="$work/cron.log"
    load_function "$TELEGRAM_SCRIPT" read_monitor_health || return 1
    load_function "$TELEGRAM_SCRIPT" check_monitor_health || return 1
    load_function "$TELEGRAM_SCRIPT" read_current_traffic_state || return 1
    load_function "$TELEGRAM_SCRIPT" daily_report || return 1
    log_cron() { :; }
    debug_log() { :; }
    telegram_send_message() { printf '%s\n' "$1" >> "$work/sent"; }
    now=$(date +%s)

    # 未知（无健康文件）：不提醒。
    check_monitor_health || return 1
    assert_absent "$work/sent" || return 1
    # 监控报告错误：提醒一次，限频期内不重复。
    printf 'HEALTH=error\nREASON=vnStat 数据过旧\nUPDATED_EPOCH=%s\n' "$now" > "$MONITOR_HEALTH_FILE"
    check_monitor_health || return 1
    check_monitor_health || return 1
    [ "$(grep -c '流量监控异常' "$work/sent")" = 1 ] || return 1
    grep -q 'vnStat 数据过旧' "$work/sent" || return 1
    # 限频期过后再次提醒。
    printf '%s\n' $((now - 21601)) > "$MONITOR_ALERT_STATE_FILE"
    check_monitor_health || return 1
    [ "$(grep -c '流量监控异常' "$work/sent")" = 2 ] || return 1
    # 恢复：发送一次“已恢复”，并清除提醒状态。
    printf 'HEALTH=ok\nREASON=\nUPDATED_EPOCH=%s\n' "$now" > "$MONITOR_HEALTH_FILE"
    check_monitor_health || return 1
    check_monitor_health || return 1
    [ "$(grep -c '监控已恢复' "$work/sent")" = 1 ] || return 1
    assert_absent "$MONITOR_ALERT_STATE_FILE" || return 1
    # 健康状态长时间未更新（cron 停止）：提醒。
    printf 'HEALTH=ok\nREASON=\nUPDATED_EPOCH=%s\n' $((now - 3600)) > "$MONITOR_HEALTH_FILE"
    check_monitor_health || return 1
    grep -q '60 分钟没有运行' "$work/sent" || return 1
    # 主动禁用：不提醒，且清除提醒状态。
    : > "$work/sent"
    printf 'HEALTH=disabled\nREASON=监控已禁用\nUPDATED_EPOCH=%s\n' "$now" > "$MONITOR_HEALTH_FILE"
    check_monitor_health || return 1
    [ ! -s "$work/sent" ] || return 1
    assert_absent "$MONITOR_ALERT_STATE_FILE" || return 1
    # 日报：实时状态不可用且监控异常时，发送“状态不可用”日报并视为已发送。
    printf 'HEALTH=error\nREASON=配置文件读取失败\nUPDATED_EPOCH=%s\n' "$now" > "$MONITOR_HEALTH_FILE"
    daily_report >/dev/null || return 1
    grep -q '实时流量状态不可用：配置文件读取失败' "$work/sent" || return 1
    # 健康未知时保持原行为（稍后重试）。
    rm -f "$MONITOR_HEALTH_FILE"
    if daily_report >/dev/null; then return 1; fi
}

# shellcheck disable=SC2034,SC2317,SC2329
test_monitor_writes_health_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/monitor-health.XXXXXX") || return 1
    HEALTH_STATE_FILE="$work/health"; LOG_FILE="$work/log"
    load_function "$MONITOR_SCRIPT" write_health_state || return 1
    load_function "$MONITOR_SCRIPT" last_log_reason || return 1
    printf '%s\n' '2026-11-15 10:00:00 无法可靠读取当前流量，本轮跳过限速判断并保留现有限速状态。' > "$LOG_FILE"
    write_health_state error "$(last_log_reason)" || return 1
    grep -Fxq 'HEALTH=error' "$HEALTH_STATE_FILE" || return 1
    grep -Fxq 'REASON=无法可靠读取当前流量，本轮跳过限速判断并保留现有限速状态。' "$HEALTH_STATE_FILE" || return 1
    grep -Eq '^UPDATED_EPOCH=[0-9]+$' "$HEALTH_STATE_FILE" || return 1
    [ "$(stat -c %a "$HEALTH_STATE_FILE")" = 600 ] || return 1
    # 多行、超长原因被压成单行并截断。
    write_health_state error "$(printf 'a\nb%0300d' 0)" || return 1
    [ "$(wc -l < "$HEALTH_STATE_FILE")" = 3 ] || return 1
    [ "$(grep '^REASON=' "$HEALTH_STATE_FILE" | wc -c)" -le 208 ]
}

test_repository_sha256sums_match_scripts() {
    (cd "$ROOT_DIR" && sha256sum -c --quiet SHA256SUMS) || return 1
    [ "$(awk '{print $2}' "$ROOT_DIR/SHA256SUMS" | LC_ALL=C sort | paste -sd ' ')" = \
      'trafficcop-lite-machine-limit.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite.sh' ]
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
    # SHA256SUMS 与正文一致，失败只能来自“正文没有版本号”。
    download_url_to_file() {
        case "$1" in
            */SHA256SUMS) printf '%s  trafficcop-lite-monitor.sh\n' "$(printf '%s\n' 'upstream temporarily unavailable' | sha256sum | awk '{print $1}')" > "$2" ;;
            *) printf '%s\n' 'upstream temporarily unavailable' > "$2" ;;
        esac
    }

    if download_component trafficcop-lite-monitor.sh >/dev/null; then
        return 1
    fi
    assert_absent "$WORK_DIR/trafficcop-lite-monitor.sh"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_component_download_requires_a_verified_installed_target() {
    local work
    work=$(mktemp -d "$TEST_ROOT/component-target-verify.XXXXXX") || return 1
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
    download_url_to_file() {
        case "$1" in
            */SHA256SUMS) printf '%s  trafficcop-lite-monitor.sh\n' "$(printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.0"' | sha256sum | awk '{print $1}')" > "$2" ;;
            *) printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.0"' > "$2" ;;
        esac
    }
    # 模拟复制工具错误地报告成功但没有生成目标，安装函数仍须自行校验并失败。
    mv() { return 0; }

    if download_component trafficcop-lite-monitor.sh >/dev/null; then
        return 1
    fi
    assert_absent "$WORK_DIR/trafficcop-lite-monitor.sh"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_local_component_copy_failure_is_reported() {
    local work
    work=$(mktemp -d "$TEST_ROOT/component-local-copy.XXXXXX") || return 1
    SCRIPT_DIR="$work/source"
    WORK_DIR="$work/installed"
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
    mkdir -p "$SCRIPT_DIR" "$WORK_DIR"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.0.0"' > "$SCRIPT_DIR/trafficcop-lite-monitor.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="0.9.0"' '# old-installed-copy' > \
        "$WORK_DIR/trafficcop-lite-monitor.sh"

    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" version_is_newer || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" ensure_component || return 1
    ensure_work_dir() { return 0; }
    cp() { return 1; }

    if ensure_component trafficcop-lite-monitor.sh >/dev/null; then
        return 1
    fi
    grep -Fxq '# old-installed-copy' "$WORK_DIR/trafficcop-lite-monitor.sh" || return 1
    [ "$(script_version_from_file "$WORK_DIR/trafficcop-lite-monitor.sh")" = 0.9.0 ]
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

    load_function "$MONITOR_SCRIPT" normalize_vnstat_json_for_interface || return 1
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
{"jsonversion":"2","interfaces":[{"name":"eth0","created":{"date":{"year":2025,"month":1,"day":1}},"updated":{"timestamp":1},"traffic":{"day":[{"date":{"year":2026,"month":6,"day":30},"rx":10000000000,"tx":10000000000},{"date":{"year":2026,"month":7,"day":1},"rx":1000000000,"tx":2000000000},{"date":{"year":2026,"month":7,"day":2},"rx":3000000000,"tx":1000000000}]}}]}
JSON
    }
    vnstat_cmd() { vnstat "$@"; }
    vnstat_data_is_fresh() { return 0; }
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
    VNSTAT_MAX_BANDWIDTH=0

    load_function "$MONITOR_SCRIPT" vnstat_max_bandwidth_valid || return 1
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
test_invalid_disabled_value_is_rejected() {
    local work
    work=$(mktemp -d "$TEST_ROOT/invalid-disabled.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TRAFFIC_MODE=total
    TRAFFIC_PERIOD=monthly
    TRAFFIC_LIMIT=100
    TRAFFIC_TOLERANCE=0
    TRAFFIC_UNIT=decimal
    PERIOD_START_DAY=1
    PERIOD_START_MONTH=1
    LIMIT_SPEED=20
    TC_BOOT_GRACE_MINUTES=10
    ALLOW_PARTIAL_HISTORY=false
    MAIN_INTERFACE=eth0
    LIMIT_MODE=tc
    VNSTAT_MAX_BANDWIDTH=0

    load_function "$MONITOR_SCRIPT" vnstat_max_bandwidth_valid || return 1
    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    load_function "$MONITOR_SCRIPT" validate_config || return 1
    command_exists() { return 1; }

    DISABLED=garbage
    if validate_config >/dev/null; then
        return 1
    fi
    [ "$DISABLED" = garbage ] || return 1
    DISABLED=false
    validate_config >/dev/null || return 1
    DISABLED=true
    validate_config >/dev/null
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_period_start_day_validation_rejects_explicit_invalid_values() {
    local work invalid
    work=$(mktemp -d "$TEST_ROOT/invalid-period-day.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TRAFFIC_MODE='total'
    TRAFFIC_PERIOD='monthly'
    TRAFFIC_LIMIT='100'
    TRAFFIC_TOLERANCE='0'
    TRAFFIC_UNIT='decimal'
    PERIOD_START_MONTH='1'
    LIMIT_SPEED='20'
    TC_BOOT_GRACE_MINUTES='10'
    ALLOW_PARTIAL_HISTORY='false'
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    VNSTAT_MAX_BANDWIDTH=0

    load_function "$MONITOR_SCRIPT" vnstat_max_bandwidth_valid || return 1
    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    load_function "$MONITOR_SCRIPT" validate_config || return 1
    command_exists() { return 1; }

    unset PERIOD_START_DAY
    validate_config >/dev/null || return 1
    [ "$PERIOD_START_DAY" -eq 1 ] || return 1

    for invalid in '' 0 32 99 abc 001 031; do
        PERIOD_START_DAY="$invalid"
        if validate_config >/dev/null; then
            return 1
        fi
        [ "$PERIOD_START_DAY" = "$invalid" ] || return 1
    done

    PERIOD_START_DAY=09
    validate_config >/dev/null || return 1
    [ "$PERIOD_START_DAY" -eq 9 ] || return 1
    grep -Fq 'PERIOD_START_DAY 必须是 1-31 的整数' "$LOG_FILE"
}

# 2.0：仪表盘只读状态文件。准备一个临时安装目录，加载仪表盘及其辅助函数，屏蔽外部命令。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
setup_dashboard_case() {
    WORK_DIR="$1"
    ENFORCEMENT_STATE_FILE="$1/enforcement_state"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    SCRIPT_VERSION='2.0.0'
    load_function "$ROOT_DIR/trafficcop-lite.sh" show_dashboard || return 1
    ntc_hostname() { printf '%s' test-host; }
    ntc_missing_tools() { return 0; }
    dashboard_month_bytes() { return 1; }
    dashboard_default_interface() { printf '%s' eth0; }
    read_current_crontab() {
        printf '%s\n' "* * * * * $WORK_DIR/trafficcop-lite-monitor.sh --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"
    }
    printf 'HEALTH=ok\nREASON=\nUPDATED_EPOCH=%s\n' "$(date +%s)" > "$1/monitor_health"
}

# 2.0 改写（原测 1.x 的 show_traffic_overview）：起始日非法时不能悄悄按 1 日显示。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_dashboard_rejects_invalid_period_start_day_before_calculation() {
    local work
    work=$(mktemp -d "$TEST_ROOT/dashboard-invalid-day.XXXXXX") || return 1
    setup_dashboard_case "$work" || return 1
    printf '%s\n' TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly TRAFFIC_LIMIT=100 TRAFFIC_UNIT=decimal \
        PERIOD_START_DAY=99 MAIN_INTERFACE=eth0 > "$work/traffic_monitor_config.txt"
    show_dashboard > "$work/output" 2>&1 || return 1
    grep -Fq '配置异常：周期起始日必须为 1–31' "$work/output" || return 1
    ! grep -Fq '每月 1 日重置' "$work/output"
}

# 2.0 改写（原测 1.x 的 show_enforcement_overview）：已停用时，残留的限速/宽限状态不能盖过“已停用”。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_main_disabled_enforcement_status_has_highest_priority() {
    local work stale_mode
    work=$(mktemp -d "$TEST_ROOT/main-disabled-status.XXXXXX") || return 1
    setup_dashboard_case "$work" || return 1
    printf '%s\n' LIMIT_MODE=tc LIMIT_SPEED=50 DISABLED=true TRAFFIC_LIMIT=100 TRAFFIC_TOLERANCE=1 \
        PERIOD_START_DAY=1 TRAFFIC_UNIT=decimal MAIN_INTERFACE=eth0 > "$work/traffic_monitor_config.txt"
    printf '%s\n' STATUS=limited USAGE=99.5 LIMIT_THRESHOLD=99 PERIOD_START=2026-11-01 PERIOD_END=2026-11-30 \
        "UPDATED_EPOCH=$(date +%s)" > "$work/current_traffic_state"
    for stale_mode in none paused grace; do
        if [ "$stale_mode" = none ]; then
            rm -f "$ENFORCEMENT_STATE_FILE"
        else
            printf 'MODE=%s\nUNTIL_EPOCH=4102444800\n' "$stale_mode" > "$ENFORCEMENT_STATE_FILE"
        fi
        show_dashboard > "$work/output" 2>&1 || return 1
        grep -Fq '○ 已停用' "$work/output" || return 1
        if grep -Eq '已限速|宽限中|已暂停限制' "$work/output"; then return 1; fi
    done
}

# 只读命令（--status、--status --json、--config-show、--help）不写监控日志、不在工作目录里留下文件。
# 用完整脚本执行，防止入口外的日志写入绕过函数级测试。（替代 1.x 的日志头尾测试：2.0 不再写每次运行的头尾行。）
# shellcheck disable=SC2016,SC2034,SC2209,SC2317,SC2329
test_self_check_generic_log_is_byte_identical() {
    local work candidate args files_before
    work=$(mktemp -d "$TEST_ROOT/readonly-commands.XXXXXX") || return 1
    candidate="$work/trafficcop-lite-monitor.sh"
    mkdir -p "$work/bin" || return 1
    printf '%s\n' '#!/bin/sh' 'echo "no crontab for root" >&2' 'exit 1' > "$work/bin/crontab"
    chmod 700 "$work/bin/crontab" || return 1
    sed \
        -e "s#^export PATH=#export PATH=$work/bin:#" \
        -e 's#^if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\] && \[ "\$(id -u)" -ne 0 \]; then#if false; then#' \
        -e "s#^WORK_DIR=.*#WORK_DIR=\"$work\"#" \
        -e "s#^DOG_CONFIG_FILE=.*#DOG_CONFIG_FILE=\"$work/dog-config.json\"#" \
        -e "s#^DOG_TC_OWNER_FILE=.*#DOG_TC_OWNER_FILE=\"$work/dog-owner\"#" \
        -e 's#^TC_BIN=.*#TC_BIN=true#' \
        "$MONITOR_SCRIPT" > "$candidate" || return 1
    grep -q '^if false; then' "$candidate" || return 1
    chmod 700 "$candidate" || return 1
    printf '%s\n' MAIN_INTERFACE=lo TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly TRAFFIC_LIMIT=500 TRAFFIC_TOLERANCE=1 \
        TRAFFIC_UNIT=decimal LIMIT_MODE=tc LIMIT_SPEED=50 > "$work/traffic_monitor_config.txt"
    chmod 600 "$work/traffic_monitor_config.txt" || return 1
    printf '%s\n' seed-line > "$work/traffic_monitor.log"
    cp "$work/traffic_monitor.log" "$work/expected" || return 1
    files_before=$(find "$work" -mindepth 1 -maxdepth 1 ! -name out -printf '%f\n' | LC_ALL=C sort)
    for args in --status '--status --json' --config-show --help; do
        # shellcheck disable=SC2086
        TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE="$work/recovery.service" TRAFFIC_TOOLS_TC_LOCK_FILE="$work/tc.lock" \
            bash "$candidate" $args > "$work/out" 2>&1 || return 1
        cmp -s "$work/expected" "$work/traffic_monitor.log" || return 1
        [ "$files_before" = "$(find "$work" -mindepth 1 -maxdepth 1 ! -name out -printf '%f\n' | LC_ALL=C sort)" ] || return 1
        [ "$args" != '--status --json' ] || jq -e '.configured == true and .interface == "lo"' "$work/out" > /dev/null || return 1
    done
}

# 执行完整脚本，防止函数外的普通日志写入绕过上面的头尾函数测试。
test_self_check_full_invocation_preserves_generic_log() {
    local work candidate mode
    work=$(mktemp -d "$TEST_ROOT/self-check-process.XXXXXX") || return 1
    candidate="$work/trafficcop-lite-monitor.sh"

    sed \
        -e "s#^if \[ \"\$(id -u)\" -ne 0 \]; then#if false; then#" \
        -e "s#^WORK_DIR=.*#WORK_DIR=\"$work\"#" \
        -e "s#^DOG_CONFIG_FILE=.*#DOG_CONFIG_FILE=\"$work/dog-config.json\"#" \
        -e "s#^DOG_TC_OWNER_FILE=.*#DOG_TC_OWNER_FILE=\"$work/dog-owner\"#" \
        -e 's#^TC_BIN=.*#TC_BIN=true#' \
        "$MONITOR_SCRIPT" > "$candidate" || return 1
    chmod 700 "$candidate" || return 1
    printf '%s\n' seed-line > "$work/traffic_monitor.log"
    cp "$work/traffic_monitor.log" "$work/expected" || return 1

    for mode in --self-check --tc-self-check; do
        TRAFFIC_TOOLS_TC_LOCK_FILE="$work/tc.lock" \
            bash "$candidate" "$mode" lo >/dev/null 2>&1 || true
        cmp -s "$work/expected" "$work/traffic_monitor.log" || return 1
    done
}

# 2.0 machine-limit 有意改变：monitor 2.0 的日志只记事件，不再每分钟写“正在以自动化模式运行”，
# 所以“最近检查”改读 monitor_health（ntc_health_summary）；日志里的旧标记行不再影响结论。
# 原用例按日志标记判断“最近已执行/空闲中”，已改写为下面的断言（更多健康状态见「2.0 machine-limit」区段）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_machine_monitor_task_status_reads_health_state() {
    local work now_text
    work=$(mktemp -d "$TEST_ROOT/machine-task-status.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 「最近检查」经 ui_row 输出：整句断言时把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    now_text=$(date '+%Y-%m-%d %H:%M:%S')

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" show_monitor_task_status || return 1

    printf '%s 正在以自动化模式运行\n' "$now_text" > "$work/traffic_monitor.log"
    show_monitor_task_status > "$work/output" || return 1
    grep -Fq '还没有运行记录' "$work/output" || return 1
    ! grep -Fq '最近已执行' "$work/output" || return 1

    printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$(date +%s)" > "$work/monitor_health"
    show_monitor_task_status > "$work/output" || return 1
    grep -Eq '^  最近检查  运行正常' "$work/output"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_machine_disabled_enforcement_status_has_highest_priority() {
    local work stale_mode
    work=$(mktemp -d "$TEST_ROOT/machine-disabled-status.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    BACKUP_CONFIG_FILE="$work/config.backup"
    SCRIPT_PATH="$work/monitor.sh"
    TC_BIN=''
    CYAN=''; RED=''; YELLOW=''; GREEN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' 'DISABLED_TIME=2026-08-28T00:00:00+0800' > "$CONFIG_FILE"

    # 2.0 machine-limit：show_status 的数据改由 machine_status_collect 收集，「执行方式」「开机宽限」两行由
    # machine_action_rows 输出，都需一并加载。
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" show_monitor_task_status || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" machine_status_collect || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" machine_action_rows || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" show_status || return 1
    read_root_crontab_locked() { return 1; }
    get_main_interface() { printf '%s\n' eth0; }
    tc_state_value() { return 0; }

    for stale_mode in paused grace; do
        printf 'MODE=%s\nUNTIL_EPOCH=4102444800\n' "$stale_mode" > "$ENFORCEMENT_STATE_FILE"
        show_status > "$work/output" 2> "$work/errors" || return 1
        # 2.0 machine-limit 有意改变：状态行改为 ui_kv 样式（原为「限制执行: 已禁用」），措辞统一为“停用”。
        grep -Eq '^  限制执行  已停用' "$work/output" || return 1
        # 停用后仍列出配置的执行方式与开机宽限（machine_action_rows）；标准错误为空（没有漏加载的函数）。
        grep -Eq '^  执行方式  整机限速' "$work/output" && grep -Eq '^  开机宽限  10 分钟' "$work/output" || return 1
        [ ! -s "$work/errors" ] || return 1
        ! grep -Eq '已暂停|宽限中|按配置执行' "$work/output" || return 1
    done
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

    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
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
test_runtime_calculation_failure_preserves_existing_limit() {
    local work
    work=$(mktemp -d "$TEST_ROOT/runtime-calculation-failure.XXXXXX") || return 1
    LOG_FILE="$work/log"
    TRAFFIC_UNIT='decimal'
    TRAFFIC_LIMIT='100'
    TRAFFIC_TOLERANCE='0'
    LIMIT_MODE='tc'
    LIMIT_SPEED='20'

    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    load_function "$MONITOR_SCRIPT" check_and_limit_traffic || return 1
    get_traffic_usage() { printf '%s\n' '150.000'; }
    bc() { return 127; }
    clear_owned_tc_rules() { printf '%s\n' called > "$work/tc-cleared"; }
    apply_tc_limit() { printf '%s\n' called > "$work/tc-applied"; }
    write_usage_state() { printf '%s\n' called > "$work/usage-written"; }

    if check_and_limit_traffic >/dev/null; then
        return 1
    fi
    assert_absent "$work/tc-cleared" || return 1
    assert_absent "$work/tc-applied" || return 1
    assert_absent "$work/usage-written"
}

# 2.0 有意改变：cancel_shutdown_interactive 不再读标准输入，只在系统里确有计划关机时才处理 NTC 没有记录的关机，
# 是否取消由卸载事先问到的回答（LITE_UNOWNED_SHUTDOWN_ANSWER=y）决定。三段都按「确有计划关机、已同意取消」执行。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_legacy_shutdown_cancel_failure_is_reported() {
    local work pending
    work=$(mktemp -d "$TEST_ROOT/legacy-shutdown.XXXXXX") || return 1
    WORK_DIR="$work"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    RED=''
    YELLOW=''
    NC=''
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$work/traffic_monitor_config.txt"

    load_function "$ROOT_DIR/trafficcop-lite.sh" cancel_shutdown_interactive || return 1
    shutdown() { return 1; }
    lite_has_pending_shutdown() { return 0; }
    if LITE_UNOWNED_SHUTDOWN_ANSWER=y cancel_shutdown_interactive >/dev/null; then
        return 1
    fi

    shutdown() { return 0; }
    lite_has_pending_shutdown() { return 0; }
    if LITE_UNOWNED_SHUTDOWN_ANSWER=y cancel_shutdown_interactive >/dev/null; then
        return 1
    fi

    pending=true
    shutdown() { pending=false; }
    lite_has_pending_shutdown() { [ "$pending" = true ]; }
    LITE_UNOWNED_SHUTDOWN_ANSWER=y cancel_shutdown_interactive >/dev/null || return 1
    [ "$pending" = false ]
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
    # 2.0 machine-limit 有意改变：只在系统里确有计划关机时才询问是否取消（1.2.0 不检查就问，
    # 见 ux-inventory §3），所以这里改为模拟“有一个无法确认归属的计划关机”（原为 return 1）。
    has_pending_shutdown() { return 0; }

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
test_enable_grace_clears_tc_under_monitor_lock_before_commit() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/enable-grace.XXXXXX") || return 1
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    printf '%s\n' old-state > "$ENFORCEMENT_STATE_FILE"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; printf '%s\n' acquire >> "$work/events"; }
    release_monitor_cleanup_lock() { lock_held=false; printf '%s\n' release >> "$work/events"; }
    clear_tc_rules() {
        [ "$lock_held" = true ] || return 1
        printf '%s\n' clear >> "$work/events"
    }
    cancel_owned_shutdown() {
        [ "$lock_held" = true ] || return 1
        printf '%s\n' cancel >> "$work/events"
    }

    begin_enable_grace 10 >/dev/null || return 1
    assert_file_content $'acquire\nclear\ncancel\nrelease' "$work/events" || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" || return 1
    [ "$lock_held" = false ] || return 1
    ! find "$work" -name '*.enable-candidate.*' -print -quit | grep -q .
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_enable_grace_clear_failure_preserves_old_enforcement() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/enable-grace-clear-fail.XXXXXX") || return 1
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    printf '%s\n' old-state > "$ENFORCEMENT_STATE_FILE"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; printf '%s\n' released > "$work/released"; }
    clear_tc_rules() { return 1; }
    cancel_owned_shutdown() { printf '%s\n' unexpected > "$work/shutdown"; }

    if begin_enable_grace 10 >/dev/null; then
        return 1
    fi
    assert_file_content old-state "$ENFORCEMENT_STATE_FILE" || return 1
    assert_file_content released "$work/released" || return 1
    assert_absent "$work/shutdown" || return 1
    [ "$lock_held" = false ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_enable_candidate_failure_preserves_pre_enable_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/enable-candidate-fail.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' 'MODE=paused' > "$ENFORCEMENT_STATE_FILE"
    printf '%s\n' old-tc > "$TC_STATE_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" rollback_enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    write_enforcement_state_file() { return 1; }
    acquire_monitor_cleanup_lock() { printf '%s\n' unexpected > "$work/lock"; return 1; }
    clear_tc_rules_with_lock() { printf '%s\n' unexpected > "$work/clear"; return 1; }
    bash() { printf '%s\n' unexpected > "$work/monitor"; }
    add_cron_job() { printf '%s\n' unexpected > "$work/cron"; }

    if enable_machine_limit >/dev/null; then
        return 1
    fi
    assert_file_content $'LIMIT_MODE=tc\nDISABLED=true' "$CONFIG_FILE" || return 1
    assert_file_content 'MODE=paused' "$ENFORCEMENT_STATE_FILE" || return 1
    assert_file_content old-tc "$TC_STATE_FILE" || return 1
    assert_absent "$work/lock" || return 1
    assert_absent "$work/clear" || return 1
    assert_absent "$work/monitor" || return 1
    assert_absent "$work/cron"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_enable_lock_failure_preserves_pre_enable_state() {
    local work
    work=$(mktemp -d "$TEST_ROOT/enable-lock-fail.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' 'MODE=paused' > "$ENFORCEMENT_STATE_FILE"
    printf '%s\n' old-tc > "$TC_STATE_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" rollback_enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    acquire_monitor_cleanup_lock() { return 1; }
    clear_tc_rules_with_lock() { printf '%s\n' unexpected > "$work/clear"; return 1; }
    bash() { printf '%s\n' unexpected > "$work/monitor"; }
    add_cron_job() { printf '%s\n' unexpected > "$work/cron"; }

    if enable_machine_limit >/dev/null; then
        return 1
    fi
    assert_file_content $'LIMIT_MODE=tc\nDISABLED=true' "$CONFIG_FILE" || return 1
    assert_file_content 'MODE=paused' "$ENFORCEMENT_STATE_FILE" || return 1
    assert_file_content old-tc "$TC_STATE_FILE" || return 1
    assert_absent "$work/clear" || return 1
    assert_absent "$work/monitor" || return 1
    assert_absent "$work/cron" || return 1
    ! find "$work" -name '*.enable-candidate.*' -print -quit | grep -q .
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_enable_machine_limit_clears_existing_tc_before_monitor() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/enable-machine-success.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' state > "$TC_STATE_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; }
    clear_tc_rules() {
        [ "$lock_held" = true ] || return 1
        # 禁用态残留的统一 HTB 只能在配置仍保留 DISABLED=true 时安全收尾。
        grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1
        rm -f "$TC_STATE_FILE"
        printf '%s\n' clear >> "$work/events"
    }
    cancel_owned_shutdown() { printf '%s\n' cancel >> "$work/events"; }
    bash() { printf '%s\n' monitor >> "$work/events"; }
    add_cron_job() { printf '%s\n' cron >> "$work/events"; }

    enable_machine_limit >/dev/null || return 1
    assert_file_content $'clear\ncancel\nmonitor\ncron' "$work/events" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" || return 1
    ! grep -q '^DISABLED=' "$CONFIG_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_disabled_enable_cleans_residual_ntc_state_before_config_restore() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/enable-disabled-residual.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' 'SCHEMA=traffic-tools-unified-htb-v1' > "$TC_STATE_FILE"
    printf '%s\n' dog-class dog-filter > "$work/dog-rules"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" rollback_enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; }
    clear_tc_rules() {
        [ "$lock_held" = true ] || return 1
        # 模拟 monitor 的禁用态残留分支：父类已恢复为 100gbit，只移除 NTC state。
        grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1
        assert_file_content $'dog-class\ndog-filter' "$work/dog-rules" || return 1
        rm -f "$TC_STATE_FILE"
        printf '%s\n' clear >> "$work/events"
    }
    cancel_owned_shutdown() { printf '%s\n' cancel >> "$work/events"; }
    bash() { printf '%s\n' monitor >> "$work/events"; }
    add_cron_job() { printf '%s\n' cron >> "$work/events"; }

    enable_machine_limit >/dev/null || return 1
    assert_file_content $'clear\ncancel\nmonitor\ncron' "$work/events" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_file_content $'dog-class\ndog-filter' "$work/dog-rules" || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" || return 1
    ! grep -q '^DISABLED=' "$CONFIG_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_enable_machine_limit_clear_failure_rolls_back_without_monitor() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/enable-machine-clear-fail.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' state > "$TC_STATE_FILE"
    printf '%s\n' stale > "$ENFORCEMENT_STATE_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" rollback_enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; }
    clear_tc_rules() { return 1; }
    cancel_owned_shutdown() { printf '%s\n' unexpected > "$work/shutdown"; }
    clear_tc_rules_with_lock() { rm -f "$TC_STATE_FILE"; printf '%s\n' cleanup > "$work/cleanup"; }
    bash() { printf '%s\n' unexpected > "$work/monitor"; }
    add_cron_job() { printf '%s\n' unexpected > "$work/cron"; }

    if enable_machine_limit >/dev/null; then
        return 1
    fi
    grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_file_content cleanup "$work/cleanup" || return 1
    assert_absent "$work/monitor" || return 1
    assert_absent "$work/cron" || return 1
    assert_absent "$work/shutdown"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_enable_failure_restores_old_enforcement_but_stays_fail_open() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/enable-machine-monitor-fail.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' > "$CONFIG_FILE"
    printf '%s\n' 'MODE=paused' > "$ENFORCEMENT_STATE_FILE"
    printf '%s\n' state > "$TC_STATE_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" rollback_enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; }
    clear_tc_rules() { rm -f "$TC_STATE_FILE"; }
    cancel_owned_shutdown() { return 0; }
    clear_tc_rules_with_lock() { rm -f "$TC_STATE_FILE"; }
    bash() { return 1; }
    add_cron_job() { printf '%s\n' unexpected > "$work/cron"; }

    if enable_machine_limit > "$work/output"; then
        return 1
    fi
    assert_file_content 'MODE=paused' "$ENFORCEMENT_STATE_FILE" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_absent "$work/cron" || return 1
    grep -q '旧 TC 限速出于安全未恢复' "$work/output"
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

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_restore_from_enabled_state_preserves_paused_enforcement_on_failure() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/restore-enabled-paused.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    BACKUP_CONFIG_FILE="$work/config.disabled.backup"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'TRAFFIC_LIMIT=100' > "$CONFIG_FILE"
    printf '%s\n' 'LIMIT_MODE=tc' 'TRAFFIC_LIMIT=200' > "$BACKUP_CONFIG_FILE"
    printf '%s\n' 'MODE=paused' > "$ENFORCEMENT_STATE_FILE"
    printf '%s\n' old-tc > "$TC_STATE_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" begin_enable_grace || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" rollback_enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" enable_machine_limit || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" restore_machine_limit || return 1
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; }
    clear_tc_rules() { rm -f "$TC_STATE_FILE"; }
    cancel_owned_shutdown() { return 0; }
    clear_tc_rules_with_lock() { rm -f "$TC_STATE_FILE"; }
    bash() { return 1; }
    add_cron_job() { printf '%s\n' unexpected > "$work/cron"; }

    if restore_machine_limit >/dev/null; then
        return 1
    fi
    assert_file_content $'LIMIT_MODE=tc\nTRAFFIC_LIMIT=100' "$CONFIG_FILE" || return 1
    assert_file_content 'MODE=paused' "$ENFORCEMENT_STATE_FILE" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_absent "$work/cron"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_auto_recovery_without_state_is_noop() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-auto-no-state.XXXXXX") || return 1
    TC_BIN='mock_tc'
    TC_STATE_FILE="$work/tc-state"
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    DISABLED='false'

    load_function "$MONITOR_SCRIPT" recover_owned_tc_hierarchy || return 1
    trafficcop_config_is_disabled() { return 1; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    recover_owned_tc_hierarchy --auto > "$work/output" || return 1
    assert_absent "$work/tc-called" || return 1
    grep -Fq '没有需要自动恢复' "$work/output"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_auto_recovery_refuses_a_foreign_root_with_owned_state() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-auto-foreign-root.XXXXXX") || return 1
    TC_BIN='mock_tc'
    TC_STATE_FILE="$work/tc-state"
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    DISABLED='false'
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" recover_owned_tc_hierarchy || return 1
    trafficcop_config_is_disabled() { return 1; }
    tc_state_file_is_interpretable() { return 0; }
    tc_state_interface() { printf '%s\n' eth0; }
    tc_state_value() {
        case "$1" in
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
            LIMIT_SPEED) printf '%s\n' 90 ;;
        esac
    }
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc tbf 8001: root refcnt 2 rate 1Gbit'; }
    tc_root_is_unified_compatible() { return 1; }
    is_default_qdisc_line() { return 1; }
    dog_configured_class_ids() { return 0; }
    write_tc_state() { printf '%s\n' called > "$work/state-write-called"; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    if recover_owned_tc_hierarchy --auto > "$work/output" 2>&1; then
        return 1
    fi
    grep -Fq '拒绝接管' "$work/output" || return 1
    assert_file_content state "$TC_STATE_FILE" || return 1
    assert_absent "$work/state-write-called" || return 1
    assert_absent "$work/tc-called" || return 1
    [ "$lock_held" = false ]
}

# shellcheck disable=SC2016,SC2034,SC2209,SC2317,SC2329
test_shared_recovery_service_is_opt_in() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-recovery-service.XXXXXX") || return 1
    TC_RECOVERY_RUNNER="$work/bin/traffic-tools-tc-recovery.sh"
    TC_RECOVERY_UNIT_FILE="$work/systemd/traffic-tools-tc-recovery.service"
    TC_RECOVERY_SERVICE='traffic-tools-tc-recovery.service'
    TC_RECOVERY_SYSTEMCTL="$work/systemctl-mock"
    export SYSTEMCTL_LOG="$work/systemctl.log"

    printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$SYSTEMCTL_LOG"' > "$TC_RECOVERY_SYSTEMCTL"
    chmod 755 "$TC_RECOVERY_SYSTEMCTL"
    load_function "$ROOT_DIR/trafficcop-lite.sh" tc_recovery_unit_is_owned || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" tc_recovery_runner_is_owned || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_tc_recovery_service_files || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" enable_tc_auto_recovery || return 1
    tc_recovery_systemd_available() { return 0; }

    install_tc_recovery_service_files || return 1
    grep -Fq '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_RUNNER" || return 1
    grep -Fq 'After=network-online.target vnstat.service' \
        "$TC_RECOVERY_UNIT_FILE" || return 1
    grep -Fq "ExecStart=$TC_RECOVERY_RUNNER --auto" "$TC_RECOVERY_UNIT_FILE" || return 1
    grep -Fxq 'daemon-reload' "$SYSTEMCTL_LOG" || return 1
    ! grep -Eq '^enable([[:space:]]|$)' "$SYSTEMCTL_LOG" || return 1

    enable_tc_auto_recovery || return 1
    grep -Fxq 'enable traffic-tools-tc-recovery.service' "$SYSTEMCTL_LOG"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_recovery_waits_for_monitor_lock() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-recovery-monitor-lock.XXXXXX") || return 1

    (
        load_function "$MONITOR_SCRIPT" main || exit 1
        load_function "$MONITOR_SCRIPT" monitor_take_lock || exit 1
        load_function "$MONITOR_SCRIPT" round_log_finish || exit 1
        WORK_DIR="$work/runtime"
        LOCK_FILE="$WORK_DIR/monitor.lock"
        LOG_FILE="$WORK_DIR/monitor.log"
        LOG_MAX_LINES=100
        mkdir -p "$WORK_DIR"

        migrate_files() { :; }
        command_exists() { return 1; }
        read_config() { :; }
        align_timezone_with_vnstat() { :; }
        recover_owned_tc_hierarchy() { :; }
        trim_log_file() { :; }
        flock() { printf '%s\n' "$*" >> "$work/flock.calls"; }

        main --tc-recover-owned --auto >/dev/null || exit 1
    ) || return 1

    [ "$(head -n 1 "$work/flock.calls")" = '-w 15 9' ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_recovery_menu_requires_confirm_only_for_conflict() {
    local healthy_output
    local conflict_output
    local automatic_output

    BLUE=''
    BOLD=''
    GREEN=''
    YELLOW=''
    RED=''
    NC=''

    load_function "$ROOT_DIR/trafficcop-lite.sh" ntc_tc_status_label || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" ntc_tc_status_kind || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" show_tc_auto_recovery_notice || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" confirm_enable_tc_auto_recovery || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" manage_tc_recovery || return 1

    clear() { :; }
    menu_item() { printf '%s. %s\n' "$1" "$2"; }
    pause() { :; }
    tc_auto_recovery_state() { echo '未启用'; }
    show_tc_takeover_warning() { echo 'TAKEOVER_WARNING'; }
    run_shared_tc_recovery() { echo 'RECOVERY_CALLED'; }
    enable_tc_auto_recovery() { echo 'AUTO_RECOVERY_ENABLED'; }

    [ "$(ntc_tc_status_kind 'TC_SELF_CHECK=OK INTERFACE=eth0 MODEL=traffic-tools-unified-htb-v1')" = 'ok' ] || return 1
    [ "$(ntc_tc_status_kind 'TC_SELF_CHECK=OK INTERFACE=eth0 MODEL=absent')" = 'idle' ] || return 1
    [ "$(ntc_tc_status_kind 'TC_SELF_CHECK=CONFLICT REASON=external-root-qdisc')" = 'conflict' ] || return 1
    [ "$(ntc_tc_status_kind 'TC_SELF_CHECK=DRIFT REASON=missing-class')" = 'conflict' ] || return 1
    [ "$(ntc_tc_status_kind 'TC_SELF_CHECK=ERROR REASON=tc-unavailable')" = 'error' ] || return 1

    run_tc_self_check() {
        echo 'TC_SELF_CHECK=OK INTERFACE=eth0 MODEL=traffic-tools-unified-htb-v1'
    }
    healthy_output=$(manage_tc_recovery <<< '1') || return 1
    grep -Fq '当前 TC 状态正常，无需强制重建。' <<< "$healthy_output" || return 1
    ! grep -Fq 'TAKEOVER_WARNING' <<< "$healthy_output" || return 1
    ! grep -Fq 'RECOVERY_CALLED' <<< "$healthy_output" || return 1

    run_tc_self_check() {
        echo 'TC_SELF_CHECK=CONFLICT REASON=external-root-qdisc'
    }
    conflict_output=$(manage_tc_recovery <<< $'1\nREBUILD') || return 1
    grep -Fq 'TAKEOVER_WARNING' <<< "$conflict_output" || return 1
    grep -Fq 'RECOVERY_CALLED' <<< "$conflict_output" || return 1

    run_tc_self_check() {
        echo 'TC_SELF_CHECK=OK INTERFACE=eth0 MODEL=traffic-tools-unified-htb-v1'
    }
    automatic_output=$(manage_tc_recovery <<< $'3\nNO') || return 1
    grep -Fq '规则正常或当前没有需要恢复的规则时，不会修改 TC。' <<< "$automatic_output" || return 1
    ! grep -Fq 'TAKEOVER_WARNING' <<< "$automatic_output" || return 1
    ! grep -Fq 'AUTO_RECOVERY_ENABLED' <<< "$automatic_output"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_boot_rebuild_requires_a_known_state_schema() {
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    local mock_schema='unknown-v2'
    local mock_provider='trafficcop-lite'

    load_function "$MONITOR_SCRIPT" tc_state_allows_boot_rebuild || return 1
    tc_state_interface() { printf '%s\n' eth0; }
    current_boot_id() { printf '%s\n' current-boot; }
    tc_state_value() {
        case "$1" in
            SCHEMA) printf '%s\n' "$mock_schema" ;;
            PROVIDER) printf '%s\n' "$mock_provider" ;;
            LIMIT_SPEED) printf '%s\n' 90 ;;
            BOOT_ID) printf '%s\n' previous-boot ;;
        esac
    }

    ! tc_state_allows_boot_rebuild eth0 || return 1
    mock_schema="$TC_STATE_SCHEMA"
    mock_provider=''
    ! tc_state_allows_boot_rebuild eth0 || return 1
    mock_schema=''
    mock_provider=''
    tc_state_allows_boot_rebuild eth0 || return 1
    mock_schema="$TC_STATE_SCHEMA"
    mock_provider="$TC_STATE_PROVIDER"
    tc_state_allows_boot_rebuild eth0
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_clear_preserves_state_without_an_interface() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-state-no-interface.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    TC_BIN='mock_tc'
    printf '%s\n' 'LIMIT_SPEED=90' > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" clear_owned_tc_rules_locked || return 1
    tc_state_interface() { return 0; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    if clear_owned_tc_rules_locked test >/dev/null; then
        return 1
    fi
    assert_file_content 'LIMIT_SPEED=90' "$TC_STATE_FILE" || return 1
    assert_absent "$work/tc-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_manual_recovery_rejects_an_unreadable_dog_config() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-recover-invalid-dog.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    DOG_CONFIG_FILE="$work/dog-config.json"
    DOG_TC_OWNER_FILE="$work/dog-owner"
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    TC_BIN='mock_tc'
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    DISABLED='false'
    printf '%s\n' state > "$TC_STATE_FILE"
    printf '%s\n' '{"ports":' > "$DOG_CONFIG_FILE"

    load_function "$MONITOR_SCRIPT" dog_configured_class_ids || return 1
    load_function "$MONITOR_SCRIPT" recover_owned_tc_hierarchy || return 1
    trafficcop_config_is_disabled() { return 1; }
    tc_state_file_is_interpretable() { return 0; }
    tc_state_interface() { printf '%s\n' eth0; }
    tc_state_value() {
        case "$1" in
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
            LIMIT_SPEED) printf '%s\n' 90 ;;
        esac
    }
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc tbf 8001: root rate 1Gbit'; }
    tc_root_is_unified_compatible() { return 1; }
    is_default_qdisc_line() { return 1; }
    write_tc_state() { printf '%s\n' called > "$work/state-write-called"; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    if recover_owned_tc_hierarchy --manual > "$work/output" 2>&1; then
        return 1
    fi
    grep -Fq 'Dog 配置存在但无法安全解析' "$work/output" || return 1
    assert_file_content state "$TC_STATE_FILE" || return 1
    assert_absent "$work/state-write-called" || return 1
    assert_absent "$work/tc-called" || return 1
    [ "$lock_held" = false ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shared_tc_state_contract_rejects_insecure_and_duplicate_keys() {
    local work status=0
    work=$(mktemp -d "$TEST_ROOT/tc-state-contract.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"

    load_function "$MONITOR_SCRIPT" tc_file_is_secure || return 1
    load_function "$MONITOR_SCRIPT" tc_file_unique_value || return 1
    load_function "$MONITOR_SCRIPT" tc_file_optional_unique_value || return 1
    load_function "$MONITOR_SCRIPT" tc_state_file_is_interpretable || return 1
    load_function "$MONITOR_SCRIPT" tc_state_value || return 1

    printf '%s\n' \
        'SCHEMA=traffic-tools-unified-htb-v1' \
        'PROVIDER=trafficcop-lite' \
        'INTERFACE=eth0' \
        'LIMIT_SPEED=90' > "$TC_STATE_FILE"
    chmod 600 "$TC_STATE_FILE"
    [ "$(tc_state_value LIMIT_SPEED)" = 90 ] || return 1

    chmod 666 "$TC_STATE_FILE"
    tc_state_file_is_interpretable && return 1
    chmod 600 "$TC_STATE_FILE"
    printf '%s\n' 'LIMIT_SPEED=90' >> "$TC_STATE_FILE"
    tc_state_file_is_interpretable && return 1
    tc_state_value LIMIT_SPEED >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_disabled_tc_recovery_is_never_automatic() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-disabled-recovery.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    TC_BIN='mock_tc'
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    DISABLED='true'
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" recover_owned_tc_hierarchy || return 1
    trafficcop_config_is_disabled() { return 0; }
    clear_owned_tc_rules() { printf '%s\n' "$1" > "$work/cleared"; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    recover_owned_tc_hierarchy --auto > "$work/output" || return 1
    grep -Fq '不会自动恢复' "$work/output" || return 1
    assert_absent "$work/cleared" || return 1
    assert_absent "$work/tc-called" || return 1

    recover_owned_tc_hierarchy --manual >/dev/null || return 1
    grep -Fq 'TrafficCop 已禁用' "$work/cleared"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ntc_self_check_includes_dog_port_rules() {
    local work status=0 lock_held=false
    work=$(mktemp -d "$TEST_ROOT/tc-dog-cross-check.XXXXXX") || return 1
    TC_BIN='mock_tc'
    TC_STATE_FILE="$work/tc-state"
    DOG_CONFIG_FILE="$work/dog-config.json"
    printf '%s\n' state > "$TC_STATE_FILE"
    printf '%s\n' '{"ports":{}}' > "$DOG_CONFIG_FILE"

    load_function "$MONITOR_SCRIPT" tc_self_check || return 1
    trafficcop_config_is_disabled() { return 1; }
    tc_state_file_is_interpretable() { return 0; }
    resolve_tc_self_check_interface() { printf '%s\n' eth0; }
    acquire_tc_hierarchy_lock() { lock_held=true; }
    release_tc_hierarchy_lock() { lock_held=false; }
    tc_root_qdisc() { printf '%s\n' 'qdisc htb 1: root default 30'; }
    is_default_qdisc_line() { return 1; }
    tc_root_is_unified_compatible() { return 0; }
    tc_default_class_is_safe() { return 0; }
    tc_state_is_unified_for_interface() { return 0; }
    tc_state_value() { [ "$1" = LIMIT_SPEED ] && printf '%s\n' 90; }
    tc_verify_unified_hierarchy() { return 0; }
    dog_live_objects_match_config() { return 1; }

    tc_self_check eth0 > "$work/output" || status=$?
    [ "$status" -eq 1 ] || return 1
    assert_file_content 'TC_SELF_CHECK=DRIFT INTERFACE=eth0 REASON=dog-port-rules-mismatch' "$work/output" || return 1
    [ "$lock_held" = false ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_disabled_state_cleanup_accepts_dog_rebuilt_parent() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-disabled-cleanup.XXXXXX") || return 1
    TC_STATE_FILE="$work/tc-state"
    LOG_FILE="$work/log"
    TC_BIN='mock_tc'
    TC_PARENT_RATE='100gbit'
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    DISABLED='true'
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" clear_owned_tc_rules_locked || return 1
    tc_state_interface() { printf '%s\n' eth0; }
    tc_state_value() {
        case "$1" in
            LIMIT_SPEED) printf '%s\n' 90 ;;
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
        esac
    }
    tc_root_qdisc() { printf '%s\n' 'qdisc htb 1: root default 30'; }
    is_default_qdisc_line() { return 1; }
    tc_root_is_unified_compatible() { return 0; }
    tc_verify_unified_hierarchy() { [ "$2" = "$TC_PARENT_RATE" ]; }
    trafficcop_config_is_disabled() { return 0; }
    tc_has_other_consumers() { return 0; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }

    clear_owned_tc_rules_locked test >/dev/null || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_absent "$work/tc-called"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_recovery_unit_ownership_is_fail_closed() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-recovery-unit.XXXXXX") || return 1
    TC_RECOVERY_UNIT_FILE="$work/traffic-tools-tc-recovery.service"
    TC_RECOVERY_RUNNER="$work/traffic-tools-tc-recovery.sh"
    TC_RECOVERY_SERVICE='traffic-tools-tc-recovery.service'
    TC_RECOVERY_SYSTEMCTL='mock_systemctl'
    local disable_rc=1
    local systemctl_trace="$work/systemctl.trace"

    load_function "$ROOT_DIR/trafficcop-lite.sh" tc_recovery_unit_is_owned || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" tc_recovery_runner_is_owned || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_tc_recovery_service_files || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" tc_auto_recovery_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" disable_tc_auto_recovery || return 1
    tc_recovery_systemd_available() { return 0; }
    mock_systemctl() {
        printf '%s\n' "$*" >> "$systemctl_trace"
        case "${1:-}" in
            is-enabled|daemon-reload) return 0 ;;
            disable) return "$disable_rc" ;;
            *) return 0 ;;
        esac
    }

    printf '%s\n' '# traffic-tools-tc-recovery-v1' > "$TC_RECOVERY_UNIT_FILE"
    rm -f "$TC_RECOVERY_RUNNER"
    [ "$(tc_auto_recovery_state)" = '损坏（恢复入口缺失）' ] || return 1
    printf '%s\n' '# foreign runner' > "$TC_RECOVERY_RUNNER"
    [ "$(tc_auto_recovery_state)" = '冲突（恢复入口不属于 Dog/NTC）' ] || return 1
    rm -f "$TC_RECOVERY_RUNNER"
    printf '%s\n' '# foreign unit' > "$TC_RECOVERY_UNIT_FILE"
    if install_tc_recovery_service_files >/dev/null 2>&1; then
        return 1
    fi
    assert_absent "$TC_RECOVERY_RUNNER" || return 1
    [ "$(tc_auto_recovery_state)" = '冲突（同名 unit 不属于 Dog/NTC）' ] || return 1
    : > "$systemctl_trace"
    if disable_tc_auto_recovery >/dev/null 2>&1; then
        return 1
    fi
    [ ! -s "$systemctl_trace" ] || return 1

    printf '%s\n' '# traffic-tools-tc-recovery-v1' > "$TC_RECOVERY_UNIT_FILE"
    if disable_tc_auto_recovery >/dev/null 2>&1; then
        return 1
    fi
    grep -Fqx "disable $TC_RECOVERY_SERVICE" "$systemctl_trace" || return 1
    disable_rc=0
    disable_tc_auto_recovery || return 1

    rm -f "$TC_RECOVERY_UNIT_FILE"
    install_tc_recovery_service_files || return 1
    # Match literal shell source in the generated recovery runner.
    # shellcheck disable=SC2016
    grep -Fq 'bash "$dog_script" --recover-tc "$mode" || result=1' "$TC_RECOVERY_RUNNER" || return 1
    # shellcheck disable=SC2016
    grep -Fq 'bash "$ntc_monitor" --tc-recover-owned "$mode" || result=1' "$TC_RECOVERY_RUNNER" || return 1
    # shellcheck disable=SC2016
    grep -Fq 'exit "$result"' "$TC_RECOVERY_RUNNER" || return 1
    extract_function "$ROOT_DIR/trafficcop-lite.sh" uninstall_lite |
        grep -Fq 'if ! cleanup_tc_recovery_files_if_unused'
}

# ---- 本轮修复的回归保护 ----

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_invalid_traffic_mode_falls_back_to_total() {
    command -v jq >/dev/null 2>&1 || return 1
    MAIN_INTERFACE='eth0'
    TRAFFIC_PERIOD='monthly'
    TRAFFIC_UNIT='decimal'
    ALLOW_PARTIAL_HISTORY='false'
    WORK_DIR="$TEST_ROOT/nonexistent"
    RETENTION_STATE_FILE="$WORK_DIR/coverage"

    load_function "$MONITOR_SCRIPT" normalize_vnstat_json_for_interface || return 1
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
{"jsonversion":"2","interfaces":[{"name":"eth0","created":{"date":{"year":2025,"month":1,"day":1}},"updated":{"timestamp":1},"traffic":{"day":[{"date":{"year":2026,"month":6,"day":30},"rx":10000000000,"tx":10000000000},{"date":{"year":2026,"month":7,"day":1},"rx":1000000000,"tx":2000000000},{"date":{"year":2026,"month":7,"day":2},"rx":3000000000,"tx":1000000000}]}}]}
JSON
    }
    vnstat_cmd() { vnstat "$@"; }
    vnstat_data_is_fresh() { return 0; }
    check_mode() {
        TRAFFIC_MODE="$1"
        [ "$(get_traffic_usage 2>/dev/null)" = "$2" ]
    }

    # max 分支必须排在兜底之前：否则会被 *) 抢走，静默按 total 计算。
    check_mode max 4.000 || return 1
    # 非法值必须按 total 兜底继续限速，而不是静默跳过限速。
    check_mode bogus 7.000 || return 1
    check_mode '' 7.000 || return 1
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_shortcut_conflict_does_not_fail_install() {
    local work
    work=$(mktemp -d "$TEST_ROOT/shortcut-install.XXXXXX") || return 1
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
    printf '%s\n' 'foreign-command' > "$SHORTCUT_PATH"

    load_function "$ROOT_DIR/trafficcop-lite.sh" install_shortcut || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_shortcut_link || return 1

    # 快捷命令被外部文件占用：不覆盖，也不能让安装整体失败（否则主入口会把人挡在菜单外）。
    install_all_components() { return 0; }
    install_shortcut >/dev/null 2>&1 || return 1
    assert_file_content 'foreign-command' "$SHORTCUT_PATH" || return 1

    # 组件缺失仍然是硬失败。
    install_all_components() { return 1; }
    if install_shortcut >/dev/null 2>&1; then
        return 1
    fi
}

# 2.0 改写（原测 1.x 的 show_status_line）：读不出 crontab 是“状态未知”，不是“定时任务缺失”。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_status_line_reports_unreadable_crontab() {
    local work
    work=$(mktemp -d "$TEST_ROOT/status-unreadable.XXXXXX") || return 1
    setup_dashboard_case "$work" || return 1
    printf '%s\n' LIMIT_MODE=tc TRAFFIC_LIMIT=100 PERIOD_START_DAY=1 MAIN_INTERFACE=eth0 > "$work/traffic_monitor_config.txt"
    read_current_crontab() { return 1; }
    show_dashboard > "$work/output" 2>&1 || return 1
    grep -Fq '无法读取 root crontab' "$work/output" || return 1
    ! grep -Fq '定时任务缺失' "$work/output"
}

# ---- 1.2.1：配置保存、前导零分钟数、停用状态与输入结束（EOF） ----

# 限额减容错只用到减法；kvm 测试机没有 bc，CI 有。统一用 awk 代替，保证两边结果一致。
# shellcheck disable=SC2317,SC2329
subtract_bc() { awk '$2 == "-" { print $1 - $3; next } { exit 1 }'; }

# 在后台运行函数，超过期限即强杀（防止死循环拖住测试）。$1=秒数，$2=输入文件，其余为命令。
run_with_deadline() {
    local seconds="$1" input="$2" pid ticks=0
    shift 2
    # 生产脚本不开 set -u；这里关掉，避免未设置变量让函数提前退出而掩盖真实行为。
    ( set +u; "$@" ) < "$input" > /dev/null 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((seconds * 10)) ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
setup_post_save_case() {
    ENFORCEMENT_STATE_FILE="$1/enforcement"
    LOG_FILE="$1/log"
    TRAFFIC_UNIT=decimal
    TRAFFIC_LIMIT=500
    TRAFFIC_TOLERANCE=1
    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    load_function "$MONITOR_SCRIPT" configure_post_save_enforcement || return 1
    bc() { subtract_bc; }
    clear_owned_tc_rules() { printf '%s\n' called > "$POST_SAVE_WORK/tc-cleared"; }
    clear_owned_shutdown_schedule() { printf '%s\n' called > "$POST_SAVE_WORK/shutdown-cleared"; }
    write_enforcement_state_file() {
        printf 'MODE=%s\nUNTIL_EPOCH=%s\nREASON=%s\n' "$1" "$2" "$3" > "$4"
    }
}

# 1.2.0：用量低于阈值时函数末句 `[ -n "" ] && echo` 返回 1，首次配置被整体回滚。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_below_threshold_succeeds() {
    POST_SAVE_WORK=$(mktemp -d "$TEST_ROOT/post-save-below.XXXXXX") || return 1
    setup_post_save_case "$POST_SAVE_WORK" || return 1
    printf '%s\n' 'MODE=paused' > "$ENFORCEMENT_STATE_FILE"
    get_traffic_usage() { printf '%s\n' 61.25; }

    configure_post_save_enforcement < /dev/null > "$POST_SAVE_WORK/out" || return 1
    assert_file_content called "$POST_SAVE_WORK/tc-cleared" || return 1
    assert_file_content called "$POST_SAVE_WORK/shutdown-cleared" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE"
}

# 已超额并选择“2) 立即执行”同样没有提示语，1.2.0 也会返回 1。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_immediate_choice_succeeds() {
    POST_SAVE_WORK=$(mktemp -d "$TEST_ROOT/post-save-now.XXXXXX") || return 1
    setup_post_save_case "$POST_SAVE_WORK" || return 1
    get_traffic_usage() { printf '%s\n' 600; }

    configure_post_save_enforcement <<< 2 > "$POST_SAVE_WORK/out" || return 1
    assert_file_content called "$POST_SAVE_WORK/tc-cleared" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE"
}

# 宽限分钟数“08”：1.2.0 在 $((08 * 60)) 处按八进制报错，整个调用链中止。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_grace_accepts_leading_zero() {
    local now until_epoch
    POST_SAVE_WORK=$(mktemp -d "$TEST_ROOT/post-save-grace.XXXXXX") || return 1
    setup_post_save_case "$POST_SAVE_WORK" || return 1
    get_traffic_usage() { printf '%s\n' 600; }

    now=$(date +%s)
    configure_post_save_enforcement <<< $'1\n08' > "$POST_SAVE_WORK/out" || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" || return 1
    until_epoch=$(sed -n 's/^UNTIL_EPOCH=//p' "$ENFORCEMENT_STATE_FILE")
    [ "$until_epoch" -ge $((now + 480)) ] && [ "$until_epoch" -le $((now + 485)) ] || return 1
    grep -Fq '8 分钟' "$POST_SAVE_WORK/out"
}

# 开机宽限“08”：1.2.0 在 tc_boot_grace_active 中崩溃，超额时 TC 永远不会下发。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_boot_grace_leading_zero_does_not_abort() {
    local work
    work=$(mktemp -d "$TEST_ROOT/boot-grace-zero.XXXXXX") || return 1
    load_function "$MONITOR_SCRIPT" tc_boot_grace_active || return 1
    owned_tc_limit_active() { return 1; }
    TC_BOOT_GRACE_MINUTES=08
    ( tc_boot_grace_active; printf 'rc=%s\n' "$?" ) > "$work/out" 2>&1
    grep -Eq '^rc=[01]$' "$work/out" || return 1
    ! grep -Fq 'value too great' "$work/out"
}

# 配置文件里已有的“08”在读取时规范为 8，而不是被当成非法值或八进制。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_validate_config_normalizes_boot_grace() {
    local work
    work=$(mktemp -d "$TEST_ROOT/validate-boot-grace.XXXXXX") || return 1
    LOG_FILE="$work/log"
    load_function "$MONITOR_SCRIPT" validate_config || return 1
    load_function "$MONITOR_SCRIPT" is_decimal || return 1
    load_function "$MONITOR_SCRIPT" compare_decimal || return 1
    command_exists() { return 1; }
    vnstat_max_bandwidth_valid() { return 0; }
    TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly TRAFFIC_LIMIT=500 TRAFFIC_TOLERANCE=1
    TRAFFIC_UNIT=decimal PERIOD_START_DAY=1 LIMIT_SPEED=50 MAIN_INTERFACE=eth0 LIMIT_MODE=tc
    TC_BOOT_GRACE_MINUTES=08 VNSTAT_MAX_BANDWIDTH=0 DISABLED=false ALLOW_PARTIAL_HISTORY=false
    validate_config > /dev/null 2>&1 || return 1
    [ "$TC_BOOT_GRACE_MINUTES" = 8 ]
}

# 2.0 改写（原测 1.x 的 show_enforcement_overview）：配置里的前导零（08、09）不能让仪表盘出错。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_main_enforcement_overview_leading_zero_boot_grace() {
    local work
    work=$(mktemp -d "$TEST_ROOT/main-boot-grace-zero.XXXXXX") || return 1
    setup_dashboard_case "$work" || return 1
    printf '%s\n' LIMIT_MODE=tc LIMIT_SPEED=50 TC_BOOT_GRACE_MINUTES=09 PERIOD_START_DAY=08 PERIOD_START_MONTH=01 \
        TRAFFIC_PERIOD=monthly TRAFFIC_LIMIT=100 TRAFFIC_TOLERANCE=1 TRAFFIC_UNIT=decimal MAIN_INTERFACE=eth0 \
        > "$work/traffic_monitor_config.txt"
    ( show_dashboard; printf 'rc=%s\n' "$?" ) > "$work/out" 2>&1
    grep -Fq '每月 8 日重置' "$work/out" || return 1
    grep -Eq '^rc=0$' "$work/out"
}

# 机器限速“限制执行控制”：宽限“08”在 1.2.0 中先清掉 TC、再崩溃，宽限没写上。
# 2.0 machine-limit 有意改变：manage_enforcement_control 子菜单已取消，宽限与开机宽限改由平铺菜单的
# machine_grace_interactive / machine_boot_grace_interactive 处理（开机宽限改动前确认，回车 = 是）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_machine_grace_and_boot_grace_accept_leading_zero() {
    local work now until_epoch function_name
    work=$(mktemp -d "$TEST_ROOT/machine-grace-zero.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    CYAN='' NC=''
    printf '%s\n' 'LIMIT_MODE=tc' 'TC_BOOT_GRACE_MINUTES=10' > "$CONFIG_FILE"
    for function_name in machine_set_enforcement machine_grace machine_grace_interactive \
        machine_set_boot_grace machine_boot_grace_interactive; do
        load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" "$function_name" || return 1
    done
    acquire_monitor_cleanup_lock() { return 0; }
    release_monitor_cleanup_lock() { return 0; }
    clear_tc_rules() { return 0; }
    cancel_owned_shutdown() { return 0; }
    write_enforcement_state() {
        printf 'MODE=%s\nUNTIL_EPOCH=%s\nREASON=%s\n' "$1" "$2" "$3" > "$ENFORCEMENT_STATE_FILE"
    }

    now=$(date +%s)
    ( machine_grace_interactive <<< '08' ) > "$work/out" 2>&1 || return 1
    until_epoch=$(sed -n 's/^UNTIL_EPOCH=//p' "$ENFORCEMENT_STATE_FILE")
    [ -n "$until_epoch" ] && [ "$until_epoch" -ge $((now + 480)) ] && [ "$until_epoch" -le $((now + 485)) ] || return 1

    ( machine_boot_grace_interactive <<< $'08\n' ) > "$work/out" 2>&1 || return 1
    grep -Fxq 'TC_BOOT_GRACE_MINUTES=8' "$CONFIG_FILE"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
setup_eof_wizard_case() {
    CONFIG_FILE="$1/config"
    ENFORCEMENT_STATE_FILE="$1/enforcement"
    TC_STATE_FILE="$1/tc-state"
    SHUTDOWN_STATE_FILE="$1/shutdown-state"
    LOG_FILE="$1/log"
    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    setup_initial_config_transaction_mocks
    rollback_initial_vnstat_transaction() { printf '%s\n' rolled-back >> "$EOF_WORK/vnstat-rollback"; }
    detect_main_interface() { printf '%s\n' 'eth0'; }
    interface_exists() { return 0; }
    get_traffic_usage() { printf '%s\n' 1; }
    ensure_vnstat_runtime_config() { return 0; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    bc() { mock_bc; }
    write_config() { printf '%s\n' 'new-config' > "$CONFIG_FILE"; }
    configure_post_save_enforcement() { return 0; }
}

# 输入在任何一步结束都应取消本次配置并回滚 vnStat 事务；1.2.0 在 4 个循环里死循环（两处还不停写日志），
# 在限速/宽限两步则用默认值继续并保存。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_config_eof_cancels_without_looping() {
    local partial rc
    EOF_WORK=$(mktemp -d "$TEST_ROOT/config-eof.XXXXXX") || return 1
    setup_eof_wizard_case "$EOF_WORK" || return 1
    # 2.0 的问题顺序：网卡、方向、周期、起始日、单位、限额、提前量、超额处理、限速、开机宽限，最后确认保存。
    for partial in '' $'\n' $'\n3\n' $'\n3\n1\n' $'\n3\n1\n1\n' $'\n3\n1\n1\n1\n' $'\n3\n1\n1\n1\n100\n' \
        $'\n3\n1\n1\n1\n100\n10\n' $'\n3\n1\n1\n1\n100\n10\n1\n' $'\n3\n1\n1\n1\n100\n10\n1\n100\n' \
        $'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n'; do
        rm -f "$CONFIG_FILE" "$EOF_WORK/vnstat-rollback"
        printf '%s' "$partial" > "$EOF_WORK/input"
        rc=0
        run_with_deadline 5 "$EOF_WORK/input" initial_config || rc=$?
        [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || return 1
        assert_absent "$CONFIG_FILE" || return 1
        assert_file_content rolled-back "$EOF_WORK/vnstat-rollback" || return 1
    done
    # 完整输入仍能保存。
    printf '%s' $'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n\n' > "$EOF_WORK/input"
    run_with_deadline 5 "$EOF_WORK/input" initial_config || return 1
    assert_file_content 'new-config' "$CONFIG_FILE"
}

# 检测不到默认网卡时的网卡输入：EOF 必须返回失败；输错网卡只会重问，不会无限循环。
# （2.0 由 config_wizard_collect 负责；1.2.0 的 get_main_interface 在这里死循环。）
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_interface_prompt_eof_returns_failure() {
    local work rc=0
    work=$(mktemp -d "$TEST_ROOT/iface-eof.XXXXXX") || return 1
    LOG_FILE="$work/log"
    load_function "$MONITOR_SCRIPT" config_wizard_collect || return 1
    unset MAIN_INTERFACE
    detect_main_interface() { return 1; }
    list_interfaces() { printf '%s' 'eth0 ens3'; }
    interface_exists() { [ "$1" = eth0 ]; }
    : > "$work/input"
    run_with_deadline 5 "$work/input" config_wizard_collect || rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || return 1
    printf 'wlan9\n\n' > "$work/input"
    rc=0
    run_with_deadline 5 "$work/input" config_wizard_collect || rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]
}

# Telegram 首次配置：EOF 时 1.2.0 在 Token 等 4 个循环里死循环。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_telegram_config_eof_cancels() {
    local work partial rc
    work=$(mktemp -d "$TEST_ROOT/telegram-eof.XXXXXX") || return 1
    load_function "$TELEGRAM_SCRIPT" initial_config || return 1
    load_function "$TELEGRAM_SCRIPT" is_valid_timezone || return 1
    # 2.0：首次设置的各个提问拆到 prompt_bot_settings / prompt_report_schedule，一并加载，
    # 否则用例会在第一个提问处因函数缺失提前返回，后面几步的 EOF 就没有测到。
    load_function "$TELEGRAM_SCRIPT" prompt_bot_settings || return 1
    load_function "$TELEGRAM_SCRIPT" prompt_report_schedule || return 1
    write_config() { printf '%s\n' written > "$work/written"; }
    read_config() { return 0; }
    BOT_TOKEN='' CHAT_ID='' MACHINE_NAME='' DAILY_REPORT_TIME='' REPORT_TIMEZONE='' TG_DISABLED=false
    for partial in '' $'123:abc\n' $'123:abc\n42\n' $'123:abc\n42\nnode\n' $'123:abc\n42\nnode\n25:00\n' \
        $'123:abc\n42\nnode\n01:00\n'; do
        printf '%s' "$partial" > "$work/input"
        rc=0
        run_with_deadline 5 "$work/input" initial_config || rc=$?
        [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || return 1
        assert_absent "$work/written" || return 1
    done
}

# 停用（DISABLED=true）后打开「修改监控配置」：只显示配置和提示，不进向导、不写 cron、不执行限速
# （1.2.0 会重装 cron 并执行一轮限速）。2.0：已配置时先显示子菜单，只有选 1 才进向导；未配置时直接进向导。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_interactive_respects_disabled_and_explicit_yes() {
    local work answer
    work=$(mktemp -d "$TEST_ROOT/interactive-disabled.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    printf '%s\n' 'TRAFFIC_LIMIT=1' > "$CONFIG_FILE"
    load_function "$MONITOR_SCRIPT" configure_menu || return 1
    config_summary_rows() { :; }
    menu_clear() { :; }
    initial_config() { printf '%s\n' wizard >> "$work/calls"; }
    config_after_save() { printf '%s\n' after-save >> "$work/calls"; }
    setup_crontab() { printf '%s\n' cron >> "$work/calls"; }
    configure_vnstat_max_bandwidth() { printf '%s\n' maxbw >> "$work/calls"; }
    check_and_limit_traffic() { printf '%s\n' enforce >> "$work/calls"; }
    ui_pause() { :; }
    sleep() { :; }

    read_config() { DISABLED=true; return 0; }
    configure_menu <<< 1 > "$work/out-disabled" 2>&1 || return 1
    assert_absent "$work/calls" || return 1
    grep -Fq '停用' "$work/out-disabled" || return 1
    grep -Fq '「限制执行」' "$work/out-disabled" || return 1

    read_config() { DISABLED=false; return 0; }
    for answer in 0 '' x; do
        rm -f "$work/calls"
        configure_menu <<< "$answer" > /dev/null 2>&1 || return 1
        assert_absent "$work/calls" || return 1
    done
    configure_menu <<< $'1\n0' > /dev/null 2>&1 || return 1
    assert_file_content $'wizard\nafter-save' "$work/calls" || return 1

    rm -f "$work/calls" "$CONFIG_FILE"
    configure_menu < /dev/null > /dev/null 2>&1 || return 1
    assert_file_content $'wizard\nafter-save' "$work/calls"
}

# check_and_limit_traffic 自身也要尊重 DISABLED（纵深防御，避免其他入口绕过）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_check_and_limit_respects_disabled() {
    local work
    work=$(mktemp -d "$TEST_ROOT/limit-disabled.XXXXXX") || return 1
    LOG_FILE="$work/log"
    load_function "$MONITOR_SCRIPT" check_and_limit_traffic || return 1
    get_traffic_usage() { printf '%s\n' called > "$work/usage"; printf '%s\n' 999; }
    apply_tc_limit() { printf '%s\n' called > "$work/tc"; }
    DISABLED=true LIMIT_MODE=tc TRAFFIC_LIMIT=1 TRAFFIC_TOLERANCE=0
    check_and_limit_traffic > /dev/null 2>&1 || return 1
    assert_absent "$work/usage" || return 1
    assert_absent "$work/tc"
}

# Additional IFB tests share the function extractor and private mock workspace.
# shellcheck source=tests/ifb-regression.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/ifb-regression.sh"
# shellcheck source=tests/logging-regression.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/logging-regression.sh"
# shellcheck source=tests/filter-json-regression.sh disable=SC1091
source "$ROOT_DIR/tests/filter-json-regression.sh"

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

# 调用主脚本 CLI 的用例：主脚本按设计要求 root，非 root（如 GitHub Actions runner）下记为 SKIP。
run_root_test() {
    if [ "$EUID" -ne 0 ]; then
        printf 'skip - %s（需要 root）\n' "$1"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    run_test "$@"
}

run_test 'period reset cancels owned shutdown' test_period_reset_cancels_owned_shutdown
run_test 'period reset aborts safely on cancellation failure' test_period_reset_stops_when_shutdown_cancel_fails
run_test 'shutdown cleanup respects boot ownership' test_shutdown_cleanup_respects_boot_ownership
run_test 'shutdown cleanup blocks unverifiable pending task' test_shutdown_cleanup_blocks_unverifiable_pending_task
run_test 'shutdown cleanup requires exact task identity in every entrypoint' test_shutdown_cleanup_requires_exact_task_identity_in_all_entrypoints
run_test 'tc dependency maps to the platform iproute package' test_tc_dependency_package_mapping
run_test 'dependency check rejects tc still missing after install' test_dependency_check_rejects_missing_tc_after_install
run_test 'cron service start failures propagate to dependency setup' test_cron_service_start_failure_propagates_to_dependency_check
run_test 'monitor config restores previous state' test_monitor_config_restores_previous_state
run_test 'monitor first config is removed after post-save failure' test_monitor_config_removes_failed_first_config
run_test 'monitor config rolls back when writer reports failure' test_monitor_config_rolls_back_when_writer_reports_failure
run_test 'monitor rollback preserves backup after restore failure' test_monitor_rollback_preserves_backup_on_restore_failure
run_test 'vnStat modern config is idempotent and preserves custom values' test_vnstat_modern_config_is_idempotent_and_preserves_custom_values
run_test 'vnStat 2.0-2.8 compatibility disables detection at 50000 Mbit' test_vnstat_legacy_config_disables_detection_at_50000_mbit
run_test 'vnStat MaxBW zero disables the sanity check' test_vnstat_zero_disables_max_bandwidth_check
run_test 'vnStat bandwidth prompt defaults to zero and accepts custom values' test_vnstat_bandwidth_prompt_defaults_to_zero_and_accepts_custom_value
run_test 'old monitor config defaults vnStat bandwidth check to zero' test_old_monitor_config_defaults_vnstat_bandwidth_check_to_zero
run_test 'vnStat custom daemon config path is preserved idempotently' test_vnstat_custom_daemon_config_path_is_preserved_idempotently
run_test 'vnStat default config requires matching daemon and CLI prefixes' test_vnstat_default_config_requires_matching_install_prefixes
run_test 'vnStat starts daemon before resolving a custom service config' test_vnstat_runtime_starts_daemon_before_resolving_custom_config
run_test 'vnStat unchanged config does not reload the daemon' test_vnstat_unchanged_config_does_not_reload_daemon
run_test 'vnStat reload failure restores config and coverage marker' test_vnstat_reload_failure_restores_config_and_marker
run_test 'vnStat config and coverage marker commit together' test_vnstat_config_and_marker_commit_together
run_test 'vnStat backups remain bound to canonical config paths' test_vnstat_backups_are_bound_to_canonical_config_paths
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
run_test 'vnStat freshness rejects dead and stale daemon data' test_vnstat_freshness_rejects_dead_and_stale_daemon_data
run_test 'vnStat JSON is normalized for the requested interface' test_vnstat_json_is_normalized_for_the_requested_interface
run_test 'vnStat history read errors abort configuration' test_vnstat_history_read_error_aborts_configuration
run_test 'post-save read errors preserve runtime state' test_post_save_read_error_preserves_runtime_state
run_test 'post-save prepares enforcement before runtime mutation' test_post_save_prepares_enforcement_before_runtime_mutation
run_test 'post-save clears TC before shutdown and preserves old state on failure' test_post_save_clears_tc_before_shutdown_and_keeps_old_state_on_failure
run_test 'vnStat config transactions restore config marker interface and daemon state' test_vnstat_transaction_rolls_back_config_marker_interface_and_daemon
run_test 'config rollback compensates live TC and shutdown state' test_config_rollback_compensates_live_tc_and_shutdown
run_test 'config rollback reports failed runtime compensation' test_config_rollback_reports_failed_runtime_compensation
run_test 'vnStat interface additions are recorded before reload' test_vnstat_interface_addition_is_recorded_before_reload
run_test 'TC changes require a prepared ownership state' test_tc_change_requires_prepared_state
run_test 'TC query helpers preserve command errors' test_tc_query_helpers_preserve_command_errors
run_test 'TC apply query failure performs zero mutation' test_tc_apply_query_failure_is_zero_mutation
run_test 'TC clear query failure preserves rules and state' test_tc_clear_query_failure_preserves_rules_and_state
run_test 'TC rollback requires removal of a newly added default class' test_tc_existing_htb_rollback_requires_default_class_delete
run_test 'TC state deletion failures are reported for a default qdisc' test_tc_default_qdisc_state_delete_failure_is_reported
run_test 'TC recovery query failure performs zero mutation' test_tc_recovery_query_failure_is_zero_mutation
run_test 'TC self-check reports query errors' test_tc_self_check_reports_query_error
run_test 'TC builds the unified HTB directly without invoking Dog' test_tc_builds_unified_htb_directly
run_test 'TC self-check flags legacy state after Dog migrates the hierarchy' test_self_check_flags_legacy_state_after_dog_migration
run_test 'TC refuses an unrecognized root qdisc without mutation' test_tc_refuses_foreign_root_without_mutation
run_test 'TC auto recovery is a no-op without an existing owned state' test_tc_auto_recovery_without_state_is_noop
run_test 'TC auto recovery refuses a foreign root with owned state' test_tc_auto_recovery_refuses_a_foreign_root_with_owned_state
run_test 'shared TC recovery service remains disabled until explicitly enabled' test_shared_recovery_service_is_opt_in
run_test 'TC recovery waits briefly for the monitor lock' test_tc_recovery_waits_for_monitor_lock
run_test 'TC recovery menu confirms takeover only after detecting a conflict' test_tc_recovery_menu_requires_confirm_only_for_conflict
run_test 'TC boot rebuild accepts only known state schemas' test_tc_boot_rebuild_requires_a_known_state_schema
run_test 'TC cleanup preserves an invalid state without an interface' test_tc_clear_preserves_state_without_an_interface
run_test 'TC manual recovery rejects an unreadable Dog config without mutation' test_tc_manual_recovery_rejects_an_unreadable_dog_config
run_test 'shared TC state rejects insecure modes and duplicate keys' test_shared_tc_state_contract_rejects_insecure_and_duplicate_keys
run_test 'disabled TrafficCop state is never restored automatically' test_disabled_tc_recovery_is_never_automatic
run_test 'NTC self-check validates configured Dog port rules' test_ntc_self_check_includes_dog_port_rules
run_test 'disabled residual state accepts the Dog-rebuilt parent' test_disabled_state_cleanup_accepts_dog_rebuilt_parent
run_test 'TC recovery unit ownership and disable failures are fail-closed' test_tc_recovery_unit_ownership_is_fail_closed
run_test 'legacy TBF adoption requires a matching numeric speed' test_legacy_tbf_requires_matching_numeric_speed
run_test 'invalid Dog config cannot authorize HTB adoption' test_invalid_dog_config_cannot_authorize_adoption
run_test 'unified HTB verification requires the full root and class contract' test_unified_hierarchy_verification_requires_full_contract
run_test 'root crontab updates hold the TrafficCop project lock' test_monitor_crontab_update_holds_project_lock
run_test 'all root crontab writers validate candidates before installation' test_all_crontab_writers_build_candidates_before_installing
run_test 'shutdown scheduling requires a prepared ownership state' test_shutdown_requires_prepared_state
run_test 'Telegram config does not reuse stale secrets' test_telegram_config_does_not_reuse_stale_secret
run_test 'Telegram legacy config is parsed without execution' test_telegram_legacy_config_is_parsed_without_execution
run_test 'Telegram plain config round-trips special values' test_telegram_plain_config_round_trip
run_test 'Telegram token is absent from curl arguments' test_telegram_token_is_not_in_curl_arguments
run_test 'component download rejects versionless responses' test_component_download_rejects_versionless_body
run_test 'update rejects checksum mismatch and missing SHA256SUMS' test_update_rejects_checksum_mismatch_and_missing_sums
run_test 'repository SHA256SUMS matches the four scripts' test_repository_sha256sums_match_scripts
run_test 'Telegram monitor-health alerts are rate limited and announce recovery' test_telegram_monitor_health_alerts
run_test 'monitor writes a single-line health state' test_monitor_writes_health_state
run_test 'component download verifies the installed target' test_component_download_requires_a_verified_installed_target
run_test 'local component copy failures are reported' test_local_component_copy_failure_is_reported
run_test 'period date boundaries remain correct' test_period_date_boundaries
run_test 'traffic accounting modes remain correct' test_traffic_accounting_modes
run_test 'invalid limit speed is rejected while missing values stay compatible' test_invalid_limit_speed_is_rejected
run_test 'invalid disabled values are rejected' test_invalid_disabled_value_is_rejected
run_test 'explicit invalid period start days are rejected while missing defaults to one' test_period_start_day_validation_rejects_explicit_invalid_values
run_test 'dashboard flags an invalid period start day (2.0)' test_dashboard_rejects_invalid_period_start_day_before_calculation
run_test 'dashboard shows disabled above stale transient state (2.0)' test_main_disabled_enforcement_status_has_highest_priority
run_test 'read-only commands leave the monitor log and work directory untouched (2.0)' test_self_check_generic_log_is_byte_identical
run_test 'full self-check invocation leaves the monitor log byte-identical' test_self_check_full_invocation_preserves_generic_log
# 2.0 machine-limit：原描述 'machine task status uses only explicit automation markers'，最近检查改读 monitor_health。
run_test 'machine task status reads monitor_health instead of log markers (2.0)' test_machine_monitor_task_status_reads_health_state
run_test 'machine disabled enforcement status overrides stale transient state' test_machine_disabled_enforcement_status_has_highest_priority
run_test 'runtime rejects an invalid limit speed' test_runtime_rejects_invalid_limit_speed
run_test 'runtime calculation failure preserves the existing limit' test_runtime_calculation_failure_preserves_existing_limit
run_test 'legacy shutdown cancellation failures are reported' test_legacy_shutdown_cancel_failure_is_reported
run_test 'machine disable reports legacy shutdown cancellation failures' test_machine_legacy_shutdown_cancel_failure_is_reported
run_test 'manual TC cleanup always uses the monitor lock' test_machine_tc_clear_always_uses_lock
run_test 'foreign shortcut paths are preserved' test_shortcut_conflicts_are_preserved
run_test 'main script copy failures preserve the installed version' test_main_copy_failure_preserves_installed_script
run_test 'enable grace clears TC under the monitor lock before commit' test_enable_grace_clears_tc_under_monitor_lock_before_commit
run_test 'enable grace clear failures preserve the old enforcement state' test_enable_grace_clear_failure_preserves_old_enforcement
run_test 'enable candidate failures preserve config enforcement and TC state' test_enable_candidate_failure_preserves_pre_enable_state
run_test 'enable lock failures preserve config enforcement and TC state' test_enable_lock_failure_preserves_pre_enable_state
run_test 'machine enable clears existing TC before the monitor test' test_enable_machine_limit_clears_existing_tc_before_monitor
run_test 'disabled enable cleans residual NTC state before restoring config' test_disabled_enable_cleans_residual_ntc_state_before_config_restore
run_test 'machine enable clear failures roll back before monitor or cron' test_enable_machine_limit_clear_failure_rolls_back_without_monitor
run_test 'machine enable failure restores enforcement and remains fail-open' test_enable_failure_restores_old_enforcement_but_stays_fail_open
run_test 'restore failures recover the previous config' test_restore_failure_restores_previous_config
run_test 'restore from enabled state preserves paused enforcement on failure' test_restore_from_enabled_state_preserves_paused_enforcement_on_failure
run_test 'invalid traffic mode falls back to total' test_invalid_traffic_mode_falls_back_to_total
run_test 'shortcut conflict does not fail the install' test_shortcut_conflict_does_not_fail_install
run_test 'dashboard reports an unreadable crontab (2.0)' test_status_line_reports_unreadable_crontab

run_test 'IFB apply and clear preserve Dog objects in one TC transaction' test_ifb_apply_and_clear
run_test 'IFB with Dog 2.x manifest: apply and clear preserve Dog objects' test_ifb_v2_apply_and_clear
run_test 'Dog 2.x manifest missing/orphan/insecure/bad formula fails closed with zero mutation' test_ifb_v2_manifest_problems_fail_closed
run_test 'manual recovery refuses to delete a root that still has foreign classes (H2)' test_recovery_refuses_root_delete_with_foreign_classes
run_test 'Dog config schema detection fails closed on unknown formats' test_dog_config_schema_detection
run_test 'IFB installed after NTC repairs the same-rate fast path' test_ifb_late_install_and_recovery
run_test 'IFB partial update failure restores exact physical and IFB rates' test_ifb_apply_failure_rolls_back
run_test 'IFB state commit failure rolls back both directions' test_ifb_state_commit_failure_rolls_back
run_test 'IFB clear failure restores both directions and ownership state' test_ifb_clear_failure_rolls_back
run_test 'IFB state deletion failure rolls back both directions' test_ifb_state_delete_failure_rolls_back
run_test 'IFB clear also handles an absent physical root transactionally' test_ifb_clear_without_physical_root
run_test 'IFB unverified ownership and query failures cause zero mutation' test_ifb_unverified_is_zero_mutation
run_test 'IFB self-check detects parent class port filter and redirect drift' test_ifb_self_check_detects_drift
run_test 'standalone NTC leaves unknown IFB untouched' test_ifb_standalone_preserves_unknown_device
run_root_test 'main CLI self-check preserves insecure permissions and absent install' test_ifb_cli_self_check_is_readonly
run_test 'invalid NTC state cannot authorize physical or IFB mutation' test_ifb_invalid_ntc_state_is_zero_mutation
run_test 'IFB class references accept Dog flower groups and ranges' test_ifb_group_and_range_class_references
run_test 'IFB recovery retains scope and rolls back without port consumers' test_ifb_recovery_without_port_consumers
run_test 'IFB clear rejects existing child rate drift without mutation' test_ifb_existing_child_drift_is_zero_mutation
run_test 'IFB missing children fail strict checks but allow clear' test_ifb_missing_child_is_only_allowed_during_clear
run_test 'NTC installs first when only an unapplied Dog config exists' test_ifb_ntc_first_with_config_only
run_test 'IFB pending groups and empty class fields preserve record columns' test_ifb_unmaterialized_group_and_empty_class_fields
run_test 'IFB already removed by Dog clears only residual NTC state' test_ifb_clear_after_dog_removed_device
run_test 'operation audit permissions rotation and untrusted input' test_operation_log_permissions_rotation_and_input
run_test 'operation audit failure preserves business result' test_operation_log_failure_preserves_business_result
run_test 'installation and update rollback audit both outcomes' test_install_and_rollback_audit_results
run_test 'sourcing every component creates no files or logs' test_operation_logging_source_is_readonly
run_root_test 'logs and status preserve absent install and insecure permissions' test_operation_log_view_and_status_are_readonly
run_test 'IFB operations audit changes but not unchanged apply' test_ifb_operation_audit_and_unchanged_apply
run_test 'single-port JSON queries isolate unrelated legacy fw output' test_single_port_filter_json_excludes_unrelated_fw_printer

run_test 'post-save enforcement succeeds below the threshold (1.2.1)' test_post_save_below_threshold_succeeds
run_test 'post-save enforcement succeeds when enforcing immediately (1.2.1)' test_post_save_immediate_choice_succeeds
run_test 'post-save grace accepts minutes with a leading zero (1.2.1)' test_post_save_grace_accepts_leading_zero
run_test 'boot grace with a leading zero does not abort the monitor (1.2.1)' test_boot_grace_leading_zero_does_not_abort
run_test 'config validation normalizes a leading-zero boot grace (1.2.1)' test_validate_config_normalizes_boot_grace
run_test 'dashboard accepts leading zeros in config numbers (1.2.1, 2.0)' test_main_enforcement_overview_leading_zero_boot_grace
run_test 'machine grace and boot grace accept a leading zero (1.2.1)' test_machine_grace_and_boot_grace_accept_leading_zero
run_test 'monitor wizard cancels on end of input at every prompt (1.2.1)' test_monitor_config_eof_cancels_without_looping
run_test 'interface prompt returns failure on end of input (1.2.1)' test_interface_prompt_eof_returns_failure
run_test 'telegram setup cancels on end of input (1.2.1)' test_telegram_config_eof_cancels
run_test 'configure menu respects DISABLED and opens the wizard only on request (1.2.1, 2.0)' test_monitor_interactive_respects_disabled_and_explicit_yes
run_test 'limit check honours DISABLED (1.2.1)' test_check_and_limit_respects_disabled

# ── 2.0 monitor ──
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_normalize_decimal_and_threshold() {
    load_function "$MONITOR_SCRIPT" normalize_decimal || return 1
    load_function "$MONITOR_SCRIPT" config_threshold || return 1
    [ "$(normalize_decimal 500.000000)" = 500 ] || return 1
    [ "$(normalize_decimal 01.50)" = 1.5 ] || return 1
    [ "$(normalize_decimal 100)" = 100 ] || return 1
    [ "$(normalize_decimal 0.0)" = 0 ] || return 1
    if normalize_decimal -1 >/dev/null; then return 1; fi
    if normalize_decimal abc >/dev/null; then return 1; fi
    TRAFFIC_LIMIT=500 TRAFFIC_TOLERANCE=1
    [ "$(config_threshold)" = 499 ] || return 1
    TRAFFIC_LIMIT=1.5 TRAFFIC_TOLERANCE=0.25
    [ "$(config_threshold)" = 1.25 ]
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
setup_wizard_2_0_case() {
    CONFIG_FILE="$1/config"
    ENFORCEMENT_STATE_FILE="$1/enforcement"
    TC_STATE_FILE="$1/tc-state"
    SHUTDOWN_STATE_FILE="$1/shutdown-state"
    LOG_FILE="$1/log"
    load_function "$MONITOR_SCRIPT" restore_file_snapshot || return 1
    load_function "$MONITOR_SCRIPT" restore_monitor_config_snapshot || return 1
    load_function "$MONITOR_SCRIPT" initial_config || return 1
    setup_initial_config_transaction_mocks
    detect_main_interface() { printf '%s\n' eth0; }
    interface_exists() { return 0; }
    ensure_vnstat_runtime_config() { return 0; }
    ensure_vnstat_interface() { return 0; }
    ensure_vnstat_daily_retention() { return 0; }
    configure_history_policy() { return 0; }
    write_config() { printf '%s\n' new-config > "$CONFIG_FILE"; }
}

# 已超阈值时，向导在显示摘要之前问清楚这次怎么处理，并把选择原样交给保存后的执行策略（保存过程中不再提问）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_wizard_asks_exceed_policy_before_saving() {
    WIZARD_WORK=$(mktemp -d "$TEST_ROOT/wizard-exceed.XXXXXX") || return 1
    setup_wizard_2_0_case "$WIZARD_WORK" || return 1
    get_traffic_usage() { printf '%s\n' 120; }
    configure_post_save_enforcement() { printf '%s\n' "$CONFIG_EXCEED_POLICY" > "$WIZARD_WORK/policy"; }

    # 限额 100、提前量 10 → 阈值 90，已用 120：选 1（宽限）并输入 08 分钟，然后回车确认保存。
    printf '%s' $'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n1\n08\n\n' > "$WIZARD_WORK/input"
    run_with_deadline 5 "$WIZARD_WORK/input" initial_config || return 1
    assert_file_content 'grace:8' "$WIZARD_WORK/policy" || return 1
    assert_file_content new-config "$CONFIG_FILE" || return 1

    printf '%s' $'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n2\n\n' > "$WIZARD_WORK/input"
    run_with_deadline 5 "$WIZARD_WORK/input" initial_config || return 1
    assert_file_content now "$WIZARD_WORK/policy" || return 1

    # 没超阈值时不提问，并预设 10 分钟宽限以防保存前的几秒内越过阈值。
    get_traffic_usage() { printf '%s\n' 1; }
    printf '%s' $'\n3\n1\n1\n1\n100\n10\n1\n100\n10\n\n' > "$WIZARD_WORK/input"
    run_with_deadline 5 "$WIZARD_WORK/input" initial_config || return 1
    assert_file_content 'grace:10' "$WIZARD_WORK/policy"
}

# 摘要后回答 n：回滚 vnStat 事务，不写配置。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_wizard_declined_save_rolls_back() {
    local rc=0
    WIZARD_WORK=$(mktemp -d "$TEST_ROOT/wizard-decline.XXXXXX") || return 1
    setup_wizard_2_0_case "$WIZARD_WORK" || return 1
    get_traffic_usage() { printf '%s\n' 1; }
    rollback_initial_vnstat_transaction() { printf '%s\n' rolled-back > "$WIZARD_WORK/rollback"; }
    write_config() { printf '%s\n' written > "$WIZARD_WORK/written"; }
    configure_post_save_enforcement() { return 0; }

    printf '%s' $'\n3\n1\n1\n1\n100\n10\n1\n100\n10\nn\n' > "$WIZARD_WORK/input"
    run_with_deadline 5 "$WIZARD_WORK/input" initial_config || rc=$?
    [ "$rc" -eq 1 ] || return 1
    assert_absent "$WIZARD_WORK/written" || return 1
    assert_file_content rolled-back "$WIZARD_WORK/rollback"
}

# 保存后的执行策略按预设执行、不读标准输入（ntc config set 不能卡在提问上；1.2.1 只能交互选择）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_uses_preset_policy_without_reading_stdin() {
    local now until_epoch
    POST_SAVE_WORK=$(mktemp -d "$TEST_ROOT/post-save-preset.XXXXXX") || return 1
    setup_post_save_case "$POST_SAVE_WORK" || return 1
    get_traffic_usage() { printf '%s\n' 600; }

    CONFIG_EXCEED_POLICY=monitor
    configure_post_save_enforcement < /dev/null > "$POST_SAVE_WORK/out" 2>&1 || return 1
    grep -Fxq 'MODE=paused' "$ENFORCEMENT_STATE_FILE" || return 1

    CONFIG_EXCEED_POLICY=now
    configure_post_save_enforcement < /dev/null > "$POST_SAVE_WORK/out" 2>&1 || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1

    CONFIG_EXCEED_POLICY=grace:08
    now=$(date +%s)
    configure_post_save_enforcement < /dev/null > "$POST_SAVE_WORK/out" 2>&1 || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" || return 1
    until_epoch=$(sed -n 's/^UNTIL_EPOCH=//p' "$ENFORCEMENT_STATE_FILE")
    [ "$until_epoch" -ge $((now + 480)) ] && [ "$until_epoch" -le $((now + 485)) ]
}

# vnStat 日数据保留期不足时，输入结束等同于回答“否”：取消配置、不改 vnStat（1.2.1 读到 EOF 会按“是”修改）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_retention_prompt_eof_cancels() {
    local work
    work=$(mktemp -d "$TEST_ROOT/retention-eof.XXXXXX") || return 1
    TRAFFIC_PERIOD=monthly
    MAIN_INTERFACE=eth0
    load_function "$MONITOR_SCRIPT" ensure_vnstat_daily_retention || return 1
    vnstat_config_value() { printf '%s\n' 30; }
    ensure_vnstat_runtime_config() { printf '%s\n' "$2" > "$work/changed"; }

    if ensure_vnstat_daily_retention < /dev/null > /dev/null 2>&1; then return 1; fi
    assert_absent "$work/changed" || return 1
    # ntc config set --yes：不提问，直接调整。
    CONFIG_ASSUME_YES=true
    ensure_vnstat_daily_retention < /dev/null > /dev/null 2>&1 || return 1
    assert_file_content 40 "$work/changed"
}

# 依赖齐全时什么都不输出、不写日志（1.x 每次打开配置都打印 vnStat 版本、网卡和统计起始日期）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_dependency_check_is_quiet_when_complete() {
    local work
    work=$(mktemp -d "$TEST_ROOT/deps-quiet.XXXXXX") || return 1
    LOG_FILE="$work/log"
    load_function "$MONITOR_SCRIPT" check_and_install_packages || return 1
    find_tc_bin() { printf '%s\n' /sbin/tc; }
    required_command_available() { return 0; }
    ensure_service_running() { return 0; }
    ensure_vnstat_daemon_running() { return 0; }
    vnstat() { printf '%s\n' 'vnStat 2.12 by Teemu Toivola <tst at iki dot fi>'; }
    vnstat_cmd() { return 1; }
    ip() { printf '%s\n' 'default via 192.0.2.1 dev eth0'; }

    check_and_install_packages > "$work/out" 2>&1 || return 1
    [ ! -s "$work/out" ] || return 1
    [ ! -s "$LOG_FILE" ] || return 1
    # vnStat 1.x 仍然拒绝。
    vnstat() { printf '%s\n' 'vnStat 1.18 by Teemu Toivola'; }
    if check_and_install_packages > "$work/out" 2>&1; then return 1; fi
    grep -Fq 'vnStat 2.x' "$work/out"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
setup_round_log_case() {
    WORK_DIR="$1"
    LOG_FILE="$1/traffic_monitor.log"
    LOG_SIGNATURE_FILE="$1/monitor_log_signature"
    USAGE_STATE_FILE="$1/current_traffic_state"
    ENFORCEMENT_STATE_FILE="$1/enforcement_state"
    TC_STATE_FILE="$1/tc_limit_state"
    SHUTDOWN_STATE_FILE="$1/shutdown_limit_state"
    HEALTH_STATE_FILE="$1/monitor_health"
    PERIOD_STATE_FILE="$1/last_reset_period"
    SCRIPT_VERSION=test
    DISABLED=false
    local function_name
    for function_name in round_log_begin round_state_signature round_log_finish round_heartbeat_line usage_status_label; do
        load_function "$MONITOR_SCRIPT" "$function_name" || return 1
    done
}

# 模拟一轮检查：$1=用量状态 $2=返回码 $3=失败原因。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
fake_monitor_round() {
    printf 'STATUS=%s\nPERIOD_START=2026-11-01\nUSAGE=1\nLIMIT_THRESHOLD=9\nUNIT=GB\n' "$1" > "$USAGE_STATE_FILE"
    if [ "$2" = 0 ]; then
        printf 'HEALTH=ok\nREASON=\n' > "$HEALTH_STATE_FILE"
    else
        printf 'HEALTH=error\nREASON=%s\n' "$3" > "$HEALTH_STATE_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') round $1 ${3:-}" >> "$LOG_FILE"
    return "$2"
}

# shellcheck disable=SC2034,SC2209,SC2317,SC2329
run_fake_round() {
    local rc=0
    round_log_begin || return 1
    fake_monitor_round "$@" > /dev/null 2>> "$ROUND_LOG_BUFFER" || rc=$?
    round_log_finish "$rc"
}

# 日志只记事件：状态不变不写；状态变化、失败或新的失败原因整段写入；同一失败最多 10 分钟写一次；
# 一切正常时每小时一行“运行正常”。1.x 每分钟写 5 行，5000 行日志只够十几个小时。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_round_log_records_events_only() {
    local work
    work=$(mktemp -d "$TEST_ROOT/round-log.XXXXXX") || return 1
    setup_round_log_case "$work" || return 1

    run_fake_round normal 0 || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 1 ] || return 1
    run_fake_round normal 0 || return 1
    run_fake_round normal 0 || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 1 ] || return 1
    touch -d '61 minutes ago' "$LOG_FILE" || return 1
    run_fake_round normal 0 || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 2 ] || return 1
    tail -n 1 "$LOG_FILE" | grep -Fq '运行正常：本期已用 1 GB / 阈值 9 GB，流量正常（NTC test）' || return 1
    run_fake_round limited 0 || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 3 ] || return 1
    run_fake_round limited 1 'vnStat 读取失败' || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 4 ] || return 1
    run_fake_round limited 1 'vnStat 读取失败' || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 4 ] || return 1
    touch -d '11 minutes ago' "$LOG_FILE" || return 1
    run_fake_round limited 1 'vnStat 读取失败' || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 5 ] || return 1
    run_fake_round limited 1 'TC 下发失败' || return 1
    [ "$(wc -l < "$LOG_FILE")" -eq 6 ] || return 1
    ! find "$work" -name '.round-log.*' -print -quit | grep -q .
}

# 定时任务遇到监控锁被占用（上一轮或配置向导还在运行）时静默退出：返回 0、不写日志
# （1.x 每分钟写一行“另一个脚本实例正在运行”并返回 1）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_cron_skips_silently_when_locked() {
    local work
    work=$(mktemp -d "$TEST_ROOT/cron-locked.XXXXXX") || return 1
    (
        load_function "$MONITOR_SCRIPT" main || exit 1
        load_function "$MONITOR_SCRIPT" monitor_take_lock || exit 1
        WORK_DIR="$work"
        LOCK_FILE="$work/monitor.lock"
        LOG_FILE="$work/monitor.log"
        migrate_files() { :; }
        flock() { return 1; }
        run_monitor_round() { printf '%s\n' ran > "$work/ran"; }
        main --run > "$work/out" 2>&1
    ) || return 1
    assert_absent "$work/ran" || return 1
    assert_absent "$work/monitor.log" || return 1
    [ ! -s "$work/out" ]
}

# 开机自动恢复：仍在开机限速宽限期内时不重建 NTC 的整机上限，只清理它的状态（Dog 的类不受影响）；
# 手动恢复、以及宽限期过后的自动恢复照常重建（这里在取 TC 锁处截停）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tc_auto_recovery_defers_during_boot_grace() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tc-auto-boot-grace.XXXXXX") || return 1
    TC_BIN='mock_tc'
    TC_STATE_FILE="$work/tc-state"
    MAIN_INTERFACE='eth0'
    LIMIT_MODE='tc'
    DISABLED='false'
    TC_STATE_SCHEMA='traffic-tools-unified-htb-v1'
    TC_STATE_PROVIDER='trafficcop-lite'
    printf '%s\n' state > "$TC_STATE_FILE"

    load_function "$MONITOR_SCRIPT" recover_owned_tc_hierarchy || return 1
    trafficcop_config_is_disabled() { return 1; }
    tc_state_file_is_interpretable() { return 0; }
    tc_state_interface() { printf '%s\n' eth0; }
    tc_state_value() {
        case "$1" in
            SCHEMA) printf '%s\n' "$TC_STATE_SCHEMA" ;;
            PROVIDER) printf '%s\n' "$TC_STATE_PROVIDER" ;;
            LIMIT_SPEED) printf '%s\n' 90 ;;
        esac
    }
    clear_owned_tc_rules() { printf '%s\n' "$1" > "$work/cleared"; }
    acquire_tc_hierarchy_lock() { printf '%s\n' rebuild > "$work/rebuild"; return 1; }
    mock_tc() { printf '%s\n' "$*" > "$work/tc-called"; }
    boot_grace_window_active() { TC_BOOT_GRACE_REMAINING=7; return 0; }

    recover_owned_tc_hierarchy --auto > "$work/out" 2>&1 || return 1
    grep -Fq '开机限速宽限期（剩余约 7 分钟）' "$work/out" || return 1
    [ -s "$work/cleared" ] || return 1
    assert_absent "$work/rebuild" || return 1

    rm -f "$work/cleared"
    recover_owned_tc_hierarchy --manual > "$work/out" 2>&1
    assert_absent "$work/cleared" || return 1
    [ -s "$work/rebuild" ] || return 1

    rm -f "$work/rebuild"
    boot_grace_window_active() { return 1; }
    recover_owned_tc_hierarchy --auto > "$work/out" 2>&1
    assert_absent "$work/cleared" || return 1
    [ -s "$work/rebuild" ]
}

# ntc config set：参数错误退出 2，且不读标准输入、不改配置、不开始 vnStat 事务；--yes 全程不提问；
# 没有 --yes 时读到 EOF 视为不保存；停用时拒绝修改。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_config_set_validates_arguments_without_prompting() {
    local args rc
    CONFIG_SET_WORK=$(mktemp -d "$TEST_ROOT/config-set.XXXXXX") || return 1
    CONFIG_FILE="$CONFIG_SET_WORK/config"
    LOG_FILE="$CONFIG_SET_WORK/log"
    printf '%s\n' MAIN_INTERFACE=eth0 TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly PERIOD_START_DAY=1 TRAFFIC_LIMIT=500 \
        TRAFFIC_TOLERANCE=1 TRAFFIC_UNIT=decimal LIMIT_MODE=tc LIMIT_SPEED=50 > "$CONFIG_FILE"
    cp "$CONFIG_FILE" "$CONFIG_SET_WORK/config.orig" || return 1
    for args in config_set_cli config_set_error normalize_decimal default_tolerance compare_decimal is_decimal \
        config_threshold config_show_summary config_summary_rows vnstat_max_bandwidth_valid; do
        load_function "$MONITOR_SCRIPT" "$args" || return 1
    done
    read_config() {
        local key value
        while IFS='=' read -r key value; do printf -v "$key" '%s' "$value"; done < "$CONFIG_FILE"
        DISABLED="${DISABLED:-false}"
        ALLOW_PARTIAL_HISTORY="${ALLOW_PARTIAL_HISTORY:-false}"
        VNSTAT_MAX_BANDWIDTH="${VNSTAT_MAX_BANDWIDTH:-0}"
        TC_BOOT_GRACE_MINUTES="${TC_BOOT_GRACE_MINUTES:-10}"
        PERIOD_START_MONTH="${PERIOD_START_MONTH:-1}"
    }
    interface_exists() { [ "$1" = eth0 ]; }
    list_interfaces() { printf '%s' eth0; }
    config_prepare_vnstat() { printf '%s\n' prepared >> "$CONFIG_SET_WORK/events"; }
    get_traffic_usage() { printf '%s\n' 1; }
    rollback_initial_vnstat_transaction() { printf '%s\n' rollback >> "$CONFIG_SET_WORK/events"; }
    config_commit() {
        printf '%s|%s|%s|%s\n' "$TRAFFIC_LIMIT" "$TRAFFIC_TOLERANCE" "$LIMIT_SPEED" "$CONFIG_EXCEED_POLICY" \
            > "$CONFIG_SET_WORK/committed"
    }
    config_after_save() { printf '%s\n' after >> "$CONFIG_SET_WORK/events"; }
    save_vnstat_max_bandwidth() { printf '%s\n' "$VNSTAT_MAX_BANDWIDTH" > "$CONFIG_SET_WORK/maxbw"; }

    for args in --bogus --limit '--limit abc' '--limit 0' '--speed 0' '--mode up' '--period weekly' '--unit TB' \
        '--start-day 32' '--boot-grace 1441' '--when-over grace:0' '--when-over later' '--tolerance 500' \
        '--interface wlan9' '--vnstat-max-bw 50001' '' --yes extra; do
        rc=0
        # shellcheck disable=SC2086
        ( config_set_cli $args ) < /dev/null > /dev/null 2>&1 || rc=$?
        if [ "$rc" -ne 2 ]; then
            printf 'config set [%s] returned %s\n' "$args" "$rc" >&2
            return 1
        fi
    done
    cmp -s "$CONFIG_SET_WORK/config.orig" "$CONFIG_FILE" || return 1
    assert_absent "$CONFIG_SET_WORK/events" || return 1

    ( config_set_cli --limit=600.000 --tolerance 2 --speed 080 --when-over now --yes ) < /dev/null \
        > "$CONFIG_SET_WORK/out" 2>&1 || return 1
    assert_file_content '600|2|80|now' "$CONFIG_SET_WORK/committed" || return 1
    assert_file_content $'prepared\nafter' "$CONFIG_SET_WORK/events" || return 1

    # 只改 vnStat 异常速率上限时走轻量路径，不重新评估限速。
    rm -f "$CONFIG_SET_WORK/events" "$CONFIG_SET_WORK/committed"
    ( config_set_cli --vnstat-max-bw 01000 --yes ) < /dev/null > /dev/null 2>&1 || return 1
    assert_file_content 1000 "$CONFIG_SET_WORK/maxbw" || return 1
    assert_absent "$CONFIG_SET_WORK/committed" || return 1

    rc=0
    ( config_set_cli --limit 700 ) < /dev/null > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || return 1
    assert_absent "$CONFIG_SET_WORK/committed" || return 1
    assert_file_content $'prepared\nrollback' "$CONFIG_SET_WORK/events" || return 1

    printf '%s\n' DISABLED=true >> "$CONFIG_FILE"
    rc=0
    ( config_set_cli --limit 700 --yes ) < /dev/null > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] && [ ! -e "$CONFIG_SET_WORK/committed" ]
}

# ntc status --json：只读，字段带类型（数字是数字、布尔是布尔），状态词与主菜单仪表盘同一套规则；
# 用量取 10 分钟内同一周期的状态文件，不再读 vnStat。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_status_json_is_typed_and_read_only() {
    local work now out before function_name rc=0
    command -v jq >/dev/null 2>&1 || return 1
    work=$(mktemp -d "$TEST_ROOT/status-json.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    USAGE_STATE_FILE="$work/usage"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    HEALTH_STATE_FILE="$work/health"
    TC_STATE_FILE="$work/tc"
    TG_CONFIG_FILE="$work/tg"
    VNSTAT_CONFIG_PATH_FILE="$work/vnstat-path"
    TC_RECOVERY_UNIT_FILE="$work/recovery.service"
    DOG_CONFIG_FILE="$work/dog.json"
    SCRIPT_PATH="$work/trafficcop-lite-monitor.sh"
    LOG_FILE=/dev/null
    TC_BIN=''
    SCRIPT_VERSION=test
    now=$(date +%s)
    printf '%s\n' MAIN_INTERFACE=eth0 TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly PERIOD_START_DAY=1 TRAFFIC_LIMIT=500 \
        TRAFFIC_TOLERANCE=1 TRAFFIC_UNIT=decimal LIMIT_MODE=tc LIMIT_SPEED=50 > "$CONFIG_FILE"
    printf '%s\n' STATUS=normal PERIOD_START=2026-11-01 PERIOD_END=2026-11-30 USAGE=61.25 LIMIT_THRESHOLD=499 \
        UNIT=GB "UPDATED_EPOCH=$now" > "$USAGE_STATE_FILE"
    printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$now" > "$HEALTH_STATE_FILE"
    printf '%s\n' DAILY_REPORT_TIME=08:00 TG_DISABLED=false > "$TG_CONFIG_FILE"
    for function_name in monitor_status status_collect status_print_json status_print_human config_threshold \
        normalize_decimal is_decimal count_dog_classes enforcement_reason_label read_current_crontab; do
        load_function "$MONITOR_SCRIPT" "$function_name" || return 1
    done
    read_config() {
        local key value
        while IFS='=' read -r key value; do printf -v "$key" '%s' "$value"; done < "$CONFIG_FILE"
        DISABLED=false PERIOD_START_MONTH=1 ALLOW_PARTIAL_HISTORY=false VNSTAT_MAX_BANDWIDTH=0 TC_BOOT_GRACE_MINUTES=10
    }
    align_timezone_with_vnstat() { :; }
    get_period_start_date() { printf '%s\n' 2026-11-01; }
    get_period_end_date() { printf '%s\n' 2026-11-30; }
    get_traffic_usage() { printf '%s\n' unexpected > "$work/live-read"; return 1; }
    crontab() {
        printf '%s\n' "* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 # TrafficCop-Lite Monitor" \
            "* * * * * $work/trafficcop-lite-telegram.sh -cron >/dev/null 2>&1"
    }
    vnstat_daemon_is_running() { return 0; }
    command_exists() { return 1; }

    before=$(ls -lA --time-style=+%s "$work")
    out=$(monitor_status --json) || return 1
    [ "$before" = "$(ls -lA --time-style=+%s "$work")" ] || return 1
    assert_absent "$work/live-read" || return 1
    jq -e '.configured == true and .usage == 61.25 and .limit == 500 and .threshold == 499 and .percent == 12
        and .usage_source == "state" and .status.label == "● 监控中" and .status.level == "ok"
        and .cron.monitor == true and .cron.telegram == true and .telegram.state == "enabled"
        and .telegram.warn_percents == "80,90" and .action.speed_kbit == 50 and .dog_installed == false
        and .period.start == "2026-11-01" and .enforcement.mode == "normal"' <<< "$out" > /dev/null || return 1
    ( monitor_status --xml ) > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || return 1
    NO_COLOR=1 monitor_status > "$work/human" 2>&1 || return 1
    grep -Fq '● 监控中' "$work/human" || return 1
    grep -Fq '61.25 GB / 500 GB' "$work/human" || return 1

    # 安装目录还不存在时也能读 crontab，且不会创建该目录（读 crontab 的临时文件放在临时目录）。
    WORK_DIR="$work/missing"
    out=$(monitor_status --json) || return 1
    assert_absent "$work/missing" || return 1
    jq -e '.cron.readable == true and .cron.monitor == true' <<< "$out" > /dev/null || return 1

    # 预警档位与 Telegram 组件同一套解释：空值是关闭，写坏的值按默认 80,90 执行。
    WORK_DIR="$work"
    printf '%s\n' WARN_PERCENTS= >> "$TG_CONFIG_FILE"
    out=$(monitor_status --json) || return 1
    jq -e '.telegram.warn_percents == "off"' <<< "$out" > /dev/null || return 1
    out=$(NO_COLOR=1 monitor_status 2>&1) || return 1
    grep -Fq '用量预警已关闭' <<< "$out" || return 1
    printf '%s\n' WARN_PERCENTS=80,abc >> "$TG_CONFIG_FILE"
    out=$(monitor_status --json) || return 1
    jq -e '.telegram.warn_percents == "80,90"' <<< "$out" > /dev/null
}

# 命令行：未知参数与多余参数退出 2，而且在迁移文件、取锁之前就拒绝；--help 退出 0。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_cli_rejects_unknown_arguments() {
    local work args rc
    work=$(mktemp -d "$TEST_ROOT/monitor-cli.XXXXXX") || return 1
    load_function "$MONITOR_SCRIPT" main || return 1
    load_function "$MONITOR_SCRIPT" show_monitor_usage || return 1
    migrate_files() { printf '%s\n' migrated >> "$work/calls"; }
    monitor_take_lock() { printf '%s\n' locked >> "$work/calls"; return 1; }
    for args in --bogus '--check extra' '--config-show x' '--configure x' -x status; do
        rc=0
        # shellcheck disable=SC2086
        ( main $args ) < /dev/null > /dev/null 2>&1 || rc=$?
        [ "$rc" -eq 2 ] || return 1
    done
    ( main --help ) > "$work/help" 2>&1 || return 1
    grep -Fq -- '--config-set' "$work/help" || return 1
    assert_absent "$work/calls"
}

# 每分钟的检查只把事件写进日志（2.0）：main 在切到本轮缓冲之前不得直接写真实日志（1.x 遗留的 migrate_files 每次运行
# 都写一行「使用独立工作目录」，cron 下就是每分钟一行）；ntc check 只打印一句结论。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_monitor_main_writes_no_log_before_round_buffer() {
    local work out
    work=$(mktemp -d "$TEST_ROOT/monitor-main-log.XXXXXX") || return 1
    WORK_DIR="$work"
    LOG_FILE="$work/traffic_monitor.log"
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    printf '%s\n' LIMIT_MODE=tc > "$CONFIG_FILE"
    load_function "$MONITOR_SCRIPT" main || return 1
    load_function "$MONITOR_SCRIPT" migrate_files 2> /dev/null || true
    monitor_take_lock() { :; }
    round_log_begin() { [ ! -s "$LOG_FILE" ] && printf '%s\n' begin >> "$work/calls"; }
    run_monitor_round() { printf '%s\n' round >> "$work/calls"; }
    round_log_finish() { printf '%s\n' finish >> "$work/calls"; }
    monitor_check_now() { printf '%s\n' '  ✓ 检查完成：流量正常。'; }

    ( main --run ) < /dev/null > "$work/out" 2>&1 || return 1
    assert_file_content $'begin\nround\nfinish' "$work/calls" || return 1
    assert_absent "$LOG_FILE" || return 1
    [ ! -s "$work/out" ] || return 1

    out=$( ( main --check ) < /dev/null 2>&1 ) || return 1
    [ "$out" = '  ✓ 检查完成：流量正常。' ] || return 1
    assert_absent "$LOG_FILE"
}

# 保存配置时屏幕上不出现带时间戳的日志行（2.0）：读取用量、撤销 NTC 限速、清理关机记录这些 1.x 运行函数的说明行
# 成功时只留在日志里（1.x 会在「保存？」和「配置已保存」之间打出「周期开始日期…」「配置已更新：未发现本脚本 TC
# 状态标记…」）；某一步失败时把原因去掉时间戳后显示出来。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_post_save_keeps_log_lines_off_screen() {
    local out
    POST_SAVE_WORK=$(mktemp -d "$TEST_ROOT/post-save-quiet.XXXXXX") || return 1
    setup_post_save_case "$POST_SAVE_WORK" || return 1
    get_traffic_usage() {
        echo '2026-01-01 08:00:00 周期开始日期: 2026-01-01, 周期结束日期: 2026-01-31' >&2
        printf '%s\n' 12.5
    }
    clear_owned_tc_rules() { echo "2026-01-01 08:00:01 $1：未发现本脚本 TC 状态标记，保留现有 qdisc。" | tee -a "$LOG_FILE"; }
    clear_owned_shutdown_schedule() { echo '2026-01-01 08:00:02 已清理上次开机遗留的关机状态。' | tee -a "$LOG_FILE"; }

    out=$(configure_post_save_enforcement < /dev/null 2>&1) || return 1
    ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' <<< "$out" || return 1
    grep -Fq '未发现本脚本 TC 状态标记' "$LOG_FILE" || return 1
    grep -Fq '已清理上次开机遗留的关机状态' "$LOG_FILE" || return 1

    clear_owned_tc_rules() { echo "2026-01-01 08:00:01 $1：无法取得统一 TC 层级锁。" | tee -a "$LOG_FILE"; return 1; }
    if out=$(configure_post_save_enforcement < /dev/null 2>&1); then return 1; fi
    grep -Fq '配置已更新：无法取得统一 TC 层级锁。' <<< "$out" || return 1
    ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' <<< "$out" || return 1

    get_traffic_usage() { echo '2026-01-01 08:00:00 vnStat 没有这个网卡的数据' >&2; return 1; }
    if out=$(configure_post_save_enforcement < /dev/null 2>&1); then return 1; fi
    grep -Fq 'vnStat 没有这个网卡的数据' <<< "$out" || return 1
    ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' <<< "$out"
}
# 四个脚本里的共享区块必须与 src/common 一致（CI 也会跑这一条）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_common_blocks_are_in_sync() {
    bash "$ROOT_DIR/tools/sync-common.sh" --check > /dev/null
}

run_test 'shared blocks match src/common (2.0)' test_common_blocks_are_in_sync
run_test 'monitor normalizes decimals and computes the threshold without bc (2.0)' test_monitor_normalize_decimal_and_threshold
run_test 'monitor wizard asks the over-threshold policy before saving (2.0)' test_monitor_wizard_asks_exceed_policy_before_saving
run_test 'monitor wizard rolls back when saving is declined (2.0)' test_monitor_wizard_declined_save_rolls_back
run_test 'post-save enforcement uses the preset policy without reading stdin (2.0)' test_post_save_uses_preset_policy_without_reading_stdin
run_test 'vnStat retention prompt treats end of input as no (2.0)' test_retention_prompt_eof_cancels
run_test 'dependency check is quiet when nothing is missing (2.0)' test_dependency_check_is_quiet_when_complete
run_test 'monitor log records events only (2.0)' test_monitor_round_log_records_events_only
run_test 'cron run exits silently when the monitor lock is busy (2.0)' test_monitor_cron_skips_silently_when_locked
run_test 'boot-time TC recovery defers the NTC cap during boot grace (2.0)' test_tc_auto_recovery_defers_during_boot_grace
run_test 'config set validates arguments and never prompts with --yes (2.0)' test_config_set_validates_arguments_without_prompting
run_test 'status --json is typed and read-only (2.0)' test_monitor_status_json_is_typed_and_read_only
run_test 'monitor CLI rejects unknown arguments before touching state (2.0)' test_monitor_cli_rejects_unknown_arguments
run_test 'monitor main writes nothing to the real log before the round buffer (2.0)' test_monitor_main_writes_no_log_before_round_buffer
run_test 'saving a config keeps timestamped log lines off the screen unless a step fails (2.0)' test_post_save_keeps_log_lines_off_screen
# ── end 2.0 monitor ──

# ── 2.0 main ──

# ntc 子命令：未知命令在要求 root、创建安装目录之前就退出 2；已知命令参数个数或取值不对也退出 2；
# 合法命令按约定转给组件（status/config/check → monitor，pause/resume/enable/disable/grace → 限制执行，
# telegram → 通知），只读命令不创建安装目录。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_main_cli_dispatch_and_exit_codes() {
    local work args rc
    work=$(mktemp -d "$TEST_ROOT/main-cli.XXXXXX") || return 1
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'
    WORK_DIR="$work/etc"
    RAW_BASE='https://example.invalid/raw'
    UPDATE_PROXY_BASE='https://example.invalid/proxy'
    SCRIPT_VERSION='2.0.0'
    for args in main usage_error show_usage; do
        load_function "$ROOT_DIR/trafficcop-lite.sh" "$args" || return 1
    done
    record() { printf '%s\n' "$*" >> "$work/events"; }
    check_root() { record root; }
    ensure_work_dir() { record workdir; }
    run_installed_component() { record "run $*"; }
    ensure_runtime_ready() { :; }
    bash() { record "bash $*"; }
    show_versions() { record versions; }
    run_tc_self_check() { record "self-check $*"; }
    show_logs_cli() { record "logs $*"; }
    view_logs() { record view-logs; }
    uninstall_lite() { record uninstall; }
    stop_all_services() { record stop; }
    update_scripts() { record "update $*"; }
    run_shared_tc_recovery() { record "recover $*"; }
    dependency_install_for_host() { :; }
    install_from_entrypoint() { :; }
    main_menu() { record menu; }
    ntc_missing_tools() { return 1; }

    # 未知命令：什么都不做（不要求 root、不碰安装目录）。
    for args in bogus --bogus statsu 'pause-all now'; do
        rm -f "$work/events"
        rc=0
        # shellcheck disable=SC2086
        ( main $args ) < /dev/null > /dev/null 2>&1 || rc=$?
        if [ "$rc" -ne 2 ] || [ -e "$work/events" ]; then
            printf 'ntc %s returned %s\n' "$args" "$rc" >&2
            return 1
        fi
    done
    # 已知命令、参数不对。
    for args in 'version extra' 'check extra' 'config bogus' 'config show extra' 'telegram bogus' \
        'telegram test extra' grace 'grace 5 6' 'pause now' 'update --bogus' 'uninstall now' \
        '--install --bogus' '--config extra' 'logs a b'; do
        rc=0
        # shellcheck disable=SC2086
        ( main $args ) < /dev/null > /dev/null 2>&1 || rc=$?
        if [ "$rc" -ne 2 ]; then
            printf 'ntc %s returned %s\n' "$args" "$rc" >&2
            return 1
        fi
    done
    rc=0
    ( main help ) < /dev/null > "$work/help" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && grep -Fq 'status [--json]' "$work/help" || return 1

    expect_dispatch() {
        local expected="$1"
        shift
        rm -f "$work/events"
        ( main "$@" ) < /dev/null > /dev/null 2>&1 || return 1
        if [ "$(tail -n 1 "$work/events")" != "$expected" ]; then
            printf 'ntc %s -> %s\n' "$*" "$(tail -n 1 "$work/events")" >&2
            return 1
        fi
    }
    expect_dispatch "run $MONITOR_SCRIPT --status --json" status --json || return 1
    ! grep -Fxq workdir "$work/events" || return 1
    expect_dispatch "run $MONITOR_SCRIPT --config-show" --config || return 1
    ! grep -Fxq workdir "$work/events" || return 1
    expect_dispatch "run $MONITOR_SCRIPT --check" check || return 1
    expect_dispatch "run $MONITOR_SCRIPT --config-show" config show || return 1
    expect_dispatch "run $MONITOR_SCRIPT --config-set --limit 500 --yes" config set --limit 500 --yes || return 1
    expect_dispatch "bash $WORK_DIR/$MONITOR_SCRIPT --configure" config || return 1
    for args in pause resume enable disable; do
        expect_dispatch "run $MACHINE_LIMIT_SCRIPT --$args" "$args" || return 1
    done
    expect_dispatch "run $MACHINE_LIMIT_SCRIPT --grace 30" grace 30 || return 1
    expect_dispatch "run $TELEGRAM_SCRIPT --test" telegram test || return 1
    expect_dispatch "run $TELEGRAM_SCRIPT --report" telegram report || return 1
    expect_dispatch "bash $WORK_DIR/$TELEGRAM_SCRIPT" telegram || return 1
    expect_dispatch "update $UPDATE_PROXY_BASE" update --mirror || return 1
    expect_dispatch menu
}

# 卸载/停止用到的桩：按调用顺序记录事件；解除限速的结果由 CLEANUP_TC_RC 决定。
# shellcheck disable=SC2034,SC2317,SC2329
setup_cleanup_order_case() {
    CLEANUP_WORK=$(mktemp -d "$TEST_ROOT/cleanup-order.XXXXXX") || return 1
    WORK_DIR="$CLEANUP_WORK/etc"
    SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
    SHORTCUT_PATH="$CLEANUP_WORK/ntc"
    LEGACY_NCL_SHORTCUT_PATH="$CLEANUP_WORK/ncl"
    LEGACY_TC_SHORTCUT_PATH="$CLEANUP_WORK/tc"
    CLEANUP_TC_RC=0
    acquire_monitor_cleanup_lock() { printf '%s\n' lock >> "$CLEANUP_WORK/events"; }
    release_monitor_cleanup_lock() { printf '%s\n' unlock >> "$CLEANUP_WORK/events"; }
    stop_lite_processes() { printf '%s\n' stop >> "$CLEANUP_WORK/events"; }
    clear_lite_tc_rules_interactive() { printf '%s\n' tc >> "$CLEANUP_WORK/events"; return "$CLEANUP_TC_RC"; }
    cancel_shutdown_interactive() { printf '%s\n' shutdown >> "$CLEANUP_WORK/events"; }
    lite_has_pending_shutdown() { return 1; }
    remove_lite_cron() {
        if [ -d "$WORK_DIR" ]; then
            printf '%s\n' cron >> "$CLEANUP_WORK/events"
        else
            printf '%s\n' cron-after-rm >> "$CLEANUP_WORK/events"
        fi
    }
    remove_shortcut_links() { printf '%s\n' links >> "$CLEANUP_WORK/events"; }
    cleanup_tc_recovery_files_if_unused() { printf '%s\n' recovery >> "$CLEANUP_WORK/events"; }
    pause() { :; }
}

reset_cleanup_order_case() {
    rm -rf "$WORK_DIR" "$CLEANUP_WORK/events"
    mkdir -p "$WORK_DIR" && printf '%s\n' keep > "$WORK_DIR/traffic_monitor_config.txt"
}

# L1 卸载：先问完所有问题再动手，未确认或中途 EOF 时什么都不改；解除限速失败时中止，定时任务和目录都保留；
# 成功时按「解除限速 → 取消关机 → 删除定时任务 → 删除目录」执行（1.x 先删定时任务，之后失败会留下没人解除的限速）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_uninstall_asks_first_and_removes_cron_after_cleanup() {
    local input rc
    load_function "$ROOT_DIR/trafficcop-lite.sh" uninstall_lite || return 1
    setup_cleanup_order_case || return 1

    for input in '' 'UNINSTALL\n' 'uninstall\nn\n'; do
        reset_cleanup_order_case || return 1
        rc=0
        ( printf '%b' "$input" | uninstall_lite ) > /dev/null 2>&1 || rc=$?
        [ "$rc" -ne 0 ] || return 1
        assert_absent "$CLEANUP_WORK/events" || return 1
        [ -f "$WORK_DIR/traffic_monitor_config.txt" ] || return 1
    done

    reset_cleanup_order_case || return 1
    CLEANUP_TC_RC=1
    rc=0
    ( printf 'UNINSTALL\nn\n' | uninstall_lite ) > /dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || return 1
    assert_file_content $'lock\nstop\ntc\nunlock' "$CLEANUP_WORK/events" || return 1
    [ -f "$WORK_DIR/traffic_monitor_config.txt" ] || return 1

    reset_cleanup_order_case || return 1
    CLEANUP_TC_RC=0
    ( printf 'UNINSTALL\nn\n' | uninstall_lite ) > /dev/null 2>&1 || return 1
    assert_file_content $'lock\nstop\ntc\nshutdown\ncron\nunlock\nlinks\nrecovery' "$CLEANUP_WORK/events" || return 1
    [ ! -e "$WORK_DIR" ]
}

# --stop：与卸载相同的顺序，限速或关机未能解除时保留定时任务（监控继续运行）；不读标准输入、不等按键。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_stop_all_services_keeps_cron_until_cleanup_succeeds() {
    local rc
    load_function "$ROOT_DIR/trafficcop-lite.sh" stop_all_services || return 1
    setup_cleanup_order_case || return 1

    reset_cleanup_order_case || return 1
    CLEANUP_TC_RC=1
    rc=0
    run_with_deadline 10 /dev/null stop_all_services || rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || return 1
    assert_file_content $'lock\nstop\ntc\nshutdown\nunlock' "$CLEANUP_WORK/events" || return 1

    reset_cleanup_order_case || return 1
    CLEANUP_TC_RC=0
    run_with_deadline 10 /dev/null stop_all_services || return 1
    assert_file_content $'lock\nstop\ntc\nshutdown\ncron\nunlock' "$CLEANUP_WORK/events" || return 1
    [ -f "$WORK_DIR/traffic_monitor_config.txt" ]
}

# 主脚本的关机清理（卸载与 --stop 共用 cancel_shutdown_interactive，2.0）：
# - 有 NTC 的关机记录、系统里却没有待执行关机：只删记录，不调用 shutdown -c，也不说「已取消」；
# - NTC 没有记录的计划关机（关机模式、无记录文件）无法确认归属：只有卸载时事先答 y 才取消，否则保留并说明；
#   没有待执行关机时什么都不做；这个函数本身不读标准输入；
# - 卸载在取锁之前把这一问和其他问题一起问完，读到 EOF 就取消卸载；--stop 不提问，一律保留。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_main_shutdown_cleanup_is_truthful_and_asks_first() {
    local work out rc
    work=$(mktemp -d "$TEST_ROOT/main-shutdown-cleanup.XXXXXX") || return 1
    WORK_DIR="$work"
    SHUTDOWN_STATE_FILE="$work/shutdown_limit_state"
    RED=''
    YELLOW=''
    NC=''
    load_function "$ROOT_DIR/trafficcop-lite.sh" lite_shutdown_task_token_from_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" lite_pending_shutdown_matches_owned_state || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" cancel_shutdown_interactive || return 1
    lite_has_pending_shutdown() { [ -f "$work/pending" ]; }
    shutdown() {
        [ "${1:-}" = -c ] || return 1
        printf '%s\n' cancel >> "$work/shutdown-calls"
        rm -f "$work/pending"
    }
    cat() {
        if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then
            printf '%s\n' boot-a
        else
            command cat "$@"
        fi
    }

    printf '%s\n' 'BOOT_ID=boot-a' 'TASK_TOKEN=trafficcop-lite-main-12345678' > "$SHUTDOWN_STATE_FILE"
    out=$(cancel_shutdown_interactive < /dev/null 2>&1) || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/shutdown-calls" || return 1
    grep -Fq '当前没有待执行的计划关机' <<< "$out" || return 1
    if grep -Fq '已取消' <<< "$out"; then return 1; fi

    printf '%s\n' 'LIMIT_MODE=shutdown' > "$work/traffic_monitor_config.txt"
    out=$(LITE_UNOWNED_SHUTDOWN_ANSWER=y cancel_shutdown_interactive < /dev/null 2>&1) || return 1
    assert_absent "$work/shutdown-calls" || return 1
    if grep -Fq '已取消' <<< "$out"; then return 1; fi

    touch "$work/pending"
    out=$(printf 'y\n' | cancel_shutdown_interactive 2>&1) || return 1
    [ -f "$work/pending" ] || return 1
    assert_absent "$work/shutdown-calls" || return 1
    grep -Fq '已保留' <<< "$out" || return 1

    out=$(LITE_UNOWNED_SHUTDOWN_ANSWER=y cancel_shutdown_interactive < /dev/null 2>&1) || return 1
    assert_file_content 'cancel' "$work/shutdown-calls" || return 1
    assert_absent "$work/pending" || return 1
    grep -Fq '已取消计划关机' <<< "$out" || return 1

    load_function "$ROOT_DIR/trafficcop-lite.sh" uninstall_lite || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" stop_all_services || return 1
    setup_cleanup_order_case || return 1
    lite_has_pending_shutdown() { printf '%s\n' pending-check >> "$CLEANUP_WORK/events"; return 0; }
    cancel_shutdown_interactive() { printf 'shutdown:%s\n' "${LITE_UNOWNED_SHUTDOWN_ANSWER:-unset}" >> "$CLEANUP_WORK/events"; }

    reset_cleanup_order_case || return 1
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$WORK_DIR/traffic_monitor_config.txt"
    ( printf 'UNINSTALL\nn\ny\n' | uninstall_lite ) > /dev/null 2>&1 || return 1
    assert_file_content $'pending-check\nlock\nstop\ntc\nshutdown:y\ncron\nunlock\nlinks\nrecovery' "$CLEANUP_WORK/events" || return 1

    reset_cleanup_order_case || return 1
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$WORK_DIR/traffic_monitor_config.txt"
    ( printf 'UNINSTALL\nn\n\n' | uninstall_lite ) > /dev/null 2>&1 || return 1
    assert_file_content $'pending-check\nlock\nstop\ntc\nshutdown:n\ncron\nunlock\nlinks\nrecovery' "$CLEANUP_WORK/events" || return 1

    reset_cleanup_order_case || return 1
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$WORK_DIR/traffic_monitor_config.txt"
    rc=0
    ( printf 'UNINSTALL\nn\n' | uninstall_lite ) > /dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || return 1
    assert_file_content 'pending-check' "$CLEANUP_WORK/events" || return 1
    [ -f "$WORK_DIR/traffic_monitor_config.txt" ] || return 1

    reset_cleanup_order_case || return 1
    printf '%s\n' 'LIMIT_MODE=shutdown' > "$WORK_DIR/traffic_monitor_config.txt"
    ( printf 'y\n' | stop_all_services ) > /dev/null 2>&1 || return 1
    assert_file_content $'lock\nstop\ntc\nshutdown:n\ncron\nunlock' "$CLEANUP_WORK/events"
}

# L2 更新：四个脚本都已替换并校验通过后，共享 TC 自动恢复文件写不进去只警告，更新仍算成功；
# 已是最新（没有文件变化）时同样只警告。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_update_recovery_file_failure_only_warns() {
    local work remote_dir out fn
    work=$(mktemp -d "$TEST_ROOT/update-l2.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    remote_dir="$work/remote"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'
    mkdir -p "$WORK_DIR" "$remote_dir" || return 1
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.2.1"' > "$WORK_DIR/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.2.1"' > "$WORK_DIR/$MONITOR_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.2.1"' > "$WORK_DIR/$TELEGRAM_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop 机器限速管理脚本 v2.13' > "$WORK_DIR/$MACHINE_LIMIT_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' > "$remote_dir/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' > "$remote_dir/$MONITOR_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' > "$remote_dir/$TELEGRAM_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop 机器限速管理脚本 v2.13' 'SCRIPT_VERSION="2.0.0"' \
        > "$remote_dir/$MACHINE_LIMIT_SCRIPT"
    (cd "$remote_dir" && sha256sum trafficcop-lite*.sh > SHA256SUMS) || return 1
    for fn in script_version_from_file version_is_newer validate_update_candidate verify_installed_scripts \
        rollback_script_update update_scripts; do
        load_function "$ROOT_DIR/trafficcop-lite.sh" "$fn" || return 1
    done
    ensure_work_dir() { mkdir -p "$WORK_DIR"; }
    download_url_to_file() { cp "$remote_dir/$(basename "$1")" "$2"; }
    install_shortcut_link() { :; }
    install_tc_recovery_service_files() { return 1; }

    out=$(update_scripts 'https://example.invalid/release' 2>&1) || return 1
    grep -Fq '共享 TC 自动恢复文件未能更新' <<< "$out" || return 1
    grep -Fqx 'SCRIPT_VERSION="2.0.0"' "$WORK_DIR/trafficcop-lite.sh" || return 1
    cmp -s "$remote_dir/$MACHINE_LIMIT_SCRIPT" "$WORK_DIR/$MACHINE_LIMIT_SCRIPT" || return 1

    out=$(update_scripts 'https://example.invalid/release' 2>&1) || return 1
    grep -Fq '共享 TC 自动恢复文件未能更新' <<< "$out"
}

# 更新只说实话（2.0）：四个脚本仍整组替换（备份与回滚不变），但只有内容确实变化的脚本才显示「已更新」，
# 没变化的标明「没有变化」（1.x 一律显示「已更新」）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_update_reports_only_changed_files() {
    local work remote_dir out fn name
    work=$(mktemp -d "$TEST_ROOT/update-changed.XXXXXX") || return 1
    WORK_DIR="$work/installed"
    remote_dir="$work/remote"
    MONITOR_SCRIPT='trafficcop-lite-monitor.sh'
    TELEGRAM_SCRIPT='trafficcop-lite-telegram.sh'
    MACHINE_LIMIT_SCRIPT='trafficcop-lite-machine-limit.sh'
    mkdir -p "$WORK_DIR" "$remote_dir" || return 1
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' > "$remote_dir/trafficcop-lite.sh"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' '# 修订' > "$remote_dir/$MONITOR_SCRIPT"
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' > "$remote_dir/$TELEGRAM_SCRIPT"
    printf '%s\n' '#!/bin/bash' '# TrafficCop 机器限速管理脚本 v2.13' 'SCRIPT_VERSION="2.0.0"' \
        > "$remote_dir/$MACHINE_LIMIT_SCRIPT"
    for name in trafficcop-lite.sh "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
        cp "$remote_dir/$name" "$WORK_DIR/$name" || return 1
    done
    printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="2.0.0"' > "$WORK_DIR/$MONITOR_SCRIPT"
    (cd "$remote_dir" && sha256sum trafficcop-lite*.sh > SHA256SUMS) || return 1
    for fn in script_version_from_file version_is_newer validate_update_candidate verify_installed_scripts \
        rollback_script_update update_scripts; do
        load_function "$ROOT_DIR/trafficcop-lite.sh" "$fn" || return 1
    done
    ensure_work_dir() { mkdir -p "$WORK_DIR"; }
    download_url_to_file() { cp "$remote_dir/$(basename "$1")" "$2"; }
    install_shortcut_link() { :; }
    install_tc_recovery_service_files() { :; }

    out=$(update_scripts 'https://example.invalid/release' 2>&1) || return 1
    grep -Fq "✓ 已更新 $MONITOR_SCRIPT" <<< "$out" || return 1
    for name in trafficcop-lite.sh "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
        ! grep -Fq "已更新 $name" <<< "$out" || return 1
        grep -Fq "$name 没有变化" <<< "$out" || return 1
        cmp -s "$remote_dir/$name" "$WORK_DIR/$name" || return 1
    done
    cmp -s "$remote_dir/$MONITOR_SCRIPT" "$WORK_DIR/$MONITOR_SCRIPT"
}

# 主菜单版式：仪表盘与菜单按显示宽度排版，120/80/60/40 列下每行都不超宽；宽屏两栏竖排编号，窄屏改为
# 分组单列；不在终端时（含 NO_COLOR、TERM=dumb）不输出颜色转义。正常、已限速、宽限、未配置四种状态各渲染一次。
# shellcheck disable=SC1090,SC1091,SC2034,SC2209,SC2317,SC2329
test_main_menu_fits_terminal_widths() {
    local work state cols line width now st usage
    work=$(mktemp -d "$TEST_ROOT/menu-layout.XXXXXX") || return 1
    set +u
    . "$ROOT_DIR/trafficcop-lite.sh" || return 1
    WORK_DIR="$work"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    read_current_crontab() {
        printf '%s\n' "* * * * * $work/trafficcop-lite-monitor.sh --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"
    }
    ntc_hostname() { printf '%s' layout-test-host; }
    dashboard_month_bytes() { printf '%s' 61250000000; }
    dashboard_default_interface() { printf '%s' eth0; }
    now=$(date +%s)
    for state in normal limited grace unconfigured; do
        rm -f "$work/traffic_monitor_config.txt" "$work/current_traffic_state" "$work/monitor_health" \
            "$ENFORCEMENT_STATE_FILE"
        if [ "$state" != unconfigured ]; then
            printf '%s\n' MAIN_INTERFACE=eth0 TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly PERIOD_START_DAY=1 \
                TRAFFIC_UNIT=decimal TRAFFIC_LIMIT=500 TRAFFIC_TOLERANCE=1 LIMIT_MODE=tc LIMIT_SPEED=50 \
                TC_BOOT_GRACE_MINUTES=10 > "$work/traffic_monitor_config.txt"
            st=normal
            usage=61.25
            if [ "$state" = limited ]; then st=limited; usage=499.3; fi
            if [ "$state" = grace ]; then st=grace; fi
            printf '%s\n' "STATUS=$st" PERIOD_START=2026-11-01 PERIOD_END=2026-11-30 "USAGE=$usage" \
                TRAFFIC_LIMIT=500 LIMIT_THRESHOLD=499 UNIT=GB "UPDATED_EPOCH=$now" > "$work/current_traffic_state"
            printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$now" > "$work/monitor_health"
            if [ "$state" = grace ]; then
                printf '%s\n' MODE=grace "UNTIL_EPOCH=$((now + 600))" REASON=manual > "$ENFORCEMENT_STATE_FILE"
            fi
        fi
        for cols in 120 80 60 40; do
            COLUMNS=$cols NO_COLOR=1 TERM=dumb show_main_menu > "$work/out" 2>&1 || return 1
            if grep -q $'\033' "$work/out"; then return 1; fi
            grep -Fq '10. 卸载 NTC' "$work/out" || return 1
            while IFS= read -r line; do
                ui_measure width "$line"
                if [ "$width" -gt "$cols" ]; then
                    printf '%s @%s 列超宽（%s）：%s\n' "$state" "$cols" "$width" "$line" >&2
                    return 1
                fi
            done < "$work/out"
            if [ "$cols" -ge 80 ]; then
                grep -Eq '1\. 状态详情 +6\. 查看日志' "$work/out" || return 1
            elif [ "$cols" -le 40 ]; then
                if grep -Eq '1\. 状态详情.*6\. 查看日志' "$work/out"; then return 1; fi
            fi
        done
    done
}

run_test 'ntc rejects unknown commands before touching state and dispatches subcommands (2.0)' test_main_cli_dispatch_and_exit_codes
run_test 'uninstall asks first and removes cron only after cleanup (2.0)' test_uninstall_asks_first_and_removes_cron_after_cleanup
run_test 'stop keeps cron until TC and shutdown cleanup succeed (2.0)' test_stop_all_services_keeps_cron_until_cleanup_succeeds
run_test 'main shutdown cleanup never claims a cancellation or prompts mid-way; uninstall asks first (2.0)' test_main_shutdown_cleanup_is_truthful_and_asks_first
run_test 'update only warns when shared recovery files cannot be refreshed (2.0)' test_update_recovery_file_failure_only_warns
run_test 'update marks only changed scripts as updated (2.0)' test_update_reports_only_changed_files
run_test 'main menu fits 120/80/60/40 columns without colour escapes (2.0)' test_main_menu_fits_terminal_widths
# ── end 2.0 main ──

# ── 2.0 telegram ──
# Telegram 通知 2.0：命令行、菜单、阈值预警、日报、新周期只推一次、L3、EOF 与屏幕提示。
# 被测函数经 load_function 从脚本取出；发送、crontab、锁一律用桩，不联网、不碰 root crontab。

# 一次加载多个 Telegram 脚本里的函数。
tg20_load() {
    local name
    for name in "$@"; do
        load_function "$TELEGRAM_SCRIPT" "$name" || return 1
    done
}

# 写一份刚更新过的实时流量状态与周期文件。$1=目录 $2=已用(GB) $3=周期起始日 [$4=状态]（限额 500，阈值 499）
tg20_usage_state() {
    printf 'STATUS=%s\nPERIOD_START=%s\nPERIOD_END=2099-12-31\nUSAGE=%s\nTRAFFIC_LIMIT=500\nLIMIT_THRESHOLD=499\nUNIT=GB\nUPDATED_EPOCH=%s\n' \
        "${4:-normal}" "$3" "$2" "$(date +%s)" > "$1/usage"
    printf '%s\n' "$3" > "$1/period"
}

# 统计文件 $2 里含 $1 的行数（文件不存在算 0）。
tg20_count() {
    if [ ! -f "$2" ]; then
        printf '0'
        return 0
    fi
    grep -c -F -- "$1" "$2" || true
}

# check_and_notify 的测试环境：状态读写、新周期与预警逻辑都是真的；发送换成把正文追加到 $1/sent 的桩，
# $1/fail 存在时发送失败。
# shellcheck disable=SC2034,SC2317,SC2329
tg20_notify_env() {
    WORK_DIR="$1"
    CRON_LOG="$1/cron.log"
    USAGE_STATE_FILE="$1/usage"
    PERIOD_STATE_FILE="$1/period"
    LAST_NOTIFICATION_FILE="$1/last_notification"
    MACHINE_NAME="test-host"
    WARN_PERCENTS="80,90"
    TG_DEBUG=false
    tg20_load read_current_traffic_state read_notification_state write_notification_state \
        commit_notification_state check_threshold_warnings merge_warn_levels send_status_notification \
        send_new_cycle_notification send_throttle_warning send_throttle_lifted send_shutdown_warning \
        build_threshold_warning_message threshold_line limit_action_text traffic_period_lines \
        check_and_notify || return 1
    log_cron() { printf '%s\n' "$*" >> "$CRON_LOG"; }
    debug_log() { :; }
    telegram_send_message() {
        if [ -e "$WORK_DIR/fail" ]; then
            TG_SEND_ERROR="桩：发送失败"
            return 1
        fi
        printf '%s\n' "$1" >> "$WORK_DIR/sent"
    }
}

# 命令行：未知参数打印用法到 stderr、退出 2；--help 退出 0；未配置时 --test/--report 说明原因、退出 1，
# 不取锁、不读标准输入；无参数进入菜单，-cron 仍是定时任务入口。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_cli_arguments() {
    local work rc mode started elapsed
    work=$(mktemp -d "$TEST_ROOT/tg20-cli.XXXXXX") || return 1
    grep -Fqx 'SCRIPT_VERSION="2.0.0"' "$TELEGRAM_SCRIPT" || return 1
    # 顶层变量不随 load_function 加载；用法里要显示版本号（set -u 下缺了它整段用法都打不出来）。
    SCRIPT_VERSION=2.0.0
    tg20_load main telegram_usage || return 1
    debug_log() { :; }
    log_cron() { :; }
    check_runtime_dependencies() { printf 'deps %s\n' "$1" >> "$work/calls"; }
    check_running() { printf '%s\n' lock >> "$work/calls"; }
    run_with_telegram_lock() { printf 'locked %s\n' "$*" >> "$work/calls"; }
    telegram_menu() { printf '%s\n' menu >> "$work/calls"; }
    check_and_notify() { printf '%s\n' notify >> "$work/calls"; }
    check_monitor_health() { :; }
    run_cron_daily_report() { :; }
    read_config() { TG_CONFIG_ERROR="还没有配置"; return 1; }

    for mode in --bogus -x status; do
        rc=0
        main "$mode" > "$work/out" 2> "$work/err" || rc=$?
        [ "$rc" = 2 ] || return 1
        [ ! -s "$work/out" ] || return 1
        grep -Fq '未知参数' "$work/err" || return 1
        grep -Fq -- '--report' "$work/err" || return 1
    done
    rc=0
    main --test extra > /dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || return 1
    rc=0
    main '' > /dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || return 1
    assert_absent "$work/calls" || return 1

    main --help > "$work/out" || return 1
    grep -Fq -- '--test' "$work/out" || return 1
    grep -Fq 'v2.0.0' "$work/out" || return 1
    main -h > /dev/null || return 1

    # 未配置：说明原因、退出 1；标准输入一直不关闭也立刻返回（说明没有读输入、没有等确认）。
    for mode in --test --report; do
        rc=0
        started=$(date +%s%N)
        main "$mode" < <(sleep 3) > "$work/out" 2> "$work/err" || rc=$?
        elapsed=$(( ($(date +%s%N) - started) / 1000000 ))
        [ "$rc" = 1 ] || return 1
        [ "$elapsed" -lt 2000 ] || return 1
        grep -Fq '还没有配置' "$work/err" || return 1
        grep -Fq '「Telegram 通知」' "$work/err" || return 1
    done
    ! grep -Fq locked "$work/calls" || return 1

    # 已配置：在 Telegram 锁里发测试消息 / 立即发日报。
    read_config() { TG_DISABLED=false; return 0; }
    main --test > /dev/null || return 1
    main --report > /dev/null || return 1
    grep -Fxq 'locked send_test_message' "$work/calls" || return 1
    grep -Fxq 'locked send_report_now' "$work/calls" || return 1
    grep -Fxq 'deps cli' "$work/calls" || return 1
    # 无参数进入菜单；-cron 取锁后检查。
    main > /dev/null || return 1
    grep -Fxq menu "$work/calls" || return 1
    grep -Fxq 'deps interactive' "$work/calls" || return 1
    main -cron > /dev/null || return 1
    grep -Fxq lock "$work/calls" || return 1
    grep -Fxq notify "$work/calls" || return 1
    grep -Fxq 'deps cron' "$work/calls"
}

# 每行显示宽度不超过 $2 列（按显示列数计，中文占 2 列）。
tg20_lines_fit() {
    local line w
    while IFS= read -r line; do
        ui_measure w "$line"
        [ "$w" -le "$2" ] || return 1
    done <<< "$1"
}

# 菜单版式：非终端（NO_COLOR）下没有控制序列、80 列不超宽；Token/Chat ID 只显示遮挡后的值；分组与「0. 返回」。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_menu_layout_no_color() {
    local out
    tg20_load telegram_menu_render warn_percents_label || return 1
    BOT_TOKEN='123456789:AAHsecretsecretsecret'
    CHAT_ID='-1001234567890'
    MACHINE_NAME='my-vps'
    DAILY_REPORT_TIME=08:00
    REPORT_TIMEZONE=Asia/Shanghai
    WARN_PERCENTS=80,90
    TG_DISABLED=false
    TG_WARN_INVALID=''
    TG_CRON_NOTE=''
    TG_CRON_FIXED=false
    TG_TRAFFIC_READY=true
    TG_CONFIG_ERROR=''

    out=$(NO_COLOR=1 COLUMNS=80 telegram_menu_render true < /dev/null 2>/dev/null) || return 1
    ! grep -q "$(printf '\033')" <<< "$out" || return 1
    grep -Fq 'Telegram 通知 · 已启用，每日 08:00（Asia/Shanghai）发送日报' <<< "$out" || return 1
    grep -Fq 'Token 1234…cret · Chat ID -100…7890' <<< "$out" || return 1
    ! grep -Fq 'AAHsecret' <<< "$out" || return 1
    ! grep -Fq '1001234567890' <<< "$out" || return 1
    grep -Fq '80%、90%' <<< "$out" || return 1
    for line in '   设置' '   操作' ' 1. 设置机器人与机器名' ' 2. 每日报告时间与时区' ' 3. 阈值预警档位' \
        ' 4. 发送测试消息' ' 5. 立即发送一次日报' ' 6. 停用通知' ' 0. 返回'; do
        grep -Fq -- "$line" <<< "$out" || return 1
    done
    COLUMNS=80 tg20_lines_fit "$out" 78 || return 1

    # 停用、预警档位写坏、定时任务读不出来：标题、选项与提示都跟着变。
    TG_DISABLED=true
    TG_WARN_INVALID='95,abc'
    TG_CRON_NOTE='读不出 root crontab，无法确认定时任务是否已清除。'
    out=$(COLUMNS=80 telegram_menu_render true < /dev/null 2>/dev/null) || return 1
    grep -Fq 'Telegram 通知 · 已停用' <<< "$out" || return 1
    grep -Fq ' 6. 启用通知' <<< "$out" || return 1
    grep -Fq '95,abc' <<< "$out" || return 1
    grep -Fq '读不出 root crontab' <<< "$out" || return 1
    tg20_lines_fit "$out" 78 || return 1

    # 未配置：第一项引导设置，没有其他选项。
    TG_CONFIG_ERROR='还没有配置'
    out=$(COLUMNS=80 telegram_menu_render false < /dev/null 2>/dev/null) || return 1
    grep -Fq 'Telegram 通知 · 未配置' <<< "$out" || return 1
    grep -Fq ' 1. 开始设置' <<< "$out" || return 1
    ! grep -Fq ' 2. ' <<< "$out" || return 1
    grep -Fq ' 0. 返回' <<< "$out" || return 1
    tg20_lines_fit "$out" 78
}

# 菜单循环：无效输入提示后重画；EOF 返回上一级；每项都进对应入口；4、5 在 Telegram 锁里执行；
# 停用要确认（回车 = 否），y 才停用。打开时只核对一次定时任务（且只在已配置时）。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_menu_loop_and_eof() {
    local work out
    work=$(mktemp -d "$TEST_ROOT/tg20-loop.XXXXXX") || return 1
    tg20_load telegram_menu telegram_menu_render warn_percents_label toggle_notifications || return 1
    BOT_TOKEN='123456:abcdefgh'
    CHAT_ID=42
    MACHINE_NAME=node
    DAILY_REPORT_TIME=08:00
    REPORT_TIMEZONE=UTC
    WARN_PERCENTS=80,90
    TG_DISABLED=false
    read_config() {
        if [ -e "$work/configured" ]; then
            TG_CONFIG_ERROR=''
            return 0
        fi
        TG_CONFIG_ERROR='还没有配置'
        return 1
    }
    sync_telegram_cron() { printf '%s\n' sync >> "$work/calls"; }
    read_current_traffic_state() { return 0; }
    sleep() { :; }
    clear() { :; }
    run_with_telegram_lock() { printf 'locked %s\n' "$*" >> "$work/calls"; }
    initial_config() { printf '%s\n' initial >> "$work/calls"; : > "$work/configured"; }
    configure_bot() { printf '%s\n' bot >> "$work/calls"; }
    edit_report_schedule() { printf '%s\n' schedule >> "$work/calls"; }
    edit_warn_percents() { printf '%s\n' warn >> "$work/calls"; }

    # 未配置：2 无效 → 提示；1 → 开始设置（之后是完整菜单）；0 → 返回。
    out=$(printf '%s\n' 2 1 '' 0 | telegram_menu 2>&1) || return 1
    grep -Fq '无效选择' <<< "$out" || return 1
    grep -Fxq initial "$work/calls" || return 1
    grep -Fq ' 6. 停用通知' <<< "$out" || return 1
    ! grep -Fxq sync "$work/calls" || return 1

    # 已配置：1–6 依次执行，停用先回车（取消）再 y；最后 EOF 返回。
    rm -f "$work/calls"
    out=$(printf '%s\n' 1 '' 2 '' 3 '' 4 '' 5 '' 6 '' '' 6 y '' | telegram_menu 2>&1) || return 1
    [ "$(tg20_count sync "$work/calls")" = 1 ] || return 1
    grep -Fxq bot "$work/calls" || return 1
    grep -Fxq schedule "$work/calls" || return 1
    grep -Fxq warn "$work/calls" || return 1
    grep -Fxq 'locked send_test_message' "$work/calls" || return 1
    grep -Fxq 'locked send_report_now' "$work/calls" || return 1
    [ "$(tg20_count 'locked disable_telegram_notifications' "$work/calls")" = 1 ] || return 1
    grep -Fq '已取消，通知保持启用' <<< "$out" || return 1

    # 输入直接结束：返回 0，不再等回车。
    out=$(telegram_menu < /dev/null 2>&1) || return 1
    [ "$(grep -c '0. 返回' <<< "$out")" = 1 ]
}

# 打开菜单不再打印整个 root crontab：条目正确时不改写，缺失时只补一次（保留其他任务），停用时清掉残留。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_menu_open_keeps_crontab_quiet() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg20-sync.XXXXXX") || return 1
    WORK_DIR="$work"
    CRON_LOG="$work/cron.log"
    SCRIPT_PATH=/etc/trafficcop-lite/trafficcop-lite-telegram.sh
    tg20_load sync_telegram_cron telegram_cron_state telegram_cron_entry setup_cron remove_telegram_cron \
        read_root_crontab_locked || return 1
    acquire_root_crontab_lock() { return 0; }
    release_root_crontab_lock() { :; }
    read_current_crontab() { cat "$work/crontab"; }
    crontab() { cat "$1" > "$work/crontab"; printf '%s\n' write >> "$work/writes"; }
    log_cron() { :; }
    printf '%s\n' '17 3 * * * /usr/local/bin/unrelated-backup' \
        "* * * * * $SCRIPT_PATH -cron >/dev/null 2>&1 # TrafficCop-Lite Telegram" > "$work/crontab"

    # 条目正确：不改写，也不输出任何内容。
    TG_DISABLED=false
    sync_telegram_cron > "$work/out" 2>&1 || return 1
    [ ! -s "$work/out" ] || return 1
    [ -z "$TG_CRON_NOTE" ] || return 1
    [ "$TG_CRON_FIXED" = false ] || return 1
    assert_absent "$work/writes" || return 1
    # 条目缺失：补一次，其他任务保留；再打开不重复改写。
    printf '%s\n' '17 3 * * * /usr/local/bin/unrelated-backup' > "$work/crontab"
    sync_telegram_cron > "$work/out" 2>&1 || return 1
    [ ! -s "$work/out" ] || return 1
    [ "$TG_CRON_FIXED" = true ] || return 1
    [ "$(tg20_count write "$work/writes")" = 1 ] || return 1
    grep -Fqx '17 3 * * * /usr/local/bin/unrelated-backup' "$work/crontab" || return 1
    [ "$(tg20_count 'TrafficCop-Lite Telegram' "$work/crontab")" = 1 ] || return 1
    sync_telegram_cron > "$work/out" 2>&1 || return 1
    [ "$(tg20_count write "$work/writes")" = 1 ] || return 1
    # 停用：清掉残留条目，其他任务保留。
    TG_DISABLED=true
    sync_telegram_cron > "$work/out" 2>&1 || return 1
    [ ! -s "$work/out" ] || return 1
    ! grep -Fq 'TrafficCop-Lite Telegram' "$work/crontab" || return 1
    grep -Fqx '17 3 * * * /usr/local/bin/unrelated-backup' "$work/crontab"
}

# L3：setup_cron 的结果只取决于写入本身（1.2.x 末尾为显示而重读 crontab，重读失败就把成功的写入报成失败）；
# 写入的条目与 telegram_cron_state 认定的格式一致。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_setup_cron_ignores_display_reread() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg20-l3.XXXXXX") || return 1
    WORK_DIR="$work"
    CRON_LOG="$work/cron.log"
    SCRIPT_PATH=/etc/trafficcop-lite/trafficcop-lite-telegram.sh
    tg20_load setup_cron telegram_cron_entry telegram_cron_state read_root_crontab_locked || return 1
    acquire_root_crontab_lock() { return 0; }
    release_root_crontab_lock() { :; }
    # 写入前那次读取成功，之后的读取一律失败。
    read_current_crontab() {
        [ ! -e "$work/read-once" ] || return 1
        : > "$work/read-once"
        printf '%s\n' '17 3 * * * /usr/local/bin/unrelated-backup'
    }
    crontab() { cat "$1" > "$work/crontab"; }

    setup_cron > "$work/out" 2>&1 || return 1
    [ ! -s "$work/out" ] || return 1
    grep -Fqx "$(telegram_cron_entry)" "$work/crontab" || return 1
    grep -Fqx '17 3 * * * /usr/local/bin/unrelated-backup' "$work/crontab" || return 1
    read_current_crontab() { cat "$work/crontab"; }
    [ "$(telegram_cron_state)" = ok ] || return 1
    telegram_cron_entry >> "$work/crontab"
    printf '\n' >> "$work/crontab"
    [ "$(telegram_cron_state)" = drift ] || return 1
    printf '%s\n' "* * * * * $SCRIPT_PATH -cron # 手工改过" > "$work/crontab"
    [ "$(telegram_cron_state)" = drift ] || return 1
    : > "$work/crontab"
    [ "$(telegram_cron_state)" = missing ] || return 1
    read_current_crontab() { return 1; }
    [ "$(telegram_cron_state)" = unreadable ]
}

# 预警档位配置：输入规范化；1.2.x 的配置没有该键时取默认 80,90；off/空为关闭；写回带新键；
# 手工写坏时按默认执行并留给菜单提示，配置本身仍可用。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_warn_percents_config_compat() {
    local work value
    work=$(mktemp -d "$TEST_ROOT/tg20-warncfg.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    tg20_load normalize_warn_percents warn_percents_label read_config write_config write_config_value \
        decode_legacy_config_value || return 1
    is_valid_timezone() { return 0; }

    [ "$(normalize_warn_percents ' 90, 80，80、85 ')" = 80,85,90 ] || return 1
    [ "$(normalize_warn_percents 05)" = 5 ] || return 1
    [ "$(normalize_warn_percents OFF)" = off ] || return 1
    [ "$(normalize_warn_percents '')" = off ] || return 1
    for value in 0 100 abc '80,x' '-5' '8.5'; do
        if normalize_warn_percents "$value" > /dev/null; then return 1; fi
    done
    [ "$(warn_percents_label 80,90)" = '80%、90%' ] || return 1
    [ "$(warn_percents_label off)" = '已关闭' ] || return 1

    printf '%s\n' CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc CHAT_ID=42 DAILY_REPORT_TIME=08:00 \
        REPORT_TIMEZONE=UTC MACHINE_NAME=node TG_DISABLED=false > "$CONFIG_FILE"
    read_config || return 1
    [ "$WARN_PERCENTS" = 80,90 ] || return 1
    [ -z "$TG_WARN_INVALID" ] || return 1
    WARN_PERCENTS=70,95
    write_config || return 1
    grep -Fxq 'WARN_PERCENTS=70,95' "$CONFIG_FILE" || return 1
    read_config || return 1
    [ "$WARN_PERCENTS" = 70,95 ] || return 1
    [ "$BOT_TOKEN" = 123:abc ] || return 1
    sed -i 's/^WARN_PERCENTS=.*/WARN_PERCENTS=off/' "$CONFIG_FILE"
    read_config || return 1
    [ "$WARN_PERCENTS" = off ] || return 1
    sed -i 's/^WARN_PERCENTS=.*/WARN_PERCENTS=/' "$CONFIG_FILE"
    read_config || return 1
    [ "$WARN_PERCENTS" = off ] || return 1
    sed -i 's/^WARN_PERCENTS=.*/WARN_PERCENTS=95,abc/' "$CONFIG_FILE"
    read_config || return 1
    [ "$WARN_PERCENTS" = 80,90 ] || return 1
    [ "$TG_WARN_INVALID" = 95,abc ]
}

# 阈值预警：每期每档只发一次；同时越过多档只发最高的一档；新周期重新计；关闭后不发；
# 1.2.x 的状态文件（没有 WARN_* 键）视为本期未发；发送失败下次重试；状态文件写不进去时不发。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_threshold_warnings_once_per_period() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg20-warn.XXXXXX") || return 1
    tg20_notify_env "$work" || return 1

    # 79%：不到最低一档；第一次运行写成新格式并记下周期。
    tg20_usage_state "$work" 395 2026-09-01
    check_and_notify || return 1
    assert_absent "$work/sent" || return 1
    grep -Fxq 'WARN_PERIOD=2026-09-01' "$LAST_NOTIFICATION_FILE" || return 1
    grep -Fxq 'CYCLE_EVENT=2026-09-01' "$LAST_NOTIFICATION_FILE" || return 1
    # 80.5%：发一次 80% 预警，之后每分钟再跑都不重复。
    tg20_usage_state "$work" 402.5 2026-09-01
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '流量预警' "$work/sent")" = 1 ] || return 1
    grep -Fq '本期用量已达到 80%' "$work/sent" || return 1
    grep -Fxq 'WARN_SENT=80' "$LAST_NOTIFICATION_FILE" || return 1
    # 95%：只补 90% 一档。
    tg20_usage_state "$work" 475 2026-09-01
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '流量预警' "$work/sent")" = 2 ] || return 1
    grep -Fq '本期用量已达到 90%' "$work/sent" || return 1
    grep -Fxq 'WARN_SENT=80,90' "$LAST_NOTIFICATION_FILE" || return 1

    # 新周期一开始就 92%（同时越过两档）：新周期通知 + 只发 90% 一条，80 一并记为已发。
    : > "$work/sent"
    tg20_usage_state "$work" 460 2026-10-01
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '新周期开始' "$work/sent")" = 1 ] || return 1
    [ "$(tg20_count '流量预警' "$work/sent")" = 1 ] || return 1
    grep -Fq '本期用量已达到 90%' "$work/sent" || return 1
    ! grep -Fq '本期用量已达到 80%' "$work/sent" || return 1
    grep -Fxq 'WARN_PERIOD=2026-10-01' "$LAST_NOTIFICATION_FILE" || return 1
    grep -Fxq 'WARN_SENT=80,90' "$LAST_NOTIFICATION_FILE" || return 1

    # 发送失败：不记为已发，下次运行重试；恢复后只发一次。
    : > "$work/sent"
    tg20_usage_state "$work" 10 2026-11-01
    check_and_notify || return 1
    tg20_usage_state "$work" 405 2026-11-01
    : > "$work/fail"
    if check_and_notify; then return 1; fi
    grep -Fxq 'WARN_SENT=' "$LAST_NOTIFICATION_FILE" || return 1
    rm -f "$work/fail"
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '流量预警' "$work/sent")" = 1 ] || return 1

    # 状态文件写不进去：这一轮不发（宁可不发，也不会每分钟重复推送）。
    tg20_usage_state "$work" 455 2026-11-01
    : > "$work/sent"
    (
        write_notification_state() { return 1; }
        if check_and_notify; then exit 1; fi
        [ ! -s "$work/sent" ]
    ) || return 1

    # 关闭预警：一条都不发。
    WARN_PERCENTS=off
    rm -f "$LAST_NOTIFICATION_FILE" "$work/sent"
    tg20_usage_state "$work" 495 2026-11-01
    check_and_notify || return 1
    check_and_notify || return 1
    assert_absent "$work/sent" || return 1

    # 1.2.x 的状态文件：没有 WARN_* 键，视为本期还没发过，只发最高一档一次。
    WARN_PERCENTS=80,90
    printf 'STATUS=正常\nCYCLE_EVENT=2026-11-01\nUPDATED_AT=2026-11-02 10:00:00\n' > "$LAST_NOTIFICATION_FILE"
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '流量预警' "$work/sent")" = 1 ] || return 1
    grep -Fq '本期用量已达到 90%' "$work/sent"
}

# 新周期开始每期只推一次（上游 TrafficCop 会重复推送）：记录过上一个周期才推；状态文件没有周期记录
# （先配 Telegram 后配监控、1.x 单行旧格式）时只记下不推；发送失败撤回记录重试；状态写不进去时不发。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_new_cycle_notified_once() {
    local work
    work=$(mktemp -d "$TEST_ROOT/tg20-cycle.XXXXXX") || return 1
    tg20_notify_env "$work" || return 1
    WARN_PERCENTS=off
    tg20_usage_state "$work" 1 2026-11-01

    printf 'STATUS=正常\nCYCLE_EVENT=2026-10-01\n' > "$LAST_NOTIFICATION_FILE"
    check_and_notify || return 1
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '新周期开始' "$work/sent")" = 1 ] || return 1
    grep -Fxq 'CYCLE_EVENT=2026-11-01' "$LAST_NOTIFICATION_FILE" || return 1

    # 状态文件早于周期文件（先配好 Telegram，监控后来才第一次写周期）：只记下周期，不推送。
    rm -f "$work/sent"
    printf 'STATUS=\nCYCLE_EVENT=\n' > "$LAST_NOTIFICATION_FILE"
    check_and_notify || return 1
    assert_absent "$work/sent" || return 1
    grep -Fxq 'CYCLE_EVENT=2026-11-01' "$LAST_NOTIFICATION_FILE" || return 1

    # 更早的单行旧格式：不推送，并升级成键值格式。
    printf '%s\n' '2026-10-15 08:00:00 正常' > "$LAST_NOTIFICATION_FILE"
    check_and_notify || return 1
    assert_absent "$work/sent" || return 1
    grep -Fxq 'CYCLE_EVENT=2026-11-01' "$LAST_NOTIFICATION_FILE" || return 1
    grep -Fxq 'STATUS=正常' "$LAST_NOTIFICATION_FILE" || return 1

    # 发送失败：撤回记录，下次运行重试；成功后不再重复。
    printf 'STATUS=正常\nCYCLE_EVENT=2026-10-01\n' > "$LAST_NOTIFICATION_FILE"
    : > "$work/fail"
    if check_and_notify; then return 1; fi
    grep -Fxq 'CYCLE_EVENT=2026-10-01' "$LAST_NOTIFICATION_FILE" || return 1
    rm -f "$work/fail"
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '新周期开始' "$work/sent")" = 1 ] || return 1

    # 状态文件写不进去：不发（1.2.x 先发后写，写失败后每分钟重复推送）。
    printf 'STATUS=正常\nCYCLE_EVENT=2026-10-01\n' > "$LAST_NOTIFICATION_FILE"
    rm -f "$work/sent"
    (
        write_notification_state() { return 1; }
        if check_and_notify; then exit 1; fi
        [ ! -e "$work/sent" ]
    )
}

# B0：非 root 也能看帮助（单独的 --help / -h），其余用法仍要求 root。
# 只取脚本开头的 root 检查片段运行，id 换成桩，不执行真实入口。
test_tg20_help_without_root() {
    local work rc mode
    work=$(mktemp -d "$TEST_ROOT/tg20-root.XXXXXX") || return 1
    {
        printf '%s\n' 'id() { echo 1000; }'
        awk 'NR > 1 { print } /^fi$/ { exit }' "$TELEGRAM_SCRIPT"
        printf '%s\n' 'echo passed'
    } > "$work/guard.sh"
    grep -Fq 'id -u' "$work/guard.sh" || return 1
    for mode in --help -h; do
        bash "$work/guard.sh" "$mode" > "$work/out" 2> "$work/err" || return 1
        grep -Fxq passed "$work/out" || return 1
        [ ! -s "$work/err" ] || return 1
    done
    for mode in --test --report -cron; do
        rc=0
        bash "$work/guard.sh" "$mode" > "$work/out" 2> "$work/err" || rc=$?
        [ "$rc" = 1 ] || return 1
        [ ! -s "$work/out" ] || return 1
        grep -Fq '请使用 root 权限运行此脚本' "$work/err" || return 1
    done
    rc=0
    bash "$work/guard.sh" > /dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ]
}

# B1：缺依赖时说明缺什么、去哪里装（用名字，不写死主菜单编号）；定时任务与 --test/--report（cli）绝不安装、
# 不读输入，只有菜单（interactive）且标准输入是终端时才提议安装。终端部分用 script 开伪终端，
# 入口文件要求属主为 root，所以只在 root 下检查；没有可用的伪终端时只验证非终端部分。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_runtime_dependencies_never_install_outside_menu() {
    local work mode rc
    work=$(mktemp -d "$TEST_ROOT/tg20-deps.XXXXXX") || return 1
    WORK_DIR="$work"
    tg20_load check_runtime_dependencies || return 1
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = curl ]; then
            return 1
        fi
        builtin command "$@"
    }
    printf '%s\n' '# BEGIN MANAGED DEPENDENCIES' > "$work/trafficcop-lite.sh"
    chmod 600 "$work/trafficcop-lite.sh"

    for mode in cron cli interactive; do
        rc=0
        check_runtime_dependencies "$mode" < /dev/null > "$work/out" 2> "$work/err" || rc=$?
        [ "$rc" = 1 ] || return 1
        grep -Fq '缺少运行依赖：curl' "$work/err" || return 1
        grep -Fq '「依赖管理」' "$work/err" || return 1
        ! grep -Eq '主菜单 *[0-9]|选择 *[0-9]' "$work/out" "$work/err" || return 1
    done

    [ "$EUID" -eq 0 ] && builtin command -v script > /dev/null 2>&1 || return 0
    {
        printf 'WORK_DIR=%q\n' "$work"
        printf '%s\n' "RED='' NC='' DIM=''"
        declare -f check_runtime_dependencies ui_err ui_note command
        cat <<'EOS'
bash() { printf '%s\n' "$mode" >> "$WORK_DIR/installs"; }
[ ! -t 0 ] || printf '%s\n' tty >> "$WORK_DIR/installs"
for mode in cli cron interactive; do
    check_runtime_dependencies "$mode" > /dev/null 2>&1
done
EOS
    } > "$work/pty.sh"
    script -qec "bash $(printf '%q' "$work/pty.sh")" /dev/null < /dev/null > /dev/null 2>&1
    grep -Fxq tty "$work/installs" 2>/dev/null || return 0
    [ "$(cat "$work/installs")" = "$(printf '%s\n' tty interactive)" ]
}

# B1：每分钟的例行运行不写流水账：没有事件时 cron 日志、标准输出、标准错误都为空（1.2.x 每分钟写十来行），
# 停用时同样安静；配置不可用时只记一行原因。入口也不再打印版本横幅和工作目录。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_routine_cron_run_is_quiet() {
    local work rc
    work=$(mktemp -d "$TEST_ROOT/tg20-quiet.XXXXXX") || return 1
    ! grep -Eq 'migrate_files|使用独立工作目录|当前版本：' "$TELEGRAM_SCRIPT" || return 1
    tg20_notify_env "$work" || return 1
    CONFIG_FILE="$work/config"
    TG_LOCK_FILE="$work/tg.lock"
    CRON_LOG_MAX_LINES=100
    # 换回真实的 log_cron / debug_log，检查的就是它们写了什么。
    tg20_load main check_running trim_log_file log_cron debug_log read_config decode_legacy_config_value || return 1
    is_valid_timezone() { return 0; }
    check_runtime_dependencies() { return 0; }
    check_monitor_health() { return 0; }
    run_cron_daily_report() { return 0; }
    printf '%s\n' CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc CHAT_ID=42 DAILY_REPORT_TIME=08:00 \
        REPORT_TIMEZONE=UTC MACHINE_NAME=node TG_DISABLED=false WARN_PERCENTS=80,90 > "$CONFIG_FILE"
    tg20_usage_state "$work" 10 2026-11-01
    printf 'STATUS=正常\nCYCLE_EVENT=2026-11-01\nWARN_PERIOD=2026-11-01\nWARN_SENT=\n' > "$LAST_NOTIFICATION_FILE"

    ( main -cron ) > "$work/out" 2> "$work/err" || return 1
    [ ! -s "$work/out" ] && [ ! -s "$work/err" ] && [ ! -s "$CRON_LOG" ] || return 1
    assert_absent "$work/sent" || return 1
    sed -i 's/^TG_DISABLED=.*/TG_DISABLED=true/' "$CONFIG_FILE"
    ( main -cron ) > "$work/out" 2> "$work/err" || return 1
    [ ! -s "$work/out" ] && [ ! -s "$work/err" ] && [ ! -s "$CRON_LOG" ] || return 1
    # 配置不可用：返回 1，日志里只有一行原因。
    rm -f "$CONFIG_FILE"
    rc=0
    ( main -cron ) > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] || return 1
    [ "$(wc -l < "$CRON_LOG")" = 1 ] || return 1
    grep -Fq '配置不可用（还没有配置）' "$CRON_LOG"
}

# 把 $2… 写成配置文件，read_config 必须拒绝，且 TG_CONFIG_ERROR 以 $1 开头。
tg20_config_rejected() {
    local expected="$1"
    shift
    printf '%s\n' "$@" > "$CONFIG_FILE"
    if read_config; then
        return 1
    fi
    [[ "${TG_CONFIG_ERROR:-}" == "$expected"* ]]
}

# B2：配置不可用时 read_config 说明原因（TG_CONFIG_ERROR），菜单、--test/--report 与 cron 日志都用它；
# 菜单「未配置」页如实显示原因，真没配置过时只有引导。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_config_error_reasons() {
    local work out
    work=$(mktemp -d "$TEST_ROOT/tg20-cfgerr.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    tg20_load read_config decode_legacy_config_value telegram_menu_render || return 1
    is_valid_timezone() { [ "$1" = UTC ]; }

    if read_config; then return 1; fi
    [ "${TG_CONFIG_ERROR:-}" = 还没有配置 ] || return 1
    tg20_config_rejected 配置不完整 CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc DAILY_REPORT_TIME=08:00 \
        REPORT_TIMEZONE=UTC MACHINE_NAME=node || return 1
    tg20_config_rejected 每日报告时间格式无效 CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc CHAT_ID=42 \
        DAILY_REPORT_TIME=25:00 REPORT_TIMEZONE=UTC MACHINE_NAME=node || return 1
    tg20_config_rejected 报告时区无效 CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc CHAT_ID=42 \
        DAILY_REPORT_TIME=08:00 REPORT_TIMEZONE=Mars/Base MACHINE_NAME=node || return 1
    tg20_config_rejected 自动通知开关的值无效 CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc CHAT_ID=42 \
        DAILY_REPORT_TIME=08:00 REPORT_TIMEZONE=UTC MACHINE_NAME=node TG_DISABLED=maybe || return 1
    tg20_config_rejected 不支持的配置格式 CONFIG_FORMAT=plain-v9 BOT_TOKEN=123:abc || return 1
    out=$(COLUMNS=80 telegram_menu_render false < /dev/null 2>&1) || return 1
    grep -Fq '现有配置不能用（不支持的配置格式：plain-v9）' <<< "$out" || return 1
    TG_CONFIG_ERROR=还没有配置
    out=$(COLUMNS=80 telegram_menu_render false < /dev/null 2>&1) || return 1
    grep -Fq ' 1. 开始设置' <<< "$out" || return 1
    ! grep -Fq '不能用' <<< "$out"
}

# B4：发送失败时 TG_SEND_ERROR 说明原因（DNS、网络、Token/Chat ID、超时、证书、意外响应），成功时清空；
# 测试消息带上当前的日报时间与预警档位；发送失败时如实说明原因（标准错误）、返回 1、不打印成功。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_send_failures_are_explained() {
    local work pair rc out
    work=$(mktemp -d "$TEST_ROOT/tg20-send.XXXXXX") || return 1
    BOT_TOKEN='123456:abc'
    CHAT_ID=42
    MACHINE_NAME=node
    DAILY_REPORT_TIME=08:00
    REPORT_TIMEZONE=UTC
    WARN_PERCENTS=80,90
    TG_DISABLED=false
    CRON_LOG="$work/cron.log"
    tg20_load telegram_send_message build_test_message send_test_message warn_percents_label || return 1
    log_cron() { printf '%s\n' "$*" >> "$CRON_LOG"; }
    # 桩：读掉标准输入里的 curl 配置；$work/rc 存在时按其中的退出码失败，否则输出 $work/response。
    curl() {
        cat > /dev/null
        if [ -e "$work/rc" ]; then
            return "$(cat "$work/rc")"
        fi
        cat "$work/response"
    }

    for pair in '6:DNS' '7:连不上' '28:超时' '60:证书' '99:错误码 99'; do
        printf '%s\n' "${pair%%:*}" > "$work/rc"
        if telegram_send_message hi; then return 1; fi
        [[ "${TG_SEND_ERROR:-}" == *"${pair#*:}"* ]] || return 1
    done
    rm -f "$work/rc"
    # 不用 curl -f：按 HTTP 状态码区分失败原因，并附上 Telegram 的说明（限流不会再被说成 Token 不对）。
    # 响应正文之后的最后一行是 curl -w 输出的状态码。
    for pair in '401|Unauthorized|Bot Token 无效' '404|Not Found|Bot Token 无效' \
        '400|Bad Request: chat not found|Chat ID 不对' '403|Forbidden: bot was blocked by the user|无权' \
        '429|Too Many Requests: retry after 5|限流' '502|Bad Gateway|暂时不可用（HTTP 502）'; do
        IFS='|' read -r rc out _ <<< "$pair"
        printf '{"ok":false,"error_code":%s,"description":"%s"}\n%s' "$rc" "$out" "$rc" > "$work/response"
        if telegram_send_message hi; then return 1; fi
        [[ "${TG_SEND_ERROR:-}" == *"${pair##*|}"* && "${TG_SEND_ERROR:-}" == *"（Telegram：$out）"* ]] || return 1
    done
    [[ "$TG_SEND_ERROR" != *Token* ]] || return 1
    printf '%s\n%s' '{"ok":false,"description":"Bad Request"}' 200 > "$work/response"
    if telegram_send_message hi; then return 1; fi
    [[ "${TG_SEND_ERROR:-}" == *意外的响应* ]] || return 1
    printf '%s\n%s' '{"ok":true,"result":{}}' 200 > "$work/response"
    telegram_send_message hi || return 1
    [ -z "$TG_SEND_ERROR" ] || return 1

    out=$(build_test_message)
    [[ "$out" == *'[node]测试消息'* && "$out" == *'每日报告：08:00（UTC）'* && "$out" == *'阈值预警：80%、90%'* ]] || return 1
    TG_DISABLED=true
    out=$(build_test_message)
    [[ "$out" == *'自动通知：已停用'* && "$out" != *每日报告* ]] || return 1
    TG_DISABLED=false

    printf '%s\n%s' '{"ok":false,"error_code":401,"description":"Unauthorized"}' 401 > "$work/response"
    rc=0
    send_test_message > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] || return 1
    grep -Fq '测试消息发送失败：Bot Token 无效' "$work/err" || return 1
    ! grep -Fq '已发送' "$work/out" || return 1
    grep -Fq '测试消息发送失败' "$CRON_LOG" || return 1
    printf '%s\n%s' '{"ok":true,"result":{}}' 200 > "$work/response"
    send_test_message > "$work/out" 2> "$work/err" || return 1
    grep -Fq '测试消息已发送' "$work/out"
}

# B5：限速、解除、关机通知同样先记状态再发送：每次变化只推一次；发送失败撤回记录、下次重试；
# 状态文件写不进去时不发（1.2.x 先发后写，写失败后每分钟重复推送）；屏幕上不打印「检查完成」之类的提示。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_status_notifications_record_before_send() {
    local work out
    work=$(mktemp -d "$TEST_ROOT/tg20-status.XXXXXX") || return 1
    tg20_notify_env "$work" || return 1
    WARN_PERCENTS=off
    printf 'STATUS=正常\nCYCLE_EVENT=2026-11-01\nWARN_PERIOD=\nWARN_SENT=\n' > "$LAST_NOTIFICATION_FILE"

    tg20_usage_state "$work" 499 2026-11-01 limited
    out=$(check_and_notify 2>&1) || return 1
    [ -z "$out" ] || return 1
    check_and_notify || return 1
    [ "$(tg20_count '限速警告' "$work/sent")" = 1 ] || return 1
    grep -Fxq 'STATUS=限速' "$LAST_NOTIFICATION_FILE" || return 1

    # 解除：发送失败时撤回为「限速」，下次重试；成功后不再重复。
    tg20_usage_state "$work" 120 2026-11-01 normal
    : > "$work/fail"
    if check_and_notify; then return 1; fi
    grep -Fxq 'STATUS=限速' "$LAST_NOTIFICATION_FILE" || return 1
    grep -Fq '限速解除通知发送失败' "$CRON_LOG" || return 1
    rm -f "$work/fail"
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '限速解除' "$work/sent")" = 1 ] || return 1
    grep -Fxq 'STATUS=正常' "$LAST_NOTIFICATION_FILE" || return 1

    # 状态文件写不进去：这一轮不发关机通知；恢复后只发一次。
    tg20_usage_state "$work" 499 2026-11-01 shutdown
    : > "$work/sent"
    (
        write_notification_state() { return 1; }
        if check_and_notify; then exit 1; fi
        [ ! -s "$work/sent" ]
    ) || return 1
    check_and_notify || return 1
    check_and_notify || return 1
    [ "$(tg20_count '关机警告' "$work/sent")" = 1 ]
}

# B6：启用 / 停用如实报告每一步：定时任务写不进去时不改配置、仍是停用；配置写不进去时撤销刚建的定时任务，
# 撤销也失败时照实说明（1.2.x 不管撤销成没成功都说「已清理」）；停用时配置写不进去说明仍在运行，
# 定时任务删不掉时说明残留会自动跳过。成功与失败都记操作日志。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_enable_disable_report_truthfully() {
    local work rc
    work=$(mktemp -d "$TEST_ROOT/tg20-toggle.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    tg20_load enable_telegram_notifications disable_telegram_notifications || return 1
    setup_cron() { printf '%s\n' setup >> "$work/calls"; [ ! -e "$work/setup-fails" ]; }
    remove_telegram_cron() { printf '%s\n' remove >> "$work/calls"; [ ! -e "$work/remove-fails" ]; }
    write_config() { printf 'write %s\n' "$TG_DISABLED" >> "$work/calls"; [ ! -e "$work/write-fails" ]; }

    TG_DISABLED=true
    : > "$work/setup-fails"
    rc=0
    enable_telegram_notifications > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$TG_DISABLED" = true ] || return 1
    [ "$(cat "$work/calls")" = setup ] || return 1
    grep -Fq '仍保持停用' "$work/err" || return 1
    [ ! -s "$work/out" ] || return 1

    rm -f "$work/setup-fails" "$work/calls"
    : > "$work/write-fails"
    rc=0
    enable_telegram_notifications > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$TG_DISABLED" = true ] || return 1
    [ "$(cat "$work/calls")" = "$(printf '%s\n' setup 'write false' remove)" ] || return 1
    grep -Fq '已撤销刚建的定时任务' "$work/err" || return 1

    rm -f "$work/calls"
    : > "$work/remove-fails"
    rc=0
    enable_telegram_notifications > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$TG_DISABLED" = true ] || return 1
    grep -Fq '没能撤销' "$work/err" || return 1
    ! grep -Fq '已撤销' "$work/err" || return 1

    rm -f "$work/remove-fails" "$work/write-fails" "$work/calls"
    enable_telegram_notifications > "$work/out" 2> "$work/err" || return 1
    [ "$TG_DISABLED" = false ] || return 1
    grep -Fq '自动通知已启用' "$work/out" || return 1
    grep -Fq 'EVENT=telegram-enable RESULT=failure' "$work/operations.log" || return 1
    grep -Fq 'EVENT=telegram-enable RESULT=success' "$work/operations.log" || return 1

    : > "$work/write-fails"
    rm -f "$work/calls"
    rc=0
    disable_telegram_notifications > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$TG_DISABLED" = false ] || return 1
    [ "$(cat "$work/calls")" = 'write true' ] || return 1
    grep -Fq '通知仍在运行' "$work/err" || return 1

    rm -f "$work/write-fails"
    : > "$work/remove-fails"
    rc=0
    disable_telegram_notifications > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$TG_DISABLED" = true ] || return 1
    grep -Fq '定时任务没能删除' "$work/out" || return 1
    ! grep -Fq '自动通知已停用；' "$work/out" || return 1

    rm -f "$work/remove-fails"
    TG_DISABLED=false
    disable_telegram_notifications > "$work/out" 2> "$work/err" || return 1
    [ "$TG_DISABLED" = true ] || return 1
    grep -Fq '自动通知已停用' "$work/out" || return 1
    grep -Fq 'EVENT=telegram-disable RESULT=success' "$work/operations.log"
}

# B3：首次设置与「设置机器人与机器名」：输入有校验，摘要只显示遮挡后的 Token/Chat ID，「保存？」确认后才写；
# 首次设置先以停用保存、在 Telegram 锁里启用定时任务，启用失败如实提示；保存后询问是否发测试消息。
# 任何一步 EOF（包括最后的确认）都不保存；写入失败时内存里的值恢复原样。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_setup_and_bot_flows_confirm_before_saving() {
    local work rc
    work=$(mktemp -d "$TEST_ROOT/tg20-setup.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    tg20_load initial_config configure_bot prompt_bot_settings prompt_report_schedule is_valid_timezone \
        warn_percents_label || return 1
    write_config() {
        printf 'write disabled=%s token=%s chat=%s name=%s time=%s zone=%s warn=%s\n' "$TG_DISABLED" "$BOT_TOKEN" \
            "$CHAT_ID" "$MACHINE_NAME" "$DAILY_REPORT_TIME" "$REPORT_TIMEZONE" "${WARN_PERCENTS:-}" >> "$work/calls"
        [ ! -e "$work/write-fails" ]
    }
    run_with_telegram_lock() { printf 'locked %s\n' "$1" >> "$work/calls"; "$@"; }
    enable_telegram_notifications() { [ ! -e "$work/enable-fails" ] || return 1; TG_DISABLED=false; }
    send_test_message() { printf '%s\n' test-message >> "$work/calls"; }
    BOT_TOKEN='' CHAT_ID='' MACHINE_NAME='' DAILY_REPORT_TIME='' REPORT_TIMEZONE='' TG_DISABLED=false
    unset WARN_PERCENTS

    # 首次设置：格式不对会重问；机器名回车取主机名；确认后先以停用保存 → 锁内启用 → 询问并发送测试消息。
    printf '%s\n' 'not-a-token' '123456789:AAHsecretsecretsecret' 'abc' '-1001234567890' '' '8:30' UTC y y \
        > "$work/input"
    HOSTNAME=my-vps initial_config < "$work/input" > "$work/out" 2> "$work/err" || return 1
    [ "$(cat "$work/calls")" = "$(printf '%s\n' \
        'write disabled=true token=123456789:AAHsecretsecretsecret chat=-1001234567890 name=my-vps time=08:30 zone=UTC warn=80,90' \
        'locked enable_telegram_notifications' 'locked send_test_message' test-message)" ] || return 1
    [ "$TG_DISABLED" = false ] || return 1
    grep -Fq '格式不对：Token' "$work/out" || return 1
    grep -Fq '格式不对：Chat ID' "$work/out" || return 1
    grep -Fq 'Token 1234…cret · Chat ID -100…7890' "$work/out" || return 1
    ! grep -Fq 'AAHsecret' "$work/out" || return 1
    grep -Fq '08:30（UTC）' "$work/out" || return 1
    grep -Fq '80%、90%' "$work/out" || return 1

    # 启用失败：返回 1，配置停在「停用」并提示可重试；测试消息问题回答 n 就不发。
    rm -f "$work/calls"
    : > "$work/enable-fails"
    printf '%s\n' '' '' '' '' '' y n > "$work/input"
    rc=0
    initial_config < "$work/input" > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$TG_DISABLED" = true ] || return 1
    grep -Fq '自动通知还没有启用' "$work/out" || return 1
    ! grep -Fxq test-message "$work/calls" || return 1

    # 最后的「保存？」读到 EOF：什么都不写。
    rm -f "$work/calls" "$work/enable-fails"
    printf '%s\n' '' '' '' '' '' > "$work/input"
    rc=0
    initial_config < "$work/input" > "$work/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] || return 1
    assert_absent "$work/calls" || return 1
    grep -Fq '已取消，配置未保存' "$work/out" || return 1

    # 改机器人：回车保留 Token 与机器名，只换 Chat ID → 摘要 → 保存 → 不发测试消息。
    printf '%s\n' '' '-1009876543210' '' y n > "$work/input"
    configure_bot < "$work/input" > "$work/out" 2> "$work/err" || return 1
    [ "$CHAT_ID" = -1009876543210 ] && [ "$BOT_TOKEN" = 123456789:AAHsecretsecretsecret ] || return 1
    [ "$(tg20_count write "$work/calls")" = 1 ] || return 1
    ! grep -Fxq test-message "$work/calls" || return 1
    grep -Fq 'Chat ID -100…3210' "$work/out" || return 1
    # 没有改动：不确认、不写。
    rm -f "$work/calls"
    printf '%s\n' '' '' '' > "$work/input"
    configure_bot < "$work/input" > "$work/out" 2>&1 || return 1
    grep -Fq '没有改动' "$work/out" || return 1
    assert_absent "$work/calls" || return 1
    # 确认时 EOF：不写，值不变。
    printf '%s\n' '' '-1001111111111' '' > "$work/input"
    rc=0
    configure_bot < "$work/input" > "$work/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] && [ "$CHAT_ID" = -1009876543210 ] || return 1
    assert_absent "$work/calls" || return 1
    # 写入失败：内存里的值恢复原样，如实报错。
    : > "$work/write-fails"
    printf '%s\n' '' '-1002222222222' '' y > "$work/input"
    rc=0
    configure_bot < "$work/input" > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] && [ "$CHAT_ID" = -1009876543210 ] || return 1
    grep -Fq '保存失败' "$work/err"
}

# B3：「每日报告时间与时区」只改配置、不碰 crontab（1.2.x 改时间时重写定时任务并提示「cron任务时间已更新」，
# 其实每分钟的条目并没有变），并如实说明今天会不会发；「阈值预警档位」输入规范化、校验，off 关闭；
# 两处都是摘要确认后才写，回答 n 或 EOF 不写。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_schedule_and_warn_edits() {
    local work rc
    work=$(mktemp -d "$TEST_ROOT/tg20-edit.XXXXXX") || return 1
    CONFIG_FILE="$work/config"
    LAST_DAILY_REPORT_FILE="$work/last_daily_report"
    tg20_load edit_report_schedule prompt_report_schedule is_valid_timezone edit_warn_percents \
        normalize_warn_percents warn_percents_label || return 1
    write_config() { printf 'write %s %s %s\n' "$DAILY_REPORT_TIME" "$REPORT_TIMEZONE" "$WARN_PERCENTS" >> "$work/calls"; }
    crontab() { printf '%s\n' crontab >> "$work/calls"; }
    setup_cron() { printf '%s\n' setup_cron >> "$work/calls"; }
    # 固定「现在」为报告时区的 2026-11-25 12:00。
    date() {
        case "$*" in
            +%Y-%m-%d) printf '%s\n' 2026-11-25 ;;
            +%H:%M) printf '%s\n' 12:00 ;;
            *) command date "$@" ;;
        esac
    }
    DAILY_REPORT_TIME=08:00
    REPORT_TIMEZONE=UTC
    WARN_PERCENTS=80,90
    TG_WARN_INVALID=''
    TG_DISABLED=false

    # 改到今天稍后：今天按新时间发。
    printf '%s\n' 21:30 '' y > "$work/input"
    edit_report_schedule < "$work/input" > "$work/out" 2>&1 || return 1
    [ "$(cat "$work/calls")" = 'write 21:30 UTC 80,90' ] || return 1
    grep -Fq '每日报告时间已改为 21:30（UTC）' "$work/out" || return 1
    grep -Fq '今天 21:30 发送' "$work/out" || return 1
    # 改到已经过去的时间、今天还没发：一分钟内补发。
    printf '%s\n' 9:00 '' y > "$work/input"
    edit_report_schedule < "$work/input" > "$work/out" 2>&1 || return 1
    grep -Fq '一分钟内会补发今天的日报' "$work/out" || return 1
    # 今天已经发过：从明天起生效。
    printf '%s\n' 2026-11-25 > "$LAST_DAILY_REPORT_FILE"
    printf '%s\n' 10:00 '' y > "$work/input"
    edit_report_schedule < "$work/input" > "$work/out" 2>&1 || return 1
    grep -Fq '新时间从明天起生效' "$work/out" || return 1
    # 停用中：只说明启用后才会发。
    TG_DISABLED=true
    printf '%s\n' 07:00 '' y > "$work/input"
    edit_report_schedule < "$work/input" > "$work/out" 2>&1 || return 1
    grep -Fq '启用后才会按时发送' "$work/out" || return 1
    [ "$(tg20_count write "$work/calls")" = 4 ] || return 1
    ! grep -Fxq crontab "$work/calls" || return 1
    ! grep -Fxq setup_cron "$work/calls" || return 1
    # 时间写错会重问；确认时回答 n、或者中途 EOF：都不写。
    rm -f "$work/calls"
    printf '%s\n' 25:00 06:15 '' n > "$work/input"
    rc=0
    edit_report_schedule < "$work/input" > "$work/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] && [ "$DAILY_REPORT_TIME" = 07:00 ] || return 1
    grep -Fq '时间格式不对' "$work/out" || return 1
    printf '%s\n' 06:15 > "$work/input"
    rc=0
    edit_report_schedule < "$work/input" > "$work/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] || return 1
    assert_absent "$work/calls" || return 1

    # 预警档位：规范化（中文逗号、空格、重复、乱序）后摘要确认；写错重问；off 关闭；EOF 不写。
    printf '%s\n' '95，85 85' y > "$work/input"
    edit_warn_percents < "$work/input" > "$work/out" 2>&1 || return 1
    [ "$WARN_PERCENTS" = 85,95 ] || return 1
    grep -Fq '阈值预警已改为：85%、95%' "$work/out" || return 1
    printf '%s\n' abc 0,50 off y > "$work/input"
    edit_warn_percents < "$work/input" > "$work/out" 2>&1 || return 1
    [ "$WARN_PERCENTS" = off ] || return 1
    [ "$(grep -c '格式不对' "$work/out")" = 2 ] || return 1
    grep -Fq '阈值预警已改为：已关闭' "$work/out" || return 1
    [ "$(tg20_count write "$work/calls")" = 2 ] || return 1
    printf '%s\n' 70 > "$work/input"
    rc=0
    edit_warn_percents < "$work/input" > "$work/out" 2>&1 || rc=$?
    [ "$rc" = 1 ] && [ "$WARN_PERCENTS" = off ] || return 1
    [ "$(tg20_count write "$work/calls")" = 2 ] || return 1
    # 配置里的档位写坏了（读取时按默认执行）：回车保留默认值也写回，把配置修好。
    WARN_PERCENTS=80,90
    TG_WARN_INVALID='95,abc'
    printf '%s\n' '' y > "$work/input"
    edit_warn_percents < "$work/input" > "$work/out" 2>&1 || return 1
    [ "$(tg20_count write "$work/calls")" = 3 ]
}

# B7：日报正文：已用与百分比、限额、执行阈值及超额动作（读流量监控配置）、执行状态、本期起止与剩余天数、
# 预计期末用量；按目前速度会达到阈值时给出预计日期；期初不足一天不给预计。预警正文同样带这些信息。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_daily_report_content() {
    local work out now line
    work=$(mktemp -d "$TEST_ROOT/tg20-report.XXXXXX") || return 1
    export TZ=UTC
    WORK_DIR="$work"
    MACHINE_NAME=my-vps
    tg20_load build_daily_report_message build_threshold_warning_message threshold_line limit_action_text \
        traffic_period_lines traffic_status_label || return 1
    printf '%s\n' LIMIT_MODE=tc LIMIT_SPEED=50 > "$work/traffic_monitor_config.txt"
    CURRENT_TRAFFIC_STATUS=normal
    CURRENT_TRAFFIC_PERIOD_START=2026-11-01
    CURRENT_TRAFFIC_PERIOD_END=2026-11-30
    CURRENT_TRAFFIC_USAGE=125.456
    CURRENT_TRAFFIC_LIMIT=500
    CURRENT_TRAFFIC_THRESHOLD=499
    CURRENT_TRAFFIC_UNIT=GB
    now=$(date -d '2026-11-11 00:00:00' +%s) || return 1

    out=$(build_daily_report_message "$now") || return 1
    grep -Fq '[my-vps]每日流量报告' <<< "$out" || return 1
    for line in '当前使用：125.46 GB（25%）' '流量限制：500 GB' '执行阈值：499 GB（达到后整机限速 50 kbit/s）' \
        '执行状态：正常' '本期：2026-11-01 至 2026-11-30，还剩 20 天' '预计期末：约 376.37 GB（按本期日均 12.55 GB）'; do
        grep -Fxq -- "$line" <<< "$out" || return 1
    done
    ! grep -Fq '达到执行阈值' <<< "$out" || return 1

    # 用得快：给出预计达到阈值的日期；关机模式说明达到后关机；已限速的状态照实写。
    CURRENT_TRAFFIC_USAGE=402.5
    CURRENT_TRAFFIC_STATUS=limited
    printf '%s\n' LIMIT_MODE=shutdown > "$work/traffic_monitor_config.txt"
    out=$(build_daily_report_message "$now") || return 1
    grep -Fxq '按目前速度，预计 2026-11-13 前后达到执行阈值' <<< "$out" || return 1
    grep -Fxq '执行阈值：499 GB（达到后关机）' <<< "$out" || return 1
    grep -Fxq '执行状态：已限速' <<< "$out" || return 1
    out=$(build_threshold_warning_message 80 "$now") || return 1
    grep -Fq '[my-vps]流量预警：本期用量已达到 80%' <<< "$out" || return 1
    grep -Fxq '已用：402.5 / 500 GB（80%）' <<< "$out" || return 1
    grep -Fxq '本期：2026-11-01 至 2026-11-30，还剩 20 天' <<< "$out" || return 1
    grep -Fxq '按目前速度，预计 2026-11-13 前后达到执行阈值' <<< "$out" || return 1

    # 期初不足一天：不给预计；读不到流量监控配置时阈值行不带动作说明。
    rm -f "$work/traffic_monitor_config.txt"
    out=$(build_daily_report_message "$(date -d '2026-11-01 05:00:00' +%s)") || return 1
    grep -Fxq '预计期末：本期刚开始，满一天后给出预计' <<< "$out" || return 1
    grep -Fxq '执行阈值：499 GB' <<< "$out"
}

# B7：定时日报先记「今天已发」再发送：没到时间不发；发送失败撤回记录、下次重试；记录写不进去时不发（宁可不发，
# 也不每分钟重复）；监控还没有数据时每分钟重试，但只在设定的那一分钟记一行日志。
# --report / 菜单「立即发送一次日报」不动这条记录，各种结果如实提示。
# shellcheck disable=SC2034,SC2317,SC2329
test_tg20_daily_report_schedule_and_manual() {
    local work rc
    work=$(mktemp -d "$TEST_ROOT/tg20-daily.XXXXXX") || return 1
    LAST_DAILY_REPORT_FILE="$work/last_daily_report"
    CRON_LOG="$work/cron.log"
    DAILY_REPORT_TIME=08:00
    REPORT_TIMEZONE=UTC
    tg20_load run_cron_daily_report write_daily_report_state send_report_now || return 1
    log_cron() { printf '%s\n' "$*" >> "$CRON_LOG"; }
    printf '%s\n' 07:59 > "$work/now"
    date() {
        case "$*" in
            +%H:%M) cat "$work/now" ;;
            +%Y-%m-%d) printf '%s\n' 2026-11-25 ;;
            *) command date "$@" ;;
        esac
    }
    # 桩：记下发送时「今天已发」记录的内容；结果取自 $work/result（没有该文件时为 sent）。
    daily_report() {
        printf 'send state=%s\n' "$(cat "$LAST_DAILY_REPORT_FILE" 2>/dev/null)" >> "$work/calls"
        DAILY_REPORT_RESULT=$(cat "$work/result" 2>/dev/null || printf 'sent')
        [ "$DAILY_REPORT_RESULT" = sent ] || [ "$DAILY_REPORT_RESULT" = unavailable_sent ]
    }

    run_cron_daily_report || return 1
    assert_absent "$work/calls" || return 1
    printf '%s\n' 08:00 > "$work/now"
    run_cron_daily_report || return 1
    run_cron_daily_report || return 1
    [ "$(cat "$work/calls")" = 'send state=2026-11-25' ] || return 1
    assert_file_content 2026-11-25 "$LAST_DAILY_REPORT_FILE" || return 1

    # 发送失败：撤回到上一次的日期，下次运行重试；从来没发过时把记录删掉。
    printf '%s\n' 2026-11-24 > "$LAST_DAILY_REPORT_FILE"
    printf '%s\n' failed > "$work/result"
    rm -f "$work/calls"
    if run_cron_daily_report; then return 1; fi
    [ "$(cat "$work/calls")" = 'send state=2026-11-25' ] || return 1
    assert_file_content 2026-11-24 "$LAST_DAILY_REPORT_FILE" || return 1
    grep -Fq '每日报告发送失败，下次运行重试' "$CRON_LOG" || return 1
    rm -f "$LAST_DAILY_REPORT_FILE"
    if run_cron_daily_report; then return 1; fi
    assert_absent "$LAST_DAILY_REPORT_FILE" || return 1

    # 监控还没有数据：每分钟重试，只在设定的那一分钟记一行。
    printf '%s\n' no_data > "$work/result"
    : > "$CRON_LOG"
    if run_cron_daily_report; then return 1; fi
    printf '%s\n' 08:01 > "$work/now"
    if run_cron_daily_report; then return 1; fi
    [ "$(tg20_count '暂无可用的实时流量数据' "$CRON_LOG")" = 1 ] || return 1
    [ "$(wc -l < "$CRON_LOG")" = 1 ] || return 1
    assert_absent "$LAST_DAILY_REPORT_FILE" || return 1

    # 记录写不进去：不发。
    rm -f "$work/calls" "$work/result"
    (
        write_daily_report_state() { return 1; }
        if run_cron_daily_report; then exit 1; fi
        [ ! -e "$work/calls" ]
    ) || return 1

    # 立即发送：不动「今天已发」；各种结果如实提示。
    printf '%s\n' 2026-11-20 > "$LAST_DAILY_REPORT_FILE"
    send_report_now > "$work/out" 2> "$work/err" || return 1
    grep -Fq '日报已发送' "$work/out" || return 1
    assert_file_content 2026-11-20 "$LAST_DAILY_REPORT_FILE" || return 1
    printf '%s\n' unavailable_sent > "$work/result"
    send_report_now > "$work/out" 2> "$work/err" || return 1
    grep -Fq '状态不可用' "$work/out" || return 1
    printf '%s\n' no_data > "$work/result"
    rc=0
    send_report_now > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] || return 1
    grep -Fq '没有可用的实时流量数据' "$work/err" || return 1
    printf '%s\n' failed > "$work/result"
    TG_SEND_ERROR='连接 Telegram 超时'
    rc=0
    send_report_now > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" = 1 ] || return 1
    grep -Fq '日报发送失败：连接 Telegram 超时' "$work/err" || return 1
    ! grep -Fq '已发送' "$work/out" || return 1
    assert_file_content 2026-11-20 "$LAST_DAILY_REPORT_FILE"
}

run_test 'Telegram CLI: usage, exit codes, no stdin when unconfigured (2.0)' test_tg20_cli_arguments
run_test 'Telegram menu layout without colour fits 80 columns and masks secrets (2.0)' test_tg20_menu_layout_no_color
run_test 'Telegram menu loop: invalid input, EOF, entries, confirm before disable (2.0)' test_tg20_menu_loop_and_eof
run_test 'Telegram menu open keeps crontab quiet and rewrites only on drift (2.0)' test_tg20_menu_open_keeps_crontab_quiet
run_test 'Telegram setup_cron result ignores display re-read, L3 (2.0)' test_tg20_setup_cron_ignores_display_reread
run_test 'Telegram WARN_PERCENTS normalise, default, off and invalid values (2.0)' test_tg20_warn_percents_config_compat
run_test 'Telegram threshold warnings once per level per period (2.0)' test_tg20_threshold_warnings_once_per_period
run_test 'Telegram new cycle is notified once (2.0)' test_tg20_new_cycle_notified_once
run_test 'Telegram --help works without root, other modes still need root (2.0)' test_tg20_help_without_root
run_test 'Telegram dependency hints name the menu and never install outside it (2.0)' test_tg20_runtime_dependencies_never_install_outside_menu
run_test 'Telegram routine cron run writes no log lines (2.0)' test_tg20_routine_cron_run_is_quiet
run_test 'Telegram config errors explain why the config is unusable (2.0)' test_tg20_config_error_reasons
run_test 'Telegram send failures are explained, test message reports truthfully (2.0)' test_tg20_send_failures_are_explained
run_test 'Telegram status notifications are recorded before sending (2.0)' test_tg20_status_notifications_record_before_send
run_test 'Telegram enable/disable report every failed step truthfully (2.0)' test_tg20_enable_disable_report_truthfully
run_test 'Telegram setup and bot settings confirm before saving, EOF saves nothing (2.0)' test_tg20_setup_and_bot_flows_confirm_before_saving
run_test 'Telegram report time and warning levels edit only the config (2.0)' test_tg20_schedule_and_warn_edits
run_test 'Telegram daily report shows percent, threshold, period, days left and forecast (2.0)' test_tg20_daily_report_content
run_test 'Telegram cron daily report records before sending, manual report keeps the record (2.0)' test_tg20_daily_report_schedule_and_manual
# ── end 2.0 telegram ──

# ── 2.0 compat ──

# 预警档位：Telegram 组件（read_config）与状态页、仪表盘（共享的 ntc_tg_warn_percents）对同一份配置的解释必须一致：
# 没有该键 → 80,90；空或 off → 关闭；写坏的值 → 按 80,90 执行。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_tg_warn_percents_rules_match_telegram() {
    local work value got
    work=$(mktemp -d "$TEST_ROOT/warn-rules.XXXXXX") || return 1
    CONFIG_FILE="$work/tg"
    load_function "$TELEGRAM_SCRIPT" read_config || return 1
    load_function "$TELEGRAM_SCRIPT" is_valid_timezone || return 1
    load_function "$TELEGRAM_SCRIPT" decode_legacy_config_value || return 1
    for value in '<absent>' '' off OFF Off 80,90 50 5,95 0 00,50 100 5,abc ' 80' '80,' 1,2,3; do
        {
            printf '%s\n' CONFIG_FORMAT=plain-v2 BOT_TOKEN=123:abc CHAT_ID=1 MACHINE_NAME=node \
                DAILY_REPORT_TIME=08:00 REPORT_TIMEZONE=UTC TG_DISABLED=false
            [ "$value" = '<absent>' ] || printf 'WARN_PERCENTS=%s\n' "$value"
        } > "$CONFIG_FILE"
        if ! read_config; then
            printf 'read_config [%s]: %s\n' "$value" "${TG_CONFIG_ERROR:-}" >&2
            return 1
        fi
        got=$(ntc_tg_warn_percents "$CONFIG_FILE")
        if [ "$got" != "$WARN_PERCENTS" ]; then
            printf 'WARN_PERCENTS=[%s]: Telegram=%s 共享=%s\n' "$value" "$WARN_PERCENTS" "$got" >&2
            return 1
        fi
    done
}

# 主菜单仪表盘的 Telegram 行：已启用时显示日报时间与预警档位（与 Telegram 组件同一套解释）；
# 定时任务缺失、已停用时如实说明，不再一律显示「已停用」。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_dashboard_telegram_line_shows_warn_levels() {
    local work out
    work=$(mktemp -d "$TEST_ROOT/dash-tg.XXXXXX") || return 1
    setup_dashboard_case "$work" || return 1
    printf '%s\n' MAIN_INTERFACE=eth0 TRAFFIC_MODE=total TRAFFIC_PERIOD=monthly PERIOD_START_DAY=1 TRAFFIC_UNIT=decimal \
        TRAFFIC_LIMIT=500 TRAFFIC_TOLERANCE=1 LIMIT_MODE=tc LIMIT_SPEED=50 > "$work/traffic_monitor_config.txt"
    printf '%s\n' CONFIG_FORMAT=plain-v2 DAILY_REPORT_TIME=08:00 TG_DISABLED=false > "$work/tg_notifier_config.txt"
    read_current_crontab() {
        printf '%s\n' "* * * * * $WORK_DIR/trafficcop-lite-monitor.sh --run >/dev/null 2>&1 # TrafficCop-Lite Monitor" \
            "* * * * * $WORK_DIR/trafficcop-lite-telegram.sh -cron >/dev/null 2>&1 # TrafficCop-Lite Telegram"
    }
    out=$(show_dashboard 2>&1) || return 1
    grep -Fq '已启用，每日 08:00 日报；预警 80%、90%' <<< "$out" || return 1
    printf '%s\n' WARN_PERCENTS= >> "$work/tg_notifier_config.txt"
    out=$(show_dashboard 2>&1) || return 1
    grep -Fq '已启用，每日 08:00 日报；预警已关闭' <<< "$out" || return 1
    printf '%s\n' WARN_PERCENTS=95,abc >> "$work/tg_notifier_config.txt"
    out=$(show_dashboard 2>&1) || return 1
    grep -Fq '预警 80%、90%' <<< "$out" || return 1
    read_current_crontab() {
        printf '%s\n' "* * * * * $WORK_DIR/trafficcop-lite-monitor.sh --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"
    }
    out=$(show_dashboard 2>&1) || return 1
    grep -Fq '定时任务缺失，不会发送' <<< "$out" || return 1
    printf '%s\n' TG_DISABLED=true >> "$work/tg_notifier_config.txt"
    out=$(show_dashboard 2>&1) || return 1
    grep -Eq 'Telegram +已停用' <<< "$out"
}

# 旧更新器兼容：已装 1.2.1 的机器会用自己的（1.2.1 的）更新器升级到 2.0。它取每个文件第一处版本号，
# 逐组件拦截降级。这里原样嵌入 1.2.1（d2a406c）的三个函数，检查仓库里的四个文件：版本识别正确
# （machine-limit 仍按组件版本 2.13 比较）、不会被当成降级；已装组件版本更高时仍会被拦住。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_old_updater_accepts_2_0_components() {
    local work name version
    work=$(mktemp -d "$TEST_ROOT/old-updater.XXXXXX") || return 1
    WORK_DIR="$work"
    RED=''
    NC=''
    # ── 以下三个函数是 1.2.1 trafficcop-lite.sh 的原样副本，不要随新版修改 ──
    script_version_from_file() {
        local file="$1"
        sed -nE '
            s/^SCRIPT_VERSION="([0-9]+([.][0-9]+)*)".*/\1/p
            s/^# .* v([0-9]+([.][0-9]+)*).*/\1/p
        ' "$file" 2>/dev/null | head -n 1
    }
    version_is_newer() {
        local installed="$1"
        local candidate="$2"
        awk -v installed="$installed" -v candidate="$candidate" 'BEGIN {
            installed_count = split(installed, installed_parts, ".")
            candidate_count = split(candidate, candidate_parts, ".")
            count = installed_count > candidate_count ? installed_count : candidate_count
            for (i = 1; i <= count; i++) {
                installed_part = installed_parts[i] + 0
                candidate_part = candidate_parts[i] + 0
                if (installed_part > candidate_part) exit 0
                if (installed_part < candidate_part) exit 1
            }
            exit 1
        }'
    }
    validate_update_candidate() {
        local script_name="$1"
        local candidate_file="$2"
        local installed_file="$WORK_DIR/$script_name"
        local candidate_version installed_version

        candidate_version=$(script_version_from_file "$candidate_file")
        if [ -z "$candidate_version" ]; then
            echo -e "${RED}无法识别 $script_name 的候选版本，已取消更新。${NC}"
            return 1
        fi

        installed_version=$(script_version_from_file "$installed_file")
        if [ -n "$installed_version" ] && version_is_newer "$installed_version" "$candidate_version"; then
            echo -e "${RED}更新源中的 $script_name 版本 $candidate_version 低于已安装版本 $installed_version，已阻止降级。${NC}"
            return 1
        fi
    }
    # ── 1.2.1 副本结束 ──

    for name in trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh; do
        version=$(script_version_from_file "$ROOT_DIR/$name")
        if [ "$version" != 2.0.0 ]; then
            printf '%s 的第一处版本号是 %s\n' "$name" "$version" >&2
            return 1
        fi
        printf '%s\n' '#!/bin/bash' 'SCRIPT_VERSION="1.2.1"' > "$work/$name"
        validate_update_candidate "$name" "$ROOT_DIR/$name" > /dev/null || return 1
    done
    name=trafficcop-lite-machine-limit.sh
    [ "$(script_version_from_file "$ROOT_DIR/$name")" = 2.13 ] || return 1
    printf '%s\n' '#!/bin/bash' '' '# TrafficCop 机器限速管理脚本 v2.13' > "$work/$name"
    validate_update_candidate "$name" "$ROOT_DIR/$name" > /dev/null || return 1
    # 已装组件版本更高（假想的 2.14）时 1.2.1 更新器会拦住：说明比较的确实是第一处版本号。
    printf '%s\n' '#!/bin/bash' '' '# TrafficCop 机器限速管理脚本 v2.14' > "$work/$name"
    if validate_update_candidate "$name" "$ROOT_DIR/$name" > /dev/null; then
        return 1
    fi
    # 新版界面显示的版本：machine-limit 显示 SCRIPT_VERSION（2.0.0），不显示组件版本。
    load_function "$ROOT_DIR/trafficcop-lite.sh" component_display_version || return 1
    [ "$(component_display_version "$ROOT_DIR/$name")" = 2.0.0 ]
}

# 与已部署的 Dog 2.1 的共享约定（Dog 按这些读取或调用 NTC，任何一项变了 Dog 都会误判）：安装路径与四个文件名、
# monitor 里的 Dog 类清单标记、--tc-recover-owned 入口、tc_limit_state 的键与取值、配置文件的 DISABLED 键、
# 共享 TC 锁、快捷命令 /usr/local/bin/ntc、监控定时任务的格式。
# shellcheck disable=SC2016,SC2034,SC2209,SC2317,SC2329
test_dog_shared_contract_is_unchanged() {
    local name key
    for name in trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh; do
        [ -f "$ROOT_DIR/$name" ] || return 1
        grep -Fqx 'WORK_DIR="/etc/trafficcop-lite"' "$ROOT_DIR/$name" || return 1
    done
    grep -Fq 'traffic-tools-dog-classes-v1' "$MONITOR_SCRIPT" || return 1
    grep -Fqx 'TC_STATE_SCHEMA="traffic-tools-unified-htb-v1"' "$MONITOR_SCRIPT" || return 1
    grep -Fqx 'TC_STATE_PROVIDER="trafficcop-lite"' "$MONITOR_SCRIPT" || return 1
    grep -Fqx 'TC_STATE_FILE="$WORK_DIR/tc_limit_state"' "$MONITOR_SCRIPT" || return 1
    grep -Fqx 'CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"' "$MONITOR_SCRIPT" || return 1
    for key in SCHEMA PROVIDER INTERFACE LIMIT_SPEED; do
        grep -Fq "printf '$key=%s\\n'" "$MONITOR_SCRIPT" || return 1
    done
    grep -Fq '/run/lock/traffic-tools-tc.lock' "$MONITOR_SCRIPT" || return 1
    extract_function "$MONITOR_SCRIPT" main | grep -Eq -- '--tc-recover-owned\)' || return 1
    grep -Fqx 'SHORTCUT_PATH="/usr/local/bin/ntc"' "$ROOT_DIR/trafficcop-lite.sh" || return 1
    grep -Fq "printf 'DISABLED=true\\n'" "$ROOT_DIR/trafficcop-lite-machine-limit.sh" || return 1
    grep -Fqx 'CRON_COMMENT="# TrafficCop-Lite Monitor"' "$ROOT_DIR/trafficcop-lite-machine-limit.sh" || return 1
    grep -Fq 'cron_entry="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 $CRON_COMMENT"' \
        "$ROOT_DIR/trafficcop-lite-machine-limit.sh"
}

run_test 'Telegram and status pages read warning levels the same way (2.0)' test_tg_warn_percents_rules_match_telegram
run_test 'dashboard Telegram line shows report time and warning levels (2.0)' test_dashboard_telegram_line_shows_warn_levels
run_test '1.2.1 updater recognises the 2.0 components without blocking them (2.0)' test_old_updater_accepts_2_0_components
run_test 'shared contract with the deployed Dog 2.1 is unchanged (2.0)' test_dog_shared_contract_is_unchanged
# ── end 2.0 compat ──

# ── 2.0 machine-limit ──
ML_SCRIPT="$ROOT_DIR/trafficcop-lite-machine-limit.sh"

# 加载 machine-limit 的函数；某个函数不存在时跳过（红绿对照换回旧版时，用例因行为失败而不是因缺函数中断）。
ml_load() {
    local function_name
    for function_name in "$@"; do
        load_function "$ML_SCRIPT" "$function_name" 2>/dev/null || true
    done
}

# 记录调用；先试着读一行标准输入，读到就记下来（用来证明命令行参数不读输入）。
ml_record() {
    local line
    if IFS= read -r -t 1 line; then
        printf '%s read-stdin:%s\n' "$1" "$line" >> "$ML_CALLS"
    fi
    printf '%s\n' "$*" >> "$ML_CALLS"
}

# 只记录调用，不读输入（菜单用例：输入要留给菜单本身）。
ml_note_call() {
    printf '%s\n' "$*" >> "$ML_CALLS"
}

# 把会动系统的函数换成桩：$1=记录函数，其后是函数名。新旧两版脚本都只会调用到这些桩。
ml_stub() {
    local recorder="$1" name
    shift
    for name in "$@"; do
        eval "$name() { $recorder $name \"\$@\"; }"
    done
}

# 两个版本里所有可能改动系统的动作入口（含 1.x 菜单会调用的函数）。
ML_ACTIONS=(enable_machine_limit disable_machine_limit restore_machine_limit machine_pause machine_resume machine_grace
    machine_set_boot_grace machine_clear_tc clear_tc_rules_with_lock manage_enforcement_control show_detailed_status
    machine_grace_interactive machine_boot_grace_interactive machine_clear_tc_interactive machine_disable_interactive
    machine_enable_interactive machine_restore_interactive machine_require_dependencies)

# 版本：1.x 更新器按第一处版本号判断组件版本（必须仍是 v2.13）；显示版本取 SCRIPT_VERSION。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_version_header_stays_first() {
    load_function "$ROOT_DIR/trafficcop-lite.sh" script_version_from_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" component_display_version || return 1
    [ "$(script_version_from_file "$ML_SCRIPT")" = 2.13 ] || return 1
    [ "$(sed -n 3p "$ML_SCRIPT")" = '# TrafficCop 机器限速管理脚本 v2.13' ] || return 1
    ! head -n 2 "$ML_SCRIPT" | grep -Eq '^SCRIPT_VERSION=|^# .* v[0-9]' || return 1
    [ "$(component_display_version "$ML_SCRIPT")" = 2.0.0 ]
}

# 命令行：未知参数、缺值、越界、多余参数 → 用法写到 stderr、退出码 2，且不碰任何文件；--help 退出 0 且不要求 root。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_cli_rejects_bad_arguments() {
    local work args rc
    work=$(mktemp -d "$TEST_ROOT/ml-cli-args.XXXXXX") || return 1
    WORK_DIR="$work/state"
    ML_CALLS="$work/calls"
    ml_load main show_machine_usage machine_usage_error
    ml_stub ml_record "${ML_ACTIONS[@]}" show_status show_menu machine_menu
    id() { printf '0\n'; }
    for args in --bogus status --grace '--grace 0' '--grace 1441' '--grace 1.5' '--grace -5' '--grace 10 extra' \
        --boot-grace '--boot-grace 1441' '--boot-grace x' '--status extra' '--pause now' '--help me' '--enable --disable'; do
        rc=0
        # shellcheck disable=SC2086
        ( main $args ) < /dev/null > "$work/out" 2> "$work/err" || rc=$?
        [ "$rc" -eq 2 ] || return 1
        [ ! -s "$work/out" ] || return 1
        grep -Fq -- '--boot-grace' "$work/err" || return 1
    done
    assert_absent "$ML_CALLS" || return 1
    assert_absent "$WORK_DIR" || return 1
    ( main --help ) > "$work/out" 2>&1 || return 1
    grep -Fq -- '--clear-tc' "$work/out" || return 1
    id() { printf '1000\n'; }
    ( main -h ) < /dev/null > "$work/out" 2>&1 || return 1
    grep -Fq -- '--grace' "$work/out" || return 1
    rc=0
    ( main --pause ) < /dev/null > "$work/out" 2> "$work/err" || rc=$?
    [ "$rc" -eq 1 ] && grep -Fq 'root' "$work/err" || return 1
    assert_absent "$ML_CALLS"
}

# 命令行动作：分钟数按十进制规范化后传给动作；动作的标准输入一律是 /dev/null（不会读到调用方的输入、不会卡住）；
# --status 只读，不建工作目录。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_cli_dispatch_never_reads_stdin() {
    local work args
    work=$(mktemp -d "$TEST_ROOT/ml-cli-dispatch.XXXXXX") || return 1
    WORK_DIR="$work/state"
    ML_CALLS="$work/calls"
    printf '%s\n' y > "$work/input"
    ml_load main show_machine_usage machine_usage_error
    ml_stub ml_record "${ML_ACTIONS[@]}" show_status machine_menu
    ml_stub ml_note_call show_menu
    id() { printf '0\n'; }

    ( main --status ) < "$work/input" > /dev/null 2>&1 || return 1
    assert_absent "$WORK_DIR" || return 1
    for args in --pause --resume '--grace 05' '--boot-grace 007' --clear-tc --disable --enable; do
        # shellcheck disable=SC2086
        run_with_deadline 10 "$work/input" main $args || return 1
    done
    ! grep -q 'read-stdin' "$ML_CALLS" || return 1
    assert_file_content $'show_status\nmachine_pause\nmachine_resume\nmachine_grace 5\nmachine_set_boot_grace 7\nmachine_clear_tc\ndisable_machine_limit batch\nmachine_require_dependencies batch\nenable_machine_limit' "$ML_CALLS"
}

# --grace / --pause / --resume / --boot-grace 写出的状态；重复操作不重写、不重复审计；关机模式拒绝开机宽限。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_cli_actions_write_state() {
    local work now until_epoch rc
    work=$(mktemp -d "$TEST_ROOT/ml-cli-state.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    TC_STATE_FILE="$work/tc_limit_state"
    ML_CALLS="$work/calls"
    printf '%s\n' MAIN_INTERFACE=eth0 LIMIT_MODE=tc LIMIT_SPEED=50 TC_BOOT_GRACE_MINUTES=10 > "$CONFIG_FILE"
    ml_load main show_machine_usage machine_usage_error machine_set_enforcement machine_grace machine_pause \
        machine_resume machine_set_boot_grace write_enforcement_state_file write_enforcement_state
    ml_stub ml_note_call show_menu show_status disable_machine_limit enable_machine_limit restore_machine_limit \
        show_detailed_status clear_tc_rules_with_lock manage_enforcement_control machine_require_dependencies
    id() { printf '0\n'; }
    acquire_monitor_cleanup_lock() { printf '%s\n' lock >> "$work/events"; }
    release_monitor_cleanup_lock() { printf '%s\n' unlock >> "$work/events"; }
    clear_tc_rules() { printf '%s\n' clear >> "$work/events"; }
    cancel_owned_shutdown() { printf '%s\n' cancel >> "$work/events"; }

    now=$(date +%s)
    ( main --grace 030 ) < /dev/null > "$work/out" 2>&1 || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" && grep -Fxq 'REASON=manual' "$ENFORCEMENT_STATE_FILE" || return 1
    until_epoch=$(ntc_kv "$ENFORCEMENT_STATE_FILE" UNTIL_EPOCH) || return 1
    [ "$until_epoch" -ge $((now + 1800)) ] && [ "$until_epoch" -le $((now + 1805)) ] || return 1
    assert_file_content $'lock\nclear\ncancel\nunlock' "$work/events" || return 1
    grep -Fq '已宽限 30 分钟' "$work/out" || return 1
    grep -Fq 'EVENT=enforcement-grace RESULT=success' "$work/operations.log" || return 1

    : > "$work/events"
    ( main --pause ) < /dev/null > "$work/out" 2>&1 || return 1
    grep -Fxq 'MODE=paused' "$ENFORCEMENT_STATE_FILE" && grep -Fxq 'UNTIL_EPOCH=0' "$ENFORCEMENT_STATE_FILE" || return 1
    ( main --pause ) < /dev/null > "$work/out" 2>&1 || return 1
    assert_file_content $'lock\nclear\ncancel\nunlock' "$work/events" || return 1
    [ "$(grep -c 'EVENT=enforcement-pause RESULT=success' "$work/operations.log")" -eq 1 ] || return 1

    ( main --resume ) < /dev/null > "$work/out" 2>&1 || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
    ( main --resume ) < /dev/null > "$work/out" 2>&1 || return 1
    [ "$(grep -c 'EVENT=enforcement-resume RESULT=success' "$work/operations.log")" -eq 1 ] || return 1

    ( main --boot-grace 007 ) < /dev/null > "$work/out" 2>&1 || return 1
    grep -Fxq 'TC_BOOT_GRACE_MINUTES=7' "$CONFIG_FILE" || return 1
    ( main --boot-grace 7 ) < /dev/null > "$work/out" 2>&1 || return 1
    [ "$(grep -c 'EVENT=boot-grace RESULT=success' "$work/operations.log")" -eq 1 ] || return 1

    printf '%s\n' MAIN_INTERFACE=eth0 LIMIT_MODE=shutdown > "$CONFIG_FILE"
    rc=0
    ( main --boot-grace 5 ) < /dev/null > "$work/out" 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || return 1
    ! grep -q '^TC_BOOT_GRACE_MINUTES=' "$CONFIG_FILE" || return 1
    assert_absent "$ML_CALLS"
}

# --clear-tc：解除后说明仍超额时下一分钟会再次限速；菜单里先说明再确认，没有 NTC 限速时不确认。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_clear_tc_explains_relimit() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ml-clear-tc.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    TC_STATE_FILE="$work/tc_limit_state"
    ML_CALLS="$work/calls"
    printf '%s\n' y > "$work/yes"
    ml_load main show_machine_usage machine_usage_error machine_clear_tc machine_clear_tc_interactive
    ml_stub ml_note_call show_menu show_status disable_machine_limit enable_machine_limit restore_machine_limit \
        show_detailed_status manage_enforcement_control machine_require_dependencies
    id() { printf '0\n'; }
    clear_tc_rules_with_lock() { rm -f "$TC_STATE_FILE"; printf '%s\n' clear >> "$work/clears"; }

    printf '%s\n' state > "$TC_STATE_FILE"
    ( main --clear-tc ) < /dev/null > "$work/out" 2>&1 || return 1
    assert_file_content clear "$work/clears" || return 1
    grep -Fq '下一分钟的检查会再次限速' "$work/out" || return 1

    printf '%s\n' state > "$TC_STATE_FILE"
    machine_clear_tc_interactive < "$work/yes" > "$work/out" 2>&1 || return 1
    grep -Fq '下一分钟的检查会再次限速' "$work/out" && grep -Fq '宽限一段时间' "$work/out" || return 1
    assert_file_content $'clear\nclear' "$work/clears" || return 1
    machine_clear_tc_interactive < /dev/null > "$work/out" 2>&1 || return 1
    grep -Fq '无需解除' "$work/out" || return 1
    assert_file_content $'clear\nclear' "$work/clears"
}

# 启用：首次检查调用 monitor --check（2.0 的 --run 不输出任何东西），失败则回滚且不加定时任务；未配置时提示 ntc config。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_enable_runs_check_instead_of_run() {
    local work lock_held=false
    work=$(mktemp -d "$TEST_ROOT/ml-enable-check.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"
    ml_load write_enforcement_state_file begin_enable_grace rollback_enable_machine_limit enable_machine_limit
    acquire_monitor_cleanup_lock() { lock_held=true; }
    release_monitor_cleanup_lock() { lock_held=false; }
    clear_tc_rules() { :; }
    cancel_owned_shutdown() { :; }
    clear_tc_rules_with_lock() { :; }
    bash() {
        printf '%s\n' "$*" >> "$work/calls"
        printf '%s\n' '  ✓ 检查完成：本期已用 1 GB / 阈值 499 GB，流量正常。'
    }
    add_cron_job() { printf '%s\n' cron >> "$work/calls"; }

    enable_machine_limit > "$work/out" 2>&1 || return 1
    assert_file_content "$SCRIPT_PATH --check"$'\ncron' "$work/calls" || return 1
    grep -Fq '检查完成' "$work/out" || return 1
    ! grep -Fq '日志中查看' "$work/out" || return 1
    ! grep -q '^DISABLED=' "$CONFIG_FILE" || return 1

    rm -f "$work/calls"
    printf '%s\n' 'LIMIT_MODE=tc' 'DISABLED=true' > "$CONFIG_FILE"
    bash() { printf '%s\n' "$*" >> "$work/calls"; return 1; }
    if enable_machine_limit > "$work/out" 2>&1; then return 1; fi
    assert_file_content "$SCRIPT_PATH --check" "$work/calls" || return 1
    grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1

    rm -f "$CONFIG_FILE"
    if enable_machine_limit > "$work/out" 2>&1; then return 1; fi
    grep -Fq '尚未配置流量监控：运行 sudo ntc config 开始。' "$work/out"
}

# 状态改读 monitor_health：正常、检查失败、超过 10 分钟没更新三种情况；日志里的旧“自动化模式”行不影响结论。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_status_reads_monitor_health() {
    local work now
    work=$(mktemp -d "$TEST_ROOT/ml-status-health.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    TC_STATE_FILE="$work/tc_limit_state"
    BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
    SCRIPT_PATH="$work/trafficcop-lite-monitor.sh"
    TC_BIN=''
    now=$(date +%s)
    printf '%s\n' MAIN_INTERFACE=eth0 LIMIT_MODE=tc LIMIT_SPEED=50 > "$CONFIG_FILE"
    printf '%s\n' STATUS=normal > "$work/current_traffic_state"
    printf '%s 正在以自动化模式运行\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$work/traffic_monitor.log"
    ml_load enforcement_state_value show_monitor_task_status machine_status_collect machine_action_rows show_status
    read_root_crontab_locked() { printf '%s\n' "* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"; }
    get_main_interface() { printf '%s\n' eth0; }
    tc_state_value() { return 0; }

    printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$now" > "$work/monitor_health"
    show_status > "$work/out" 2>&1 || return 1
    grep -Eq '^  最近检查  运行正常' "$work/out" && grep -Fq '● 监控中' "$work/out" || return 1

    printf '%s\n' HEALTH=error 'REASON=vnStat 数据不可用' "UPDATED_EPOCH=$now" > "$work/monitor_health"
    show_status > "$work/out" 2>&1 || return 1
    grep -Eq '^  最近检查  vnStat 数据不可用' "$work/out" && grep -Fq '✗ 异常' "$work/out" || return 1

    printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$((now - 1200))" > "$work/monitor_health"
    show_status > "$work/out" 2>&1 || return 1
    grep -Eq '^  最近检查  已 20 分钟没有运行' "$work/out" && grep -Fq '✗ 异常' "$work/out" || return 1
    ! grep -Fq '最近已执行' "$work/out"
}

# 菜单（非终端、NO_COLOR）：分组与编号、0 返回、输入结束直接退出、非法输入提示后重画、选项分派。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_menu_renders_without_terminal() {
    local work rc
    work=$(mktemp -d "$TEST_ROOT/ml-menu.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=80   # 按 80 列渲染（两列分组、各行不折）；不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    TC_STATE_FILE="$work/tc_limit_state"
    BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
    SCRIPT_PATH="$work/trafficcop-lite-monitor.sh"
    ML_CALLS="$work/calls"
    printf '%s\n' MAIN_INTERFACE=eth0 LIMIT_MODE=tc LIMIT_SPEED=50 TC_BOOT_GRACE_MINUTES=10 > "$CONFIG_FILE"
    printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$(date +%s)" > "$work/monitor_health"
    ml_load main show_machine_usage machine_usage_error machine_menu show_menu menu_run machine_status_collect \
        machine_action_rows
    ml_stub ml_note_call "${ML_ACTIONS[@]}" show_status
    id() { printf '0\n'; }
    read_root_crontab_locked() { printf '%s\n' "* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"; }

    printf '%s\n' 0 > "$work/in-zero"
    ( NO_COLOR=1 TERM=dumb main ) < "$work/in-zero" > "$work/out" 2>&1 || return 1
    grep -Fq '限制执行 · 按配置执行' "$work/out" || return 1
    grep -Fq '临时调整' "$work/out" && grep -Fq '设置' "$work/out" || return 1
    grep -Fq '1. 宽限一段时间' "$work/out" && grep -Fq '4. 立即解除当前限速' "$work/out" || return 1
    grep -Fq '8. 从停用前的备份恢复配置' "$work/out" && grep -Fq '9. 详细状态' "$work/out" || return 1
    grep -Fq '0. 返回' "$work/out" && grep -Fq '执行方式  整机限速 50 kbit/s' "$work/out" || return 1
    ! grep -q "$(printf '\033')" "$work/out" || return 1
    assert_absent "$ML_CALLS" || return 1

    rc=0
    run_with_deadline 5 /dev/null main || rc=$?
    [ "$rc" -eq 0 ] || return 1

    printf '%s\n' x 12 0 > "$work/in-invalid"
    ( main ) < "$work/in-invalid" > "$work/out" 2>&1 || return 1
    [ "$(grep -c '无效选择' "$work/out")" -eq 2 ] || return 1
    assert_absent "$ML_CALLS" || return 1

    printf '%s\n' 2 '' 9 '' 0 > "$work/in-actions"
    ( main ) < "$work/in-actions" > "$work/out" 2>&1 || return 1
    assert_file_content $'machine_pause\nshow_detailed_status' "$ML_CALLS"
}

# 窄终端（COLUMNS=40）：菜单与状态的每一行都不超过 40 列；过长的「总体状态」「最近检查」「TC 限速」折行，
# 续行与值对齐（缩进 12 列）。只断言不会被折开的短片段。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_rows_wrap_at_narrow_width() {
    local work line w
    work=$(mktemp -d "$TEST_ROOT/ml-narrow.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    TC_STATE_FILE="$work/tc_limit_state"
    BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
    SCRIPT_PATH="$work/trafficcop-lite-monitor.sh"
    TC_BIN=true TC_STATE_SCHEMA=traffic-tools-unified-htb-v1 TC_STATE_PROVIDER=trafficcop-lite
    printf '%s\n' MAIN_INTERFACE=eth0 LIMIT_MODE=tc LIMIT_SPEED=50 TC_BOOT_GRACE_MINUTES=10 > "$CONFIG_FILE"
    printf '%s\n' HEALTH=error 'REASON=vnStat 数据不可用，请检查 vnstat 服务是否在运行' "UPDATED_EPOCH=$(date +%s)" \
        > "$work/monitor_health"
    ml_load show_menu show_status show_monitor_task_status machine_status_collect machine_action_rows
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' BOLD_CYAN='' DIM='' NC=''
    read_root_crontab_locked() { printf '%s\n' '# 没有监控任务'; }
    get_main_interface() { printf '%s\n' eth0; }
    tc_state_value() { [ "$1" != INTERFACE ] || printf '%s\n' eth0; }
    tc_root_qdisc() { printf '%s\n' 'qdisc fq_codel 0: root refcnt 2'; }

    ( COLUMNS=40; show_menu; show_status ) < /dev/null > "$work/out" 2> "$work/err" || return 1
    [ ! -s "$work/err" ] || return 1
    grep -Fq '! 未运行' "$work/out" && grep -Eq '^  最近检查  vnStat' "$work/out" || return 1
    grep -Eq '^  TC 限速   NTC' "$work/out" || return 1
    [ "$(grep -cE '^ {12}[^ ]' "$work/out")" -ge 4 ] || return 1
    while IFS= read -r line; do
        ui_measure w "$line"
        [ "$w" -le 40 ] || return 1
    done < "$work/out"
}

# 宽限、开机宽限、解除限速、停用、从备份恢复：读到输入结束（EOF）一律取消，不取锁、不撤销限速、不写任何文件。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_interactive_eof_changes_nothing() {
    local work rc function_name
    work=$(mktemp -d "$TEST_ROOT/ml-eof.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    TC_STATE_FILE="$work/tc_limit_state"
    BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
    ML_CALLS="$work/calls"
    printf '%s\n' LIMIT_MODE=tc TC_BOOT_GRACE_MINUTES=10 > "$CONFIG_FILE"
    printf '%s\n' MODE=paused UNTIL_EPOCH=0 REASON=manual > "$ENFORCEMENT_STATE_FILE"
    printf '%s\n' state > "$TC_STATE_FILE"
    printf '%s\n' backup > "$BACKUP_CONFIG_FILE"
    cp "$CONFIG_FILE" "$work/config.before" && cp "$ENFORCEMENT_STATE_FILE" "$work/enforcement.before" || return 1
    printf '%s\n' abc > "$work/in-bad"
    printf '%s\n' 5 > "$work/in-five"
    ml_load machine_set_enforcement machine_grace machine_grace_interactive machine_set_boot_grace \
        machine_boot_grace_interactive machine_clear_tc_interactive machine_disable_interactive \
        machine_restore_interactive write_enforcement_state_file write_enforcement_state
    ml_stub ml_note_call acquire_monitor_cleanup_lock clear_tc_rules cancel_owned_shutdown clear_tc_rules_with_lock \
        disable_machine_limit restore_machine_limit machine_require_dependencies

    for function_name in machine_grace_interactive machine_boot_grace_interactive machine_clear_tc_interactive \
        machine_disable_interactive machine_restore_interactive; do
        rc=0
        run_with_deadline 5 /dev/null "$function_name" || rc=$?
        [ "$rc" -eq 1 ] || return 1
    done
    rc=0
    run_with_deadline 5 "$work/in-bad" machine_grace_interactive || rc=$?
    [ "$rc" -eq 1 ] || return 1
    rc=0
    run_with_deadline 5 "$work/in-five" machine_boot_grace_interactive || rc=$?
    [ "$rc" -eq 1 ] || return 1
    assert_absent "$ML_CALLS" || return 1
    cmp -s "$work/config.before" "$CONFIG_FILE" || return 1
    cmp -s "$work/enforcement.before" "$ENFORCEMENT_STATE_FILE" || return 1
    assert_absent "$work/operations.log"
}

# --disable（batch）绝不取消无法确认归属的计划关机，只说明；菜单里回答 y 才取消；系统里没有计划关机时不询问。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_disable_batch_never_cancels_foreign_shutdown() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ml-disable-batch.XXXXXX") || return 1
    WORK_DIR="$work"
    CONFIG_FILE="$work/config"
    BACKUP_CONFIG_FILE="$work/config.disabled.backup"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    ENFORCEMENT_STATE_FILE="$work/enforcement-state"
    printf '%s\n' y > "$work/yes"
    ml_load disable_machine_limit
    remove_cron_job() { :; }
    acquire_monitor_cleanup_lock() { :; }
    clear_tc_rules() { :; }
    release_monitor_cleanup_lock() { :; }
    cancel_owned_shutdown() { :; }
    has_pending_shutdown() { return 0; }
    shutdown() { printf '%s\n' "$*" >> "$work/shutdown-calls"; }

    printf '%s\n' LIMIT_MODE=shutdown > "$CONFIG_FILE"
    disable_machine_limit batch < "$work/yes" > "$work/out" 2>&1 || return 1
    assert_absent "$work/shutdown-calls" || return 1
    grep -Fq '未取消' "$work/out" || return 1
    grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1

    printf '%s\n' LIMIT_MODE=shutdown > "$CONFIG_FILE"
    has_pending_shutdown() { [ ! -f "$work/shutdown-calls" ]; }
    disable_machine_limit interactive < "$work/yes" > "$work/out" 2>&1 || return 1
    assert_file_content '-c' "$work/shutdown-calls" || return 1

    rm -f "$work/shutdown-calls"
    printf '%s\n' LIMIT_MODE=shutdown > "$CONFIG_FILE"
    has_pending_shutdown() { return 1; }
    disable_machine_limit interactive < "$work/yes" > "$work/out" 2>&1 || return 1
    assert_absent "$work/shutdown-calls"
}

# 关机记录清理不误报：有 NTC 的关机记录、系统里却没有待执行的计划关机时，只删记录并如实说明，不调用 shutdown -c、
# 不说「已取消」（1.x 在这里也报「已取消本脚本记录的计划关机」）；确有 NTC 安排的计划关机时才取消并说「已取消」。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_cancel_owned_shutdown_reports_truthfully() {
    local work pending=false
    work=$(mktemp -d "$TEST_ROOT/ml-cancel-shutdown.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    SHUTDOWN_STATE_FILE="$work/machine_shutdown_state"
    ml_load shutdown_task_token_from_state pending_shutdown_matches_owned_state cancel_owned_shutdown
    cat() {
        if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then printf '%s\n' boot-a; else command cat "$@"; fi
    }
    has_pending_shutdown() { [ "$pending" = true ]; }
    busctl() { printf 's "%s"\n' 'TrafficCop-Lite[trafficcop-lite-machine-12345678] owned task'; }
    shutdown() {
        [ "${1:-}" = -c ] || return 1
        printf '%s\n' "$*" >> "$work/shutdown-calls"
        pending=false
    }

    printf '%s\n' BOOT_ID=boot-a TASK_TOKEN=trafficcop-lite-machine-12345678 > "$SHUTDOWN_STATE_FILE"
    cancel_owned_shutdown > "$work/out" 2>&1 || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1
    assert_absent "$work/shutdown-calls" || return 1
    grep -Fq '当前没有待执行的计划关机' "$work/out" || return 1
    ! grep -Fq '已取消' "$work/out" || return 1

    printf '%s\n' BOOT_ID=boot-a TASK_TOKEN=trafficcop-lite-machine-12345678 > "$SHUTDOWN_STATE_FILE"
    pending=true
    cancel_owned_shutdown > "$work/out" 2>&1 || return 1
    assert_file_content '-c' "$work/shutdown-calls" || return 1
    assert_absent "$SHUTDOWN_STATE_FILE" || return 1
    grep -Fq '已取消 NTC 安排的计划关机' "$work/out"
}

# 由 tests/logging-regression.sh 的 test_enforcement_audit_success_failure_and_no_input_echo 迁来（原用例调用已取消的
# manage_enforcement_control 子菜单）：暂停/恢复成功与失败都写审计，失败时不写执行状态，审计里没有输入内容。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_enforcement_audit_success_failure_and_no_input_echo() {
    local work
    work=$(mktemp -d "$TEST_ROOT/audit-enforcement-ml.XXXXXX") || return 1
    WORK_DIR="$work"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    CONFIG_FILE="$work/config"
    printf '%s\n' LIMIT_MODE=tc > "$CONFIG_FILE"   # 2.0：暂停、恢复只对已配置且启用的流量监控生效
    ml_load machine_set_enforcement machine_pause machine_resume write_enforcement_state_file write_enforcement_state
    acquire_monitor_cleanup_lock() { return 0; }
    release_monitor_cleanup_lock() { return 0; }
    clear_tc_rules() { return 0; }
    cancel_owned_shutdown() { return 0; }
    machine_pause > /dev/null || return 1
    grep -Fq 'EVENT=enforcement-pause RESULT=success' "$work/operations.log" || return 1
    machine_resume > /dev/null || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
    grep -Fq 'EVENT=enforcement-resume RESULT=success' "$work/operations.log" || return 1
    clear_tc_rules() { return 1; }
    if machine_pause > /dev/null 2>&1; then return 1; fi
    grep -Fq 'EVENT=enforcement-pause RESULT=failure' "$work/operations.log" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
    ! grep -Eq 'BOT_TOKEN|CHAT_ID|CONFIG_FILE|https://' "$work/operations.log"
}

# 静态契约：只有一处读 crontab（共享 read_current_crontab），cron 行格式与主脚本识别逻辑不变，
# 不再依赖日志标记或旧子菜单，首次检查用 --check。
# shellcheck disable=SC2016
test_ml_static_contracts() {
    [ "$(grep -c 'crontab -l' "$ML_SCRIPT")" -eq 1 ] || return 1
    grep -Fq 'cron_entry="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 $CRON_COMMENT"' "$ML_SCRIPT" || return 1
    grep -Fxq 'CRON_COMMENT="# TrafficCop-Lite Monitor"' "$ML_SCRIPT" || return 1
    grep -Fq "grep -Fqx '# BEGIN MANAGED DEPENDENCIES'" "$ML_SCRIPT" || return 1
    grep -Fq 'bash "$SCRIPT_PATH" --check' "$ML_SCRIPT" || return 1
    ! grep -Fq 'bash "$SCRIPT_PATH" --run' "$ML_SCRIPT" || return 1
    ! grep -Fq '正在以自动化模式运行' "$ML_SCRIPT" || return 1
    ! grep -Fq 'manage_enforcement_control' "$ML_SCRIPT" || return 1
    ! grep -Fq '进行初始配置' "$ML_SCRIPT"
}

# 计划关机检测（2.0）：systemd 250 之前的 shutdown 没有 --show，logind 安排的关机也没有常驻进程，只能看
# /run/systemd/shutdown/scheduled。主脚本、monitor、限制执行三处都据此判断，否则：monitor 每分钟重新安排关机
# （把关机一直往后推）；暂停、停用会删掉 NTC 的关机记录并说「当前没有待执行的计划关机」，关机却照样执行。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_pending_shutdown_detects_logind_schedule_without_show() {
    local work spec script prefix
    work=$(mktemp -d "$TEST_ROOT/pending-shutdown.XXXXXX") || return 1
    SYSTEMD_SHUTDOWN_SCHEDULED_FILE="$work/scheduled"
    SHUTDOWN_STATE_FILE="$work/state"
    shutdown() {
        [ "${1:-}" = --help ] || return 1
        printf '%s\n' 'shutdown [OPTIONS...] [TIME] [WALL...]' '  -c   Cancel a pending shutdown'
    }
    pgrep() { return 1; }
    busctl() { return 1; }
    command_exists() { command -v "$1" > /dev/null 2>&1; }
    for spec in "$ROOT_DIR/trafficcop-lite.sh:lite_" "$MONITOR_SCRIPT:" "$ML_SCRIPT:"; do
        script=${spec%:*}
        prefix=${spec##*:}
        load_function "$script" shutdown_state_value 2> /dev/null || true
        load_function "$script" "${prefix}has_pending_shutdown" || return 1
        load_function "$script" "${prefix}shutdown_task_token_from_state" || return 1
        load_function "$script" "${prefix}pending_shutdown_matches_owned_state" || return 1
        printf '%s\n' BOOT_ID=boot-a TASK_TOKEN=trafficcop-lite-monitor-12345678 > "$SHUTDOWN_STATE_FILE"
        rm -f "$SYSTEMD_SHUTDOWN_SCHEDULED_FILE"
        if "${prefix}has_pending_shutdown"; then return 1; fi
        printf '%s\n' USEC=1787900000000000 WARN_WALL=1 MODE=poweroff \
            'WALL_MESSAGE=TrafficCop-Lite[trafficcop-lite-monitor-12345678] 流量超出限制' > "$SYSTEMD_SHUTDOWN_SCHEDULED_FILE"
        "${prefix}has_pending_shutdown" || return 1
        "${prefix}pending_shutdown_matches_owned_state" || return 1
        printf '%s\n' BOOT_ID=boot-a TASK_TOKEN=trafficcop-lite-monitor-87654321 > "$SHUTDOWN_STATE_FILE"
        if "${prefix}pending_shutdown_matches_owned_state"; then return 1; fi
    done
}

# 停用是一个事务（2.0）：先删每分钟的检查任务，删不掉就什么都不改；之后在同一把监控锁内撤销整机限速、处理 NTC 的
# 关机记录、备份并写停用标记，任何一步失败都把删掉的定时任务加回去、不写停用标记（1.x 删定时任务失败时跳过撤销限速
# 却照写停用标记，监控看到停用就不再管，限速从此没人解除）；全部成功才清除宽限/暂停；结论如实说明有没有备份。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_disable_is_all_or_nothing() {
    local work step
    work=$(mktemp -d "$TEST_ROOT/ml-disable-tx.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/config"
    BACKUP_CONFIG_FILE="$work/config.disabled.backup"
    SHUTDOWN_STATE_FILE="$work/shutdown-state"
    ENFORCEMENT_STATE_FILE="$work/enforcement-state"
    ML_FAIL=''
    ml_load disable_machine_limit disable_restore_cron
    ml_step() { printf '%s\n' "$1" >> "$work/events"; [ "$ML_FAIL" != "$1" ]; }
    remove_cron_job() { CRON_JOB_REMOVED=true; ml_step cron-remove; }
    add_cron_job() { ml_step cron-add; }
    acquire_monitor_cleanup_lock() { ml_step lock; }
    release_monitor_cleanup_lock() { ml_step unlock; }
    clear_tc_rules() { ml_step tc; }
    cancel_owned_shutdown() { ml_step shutdown; }
    has_pending_shutdown() { return 1; }
    ml_disable_case() {
        rm -f "$work/events" "$BACKUP_CONFIG_FILE"
        printf '%s\n' LIMIT_MODE=tc > "$CONFIG_FILE"
        printf '%s\n' MODE=paused UNTIL_EPOCH=0 REASON=manual > "$ENFORCEMENT_STATE_FILE"
        ML_FAIL=$1
    }

    for step in cron-remove lock tc shutdown; do
        ml_disable_case "$step"
        if disable_machine_limit batch < /dev/null > "$work/out" 2>&1; then return 1; fi
        ! grep -q '^DISABLED=' "$CONFIG_FILE" || return 1
        [ -f "$ENFORCEMENT_STATE_FILE" ] || return 1
        grep -Fq '停用未' "$work/out" || return 1
        case "$step" in
            cron-remove) assert_file_content 'cron-remove' "$work/events" ;;
            lock) assert_file_content $'cron-remove\nlock\ncron-add' "$work/events" ;;
            tc) assert_file_content $'cron-remove\nlock\ntc\nunlock\ncron-add' "$work/events" ;;
            shutdown) assert_file_content $'cron-remove\nlock\ntc\nshutdown\nunlock\ncron-add' "$work/events" ;;
        esac || return 1
    done

    # 写停用标记失败：同样加回定时任务，不清除宽限/暂停。
    ml_disable_case ''
    mv() { return 1; }
    if disable_machine_limit batch < /dev/null > "$work/out" 2>&1; then unset -f mv; return 1; fi
    unset -f mv
    ! grep -q '^DISABLED=' "$CONFIG_FILE" || return 1
    [ -f "$ENFORCEMENT_STATE_FILE" ] || return 1
    assert_file_content $'cron-remove\nlock\ntc\nshutdown\nunlock\ncron-add' "$work/events" || return 1

    # 原来就没有定时任务：失败时也不凭空加一条。
    ml_disable_case tc
    remove_cron_job() { CRON_JOB_REMOVED=false; ml_step cron-remove; }
    if disable_machine_limit batch < /dev/null > "$work/out" 2>&1; then return 1; fi
    assert_file_content $'cron-remove\nlock\ntc\nunlock' "$work/events" || return 1
    remove_cron_job() { CRON_JOB_REMOVED=true; ml_step cron-remove; }

    # 全部成功：都在锁内完成，配置先备份，宽限/暂停清除。
    ml_disable_case ''
    disable_machine_limit batch < /dev/null > "$work/out" 2>&1 || return 1
    assert_file_content $'cron-remove\nlock\ntc\nshutdown\nunlock' "$work/events" || return 1
    grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1
    grep -Fxq 'LIMIT_MODE=tc' "$BACKUP_CONFIG_FILE" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
    grep -Fq '停用前的配置已备份' "$work/out" || return 1

    # 本来就是停用状态、也没有备份：不说「已备份」「保留原来的备份」。
    rm -f "$work/events" "$BACKUP_CONFIG_FILE"
    printf '%s\n' LIMIT_MODE=tc DISABLED=true > "$CONFIG_FILE"
    disable_machine_limit batch < /dev/null > "$work/out" 2>&1 || return 1
    ! grep -Fq '已备份' "$work/out" || return 1
    ! grep -Fq '保留原来的备份' "$work/out" || return 1
    grep -Fq '没有停用前的配置备份' "$work/out"
}

# 停用失败时只把「确实删掉了」的定时任务加回去：remove_cron_job 按删除前的 crontab 设置 CRON_JOB_REMOVED；
# 原来就没有监控任务时如实说明，不说「已移除」（2.0）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_remove_cron_job_reports_whether_a_job_existed() {
    local work job
    work=$(mktemp -d "$TEST_ROOT/ml-remove-cron.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    SCRIPT_PATH=/etc/trafficcop-lite/trafficcop-lite-monitor.sh
    job="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"
    ml_load remove_cron_job
    acquire_root_crontab_lock() { :; }
    release_root_crontab_lock() { :; }
    read_current_crontab() { cat "$work/crontab"; }
    crontab() { cat "$1" > "$work/crontab"; }

    printf '%s\n' '17 3 * * * /usr/local/bin/unrelated-backup' "$job" > "$work/crontab"
    CRON_JOB_REMOVED=''
    remove_cron_job > "$work/out" 2>&1 || return 1
    [ "$CRON_JOB_REMOVED" = true ] || return 1
    assert_file_content '17 3 * * * /usr/local/bin/unrelated-backup' "$work/crontab" || return 1
    grep -Fq '已移除流量监控的定时任务' "$work/out" || return 1

    CRON_JOB_REMOVED=''
    remove_cron_job > "$work/out" 2>&1 || return 1
    [ "$CRON_JOB_REMOVED" = false ] || return 1
    ! grep -Fq '已移除' "$work/out" || return 1
    grep -Fq '本来就没有流量监控的定时任务' "$work/out" || return 1

    printf '%s\n' "$job" > "$work/crontab"
    crontab() { return 1; }
    CRON_JOB_REMOVED=''
    if remove_cron_job > "$work/out" 2>&1; then return 1; fi
    [ "$CRON_JOB_REMOVED" = false ] || return 1
    grep -Fxq "$job" "$work/crontab"
}

# 停用或尚未配置时，暂停、宽限、恢复、开机宽限一律拒绝（退出 1），不取锁、不撤销限速、不写任何状态（2.0；1.x 照常
# 写执行状态，并说「流量照常统计」「到期后自动恢复限制」等在停用状态下不成立的话）；菜单里的宽限、开机宽限也先检查，不先提问。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_enforcement_refused_when_disabled_or_unconfigured() {
    local work rc state action
    work=$(mktemp -d "$TEST_ROOT/ml-refuse.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    ML_CALLS="$work/calls"
    ml_load machine_require_active_config machine_set_enforcement machine_grace machine_pause machine_resume \
        machine_set_boot_grace write_enforcement_state_file write_enforcement_state \
        machine_grace_interactive machine_boot_grace_interactive
    ml_stub ml_note_call acquire_monitor_cleanup_lock release_monitor_cleanup_lock clear_tc_rules cancel_owned_shutdown

    for state in unconfigured disabled; do
        rm -f "$CONFIG_FILE" "$ENFORCEMENT_STATE_FILE"
        if [ "$state" = disabled ]; then
            printf '%s\n' LIMIT_MODE=tc TC_BOOT_GRACE_MINUTES=10 DISABLED=true > "$CONFIG_FILE"
            printf '%s\n' MODE=paused UNTIL_EPOCH=0 REASON=manual > "$ENFORCEMENT_STATE_FILE"
            cp "$CONFIG_FILE" "$work/config.before" && cp "$ENFORCEMENT_STATE_FILE" "$work/enforcement.before" || return 1
        fi
        for action in 'machine_grace 30' machine_pause machine_resume 'machine_set_boot_grace 5' \
            machine_grace_interactive machine_boot_grace_interactive; do
            rc=0
            # shellcheck disable=SC2086
            $action < /dev/null > "$work/out" 2>&1 || rc=$?
            [ "$rc" -eq 1 ] || return 1
            # 拒绝时只有这一句说明：菜单入口也不先提问，不打印「宽限期间流量照常统计」这类停用时不成立的话。
            [ "$(wc -l < "$work/out")" -eq 1 ] || return 1
            if [ "$state" = disabled ]; then
                grep -Fq '流量监控已停用' "$work/out" || return 1
            else
                grep -Fq '尚未配置流量监控' "$work/out" || return 1
            fi
        done
        assert_absent "$ML_CALLS" || return 1
        if [ "$state" = disabled ]; then
            cmp -s "$work/config.before" "$CONFIG_FILE" && cmp -s "$work/enforcement.before" "$ENFORCEMENT_STATE_FILE" || return 1
        else
            assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
        fi
    done
    assert_absent "$work/operations.log"
}

# 已启用时再选「启用流量监控」（例如定时任务缺失后照提示补上）：未到期的暂停或宽限保持不变，只撤销残留的整机限速、
# 补上定时任务（2.0；1.x 会把手动暂停换成 10 分钟宽限，到期后恢复限速，关机模式下会安排关机）；
# 过期的宽限和从停用状态启用照旧先给 10 分钟启用宽限。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_enable_keeps_active_pause_or_grace() {
    local work now state
    work=$(mktemp -d "$TEST_ROOT/ml-enable-keep.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    SCRIPT_PATH="$work/monitor.sh"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"
    ml_load write_enforcement_state_file begin_enable_grace rollback_enable_machine_limit enable_rollback_state_text \
        enable_machine_limit
    acquire_monitor_cleanup_lock() { :; }
    release_monitor_cleanup_lock() { :; }
    clear_tc_rules() { printf '%s\n' clear >> "$work/calls"; }
    cancel_owned_shutdown() { printf '%s\n' cancel >> "$work/calls"; }
    clear_tc_rules_with_lock() { :; }
    bash() {
        printf '%s\n' "$*" >> "$work/calls"
        printf '%s\n' '  ✓ 检查完成：本期已用 1 GB / 阈值 499 GB，流量正常。'
    }
    add_cron_job() { printf '%s\n' cron >> "$work/calls"; }
    now=$(date +%s)

    printf '%s\n' LIMIT_MODE=tc > "$CONFIG_FILE"
    for state in 'MODE=paused UNTIL_EPOCH=0 REASON=manual' "MODE=grace UNTIL_EPOCH=$((now + 600)) REASON=manual"; do
        rm -f "$work/calls"
        # shellcheck disable=SC2086
        printf '%s\n' $state > "$ENFORCEMENT_STATE_FILE"
        cp "$ENFORCEMENT_STATE_FILE" "$work/enforcement.before" || return 1
        enable_machine_limit > "$work/out" 2>&1 || return 1
        cmp -s "$work/enforcement.before" "$ENFORCEMENT_STATE_FILE" || return 1
        assert_file_content $'clear\ncancel\n'"$SCRIPT_PATH --check"$'\ncron' "$work/calls" || return 1
        grep -Fq '保持不变' "$work/out" || return 1
        ! grep -Fq '10 分钟' "$work/out" || return 1
    done

    rm -f "$work/calls"
    printf '%s\n' MODE=grace "UNTIL_EPOCH=$((now - 60))" REASON=manual > "$ENFORCEMENT_STATE_FILE"
    enable_machine_limit > "$work/out" 2>&1 || return 1
    grep -Fxq 'REASON=enable' "$ENFORCEMENT_STATE_FILE" && grep -Fq '10 分钟' "$work/out" || return 1

    rm -f "$work/calls"
    printf '%s\n' LIMIT_MODE=tc DISABLED=true > "$CONFIG_FILE"
    printf '%s\n' MODE=paused UNTIL_EPOCH=0 REASON=manual > "$ENFORCEMENT_STATE_FILE"
    enable_machine_limit > "$work/out" 2>&1 || return 1
    grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE" && grep -Fxq 'REASON=enable' "$ENFORCEMENT_STATE_FILE"
}

# 停用后定时任务已移除，monitor_health 停在最后一次的结果：状态页的「最近检查」显示「已停用」，不再在超过 10 分钟后
# 报红色的「请检查 cron」（2.0）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_status_when_disabled_has_no_stale_error() {
    local work now
    work=$(mktemp -d "$TEST_ROOT/ml-status-disabled.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/traffic_monitor_config.txt"
    ENFORCEMENT_STATE_FILE="$work/enforcement_state"
    TC_STATE_FILE="$work/tc_limit_state"
    BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
    SCRIPT_PATH="$work/trafficcop-lite-monitor.sh"
    TC_BIN=''
    now=$(date +%s)
    printf '%s\n' MAIN_INTERFACE=eth0 LIMIT_MODE=tc LIMIT_SPEED=50 DISABLED=true > "$CONFIG_FILE"
    printf '%s\n' HEALTH=ok REASON= "UPDATED_EPOCH=$((now - 1200))" > "$work/monitor_health"
    ml_load enforcement_state_value show_monitor_task_status machine_status_collect machine_action_rows show_status
    read_root_crontab_locked() { printf '%s\n' '# 没有监控任务'; }
    get_main_interface() { printf '%s\n' eth0; }
    tc_state_value() { return 0; }

    show_status > "$work/out" 2>&1 || return 1
    grep -Fq '○ 已停用' "$work/out" || return 1
    grep -Eq '^  最近检查  已停用' "$work/out" || return 1
    ! grep -Fq '请检查 cron' "$work/out" || return 1
    ! grep -Fq '没有运行' "$work/out"
}

# 失败提示如实（2.0）：暂停/宽限时计划关机没处理完，不再一律说成「无法取消 NTC 安排的计划关机」，并说明整机限速已撤销；
# 启用失败时分清「没能撤销旧限速」与「已撤销、但没能建立启用宽限」，从停用状态启用失败时说「已恢复为停用状态」，
# 停用期间留下的宽限/暂停记录被清除时照实说明（1.x 一律说「配置和执行控制已恢复原样」）。
# shellcheck disable=SC2034,SC2209,SC2317,SC2329
test_ml_failure_messages_match_what_happened() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ml-fail-messages.XXXXXX") || return 1
    WORK_DIR="$work"
    COLUMNS=200   # 整句断言：把折行宽度设宽，不受调用环境里 COLUMNS 的影响
    CONFIG_FILE="$work/config"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    TC_STATE_FILE="$work/tc-state"
    SCRIPT_PATH="$work/monitor.sh"
    printf '%s\n' '#!/bin/bash' > "$SCRIPT_PATH"
    ml_load machine_require_active_config machine_set_enforcement machine_pause write_enforcement_state_file \
        write_enforcement_state begin_enable_grace rollback_enable_machine_limit enable_rollback_state_text \
        enable_machine_limit
    acquire_monitor_cleanup_lock() { :; }
    release_monitor_cleanup_lock() { :; }
    clear_tc_rules() { :; }
    clear_tc_rules_with_lock() { :; }
    cancel_owned_shutdown() { return 1; }
    bash() { return 0; }
    add_cron_job() { :; }

    printf '%s\n' LIMIT_MODE=tc > "$CONFIG_FILE"
    if machine_pause > "$work/out" 2>&1; then return 1; fi
    ! grep -Fq '无法取消 NTC 安排的计划关机' "$work/out" || return 1
    grep -Fq '整机限速已撤销' "$work/out" || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1

    printf '%s\n' LIMIT_MODE=tc DISABLED=true > "$CONFIG_FILE"
    clear_tc_rules() { return 1; }
    if enable_machine_limit > "$work/out" 2>&1; then return 1; fi
    grep -Fq '没能撤销旧的整机限速' "$work/out" && grep -Fq '已恢复为停用状态' "$work/out" || return 1
    grep -Fxq 'DISABLED=true' "$CONFIG_FILE" || return 1

    clear_tc_rules() { :; }
    if enable_machine_limit > "$work/out" 2>&1; then return 1; fi
    grep -Fq '旧的整机限速已撤销' "$work/out" || return 1
    ! grep -Fq '没能撤销旧的整机限速' "$work/out" || return 1

    cancel_owned_shutdown() { :; }
    bash() { return 1; }
    printf '%s\n' MODE=paused UNTIL_EPOCH=0 REASON=manual > "$ENFORCEMENT_STATE_FILE"
    if enable_machine_limit > "$work/out" 2>&1; then return 1; fi
    grep -Fq '已恢复为停用状态' "$work/out" && grep -Fq '宽限/暂停记录已清除' "$work/out" || return 1
    ! grep -Fq '恢复原样' "$work/out"
}

run_test 'machine-limit keeps v2.13 as the first version marker (2.0)' test_ml_version_header_stays_first
run_test 'machine-limit CLI rejects bad arguments with exit 2 before touching state (2.0)' test_ml_cli_rejects_bad_arguments
run_test 'machine-limit CLI actions never read stdin (2.0)' test_ml_cli_dispatch_never_reads_stdin
run_test 'machine-limit --grace/--pause/--resume/--boot-grace write the expected state (2.0)' test_ml_cli_actions_write_state
run_test 'machine-limit --clear-tc explains that the next check may limit again (2.0)' test_ml_clear_tc_explains_relimit
run_test 'machine-limit enable runs monitor --check instead of --run (2.0)' test_ml_enable_runs_check_instead_of_run
run_test 'machine-limit status reads monitor_health (ok, error, stale) (2.0)' test_ml_status_reads_monitor_health
run_test 'machine-limit menu renders without a terminal and exits on 0 or EOF (2.0)' test_ml_menu_renders_without_terminal
run_test 'machine-limit rows wrap at a narrow terminal width (2.0)' test_ml_rows_wrap_at_narrow_width
run_test 'machine-limit prompts cancel on end of input without changes (2.0)' test_ml_interactive_eof_changes_nothing
run_test 'machine-limit --disable never cancels a foreign shutdown (2.0)' test_ml_disable_batch_never_cancels_foreign_shutdown
run_test 'machine-limit shutdown cleanup does not claim a cancellation without a pending shutdown (2.0)' test_ml_cancel_owned_shutdown_reports_truthfully
run_test 'enforcement controls audit success and failure safely (2.0)' test_ml_enforcement_audit_success_failure_and_no_input_echo
run_test 'machine-limit static contracts: one crontab read, cron line, --check (2.0)' test_ml_static_contracts
run_test 'pending shutdown detection sees logind schedules without shutdown --show (2.0)' test_pending_shutdown_detects_logind_schedule_without_show
run_test 'machine-limit disable is all-or-nothing and restores cron on failure (2.0)' test_ml_disable_is_all_or_nothing
run_test 'machine-limit remove_cron_job reports whether a monitor job existed (2.0)' test_ml_remove_cron_job_reports_whether_a_job_existed
run_test 'machine-limit refuses grace/pause/resume/boot-grace when disabled or unconfigured (2.0)' test_ml_enforcement_refused_when_disabled_or_unconfigured
run_test 'machine-limit enable keeps an active pause or grace when already enabled (2.0)' test_ml_enable_keeps_active_pause_or_grace
run_test 'machine-limit status shows disabled instead of a stale cron error (2.0)' test_ml_status_when_disabled_has_no_stale_error
run_test 'machine-limit failure messages match what actually happened (2.0)' test_ml_failure_messages_match_what_happened
# ── end 2.0 machine-limit ──

printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
