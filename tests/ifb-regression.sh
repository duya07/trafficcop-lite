#!/usr/bin/env bash

# Sourced by regression.sh. All runtime writes and mocked commands stay in TEST_ROOT.
# shellcheck disable=SC2034,SC2317,SC2329
setup_ifb_fixture() {
    local function_name
    IFB_WORK="$1"
    WORK_DIR="$IFB_WORK"
    CONFIG_FILE="$IFB_WORK/config"
    TC_STATE_FILE="$IFB_WORK/tc-state"
    DOG_CONFIG_FILE="$IFB_WORK/dog.json"
    DOG_TC_OWNER_FILE="$IFB_WORK/dog-owner"
    TC_HIERARCHY_LOCK_FILE="$IFB_WORK/tc.lock"
    LOG_FILE="$IFB_WORK/log"
    MAIN_INTERFACE=eth0
    TC_BIN=mock_ifb_tc
    TC_PARENT_RATE=100gbit
    TC_DEFAULT_CLASS_RATE=1kbit
    TC_STATE_SCHEMA=traffic-tools-unified-htb-v1
    TC_STATE_PROVIDER=trafficcop-lite
    DOG_TC_MANIFEST_SCHEMA=traffic-tools-dog-classes-v1
    TC_MARK_MASK=0xfffff000
    DISABLED=false
    LIMIT_MODE=tc
    IFB_LOCK_HELD=false
    IFB_FAIL_POINT=''
    IFB_LINK_KIND=ifb
    IFB_QUERY_FAIL=''
    printf '%s\n' '{"ports":{"3265":{"enabled":true,"bandwidth_limit":{"enabled":true,"rate":"10Mbps","class_id":"1:1000"}}}}' > "$DOG_CONFIG_FILE"
    printf 'eth0|%s\n' "$(tr -d '\r\n' < /etc/machine-id)" > "$DOG_TC_OWNER_FILE"
    chmod 600 "$DOG_CONFIG_FILE" "$DOG_TC_OWNER_FILE"
    printf '%s\n' 'qdisc htb 1: root default 0x30' > "$IFB_WORK/root-eth0"
    cp "$IFB_WORK/root-eth0" "$IFB_WORK/root-ifb0"
    local device
    for device in eth0 ifb0; do
        printf '%s\n' '100gbit 100gbit' > "$IFB_WORK/$device-1:1"
        printf '%s\n' '1kbit 100gbit' > "$IFB_WORK/$device-1:30"
        printf '%s\n' '1kbit 10mbit' > "$IFB_WORK/$device-1:1000"
        printf '%s\n' 'filter parent 1: protocol ip pref 4096 flower classid 1:1000' > "$IFB_WORK/filters-$device"
    done
    cat > "$IFB_WORK/redirect" <<'EOF'
filter parent ffff: protocol ip pref 49152 u32 chain 0
filter parent ffff: protocol ip pref 49152 u32 chain 0 fh 800::800
  match 00000000/00000000 at 0
  action order 1: mirred (Egress Redirect to device ifb0) stolen
filter parent ffff: protocol ipv6 pref 49153 u32 chain 0
filter parent ffff: protocol ipv6 pref 49153 u32 chain 0 fh 801::800
  match 00000000/00000000 at 0
  action order 1: mirred (Egress Redirect to device ifb0) stolen
EOF
    cp "$IFB_WORK/redirect" "$IFB_WORK/redirect.expected"
    cp "$IFB_WORK/filters-ifb0" "$IFB_WORK/filters.expected"

    for function_name in tc_root_qdisc is_default_qdisc_line tc_file_is_secure \
        tc_file_unique_value tc_file_optional_unique_value tc_state_file_is_interpretable \
        tc_state_value tc_state_interface tc_state_is_unified_for_interface \
        trafficcop_config_is_disabled normalize_tc_rate_to_bps tc_class_line tc_class_output \
        tc_filter_output tc_class_value tc_class_rate_matches tc_root_is_htb_handle_one \
        tc_root_has_default_30 tc_root_has_parent_class dog_owner_marker_matches \
        dog_bandwidth_to_tc dog_configured_class_records dog_configured_class_ids dog_port_range_filter_complete \
        dog_live_objects_match_config tc_root_is_recognized_dog_htb tc_root_is_unified_compatible \
        dog_config_reserves_default_class tc_default_class_is_safe tc_has_other_consumers \
        tc_legacy_tbf_is_owned write_tc_state tc_verify_unified_hierarchy tc_replace_base_classes \
        tc_state_allows_boot_rebuild apply_tc_limit clear_owned_tc_rules_locked clear_owned_tc_rules \
        tc_self_check recover_owned_tc_hierarchy; do
        load_function "$MONITOR_SCRIPT" "$function_name" || return 1
    done
    # Physical single-port classification is covered by Dog; keep its parser out of this IFB fixture.
    dog_single_port_filters_complete() { return 0; }
    current_boot_id() { printf '%s\n' mock-boot; }
    get_period_start_date() { printf '%s\n' 2026-10-01; }
    resolve_tc_self_check_interface() { printf '%s\n' eth0; }
    acquire_tc_hierarchy_lock() { [ "$IFB_LOCK_HELD" = false ] || return 1; IFB_LOCK_HELD=true; }
    release_tc_hierarchy_lock() { IFB_LOCK_HELD=false; }
    ip() {
        [ "$*" = '-j -d link show dev ifb0' ] || return 55
        printf '[{"ifname":"ifb0","flags":["UP"],"linkinfo":{"info_kind":"%s"}}]\n' "$IFB_LINK_KIND"
    }
    mock_ifb_tc() {
        [ "$IFB_LOCK_HELD" = true ] || return 99
        local operation="${1:-} ${2:-}" dev='' class_id='' rate='' ceil='' parent='' index
        local args=("$@")
        for ((index=0; index<${#args[@]}-1; index++)); do
            case "${args[index]}" in
                dev) dev="${args[index+1]}" ;;
                classid) class_id="${args[index+1]}" ;;
                rate) rate="${args[index+1]}" ;;
                ceil) ceil="${args[index+1]}" ;;
                parent) parent="${args[index+1]}" ;;
            esac
        done
        [ "$IFB_QUERY_FAIL" != "$operation:$dev" ] || return 55
        case "$operation" in
            'qdisc show')
                cat "$IFB_WORK/root-$dev" || return 55
                if [ "$dev" = eth0 ] && [ "${*: -1}" != root ]; then
                    printf '%s\n' 'qdisc ingress ffff: parent ffff:fff1'
                fi
                ;;
            'class show')
                local id base class_file
                for class_file in "$IFB_WORK/$dev-"1:*; do
                    [ -f "$class_file" ] || continue
                    id="${class_file##*/"$dev"-}"
                    read -r rate ceil < "$class_file"
                    if [ "$id" = 1:1 ]; then base=root; else base='parent 1:1'; fi
                    printf 'class htb %s %s rate %s ceil %s\n' "$id" "$base" "$rate" "$ceil"
                done
                ;;
            'filter show')
                if [ "$parent" = ffff: ]; then cat "$IFB_WORK/redirect"; else cat "$IFB_WORK/filters-$dev"; fi
                ;;
            'class replace')
                printf '%s\n' "$*" >> "$IFB_WORK/mutations"
                if [ "$IFB_FAIL_POINT" = "$dev:$class_id:$ceil" ] && [ ! -e "$IFB_WORK/fault-fired" ]; then
                    : > "$IFB_WORK/fault-fired"
                    return 55
                fi
                printf '%s %s\n' "$rate" "$ceil" > "$IFB_WORK/$dev-$class_id"
                ;;
            'qdisc del')
                printf '%s\n' "$*" >> "$IFB_WORK/mutations"
                printf '%s\n' 'qdisc fq_codel 0: root' > "$IFB_WORK/root-$dev"
                ;;
            'qdisc replace')
                printf '%s\n' "$*" >> "$IFB_WORK/mutations"
                printf '%s\n' 'qdisc htb 1: root default 0x30' > "$IFB_WORK/root-$dev"
                ;;
            *) printf 'unexpected TC mutation: %s\n' "$*" >&2; return 55 ;;
        esac
    }
}

# Dog 2.x 夹具：schema 2 配置 + tc-interop.json 清单，m1 → 1:4001，出向 fw mark，入向 flower。
setup_ifb_fixture_v2() {
    setup_ifb_fixture "$1" || return 1
    rm -f "$IFB_WORK/eth0-1:1000" "$IFB_WORK/ifb0-1:1000"
    printf '%s\n' '{"schema":2,"global":{"next_monitor_id":2},"monitors":{"m1":{"ports":["3265"],"bandwidth_limit":{"enabled":true,"rate":"10mbit","class_id":"1:4001","mark_id":1409290240}}}}' > "$DOG_CONFIG_FILE"
    cat > "$IFB_WORK/tc-interop.json" <<'EOF'
{"schema":"traffic-tools-dog-classes-v1","dog_version":"2.0.0","interface":"eth0","updated_at":"2026-11-15T00:00:00Z",
 "classes":[{"id":"m1","class_id":"1:4001","rate":"10mbit","mark":1409290240,"mark_mask":4294963200,"egress":"fw","ingress":"flower","ingress_filters":8}]}
EOF
    chmod 644 "$IFB_WORK/tc-interop.json"
    printf '%s\n' '1kbit 10mbit' > "$IFB_WORK/eth0-1:4001"
    printf '%s\n' '1kbit 10mbit' > "$IFB_WORK/ifb0-1:4001"
    printf '%s\n' 'filter parent 1: protocol all pref 1 fw chain 0' \
        'filter parent 1: protocol all pref 1 fw chain 0 handle 0x54001000/0xfffff000 classid 1:4001' > "$IFB_WORK/filters-eth0"
    printf '%s\n' 'filter parent 1: protocol ip pref 100 flower chain 0 handle 0x40010001 classid 1:4001' > "$IFB_WORK/filters-ifb0"
    cp "$IFB_WORK/filters-eth0" "$IFB_WORK/filters-eth0.expected"
    cp "$IFB_WORK/filters-ifb0" "$IFB_WORK/filters.expected"
}

# mock tc 只在持有 TC 锁时应答；识别函数在生产中也总是在锁内调用。
recognized_dog_eth0() {
    local rc
    IFB_LOCK_HELD=true
    tc_root_is_recognized_dog_htb eth0
    rc=$?
    IFB_LOCK_HELD=false
    return "$rc"
}

assert_ifb_v2_objects_preserved() {
    assert_file_content '1kbit 10mbit' "$IFB_WORK/eth0-1:4001" &&
        assert_file_content '1kbit 10mbit' "$IFB_WORK/ifb0-1:4001" &&
        cmp -s "$IFB_WORK/filters-eth0.expected" "$IFB_WORK/filters-eth0" &&
        cmp -s "$IFB_WORK/filters.expected" "$IFB_WORK/filters-ifb0" &&
        cmp -s "$IFB_WORK/redirect.expected" "$IFB_WORK/redirect"
}

assert_ifb_rates() {
    assert_file_content "$1 $1" "$IFB_WORK/eth0-1:1" &&
        assert_file_content "1kbit $1" "$IFB_WORK/eth0-1:30" &&
        assert_file_content "${2:-$1} ${2:-$1}" "$IFB_WORK/ifb0-1:1" &&
        assert_file_content "1kbit ${2:-$1}" "$IFB_WORK/ifb0-1:30"
}

assert_ifb_objects_preserved() {
    assert_file_content '1kbit 10mbit' "$IFB_WORK/eth0-1:1000" &&
        assert_file_content '1kbit 10mbit' "$IFB_WORK/ifb0-1:1000" &&
        cmp -s "$IFB_WORK/filters.expected" "$IFB_WORK/filters-eth0" &&
        cmp -s "$IFB_WORK/filters.expected" "$IFB_WORK/filters-ifb0" &&
        cmp -s "$IFB_WORK/redirect.expected" "$IFB_WORK/redirect"
}

# shellcheck disable=SC2034
# The assertion also checks that no filter, redirect, qdisc or child class was rewritten.
test_ifb_apply_and_clear() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-success.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    assert_ifb_rates 90kbit || return 1
    grep -Fxq IFB_INTERFACE=ifb0 "$TC_STATE_FILE" || return 1
    clear_owned_tc_rules test >/dev/null || return 1
    assert_ifb_rates 100gbit || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_ifb_objects_preserved || return 1
    ! grep -Ev '^class replace dev (eth0|ifb0) parent (1:|1:1) classid 1:(1|30) ' "$work/mutations"
}

test_ifb_late_install_and_recovery() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-late.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    printf '%s\n' '90kbit 90kbit' > "$work/eth0-1:1"
    printf '%s\n' '1kbit 90kbit' > "$work/eth0-1:30"
    write_tc_state eth0 90 '' || return 1
    if tc_self_check eth0 > "$work/check"; then return 1; fi
    grep -Fq REASON=dog-ingress-mismatch "$work/check" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    assert_ifb_rates 90kbit || return 1
    grep -Fxq IFB_INTERFACE=ifb0 "$TC_STATE_FILE" || return 1
    printf '%s\n' '777kbit 777kbit' > "$work/ifb0-1:1"
    if tc_self_check eth0 > "$work/check"; then return 1; fi
    recover_owned_tc_hierarchy --auto >/dev/null || return 1
    assert_ifb_rates 90kbit || return 1
    tc_self_check eth0 > "$work/check" || return 1
    grep -Fq TC_SELF_CHECK=OK "$work/check" || return 1
    [ "$IFB_LOCK_HELD" = false ]
}

# shellcheck disable=SC2034
test_ifb_apply_failure_rolls_back() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-partial-rollback.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    cp "$TC_STATE_FILE" "$work/old-state"
    printf '%s\n' '777kbit 888kbit' > "$work/ifb0-1:1"
    printf '%s\n' '1kbit 999kbit' > "$work/ifb0-1:30"
    IFB_FAIL_POINT='ifb0:1:30:120kbit'
    if apply_tc_limit 120 >/dev/null; then return 1; fi
    assert_file_content '90kbit 90kbit' "$work/eth0-1:1" || return 1
    assert_file_content '1kbit 90kbit' "$work/eth0-1:30" || return 1
    assert_file_content '777kbit 888kbit' "$work/ifb0-1:1" || return 1
    assert_file_content '1kbit 999kbit' "$work/ifb0-1:30" || return 1
    [ -f "$work/fault-fired" ] || return 1
    cmp -s "$work/old-state" "$TC_STATE_FILE" || return 1
    assert_ifb_objects_preserved || return 1
    [ "$IFB_LOCK_HELD" = false ]
}

test_ifb_state_commit_failure_rolls_back() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-commit-rollback.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    cp "$TC_STATE_FILE" "$work/old-state"
    mv() {
        if [ "${*: -1}" = "$TC_STATE_FILE" ]; then
            # Both directions must already be verified, while the old state is still authoritative.
            assert_ifb_rates 120kbit || return 98
            cmp -s "$work/old-state" "$TC_STATE_FILE" || return 98
            printf '%s\n' reached > "$work/commit-attempted"
            return 55
        fi
        command mv "$@"
    }
    if apply_tc_limit 120 >/dev/null; then return 1; fi
    assert_file_content reached "$work/commit-attempted" || return 1
    assert_ifb_rates 90kbit || return 1
    cmp -s "$work/old-state" "$TC_STATE_FILE" && assert_ifb_objects_preserved
}

# shellcheck disable=SC2034
test_ifb_clear_failure_rolls_back() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-clear-rollback.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    cp "$TC_STATE_FILE" "$work/old-state"
    IFB_FAIL_POINT='ifb0:1:30:100gbit'
    if clear_owned_tc_rules test >/dev/null; then return 1; fi
    assert_ifb_rates 90kbit || return 1
    cmp -s "$work/old-state" "$TC_STATE_FILE" || return 1
    [ -f "$work/fault-fired" ] && assert_ifb_objects_preserved
}

test_ifb_state_delete_failure_rolls_back() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-delete-rollback.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    cp "$TC_STATE_FILE" "$work/old-state"
    rm() {
        if [ "${*: -1}" = "$TC_STATE_FILE" ]; then
            assert_ifb_rates 100gbit || return 98
            printf '%s\n' reached > "$work/delete-attempted"
            return 55
        fi
        command rm "$@"
    }
    if clear_owned_tc_rules test >/dev/null; then return 1; fi
    assert_file_content reached "$work/delete-attempted" || return 1
    assert_ifb_rates 90kbit || return 1
    cmp -s "$work/old-state" "$TC_STATE_FILE" && assert_ifb_objects_preserved
}

test_ifb_clear_without_physical_root() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-absent-root.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    cp "$TC_STATE_FILE" "$work/old-state"
    printf '%s\n' 'qdisc fq_codel 0: root' > "$work/root-eth0"
    rm() {
        [ "${*: -1}" != "$TC_STATE_FILE" ] || return 55
        command rm "$@"
    }
    if clear_owned_tc_rules test >/dev/null; then return 1; fi
    assert_file_content '90kbit 90kbit' "$work/ifb0-1:1" || return 1
    cmp -s "$work/old-state" "$TC_STATE_FILE" || return 1
    unset -f rm
    clear_owned_tc_rules test >/dev/null || return 1
    assert_file_content '100gbit 100gbit' "$work/ifb0-1:1" || return 1
    assert_file_content '1kbit 100gbit' "$work/ifb0-1:30" || return 1
    assert_file_content 'qdisc fq_codel 0: root' "$work/root-eth0" || return 1
    assert_absent "$TC_STATE_FILE"
}

# shellcheck disable=SC2034
test_ifb_unverified_is_zero_mutation() {
    local work failure
    for failure in missing-owner wrong-owner bad-config wrong-kind query-error redirect; do
        work=$(mktemp -d "$TEST_ROOT/ifb-unverified.XXXXXX") || return 1
        setup_ifb_fixture "$work" || return 1
        case "$failure" in
            missing-owner) rm -f "$DOG_TC_OWNER_FILE" ;;
            wrong-owner) printf '%s\n' 'eth9|foreign-machine' > "$DOG_TC_OWNER_FILE" ;;
            bad-config) chmod 666 "$DOG_CONFIG_FILE" ;;
            wrong-kind) IFB_LINK_KIND=dummy ;;
            query-error) IFB_QUERY_FAIL='class show:ifb0' ;;
            redirect) sed -i '/protocol ipv6/,$d' "$work/redirect" ;;
        esac
        if apply_tc_limit 90 >/dev/null; then return 1; fi
        assert_absent "$work/mutations" || return 1
        assert_absent "$TC_STATE_FILE" || return 1
        assert_ifb_rates 100gbit || return 1
        [ "$IFB_LOCK_HELD" = false ] || return 1
    done
}

test_ifb_self_check_detects_drift() {
    local work failure
    for failure in parent default port filter redirect; do
        work=$(mktemp -d "$TEST_ROOT/ifb-drift.XXXXXX") || return 1
        setup_ifb_fixture "$work" || return 1
        apply_tc_limit 90 >/dev/null || return 1
        case "$failure" in
            parent) printf '%s\n' '777kbit 777kbit' > "$work/ifb0-1:1" ;;
            default) printf '%s\n' '1kbit 777kbit' > "$work/ifb0-1:30" ;;
            port) rm -f "$work/ifb0-1:1000" ;;
            filter) : > "$work/filters-ifb0" ;;
            redirect) sed -i '/protocol ipv6/,$d' "$work/redirect" ;;
        esac
        cp "$work/mutations" "$work/old-mutations"
        if tc_self_check eth0 > "$work/check"; then return 1; fi
        grep -Fq REASON=dog-ingress-mismatch "$work/check" || return 1
        ! grep -Fq TC_SELF_CHECK=OK "$work/check" || return 1
        cmp -s "$work/old-mutations" "$work/mutations" || return 1
        [ "$IFB_LOCK_HELD" = false ] || return 1
    done
}

test_ifb_standalone_preserves_unknown_device() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-standalone.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    rm -f "$DOG_CONFIG_FILE" "$DOG_TC_OWNER_FILE" "$work/eth0-1:1000"
    : > "$work/filters-eth0"
    printf '%s\n' 'qdisc fq_codel 0: root' > "$work/root-eth0"
    printf '%s\n' '777kbit 777kbit' > "$work/ifb0-1:1"
    apply_tc_limit 90 >/dev/null || return 1
    ! grep -q '^IFB_INTERFACE=' "$TC_STATE_FILE" || return 1
    clear_owned_tc_rules test >/dev/null || return 1
    assert_file_content '777kbit 777kbit' "$work/ifb0-1:1" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    ! grep -Fq 'dev ifb0' "$work/mutations"
}

test_ifb_cli_self_check_is_readonly() {
    local work mode
    work=$(mktemp -d "$TEST_ROOT/ifb-readonly-cli.XXXXXX") || return 1
    mkdir -p "$work/source"
    printf '%s\n' '#!/bin/bash' 'echo "qdisc fq_codel 0: root"' > "$work/tc-mock"
    chmod 700 "$work/tc-mock"
    sed -e "s#^WORK_DIR=.*#WORK_DIR=\"$work/install\"#" \
        -e "s#^TC_BIN=.*#TC_BIN=\"$work/tc-mock\"#" \
        "$ROOT_DIR/trafficcop-lite.sh" > "$work/source/trafficcop-lite.sh" || return 1
    sed -e "s#^WORK_DIR=.*#WORK_DIR=\"$work/install\"#" \
        -e "s#^DOG_CONFIG_FILE=.*#DOG_CONFIG_FILE=\"$work/dog.json\"#" \
        -e "s#^DOG_TC_OWNER_FILE=.*#DOG_TC_OWNER_FILE=\"$work/dog-owner\"#" \
        -e "s#^TC_BIN=.*#TC_BIN=\"$work/tc-mock\"#" \
        "$MONITOR_SCRIPT" > "$work/source/trafficcop-lite-monitor.sh" || return 1
    for mode in --self-check --tc-self-check; do
        TRAFFIC_TOOLS_TC_LOCK_FILE="$work/tc.lock" bash "$work/source/trafficcop-lite.sh" "$mode" eth0 > "$work/output" || return 1
        assert_absent "$work/install" || return 1
    done
    mkdir -m 750 "$work/install"
    printf '%s\n' 'SCHEMA=traffic-tools-unified-htb-v1' 'PROVIDER=trafficcop-lite' \
        'INTERFACE=eth0' 'LIMIT_SPEED=90' > "$work/install/tc_limit_state"
    chmod 666 "$work/install/tc_limit_state"
    for mode in --self-check --tc-self-check; do
        if TRAFFIC_TOOLS_TC_LOCK_FILE="$work/tc.lock" bash "$work/source/trafficcop-lite.sh" "$mode" eth0 > "$work/output"; then return 1; fi
        grep -Fq REASON=trafficcop-state-invalid "$work/output" || return 1
        [ "$(stat -c '%a' "$work/install/tc_limit_state")" = 666 ] || return 1
        [ "$(stat -c '%a' "$work/install")" = 750 ] || return 1
        assert_absent "$work/install/traffic_monitor.log" || return 1
    done
}

test_ifb_group_and_range_class_references() {
    local work port_spec mark_id
    mark_id=$((0x50000000 | (0x1000 << 12)))
    for port_spec in 3265,3266 3265-3269; do
        work=$(mktemp -d "$TEST_ROOT/ifb-port-set.XXXXXX") || return 1
        setup_ifb_fixture "$work" || return 1
        printf '{"ports":{"%s":{"enabled":true,"bandwidth_limit":{"enabled":true,"rate":"10Mbps","class_id":"1:1000","mark_id":%s}}}}\n' \
            "$port_spec" "$mark_id" > "$DOG_CONFIG_FILE"
        dog_port_range_filter_complete() { return 0; }
        apply_tc_limit 90 >/dev/null || return 1
        assert_ifb_rates 90kbit || return 1
        tc_self_check eth0 >/dev/null || return 1
        assert_ifb_objects_preserved || return 1
    done
}

# shellcheck disable=SC2034
test_ifb_recovery_without_port_consumers() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-recover-no-ports.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    # Dog removed its final port and marker; the verified NTC state retains IFB scope.
    printf '%s\n' '{"ports":{}}' > "$DOG_CONFIG_FILE"
    rm -f "$DOG_TC_OWNER_FILE" "$work/eth0-1:1000" "$work/ifb0-1:1000"
    : > "$work/filters-eth0"
    : > "$work/filters-ifb0"
    printf '%s\n' 'qdisc fq_codel 0: root' > "$work/root-eth0"
    printf '%s\n' '777kbit 777kbit' > "$work/ifb0-1:1"
    IFB_FAIL_POINT='ifb0:1:30:90kbit'
    cp "$TC_STATE_FILE" "$work/old-state"
    if recover_owned_tc_hierarchy --auto >/dev/null 2>&1; then return 1; fi
    [ -e "$work/fault-fired" ] || return 1
    assert_file_content 'qdisc fq_codel 0: root' "$work/root-eth0" || return 1
    assert_file_content '777kbit 777kbit' "$work/ifb0-1:1" || return 1
    cmp -s "$work/old-state" "$TC_STATE_FILE" || return 1
    IFB_FAIL_POINT=''
    recover_owned_tc_hierarchy --auto >/dev/null || return 1
    assert_ifb_rates 90kbit || return 1
    grep -Fxq IFB_INTERFACE=ifb0 "$TC_STATE_FILE" || return 1
    clear_owned_tc_rules test >/dev/null || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    assert_file_content '100gbit 100gbit' "$work/ifb0-1:1" || return 1
    assert_file_content '1kbit 100gbit' "$work/ifb0-1:30" || return 1
    cmp -s "$work/redirect.expected" "$work/redirect"
}

test_ifb_invalid_ntc_state_is_zero_mutation() {
    local work failure
    for failure in mode duplicate schema provider speed device; do
        work=$(mktemp -d "$TEST_ROOT/ifb-invalid-state.XXXXXX") || return 1
        setup_ifb_fixture "$work" || return 1
        apply_tc_limit 90 >/dev/null || return 1
        case "$failure" in
            mode) chmod 666 "$TC_STATE_FILE" ;;
            duplicate) printf '%s\n' LIMIT_SPEED=90 >> "$TC_STATE_FILE" ;;
            schema) sed -i 's/^SCHEMA=.*/SCHEMA=unknown-v2/' "$TC_STATE_FILE" ;;
            provider) sed -i 's/^PROVIDER=.*/PROVIDER=foreign/' "$TC_STATE_FILE" ;;
            speed) sed -i 's/^LIMIT_SPEED=.*/LIMIT_SPEED=invalid/' "$TC_STATE_FILE" ;;
            device) sed -i 's/^IFB_INTERFACE=.*/IFB_INTERFACE=ifb9/' "$TC_STATE_FILE" ;;
        esac
        cp "$TC_STATE_FILE" "$work/invalid-state"
        cp "$work/mutations" "$work/old-mutations"
        if apply_tc_limit 120 >/dev/null; then return 1; fi
        assert_ifb_rates 90kbit || return 1
        cmp -s "$work/invalid-state" "$TC_STATE_FILE" || return 1
        cmp -s "$work/old-mutations" "$work/mutations" || return 1
        [ "$IFB_LOCK_HELD" = false ] || return 1
    done
}

test_ifb_existing_child_drift_is_zero_mutation() {
    local work operation drift
    for operation in clear apply self-check; do
        for drift in '2kbit 10mbit' '1kbit 11mbit' 'invalid 10mbit' '1kbit invalid'; do
            work=$(mktemp -d "$TEST_ROOT/ifb-child-drift.XXXXXX") || return 1
            setup_ifb_fixture "$work" || return 1
            apply_tc_limit 90 >/dev/null || return 1
            printf '%s\n' "$drift" > "$work/ifb0-1:1000"
            cp "$TC_STATE_FILE" "$work/old-state"
            cp "$work/mutations" "$work/old-mutations"
            case "$operation" in
                clear) if clear_owned_tc_rules test > "$work/output"; then return 1; fi ;;
                apply) if apply_tc_limit 120 > "$work/output"; then return 1; fi ;;
                self-check) if tc_self_check eth0 > "$work/output"; then return 1; fi ;;
            esac
            cmp -s "$work/old-state" "$TC_STATE_FILE" || return 1
            cmp -s "$work/old-mutations" "$work/mutations" || return 1
            assert_ifb_rates 90kbit || return 1
            assert_file_content "$drift" "$work/ifb0-1:1000" || return 1
            [ "$IFB_LOCK_HELD" = false ] || return 1
        done
    done
}

test_ifb_missing_child_is_only_allowed_during_clear() {
    local work device
    for device in ifb0 both; do
        work=$(mktemp -d "$TEST_ROOT/ifb-deleted-child.XXXXXX") || return 1
        setup_ifb_fixture "$work" || return 1
        apply_tc_limit 90 >/dev/null || return 1
        rm -f "$work/ifb0-1:1000"
        : > "$work/filters-ifb0"
        if [ "$device" = both ]; then
            rm -f "$work/eth0-1:1000"
            : > "$work/filters-eth0"
        fi
        cp "$TC_STATE_FILE" "$work/old-state"
        cp "$work/mutations" "$work/old-mutations"
        if apply_tc_limit 120 >/dev/null; then return 1; fi
        if tc_self_check eth0 >/dev/null; then return 1; fi
        cmp -s "$work/old-state" "$TC_STATE_FILE" || return 1
        cmp -s "$work/old-mutations" "$work/mutations" || return 1
        clear_owned_tc_rules test >/dev/null || return 1
        assert_absent "$TC_STATE_FILE" || return 1
        assert_absent "$work/ifb0-1:1000" || return 1
        assert_file_content '100gbit 100gbit' "$work/ifb0-1:1" || return 1
        assert_file_content '1kbit 100gbit' "$work/ifb0-1:30" || return 1
        cmp -s "$work/redirect.expected" "$work/redirect" || return 1
        [ "$IFB_LOCK_HELD" = false ] || return 1
    done
}

test_ifb_ntc_first_with_config_only() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-ntc-first.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    printf '%s\n' '{"ports":{"3266,3267":{"enabled":true,"bandwidth_limit":{"enabled":true,"rate":"10Mbps"}}}}' > "$DOG_CONFIG_FILE"
    rm -f "$DOG_TC_OWNER_FILE" "$work/eth0-1:1000"
    : > "$work/filters-eth0"
    printf '%s\n' 'qdisc fq_codel 0: root' > "$work/root-eth0"
    ip() { printf '%s\n' unexpected > "$work/ip-called"; return 55; }
    apply_tc_limit 90 >/dev/null || return 1
    ! grep -q '^IFB_INTERFACE=' "$TC_STATE_FILE" || return 1
    tc_self_check eth0 >/dev/null || return 1
    clear_owned_tc_rules test >/dev/null || return 1
    assert_absent "$work/ip-called" || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    ! grep -Fq 'dev ifb0' "$work/mutations"
}

test_ifb_unmaterialized_group_and_empty_class_fields() {
    local work class_field records
    for class_field in '{}' '{"class_id":null}' '{"class_id":""}'; do
        work=$(mktemp -d "$TEST_ROOT/ifb-pending-group.XXXXXX") || return 1
        setup_ifb_fixture "$work" || return 1
        jq --argjson fields "$class_field" '
            .ports["3266,3267"] = {enabled:true, bandwidth_limit:
                ({enabled:true, rate:"10Mbps"} + $fields)}
        ' "$DOG_CONFIG_FILE" > "$work/candidate.json" || return 1
        cat "$work/candidate.json" > "$DOG_CONFIG_FILE"
        records=$(dog_configured_class_records) || return 1
        [ "$records" = "$(printf '3265\t1:1000\t10mbit\t')" ] || return 1
        apply_tc_limit 90 >/dev/null || return 1
        tc_self_check eth0 >/dev/null || return 1
        clear_owned_tc_rules test >/dev/null || return 1
        assert_ifb_rates 100gbit || return 1
        assert_ifb_objects_preserved || return 1
        # Empty single-port class_id falls back without shifting the rate/mark columns.
        jq '.ports = {"3265": .ports["3265"]} | .ports["3265"].bandwidth_limit.class_id = ""' \
            "$DOG_CONFIG_FILE" > "$work/candidate.json" || return 1
        cat "$work/candidate.json" > "$DOG_CONFIG_FILE"
        records=$(dog_configured_class_records) || return 1
        [ "$records" = "$(printf '3265\t1:1cc1\t10mbit\t')" ] || return 1
        # A missing rate is invalid; it cannot be repaired by shifting another field.
        jq '.ports["3265"].bandwidth_limit.rate = ""' "$DOG_CONFIG_FILE" > "$work/candidate.json" || return 1
        cat "$work/candidate.json" > "$DOG_CONFIG_FILE"
        if dog_configured_class_records >/dev/null; then return 1; fi
    done
}

test_ifb_clear_after_dog_removed_device() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-removed-device.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    apply_tc_limit 90 >/dev/null || return 1
    printf '%s\n' '{"ports":{}}' > "$DOG_CONFIG_FILE"
    rm -f "$DOG_TC_OWNER_FILE" "$work/eth0-1:1000" "$work/ifb0-1:1000"
    : > "$work/filters-eth0"
    : > "$work/filters-ifb0"
    printf '%s\n' 'qdisc fq_codel 0: root' > "$work/root-eth0"
    ip() { return 1; }
    cp "$work/mutations" "$work/old-mutations"
    clear_owned_tc_rules test >/dev/null || return 1
    assert_absent "$TC_STATE_FILE" || return 1
    cmp -s "$work/old-mutations" "$work/mutations" || return 1
    [ "$IFB_LOCK_HELD" = false ]
}

# --- Dog 2.x（tc-interop.json 清单）---

# shellcheck disable=SC2034
test_ifb_v2_apply_and_clear() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-v2.XXXXXX") || return 1
    setup_ifb_fixture_v2 "$work" || return 1
    recognized_dog_eth0 || return 1
    apply_tc_limit 90 >/dev/null || return 1
    assert_ifb_rates 90kbit || return 1
    clear_owned_tc_rules test >/dev/null || return 1
    assert_ifb_rates 100gbit || return 1
    assert_ifb_v2_objects_preserved || return 1
    ! grep -Ev '^class replace dev (eth0|ifb0) parent (1:|1:1) classid 1:(1|30) ' "$work/mutations"
}

# 清单缺失、清单外的类、清单不安全：都必须零修改地失败。
# shellcheck disable=SC2034
test_ifb_v2_manifest_problems_fail_closed() {
    local work case_name
    for case_name in missing orphan insecure formula; do
        work=$(mktemp -d "$TEST_ROOT/ifb-v2-$case_name.XXXXXX") || return 1
        setup_ifb_fixture_v2 "$work" || return 1
        # 对照：破坏前同一夹具必须能被识别，保证下面的失败只来自这一项破坏。
        recognized_dog_eth0 || { echo "v2 $case_name: 对照未通过" >&2; return 1; }
        case "$case_name" in
            missing) rm -f "$work/tc-interop.json" ;;
            orphan) printf '%s\n' '1kbit 5mbit' > "$work/eth0-1:4002" ;;
            insecure) chmod 666 "$work/tc-interop.json" ;;
            formula) sed -i 's/"mark":1409290240/"mark":1409294336/' "$work/tc-interop.json" ;;
        esac
        if apply_tc_limit 90 >/dev/null 2>&1; then echo "v2 $case_name: apply 未失败" >&2; return 1; fi
        if [ -s "$work/mutations" ]; then echo "v2 $case_name: 有修改" >&2; return 1; fi
        if recognized_dog_eth0; then echo "v2 $case_name: 仍被识别" >&2; return 1; fi
    done
}

# 审计 H2：Dog 配置与 owner 文件都缺失，但 htb 1: 树里还有 Dog 的类——--manual 恢复不得删除 root。
# shellcheck disable=SC2034
test_recovery_refuses_root_delete_with_foreign_classes() {
    local work
    work=$(mktemp -d "$TEST_ROOT/ifb-h2.XXXXXX") || return 1
    setup_ifb_fixture_v2 "$work" || return 1
    rm -f "$DOG_CONFIG_FILE" "$DOG_TC_OWNER_FILE" "$work/tc-interop.json"
    if recover_owned_tc_hierarchy --manual > "$work/out" 2>&1; then return 1; fi
    if grep -q 'qdisc del' "$work/mutations" 2>/dev/null; then return 1; fi
    assert_file_content '1kbit 10mbit' "$work/eth0-1:4001" || return 1
    [ "$IFB_LOCK_HELD" = false ] || return 1
    grep -q 'TrafficCop 之外的分类或过滤器' "$work/out"
}

# 配置格式识别：未知格式失败关闭，1.5.x 空配置为空清单。
# shellcheck disable=SC2034
test_dog_config_schema_detection() {
    local work
    work=$(mktemp -d "$TEST_ROOT/dog-schema.XXXXXX") || return 1
    setup_ifb_fixture "$work" || return 1
    printf '%s\n' '{"schema":3,"monitors":{}}' > "$DOG_CONFIG_FILE"
    if dog_configured_class_records >/dev/null 2>&1; then return 1; fi
    dog_config_reserves_default_class || return 1
    printf '%s\n' '{"monitors":{}}' > "$DOG_CONFIG_FILE"
    if dog_configured_class_records >/dev/null 2>&1; then return 1; fi
    printf '%s\n' '{}' > "$DOG_CONFIG_FILE"
    [ "$(dog_config_schema)" = 1 ] || return 1
    [ -z "$(dog_configured_class_records)" ] || return 1
    setup_ifb_fixture_v2 "$work" || return 1
    [ "$(dog_config_schema)" = 2 ] || return 1
    [ "$(dog_configured_class_records)" = "$(printf 'm1\t1:4001\t10mbit\t1409290240')" ] || return 1
    if dog_config_reserves_default_class; then return 1; fi
}
