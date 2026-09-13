#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "integration test requires root" >&2
    exit 1
fi

for command_name in bash flock ip jq nft sed tc unshare; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "missing integration dependency: $command_name" >&2
        exit 1
    }
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly NTC_SCRIPT="$PROJECT_DIR/trafficcop-lite-monitor.sh"
readonly MACHINE_SCRIPT="$PROJECT_DIR/trafficcop-lite-machine-limit.sh"
readonly DOG_SCRIPT="${DOG_SCRIPT:-}"

if [ ! -r "$DOG_SCRIPT" ]; then
    echo "set DOG_SCRIPT to the candidate port-traffic-dog.sh" >&2
    exit 1
fi
export DOG_SCRIPT

if [ "${TRAFFIC_TOOLS_NETNS_TEST:-0}" != "1" ]; then
    exec unshare -n env \
        TRAFFIC_TOOLS_NETNS_TEST=1 \
        DOG_SCRIPT="$DOG_SCRIPT" \
        bash "$(realpath "$0")"
fi

TEST_DIR="$(mktemp -d)"
readonly TEST_DIR
readonly DOG_TEST_CONFIG_DIR="$TEST_DIR/dog"
readonly DOG_TEST_CONFIG_FILE="$DOG_TEST_CONFIG_DIR/config.json"
readonly DOG_OWNER_FILE="$DOG_TEST_CONFIG_DIR/tc-root-qdisc.owner"
readonly NTC_WORK_DIR="$TEST_DIR/ntc"
readonly SHARED_TC_LOCK="$TEST_DIR/traffic-tools-tc.lock"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap '
    echo "cross-project integration failed at line $LINENO" >&2
    tc qdisc show dev eth0 >&2 || true
    tc class show dev eth0 >&2 || true
    tc filter show dev eth0 parent 1:0 >&2 || true
' ERR

assert_fails() {
    if "$@"; then
        echo "expected command to fail but it succeeded: $*" >&2
        return 1
    fi
}

# tc qdisc show 会输出自增的 direct_packets_stat（veth 上 IPv6 链路本地报文即可触发），
# 它与“外部 TC 是否被改动”无关；比较外部层级是否被改动前必须剔除，否则断言会随机失败。
tc_state_snapshot() {
    tc qdisc show dev eth0 | sed -E 's/ direct_packets_stat [0-9]+//'
    tc class show dev eth0
}

mkdir -p "$DOG_TEST_CONFIG_DIR/logs" "$NTC_WORK_DIR"
printf '%s\n' 'DISABLED=false' > "$NTC_WORK_DIR/traffic_monitor_config.txt"
chmod 600 "$NTC_WORK_DIR/traffic_monitor_config.txt"
jq -n '{
    global: {billing_mode: "double", data_retention_days: 30},
    ports: {
        "3265": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: false, monthly_limit: "unlimited"},
            bandwidth_limit: {enabled: true, rate: "10Mbps"}
        }
    },
    nftables: {table_name: "port_traffic_monitor", family: "inet"},
    notifications: {
        telegram: {enabled: false, status_notifications: {enabled: false}},
        wecom: {enabled: false, status_notifications: {enabled: false}}
    }
}' > "$DOG_TEST_CONFIG_FILE"
chmod 600 "$DOG_TEST_CONFIG_FILE"

ip link set lo up
ip link add eth0 type veth peer name peer0
ip link set eth0 up
ip link set peer0 up

dog_action() {
    local action="$1"
    local port="$2"
    local rate="${3:-}"

    TRAFFIC_TOOLS_TC_LOCK_FILE="$SHARED_TC_LOCK" \
    TRAFFICCOP_TC_STATE_FILE="$NTC_WORK_DIR/tc_limit_state" \
    TRAFFICCOP_CONFIG_FILE="$NTC_WORK_DIR/traffic_monitor_config.txt" \
    DOG_CONFIG_DIR="$DOG_TEST_CONFIG_DIR" \
    bash -c '
        set -euo pipefail
        action="$1"
        port="$2"
        rate="${3:-}"
        source <(sed \
            -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$DOG_CONFIG_DIR\"#" \
            -e "\$d" \
            "$DOG_SCRIPT")
        get_default_interface() { printf "%s\n" eth0; }
        case "$action" in
            init) init_nftables ;;
            apply) apply_tc_limit "$port" "$rate" ;;
            remove) remove_tc_limit "$port" ;;
            recover) recover_tc_runtime "$port" ;;
            nft-runtime) restore_runtime_state false ;;
            status) dog_tc_status ;;
            mark-owner) mark_tc_root_owned eth0 ;;
            clear-owner) remove_tc_root_owner_marker ;;
            legacy-contract) tc_consumers_match_unified_contract eth0 --owned-legacy-dog "$port" ;;
            strict-contract) tc_consumers_match_unified_contract eth0 "$port" ;;
            *) exit 2 ;;
        esac
    ' "$DOG_SCRIPT" "$action" "$port" "$rate"
}

export TRAFFIC_TOOLS_TC_LOCK_FILE="$SHARED_TC_LOCK"
export TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE="$NTC_WORK_DIR/root-crontab.lock"
# shellcheck disable=SC1090
source <(sed \
    -e "s#^WORK_DIR=.*#WORK_DIR=\"$NTC_WORK_DIR\"#" \
    -e "s#^DOG_CONFIG_FILE=.*#DOG_CONFIG_FILE=\"$DOG_TEST_CONFIG_FILE\"#" \
    -e "s#^DOG_TC_OWNER_FILE=.*#DOG_TC_OWNER_FILE=\"$DOG_OWNER_FILE\"#" \
    -e '/^# 执行主函数/,$d' \
    "$NTC_SCRIPT")

export TRAFFIC_PERIOD=monthly
export PERIOD_START_DAY=1
export MAIN_INTERFACE=eth0

# Dog 先安装：NTC 直接接管 1:1，保留 Dog 的端口类与过滤器。
dog_action init unused || exit 1
dog_action apply 3265 10mbit || exit 1
dog_class_id=$(jq -r '.ports["3265"].bandwidth_limit.class_id' "$DOG_TEST_CONFIG_FILE")
[ -n "$dog_class_id" ] && [ "$dog_class_id" != "null" ]
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

apply_tc_limit 5000 >/dev/null || exit 1
tc_root_is_htb_handle_one eth0
tc_root_has_default_30 eth0
tc_class_rate_matches eth0 1:1 5mbit 5mbit
tc_class_rate_matches eth0 1:30 1kbit 5mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
filter_state=$(tc filter show dev eth0 parent 1:0)
grep -Eq "(flowid|classid)[[:space:]]+$dog_class_id([[:space:]]|$)" <<< "$filter_state"
tc_self_check eth0 >/dev/null || exit 1

# 机器启用宽限必须实际撤销 NTC 父限速，但保留 Dog 的端口 class/filter。
monitor_test_cli="$TEST_DIR/ntc-monitor-cli.sh"
sed \
    -e "s#^WORK_DIR=.*#WORK_DIR=\"$NTC_WORK_DIR\"#" \
    -e "s#^DOG_CONFIG_FILE=.*#DOG_CONFIG_FILE=\"$DOG_TEST_CONFIG_FILE\"#" \
    -e "s#^DOG_TC_OWNER_FILE=.*#DOG_TC_OWNER_FILE=\"$DOG_OWNER_FILE\"#" \
    "$NTC_SCRIPT" > "$monitor_test_cli"
chmod 700 "$monitor_test_cli"
bash -c '
    set -euo pipefail
    machine_script="$1"
    work_dir="$2"
    monitor_script="$3"
    # shellcheck disable=SC1090
    source <(sed "/^# 主程序/,\$d" "$machine_script")
    WORK_DIR="$work_dir"
    CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
    BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
    SCRIPT_PATH="$monitor_script"
    TC_STATE_FILE="$WORK_DIR/tc_limit_state"
    ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
    SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
    MONITOR_LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
    begin_enable_grace 10 >/dev/null
' _ "$MACHINE_SCRIPT" "$NTC_WORK_DIR" "$monitor_test_cli"
[ ! -e "$TC_STATE_FILE" ]
grep -Fxq 'MODE=grace' "$ENFORCEMENT_STATE_FILE"
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
filter_state=$(tc filter show dev eth0 parent 1:0)
grep -Eq "(flowid|classid)[[:space:]]+$dog_class_id([[:space:]]|$)" <<< "$filter_state"

# 恢复 NTC 后再验证普通清理路径，避免宽限测试替代原有覆盖。
apply_tc_limit 5000 >/dev/null || exit 1
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
[ ! -e "$TC_STATE_FILE" ]
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# 清空 Dog 后让 NTC 先安装，再由 Dog 在 NTC 的全局父类下添加端口类。
dog_action remove 3265 || exit 1
assert_fails tc_root_is_htb_handle_one eth0
jq '
    .ports = {
        "3266": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: false, monthly_limit: "unlimited"},
            bandwidth_limit: {enabled: true, rate: "10Mbps"}
        }
    }
' "$DOG_TEST_CONFIG_FILE" > "$DOG_TEST_CONFIG_FILE.tmp"
mv "$DOG_TEST_CONFIG_FILE.tmp" "$DOG_TEST_CONFIG_FILE"
chmod 600 "$DOG_TEST_CONFIG_FILE"

apply_tc_limit 3000 >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 3mbit 3mbit
dog_action apply 3266 10mbit || exit 1
dog_class_id=$(jq -r '.ports["3266"].bandwidth_limit.class_id' "$DOG_TEST_CONFIG_FILE")
tc_class_rate_matches eth0 1:1 3mbit 3mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
grep -Fxq 'SCHEMA=traffic-tools-unified-htb-v1' "$TC_STATE_FILE"
grep -Fxq 'PROVIDER=trafficcop-lite' "$TC_STATE_FILE"
tc_self_check eth0 >/dev/null || exit 1

clear_owned_tc_rules "integration clear" >/dev/null || exit 1
[ ! -e "$TC_STATE_FILE" ]
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
dog_action remove 3266 || exit 1
assert_fails tc_root_is_htb_handle_one eth0

# 普通限速和自动恢复均拒绝外部层级；只有显式手动恢复才删除冲突并重建。
tc qdisc replace dev eth0 root handle 1: htb default 10
tc class replace dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
foreign_before="$(tc_state_snapshot)"
assert_fails apply_tc_limit 2000 >/dev/null
[ "$foreign_before" = "$(tc_state_snapshot)" ]
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action recover --auto
[ "$foreign_before" = "$(tc_state_snapshot)" ]
dog_action recover --manual || exit 1
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# Dog 已先恢复、NTC 尚无活动状态时，NTC 手动恢复应在原树中协调而不是误报 Dog 冲突。
LIMIT_MODE=tc
ntc_recheck_called=false
check_and_limit_traffic() { ntc_recheck_called=true; }
recover_owned_tc_hierarchy --manual >/dev/null || exit 1
[ "$ntc_recheck_called" = "true" ]
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

apply_tc_limit 2000 >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 2mbit 2mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# 外部程序再次覆盖后，自动恢复保持零修改，手动恢复读取 NTC 权威状态重建整棵树。
tc qdisc del dev eth0 root handle 1:
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
assert_fails tc_self_check eth0 >/dev/null
ntc_dog_foreign_before="$(tc_state_snapshot)"
assert_fails dog_action recover --auto
[ "$ntc_dog_foreign_before" = "$(tc_state_snapshot)" ]
dog_action recover --manual || exit 1
tc_class_rate_matches eth0 1:1 2mbit 2mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_self_check eth0 >/dev/null || exit 1
recover_owned_tc_hierarchy --auto >/dev/null || exit 1
tc_self_check eth0 >/dev/null || exit 1

clear_owned_tc_rules "integration clear" >/dev/null || exit 1
dog_action remove 3266 || exit 1
assert_fails tc_root_is_htb_handle_one eth0

# Dog 迁移 NTC 旧 TBF 后，NTC 自检必须先报告漂移，再由 NTC 重建权威状态。
tc qdisc replace dev eth0 root tbf rate 4mbit burst 32kbit latency 400ms
legacy_qdisc=$(tc qdisc show dev eth0 root | head -n 1)
{
    printf 'INTERFACE=eth0\n'
    printf 'LIMIT_SPEED=4000\n'
    printf 'QDISC_LINE=%s\n' "$legacy_qdisc"
    printf 'PROVIDER=trafficcop-lite\n'
} > "$TC_STATE_FILE"
chmod 600 "$TC_STATE_FILE"
dog_action apply 3266 10mbit || exit 1
legacy_self_check_status=0
tc_self_check eth0 > "$TEST_DIR/legacy-self-check.out" || legacy_self_check_status=$?
[ "$legacy_self_check_status" -eq 1 ]
grep -Fxq \
    'TC_SELF_CHECK=DRIFT INTERFACE=eth0 REASON=legacy-trafficcop-state-with-unified-htb ACTION=reapply-trafficcop-limit' \
    "$TEST_DIR/legacy-self-check.out"
apply_tc_limit 6000 >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 6mbit 6mbit
grep -Fxq 'SCHEMA=traffic-tools-unified-htb-v1' "$TC_STATE_FILE"
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
[ ! -e "$TC_STATE_FILE" ]
tc_root_is_htb_handle_one eth0
dog_action remove 3266 || exit 1
assert_fails tc_root_is_htb_handle_one eth0

# 纯 NTC 状态遇到外部 root 也必须先拒绝自动接管，再由显式手动入口重建。
jq '.ports = {}' "$DOG_TEST_CONFIG_FILE" > "$DOG_TEST_CONFIG_FILE.tmp"
mv "$DOG_TEST_CONFIG_FILE.tmp" "$DOG_TEST_CONFIG_FILE"
chmod 600 "$DOG_TEST_CONFIG_FILE"
apply_tc_limit 4500 >/dev/null || exit 1
tc qdisc del dev eth0 root handle 1:
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
assert_fails tc_self_check eth0 >/dev/null
ntc_foreign_before="$(tc_state_snapshot)"
assert_fails recover_owned_tc_hierarchy --auto >/dev/null
[ "$ntc_foreign_before" = "$(tc_state_snapshot)" ]
recover_owned_tc_hierarchy --manual >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 4500kbit 4500kbit
tc_self_check eth0 >/dev/null || exit 1

# 纯 NTC 层级出现额外消费者时必须报冲突；手动接管才能删除并重建。
tc class add dev eth0 parent 1:1 classid 1:999 htb rate 1kbit ceil 1mbit
assert_fails tc_self_check eth0 >/dev/null
recover_owned_tc_hierarchy --manual >/dev/null || exit 1
assert_fails tc_class_rate_matches eth0 1:999 1kbit 1mbit
tc_self_check eth0 >/dev/null || exit 1
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
assert_fails tc_root_is_htb_handle_one eth0

# NTC 自检必须覆盖 Dog 的端口 class/filter，不能只验证自身父类。
jq '
    .ports = {
        "3267": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: false, monthly_limit: "unlimited"},
            bandwidth_limit: {enabled: true, rate: "10Mbps"}
        }
    }
' "$DOG_TEST_CONFIG_FILE" > "$DOG_TEST_CONFIG_FILE.tmp"
mv "$DOG_TEST_CONFIG_FILE.tmp" "$DOG_TEST_CONFIG_FILE"
chmod 600 "$DOG_TEST_CONFIG_FILE"
dog_action apply 3267 10mbit || exit 1
apply_tc_limit 2500 >/dev/null || exit 1
dog_class_id=$(jq -r '.ports["3267"].bandwidth_limit.class_id' "$DOG_TEST_CONFIG_FILE")
tc class replace dev eth0 parent 1:1 classid "$dog_class_id" htb rate 1kbit ceil 20mbit
assert_fails tc_self_check eth0 >/dev/null
assert_fails recover_owned_tc_hierarchy --manual >/dev/null
dog_action recover --manual >/dev/null || exit 1
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_self_check eth0 >/dev/null || exit 1

# Dog/NTC 对统一层级的 class/filter 消费者集合必须给出相同且精确的判定。
tc class add dev eth0 parent 1:1 classid 1:999 htb rate 1kbit ceil 1mbit
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action status unused >/dev/null
tc class del dev eth0 classid 1:999
tc_self_check eth0 >/dev/null || exit 1
dog_action status unused >/dev/null || exit 1

tc filter add dev eth0 protocol all parent 1:0 prio 500 matchall flowid 1:30
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action status unused >/dev/null
tc filter del dev eth0 protocol all parent 1:0 prio 500
tc_self_check eth0 >/dev/null || exit 1
dog_action status unused >/dev/null || exit 1

# 缺失或额外的 nft mark 规则都不能只靠数量被误判为正常。
dog_mark_id=$(jq -r '.ports["3267"].bandwidth_limit.mark_id' "$DOG_TEST_CONFIG_FILE")
dog_mark_comment=ptd_tc_mark_3267
mark_rule=$(nft -j -a list table inet port_traffic_monitor |
    jq -r --arg comment "$dog_mark_comment" '
        [.nftables[] | .rule? | select(.comment == $comment)][0] |
        if . == null then empty else [.chain, .handle] | @tsv end
    ')
[ -n "$mark_rule" ]
IFS=$'\t' read -r mark_chain mark_handle <<< "$mark_rule"
nft delete rule inet port_traffic_monitor "$mark_chain" handle "$mark_handle"
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action status unused >/dev/null
assert_fails recover_owned_tc_hierarchy --manual >/dev/null
dog_action recover --manual >/dev/null || exit 1
tc_self_check eth0 >/dev/null || exit 1

printf 'add rule inet port_traffic_monitor output tcp sport 3267 meta mark set meta mark & 0x00000fff | %s comment "%s"\n' \
    "$dog_mark_id" "$dog_mark_comment" | nft -f -
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action status unused >/dev/null
dog_action recover --manual >/dev/null || exit 1
tc_self_check eth0 >/dev/null || exit 1

# 双方必须同样拒绝权限过宽或关键键重复的共享 NTC 状态。
chmod 666 "$TC_STATE_FILE"
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action status unused >/dev/null
chmod 600 "$TC_STATE_FILE"
printf 'LIMIT_SPEED=2500\n' >> "$TC_STATE_FILE"
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_action status unused >/dev/null
sed -i '$d' "$TC_STATE_FILE"
tc_self_check eth0 >/dev/null || exit 1

# Dog 的普通 @reboot 路径只恢复 nftables；删除 root 后不得由它重建 TC。
tc qdisc del dev eth0 root handle 1:
# 该交叉夹具没有建立完整 nft counter；即使 nft 恢复因此返回非零，也不得触碰 TC。
dog_action nft-runtime unused >/dev/null 2>&1 || true
assert_fails tc_root_is_htb_handle_one eth0
dog_action recover --manual >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 2500kbit 2500kbit

# NTC 明确禁用后，残留状态不得授权 Dog/NTC 自动恢复旧整机上限。
printf '%s\n' 'DISABLED=true' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
DISABLED=true
tc qdisc del dev eth0 root handle 1:
dog_action recover --auto >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
assert_fails tc_class_rate_matches eth0 1:1 2500kbit 2500kbit
# 禁用 NTC 后，其残留 state 不得阻止 Dog 删除最后一个端口类及空的基础 root。
dog_action remove 3267 || exit 1
assert_fails tc_root_is_htb_handle_one eth0
recover_owned_tc_hierarchy --auto >/dev/null || exit 1
assert_fails tc_root_is_htb_handle_one eth0
assert_fails tc_self_check eth0 >/dev/null
recover_owned_tc_hierarchy --manual >/dev/null || exit 1
[ ! -e "$TC_STATE_FILE" ]
assert_fails tc_root_is_htb_handle_one eth0

# 重新启用 NTC 后恢复优先父上限；移除最后一个 Dog 子类仍要保留 NTC。
printf '%s\n' 'DISABLED=false' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
DISABLED=false
dog_action apply 3267 10mbit || exit 1
apply_tc_limit 2500 >/dev/null || exit 1
dog_action remove 3267 || exit 1
jq '
    .ports["3267"].bandwidth_limit.enabled = false |
    .ports["3267"].bandwidth_limit.rate = "unlimited"
' "$DOG_TEST_CONFIG_FILE" > "$DOG_TEST_CONFIG_FILE.tmp"
mv "$DOG_TEST_CONFIG_FILE.tmp" "$DOG_TEST_CONFIG_FILE"
chmod 600 "$DOG_TEST_CONFIG_FILE"
tc_class_rate_matches eth0 1:1 2500kbit 2500kbit
[ -f "$TC_STATE_FILE" ]
assert_fails tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
assert_fails tc_root_is_htb_handle_one eth0

# Debian 12 的 fw JSON 输出无效；文本契约还必须真实接受已归属的 v1.5.2 四条 u32。
tc qdisc add dev eth0 root handle 1: htb
tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit ceil 100mbit
tc class add dev eth0 parent 1:1 classid 1:1001 htb rate 10mbit ceil 10mbit
tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 \
    match ip protocol 6 0xff match ip sport 3265 0xffff flowid 1:1001
tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 \
    match ip protocol 6 0xff match ip dport 3265 0xffff flowid 1:1001
tc filter add dev eth0 protocol ip parent 1:0 prio 1002 u32 \
    match ip protocol 17 0xff match ip sport 3265 0xffff flowid 1:1001
tc filter add dev eth0 protocol ip parent 1:0 prio 1002 u32 \
    match ip protocol 17 0xff match ip dport 3265 0xffff flowid 1:1001
dog_action mark-owner unused || exit 1
dog_action legacy-contract 1:1001 || exit 1
assert_fails dog_action strict-contract 1:1001
dog_action clear-owner unused || exit 1
tc qdisc del dev eth0 root handle 1:

echo "Dog/TrafficCop unified HTB integration tests passed"
