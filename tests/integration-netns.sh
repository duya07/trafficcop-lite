#!/bin/bash
# Dog 2.x + TrafficCop Lite 1.2 统一 HTB 真实内核集成测试。
#
# 运行在独立网络命名空间（unshare -n）中，使用真实的 tc/nft/ifb；Dog 一律通过公开 CLI 操作，
# 两者通过 Dog 写出的 tc-interop.json 清单协作。会加载 sch_htb、cls_fw、cls_flower、ifb 等
# 内核模块（全局生效），因此只在可丢弃的测试机上运行，不要在生产主机上运行。
#
# 用法：DOG_SCRIPT=/path/to/port-traffic-dog.sh sudo tests/integration-netns.sh

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

if [ ! -r "$DOG_SCRIPT" ] || ! grep -q '^readonly SCRIPT_VERSION="2\.' "$DOG_SCRIPT"; then
    echo "set DOG_SCRIPT to a Dog 2.x port-traffic-dog.sh" >&2
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
readonly DOG_MANIFEST_FILE="$DOG_TEST_CONFIG_DIR/tc-interop.json"
readonly NTC_WORK_DIR="$TEST_DIR/ntc"
readonly SHARED_TC_LOCK="$TEST_DIR/traffic-tools-tc.lock"
readonly STUB_DIR="$TEST_DIR/stub"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap '
    echo "cross-project integration failed at line $LINENO" >&2
    tc qdisc show dev eth0 >&2 || true
    tc class show dev eth0 >&2 || true
    tc filter show dev eth0 parent 1:0 >&2 || true
    cat "$DOG_MANIFEST_FILE" >&2 2>/dev/null || true
' ERR

assert_fails() {
    if "$@"; then
        echo "expected command to fail but it succeeded: $*" >&2
        return 1
    fi
}

mkdir -p "$DOG_TEST_CONFIG_DIR" "$NTC_WORK_DIR" "$STUB_DIR"
printf '%s\n' 'DISABLED=false' > "$NTC_WORK_DIR/traffic_monitor_config.txt"
chmod 600 "$NTC_WORK_DIR/traffic_monitor_config.txt"

# crontab 用文件桩，systemctl 用空桩：不触碰宿主定时任务与服务。
cat > "$STUB_DIR/crontab" <<EOF
#!/bin/bash
f="$TEST_DIR/crontab"
case "\${1:-}" in
    -l) [ -f "\$f" ] && cat "\$f" || { echo "no crontab for root" >&2; exit 1; } ;;
    -) cat > "\$f" ;;
    *) cp "\$1" "\$f" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/systemctl"
# cron 守护进程桩：Dog 的 core 依赖同时检查 cron 与 crontab，缺失时 --repair 会尝试安装软件包。
printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/cron"
chmod +x "$STUB_DIR/crontab" "$STUB_DIR/systemctl" "$STUB_DIR/cron"

ip link set lo up
ip link add eth0 type veth peer name peer0
ip link set eth0 up
ip link set peer0 up
ip addr add 192.0.2.1/24 dev eth0
ip route add default via 192.0.2.254 dev eth0

# Dog 2.x 公开 CLI；所有路径都指向测试目录。
dog_cli() {
    env PATH="$STUB_DIR:$PATH" \
        PORT_TRAFFIC_DOG_CONFIG_DIR="$DOG_TEST_CONFIG_DIR" \
        PORT_TRAFFIC_DOG_LOCK_FILE="$TEST_DIR/dog.lock" \
        PORT_TRAFFIC_DOG_SHORTCUT_PATH="$TEST_DIR/dog-shortcut" \
        PORT_TRAFFIC_DOG_INSTALL_PATH="$TEST_DIR/port-traffic-dog.sh" \
        TRAFFIC_TOOLS_TC_LOCK_FILE="$SHARED_TC_LOCK" \
        TRAFFICCOP_TC_STATE_FILE="$NTC_WORK_DIR/tc_limit_state" \
        TRAFFICCOP_CONFIG_FILE="$NTC_WORK_DIR/traffic_monitor_config.txt" \
        TRAFFICCOP_MONITOR_SCRIPT="$NTC_SCRIPT" \
        TRAFFIC_TOOLS_TC_RECOVERY_RUNNER="$TEST_DIR/tc-recovery.sh" \
        TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE="$TEST_DIR/tc-recovery.service" \
        TRAFFIC_TOOLS_SYSTEMCTL="$STUB_DIR/systemctl" \
        NO_COLOR=1 \
        bash "$DOG_SCRIPT" "$@" --yes
}

dog_limit() { dog_cli edit "$1" --limit "$2" >/dev/null; }
dog_class_for_port() {
    jq -r --arg p "$1" '.monitors | to_entries[] | select(.value.ports | index($p)) | .value.bandwidth_limit.class_id // empty' \
        "$DOG_TEST_CONFIG_FILE"
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

# LIMIT_MODE / DISABLED 等变量由上面 source 进来的 NTC 函数读取（下方对应行已禁用 SC2034）。
export TRAFFIC_PERIOD=monthly
export PERIOD_START_DAY=1
export MAIN_INTERFACE=eth0
# 2.0：开机自动恢复在“开机限速宽限”内会推迟重建 NTC 的整机上限。测试机可能刚开机（uptime 小于
# 默认 10 分钟），这里关掉开机宽限，让 --auto 恢复的断言与开机时长无关；推迟逻辑由 regression.sh 单独覆盖。
export TC_BOOT_GRACE_MINUTES=0

# ── Dog 先安装：NTC 读取清单接管 1:1，保留 Dog 的端口类、fw 过滤器与 ifb0 入向。
dog_cli add 3265 >/dev/null
dog_limit 3265 10Mbps
dog_class_id=$(dog_class_for_port 3265)
[ "$dog_class_id" = "1:4001" ]
jq -e '.schema == "traffic-tools-dog-classes-v1" and (.classes | length) == 1 and .classes[0].class_id == "1:4001"' \
    "$DOG_MANIFEST_FILE" >/dev/null
[ "$(dog_configured_class_records | cut -f2)" = "1:4001" ]
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_class_rate_matches ifb0 "$dog_class_id" 1kbit 10mbit
grep -Eq "handle 0x54001000/0xfffff000 classid $dog_class_id" <<< "$(tc filter show dev eth0 parent 1:0)"

# 审计 H1：Dog 2.x 已有限速类时，NTC 必须能施加、校验和撤销整机限速。
apply_tc_limit 5000 >/dev/null || exit 1
tc_root_is_htb_handle_one eth0
tc_root_has_default_30 eth0
tc_class_rate_matches eth0 1:1 5mbit 5mbit
tc_class_rate_matches eth0 1:30 1kbit 5mbit
tc_class_rate_matches ifb0 1:1 5mbit 5mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_self_check eth0 >/dev/null || exit 1
dog_cli --tc-status >/dev/null || exit 1

# Dog 侧的端口增删（2.0 新功能）不应破坏 NTC 的判断：ifb0 入向过滤器随成员重建，清单不变。
dog_cli edit 3265 --add 3268 >/dev/null
[ "$(tc -j filter show dev ifb0 parent 1:0 | jq --arg c "$dog_class_id" '[.[] | select((.options.classid? // "") == $c)] | length')" = 16 ]
tc_self_check eth0 >/dev/null || exit 1
dog_cli edit 3265 --del 3268 >/dev/null
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

apply_tc_limit 5000 >/dev/null || exit 1
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
[ ! -e "$TC_STATE_FILE" ]
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# 撤销 Dog 限速后树应被 Dog 清掉；再让 NTC 先安装，Dog 后加端口类（改用 edit --set 换端口）。
dog_limit 3265 0
assert_fails tc_root_is_htb_handle_one eth0
jq -e '.classes == []' "$DOG_MANIFEST_FILE" >/dev/null
dog_cli edit 3265 --set 3266 >/dev/null
apply_tc_limit 3000 >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 3mbit 3mbit
dog_limit 3266 10Mbps
dog_class_id=$(dog_class_for_port 3266)
tc_class_rate_matches eth0 1:1 3mbit 3mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
grep -Fxq 'SCHEMA=traffic-tools-unified-htb-v1' "$TC_STATE_FILE"
tc_self_check eth0 >/dev/null || exit 1
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# 清单与内核不一致（Dog 之外多出 2.x 号段的类）时，NTC 失败关闭、零修改。
tc class add dev eth0 parent 1:1 classid 1:4005 htb rate 1kbit ceil 5mbit
orphan_before="$(tc class show dev eth0)"
assert_fails apply_tc_limit 2000 >/dev/null
[ "$orphan_before" = "$(tc class show dev eth0)" ]
# Dog --repair 清理孤儿类后恢复协作。
dog_cli --repair >/dev/null || true
assert_fails grep -q '1:4005' <<< "$(tc class show dev eth0)"
apply_tc_limit 2000 >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 2mbit 2mbit
clear_owned_tc_rules "integration clear" >/dev/null || exit 1

# 审计 H2：Dog 配置、清单与 owner 文件都缺失时，--manual 恢复不得删除仍有 Dog 类的 root。
mv "$DOG_TEST_CONFIG_FILE" "$TEST_DIR/config.json.saved"
mv "$DOG_MANIFEST_FILE" "$TEST_DIR/tc-interop.json.saved"
mv "$DOG_OWNER_FILE" "$TEST_DIR/owner.saved"
h2_before="$(tc qdisc show dev eth0; tc class show dev eth0; tc filter show dev eth0 parent 1:0)"
# 必须处于 TC 模式，恢复逻辑才会走到 root 判断；否则它按设计直接返回“无需恢复”。
h2_saved_mode="${LIMIT_MODE:-}"
LIMIT_MODE=tc
assert_fails recover_owned_tc_hierarchy --manual >/dev/null 2>&1
LIMIT_MODE="$h2_saved_mode"
[ "$h2_before" = "$(tc qdisc show dev eth0; tc class show dev eth0; tc filter show dev eth0 parent 1:0)" ]
mv "$TEST_DIR/config.json.saved" "$DOG_TEST_CONFIG_FILE"
mv "$TEST_DIR/tc-interop.json.saved" "$DOG_MANIFEST_FILE"
mv "$TEST_DIR/owner.saved" "$DOG_OWNER_FILE"
tc_self_check eth0 >/dev/null || exit 1

# 普通限速与自动恢复拒绝外部层级；只有显式手动恢复才删除冲突并重建。
dog_limit 3266 0
assert_fails tc_root_is_htb_handle_one eth0
# Dog 先建立自己的限速，然后外部程序（如原版 TrafficCop）删掉 root 换成自己的 htb。
dog_limit 3266 10Mbps
tc qdisc del dev eth0 root
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
foreign_before="$(tc qdisc show dev eth0; tc class show dev eth0)"
# 在外部层级上改限速必须失败、不碰外部树，并把配置回滚到原来的 10Mbps。
assert_fails dog_limit 3266 20Mbps 2>/dev/null
[ "$foreign_before" = "$(tc qdisc show dev eth0; tc class show dev eth0)" ]
[ "$(jq -r '.monitors[] | select(.ports | index("3266")) | .bandwidth_limit.rate' "$DOG_TEST_CONFIG_FILE")" = 10mbit ]
assert_fails apply_tc_limit 2000 >/dev/null
[ "$foreign_before" = "$(tc qdisc show dev eth0; tc class show dev eth0)" ]
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_cli --recover-tc --auto >/dev/null
[ "$foreign_before" = "$(tc qdisc show dev eth0; tc class show dev eth0)" ]
dog_cli --recover-tc --manual >/dev/null || exit 1
dog_class_id=$(dog_class_for_port 3266)
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

# Dog 已先恢复、NTC 尚无活动状态时，NTC 手动恢复应在原树中协调而不是误报 Dog 冲突。
# shellcheck disable=SC2034
LIMIT_MODE=tc
ntc_recheck_called=false
check_and_limit_traffic() { ntc_recheck_called=true; }
recover_owned_tc_hierarchy --manual >/dev/null || exit 1
[ "$ntc_recheck_called" = "true" ]
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit

apply_tc_limit 2000 >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 2mbit 2mbit

# 外部程序再次覆盖后，自动恢复保持零修改，手动恢复读取 NTC 权威状态重建整棵树。
tc qdisc del dev eth0 root handle 1:
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit
assert_fails tc_self_check eth0 >/dev/null
ntc_dog_foreign_before="$(tc qdisc show dev eth0; tc class show dev eth0)"
assert_fails dog_cli --recover-tc --auto >/dev/null
[ "$ntc_dog_foreign_before" = "$(tc qdisc show dev eth0; tc class show dev eth0)" ]
dog_cli --recover-tc --manual >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 2mbit 2mbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_self_check eth0 >/dev/null || exit 1
recover_owned_tc_hierarchy --auto >/dev/null || exit 1
tc_self_check eth0 >/dev/null || exit 1

# NTC 自检必须覆盖 Dog 的端口 class，不能只验证自身父类；Dog 手动恢复修正漂移。
tc class replace dev eth0 parent 1:1 classid "$dog_class_id" htb rate 1kbit ceil 20mbit
assert_fails tc_self_check eth0 >/dev/null
assert_fails recover_owned_tc_hierarchy --manual >/dev/null
dog_cli --recover-tc --manual >/dev/null || exit 1
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
tc_self_check eth0 >/dev/null || exit 1

# 双方必须同样拒绝权限过宽或关键键重复的共享 NTC 状态。
chmod 666 "$TC_STATE_FILE"
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_cli --tc-status >/dev/null
chmod 600 "$TC_STATE_FILE"
printf 'LIMIT_SPEED=2000\n' >> "$TC_STATE_FILE"
assert_fails tc_self_check eth0 >/dev/null
assert_fails dog_cli --tc-status >/dev/null
sed -i '$d' "$TC_STATE_FILE"
tc_self_check eth0 >/dev/null || exit 1

# Dog 的 @reboot 路径（--boot）只恢复 nftables；删除 root 后不得由它重建 TC。
tc qdisc del dev eth0 root handle 1:
dog_cli --boot >/dev/null 2>&1 || true
assert_fails tc_root_is_htb_handle_one eth0
dog_cli --recover-tc --manual >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 2mbit 2mbit

# NTC 明确禁用后，残留状态不得授权 Dog/NTC 自动恢复旧整机上限。
printf '%s\n' 'DISABLED=true' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
DISABLED=true
tc qdisc del dev eth0 root handle 1:
dog_cli --recover-tc --auto >/dev/null || exit 1
tc_class_rate_matches eth0 1:1 100gbit 100gbit
tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
dog_limit 3266 0
assert_fails tc_root_is_htb_handle_one eth0
recover_owned_tc_hierarchy --manual >/dev/null || exit 1
[ ! -e "$TC_STATE_FILE" ]
assert_fails tc_root_is_htb_handle_one eth0

# 重新启用 NTC 后，移除最后一个 Dog 子类仍要保留 NTC 的父上限。
printf '%s\n' 'DISABLED=false' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
# shellcheck disable=SC2034
DISABLED=false
dog_limit 3266 10Mbps
apply_tc_limit 2500 >/dev/null || exit 1
dog_limit 3266 0
tc_class_rate_matches eth0 1:1 2500kbit 2500kbit
[ -f "$TC_STATE_FILE" ]
assert_fails tc_class_rate_matches eth0 "$dog_class_id" 1kbit 10mbit
clear_owned_tc_rules "integration clear" >/dev/null || exit 1
assert_fails tc_root_is_htb_handle_one eth0

echo "Dog 2.x / TrafficCop 1.2 unified HTB integration tests passed"
