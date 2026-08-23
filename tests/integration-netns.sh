#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "integration test requires root" >&2
    exit 1
fi

for command_name in bash flock ip jq sed tc unshare; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "missing integration dependency: $command_name" >&2
        exit 1
    }
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly NTC_SCRIPT="$PROJECT_DIR/trafficcop-lite-monitor.sh"
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

mkdir -p "$DOG_TEST_CONFIG_DIR/logs" "$NTC_WORK_DIR"
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
            apply) apply_tc_limit "$port" "$rate" ;;
            remove) remove_tc_limit "$port" ;;
            recover) recover_tc_runtime "$port" ;;
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
dog_action apply 3265 10mbit
dog_class_id=$(jq -r '.ports["3265"].bandwidth_limit.class_id' "$DOG_TEST_CONFIG_FILE")
[ -n "$dog_class_id" ] && [ "$dog_class_id" != "null" ]
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

apply_tc_limit 5000 >/dev/null
tc_root_is_htb_handle_one eth0
tc_root_has_default_30 eth0
tc_class_rate_matches eth0 1:1 5mbit 5mbit
tc_class_rate_matches eth0 1:30 1kbit 5mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
filter_state=$(tc filter show dev eth0 parent 1:0)
grep -Eq "(flowid|classid)[[:space:]]+$dog_class_id([[:space:]]|$)" <<< "$filter_state"
tc_self_check eth0 >/dev/null

clear_owned_tc_rules "integration clear" >/dev/null
[ ! -e "$TC_STATE_FILE" ]
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# 清空 Dog 后让 NTC 先安装，再由 Dog 在 NTC 的全局父类下添加端口类。
dog_action remove 3265
! tc_root_is_htb_handle_one eth0
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

apply_tc_limit 3000 >/dev/null
tc_class_rate_matches eth0 1:1 3mbit 3mbit
dog_action apply 3266 10mbit
dog_class_id=$(jq -r '.ports["3266"].bandwidth_limit.class_id' "$DOG_TEST_CONFIG_FILE")
tc_class_rate_matches eth0 1:1 3mbit 3mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
grep -Fxq 'SCHEMA=traffic-tools-unified-htb-v1' "$TC_STATE_FILE"
grep -Fxq 'PROVIDER=trafficcop-lite' "$TC_STATE_FILE"
tc_self_check eth0 >/dev/null

clear_owned_tc_rules "integration clear" >/dev/null
[ ! -e "$TC_STATE_FILE" ]
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
dog_action remove 3266
! tc_root_is_htb_handle_one eth0

# 普通限速继续拒绝外部层级；显式共享恢复则删除冲突并重建 Dog/NTC。
tc qdisc replace dev eth0 root handle 1: htb default 10
tc class replace dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
foreign_before="$(tc qdisc show dev eth0; tc class show dev eth0)"
! apply_tc_limit 2000 >/dev/null
[ "$foreign_before" = "$(tc qdisc show dev eth0; tc class show dev eth0)" ]
! tc_self_check eth0 >/dev/null
dog_action recover --auto
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# Dog 已先恢复、NTC 尚无活动状态时，NTC 手动恢复应在原树中协调而不是误报 Dog 冲突。
LIMIT_MODE=tc
ntc_recheck_called=false
check_and_limit_traffic() { ntc_recheck_called=true; }
recover_owned_tc_hierarchy --manual >/dev/null
[ "$ntc_recheck_called" = "true" ]
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

apply_tc_limit 2000 >/dev/null
tc_class_rate_matches eth0 1:1 2mbit 2mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# 外部程序再次覆盖后，由 Dog 读取 NTC 权威状态并一次性恢复父类和端口子类。
tc qdisc del dev eth0 root handle 1:
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
! tc_self_check eth0 >/dev/null
dog_action recover --auto
tc_class_rate_matches eth0 1:1 2mbit 2mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_self_check eth0 >/dev/null
recover_owned_tc_hierarchy --auto >/dev/null
tc_self_check eth0 >/dev/null

clear_owned_tc_rules "integration clear" >/dev/null
dog_action remove 3266
! tc_root_is_htb_handle_one eth0

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
dog_action apply 3266 10mbit
legacy_self_check_status=0
tc_self_check eth0 > "$TEST_DIR/legacy-self-check.out" || legacy_self_check_status=$?
[ "$legacy_self_check_status" -eq 1 ]
grep -Fxq \
    'TC_SELF_CHECK=DRIFT INTERFACE=eth0 REASON=legacy-trafficcop-state-with-unified-htb ACTION=reapply-trafficcop-limit' \
    "$TEST_DIR/legacy-self-check.out"
apply_tc_limit 6000 >/dev/null
tc_class_rate_matches eth0 1:1 6mbit 6mbit
grep -Fxq 'SCHEMA=traffic-tools-unified-htb-v1' "$TC_STATE_FILE"
clear_owned_tc_rules "integration clear" >/dev/null
[ ! -e "$TC_STATE_FILE" ]
tc_root_is_htb_handle_one eth0
dog_action remove 3266
! tc_root_is_htb_handle_one eth0

# 纯 NTC 的持久状态被外部 root 覆盖时，显式自动恢复入口可独立重建。
jq '.ports = {}' "$DOG_TEST_CONFIG_FILE" > "$DOG_TEST_CONFIG_FILE.tmp"
mv "$DOG_TEST_CONFIG_FILE.tmp" "$DOG_TEST_CONFIG_FILE"
chmod 600 "$DOG_TEST_CONFIG_FILE"
apply_tc_limit 4500 >/dev/null
tc qdisc del dev eth0 root handle 1:
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
! tc_self_check eth0 >/dev/null
recover_owned_tc_hierarchy --auto >/dev/null
tc_class_rate_matches eth0 1:1 4500kbit 4500kbit
tc_self_check eth0 >/dev/null
clear_owned_tc_rules "integration clear" >/dev/null
! tc_root_is_htb_handle_one eth0

echo "Dog/TrafficCop unified HTB integration tests passed"
