#!/usr/bin/env bash
# Sourced by regression.sh. All audit fixtures stay in its private TEST_ROOT.
# shellcheck disable=SC2034,SC2317,SC2329

test_operation_log_permissions_rotation_and_input() {
    local work script index
    for script in trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-machine-limit.sh trafficcop-lite-telegram.sh; do
        work=$(mktemp -d "$TEST_ROOT/audit-permissions.XXXXXX") || return 1
        WORK_DIR="$work/install"
        load_function "$ROOT_DIR/$script" ntc_operation_log || return 1
        ntc_operation_log install success || return 1
        [ "$(stat -c %a "$WORK_DIR")" = 700 ] || return 1
        [ "$(stat -c %a "$WORK_DIR/operations.log")" = 600 ] || return 1
        grep -Eq '^[0-9TZ:+-]+ 安装 NTC：成功 EVENT=install RESULT=success$' "$WORK_DIR/operations.log" || return 1
        for index in 1 2 3 4; do
            head -c 1048576 /dev/zero | tr '\0' "$index" > "$WORK_DIR/operations.log" || return 1
            ntc_operation_log update success || return 1
        done
        for index in '' .1 .2 .3; do
            [ "$(stat -c %a "$WORK_DIR/operations.log$index")" = 600 ] || return 1
        done
        [ ! -e "$WORK_DIR/operations.log.4" ] || return 1
        [ "$(head -c 1 "$WORK_DIR/operations.log.3")" = 2 ] || return 1
        cp "$WORK_DIR/operations.log" "$work/before"
        ntc_operation_log $'install\nEVENT=forged' success 2> "$work/stderr" || return 1
        ntc_operation_log install $'success\nRESULT=forged' 2>> "$work/stderr" || return 1
        cmp -s "$work/before" "$WORK_DIR/operations.log" || return 1
        ntc_operation_log update success 'token=fixture-private-value' $'request=unsafe\nforged' || return 1
        ! grep -Eq 'fixture-private-value|forged|token=|request=' "$WORK_DIR/operations.log" || return 1
    done
}

test_operation_log_failure_preserves_business_result() {
    local work
    work=$(mktemp -d "$TEST_ROOT/audit-failure.XXXXXX") || return 1
    WORK_DIR="$work/install"
    mkdir -p "$WORK_DIR"
    load_function "$ROOT_DIR/trafficcop-lite.sh" ntc_operation_log || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_shortcut || return 1
    install_all_components() { printf '%s\n' installed > "$work/business"; }
    install_shortcut_link() { return 0; }
    printf '%s\n' untouched > "$work/foreign"
    ln -s "$work/foreign" "$WORK_DIR/operations.log"
    install_shortcut >/dev/null 2> "$work/stderr" || return 1
    assert_file_content installed "$work/business" || return 1
    assert_file_content untouched "$work/foreign" || return 1
    grep -Fq 'NTC audit log unavailable' "$work/stderr" || return 1
    rm -f "$WORK_DIR/operations.log"
    ln "$work/foreign" "$WORK_DIR/operations.log"
    ntc_operation_log install success 2> "$work/stderr" || return 1
    assert_file_content untouched "$work/foreign" || return 1
    grep -Fq 'NTC audit log unavailable' "$work/stderr" || return 1
}

test_install_and_rollback_audit_results() {
    local work
    work=$(mktemp -d "$TEST_ROOT/audit-install.XXXXXX") || return 1
    WORK_DIR="$work/install"
    mkdir -p "$WORK_DIR" "$work/backup"
    load_function "$ROOT_DIR/trafficcop-lite.sh" ntc_operation_log || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" install_shortcut || return 1
    load_function "$ROOT_DIR/trafficcop-lite.sh" rollback_script_update || return 1
    install_shortcut_link() { return 0; }
    install_all_components() { return 55; }
    if install_shortcut >/dev/null; then return 1; fi
    grep -Fq 'EVENT=install RESULT=failure' "$WORK_DIR/operations.log" || return 1
    install_all_components() { return 0; }
    install_shortcut >/dev/null || return 1
    grep -Fq 'EVENT=install RESULT=success' "$WORK_DIR/operations.log" || return 1
    if rollback_script_update "$work/backup" sample.sh; then return 1; fi
    grep -Fq 'EVENT=update-rollback RESULT=failure' "$WORK_DIR/operations.log" || return 1
    printf '%s\n' old > "$work/backup/sample.sh"
    rollback_script_update "$work/backup" sample.sh || return 1
    assert_file_content old "$WORK_DIR/sample.sh" || return 1
    grep -Fq 'EVENT=update-rollback RESULT=success' "$WORK_DIR/operations.log"
}

test_operation_logging_source_is_readonly() {
    local work script
    work=$(mktemp -d "$TEST_ROOT/audit-source.XXXXXX") || return 1
    for script in trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-machine-limit.sh trafficcop-lite-telegram.sh; do
        sed "s#^WORK_DIR=.*#WORK_DIR=\"$work/install\"#" "$ROOT_DIR/$script" > "$work/$script" || return 1
        bash -uc 'source "$1"; printf "source-returned\n"' _ "$work/$script" > "$work/output" 2> "$work/stderr" || return 1
        assert_file_content source-returned "$work/output" || return 1
        assert_absent "$work/install" || return 1
    done
}

test_operation_log_view_and_status_are_readonly() {
    local work mode file permissions
    work=$(mktemp -d "$TEST_ROOT/audit-view.XXXXXX") || return 1
    sed "s#^WORK_DIR=.*#WORK_DIR=\"$work/install\"#" "$ROOT_DIR/trafficcop-lite.sh" > "$work/main.sh" || return 1
    sed "s#^WORK_DIR=.*#WORK_DIR=\"$work/install\"#" "$ROOT_DIR/trafficcop-lite-machine-limit.sh" > "$work/machine.sh" || return 1
    for mode in operations monitor telegram all; do
        bash "$work/main.sh" --logs "$mode" > "$work/output" 2> "$work/stderr" || return 1
        assert_absent "$work/install" || return 1
    done
    bash "$work/machine.sh" --status >/dev/null 2> "$work/stderr" || return 1
    assert_absent "$work/install" || return 1
    mkdir -m 750 "$work/install"
    printf '%s\n' fixture-entry > "$work/install/operations.log"
    chmod 644 "$work/install/operations.log"
    bash "$work/main.sh" --logs operations > "$work/output" || return 1
    grep -Fq fixture-entry "$work/output" || return 1
    [ "$(stat -c %a "$work/install")" = 750 ] || return 1
    [ "$(stat -c %a "$work/install/operations.log")" = 644 ] || return 1
    assert_absent "$work/install/operations.log.lock"
}

test_ifb_operation_audit_and_unchanged_apply() {
    local work
    work=$(mktemp -d "$TEST_ROOT/audit-ifb.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    load_function "$MONITOR_SCRIPT" ntc_operation_log || return 1
    apply_tc_limit 90 >/dev/null || return 1
    grep -Fq 'EVENT=tc-apply RESULT=success' "$work/operations.log" || return 1
    cp "$work/operations.log" "$work/audit-before"
    apply_tc_limit 90 >/dev/null || return 1
    cmp -s "$work/audit-before" "$work/operations.log" || return 1
    clear_owned_tc_rules test >/dev/null || return 1
    grep -Fq 'EVENT=tc-clear RESULT=success' "$work/operations.log" || return 1
    IFB_FAIL_POINT='ifb0:1:30:120kbit'
    if apply_tc_limit 120 >/dev/null; then return 1; fi
    grep -Fq 'EVENT=tc-apply RESULT=failure' "$work/operations.log"
}

test_enforcement_audit_success_failure_and_no_input_echo() {
    local work
    work=$(mktemp -d "$TEST_ROOT/audit-enforcement.XXXXXX") || return 1
    WORK_DIR="$work"
    ENFORCEMENT_STATE_FILE="$work/enforcement"
    CONFIG_FILE="$work/config"
    RED='' GREEN='' YELLOW='' CYAN='' NC=''
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" ntc_operation_log || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" manage_enforcement_control || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state_file || return 1
    load_function "$ROOT_DIR/trafficcop-lite-machine-limit.sh" write_enforcement_state || return 1
    acquire_monitor_cleanup_lock() { return 0; }
    release_monitor_cleanup_lock() { return 0; }
    clear_tc_rules() { return 0; }
    cancel_owned_shutdown() { return 0; }
    manage_enforcement_control <<< 3 >/dev/null || return 1
    grep -Fq 'EVENT=enforcement-pause RESULT=success' "$work/operations.log" || return 1
    manage_enforcement_control <<< 1 >/dev/null || return 1
    assert_absent "$ENFORCEMENT_STATE_FILE" || return 1
    grep -Fq 'EVENT=enforcement-resume RESULT=success' "$work/operations.log" || return 1
    clear_tc_rules() { return 1; }
    if manage_enforcement_control <<< 3 >/dev/null; then return 1; fi
    grep -Fq 'EVENT=enforcement-pause RESULT=failure' "$work/operations.log" || return 1
    ! grep -Eq 'BOT_TOKEN|CHAT_ID|CONFIG_FILE|https://' "$work/operations.log"
}
