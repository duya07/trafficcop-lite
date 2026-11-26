#!/bin/bash

# TrafficCop 机器限速管理脚本 v2.13
# NTC「限制执行」组件：启用/停用流量监控、宽限、暂停与恢复限制、开机宽限。
# 上一行的组件版本号供 1.x 更新器判断升降级（只增不减，必须是全文件第一处版本号）；
# SCRIPT_VERSION 只用于显示。
SCRIPT_VERSION="2.0.0"

WORK_DIR="/etc/trafficcop-lite"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-monitor.sh"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
MONITOR_LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
VNSTAT_CONFIG_PATH_FILE="$WORK_DIR/vnstat_config_path"
ROOT_CRONTAB_LOCK_FILE="${TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE:-$WORK_DIR/root-crontab.lock}"
TC_STATE_SCHEMA="traffic-tools-unified-htb-v1"
TC_STATE_PROVIDER="trafficcop-lite"
CRON_COMMENT="# TrafficCop-Lite Monitor"

# >>> ntc-common:tc-bin >>>
# 本区块由 tools/sync-common.sh 根据 src/common/tc-bin.sh 生成，请改源文件后运行该脚本，勿直接修改。
find_tc_bin() {
    local candidate
    for candidate in /usr/sbin/tc /sbin/tc /usr/bin/tc /bin/tc; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    command -v tc 2>/dev/null || true
}
# <<< ntc-common:tc-bin <<<

TC_BIN="$(find_tc_bin)"

# >>> ntc-common:audit >>>
# 本区块由 tools/sync-common.sh 根据 src/common/audit.sh 生成，请改源文件后运行该脚本，勿直接修改。
# Only fixed event/result values are accepted; extra arguments are never recorded.
ntc_operation_log() {
    local event="${1:-}" result="${2:-}"
    case "$event" in
        install|update|update-rollback|monitor-config|config-rollback|tc-apply|tc-clear|tc-recover|stop|machine-enable|machine-disable|machine-restore|machine-rollback|enforcement-pause|enforcement-resume|enforcement-grace|boot-grace|telegram-config|telegram-enable|telegram-disable) ;;
        *) printf '%s\n' 'NTC audit event rejected' >&2; return 0 ;;
    esac
    case "$result" in
        success|failure|unchanged) ;;
        *) printf '%s\n' 'NTC audit result rejected' >&2; return 0 ;;
    esac
    local description result_text
    case "$event" in
        install) description="安装 NTC" ;;
        update) description="更新脚本" ;;
        update-rollback) description="恢复更新前的脚本" ;;
        monitor-config) description="保存流量监控配置" ;;
        config-rollback) description="恢复原配置" ;;
        tc-apply) description="应用整机限速" ;;
        tc-clear) description="撤销整机限速" ;;
        tc-recover) description="恢复 Dog/NTC 限速" ;;
        stop) description="停止监控和通知" ;;
        machine-enable) description="启用整机流量限制" ;;
        machine-disable) description="停用整机流量限制" ;;
        machine-restore) description="恢复整机流量配置" ;;
        machine-rollback) description="回退整机流量配置" ;;
        enforcement-pause) description="暂停流量限制" ;;
        enforcement-resume) description="恢复流量限制" ;;
        enforcement-grace) description="设置临时宽限期" ;;
        boot-grace) description="设置开机宽限期" ;;
        telegram-config) description="保存 Telegram 通知配置" ;;
        telegram-enable) description="启用 Telegram 通知" ;;
        telegram-disable) description="停用 Telegram 通知" ;;
    esac
    case "$result" in success) result_text="成功" ;; failure) result_text="失败" ;; unchanged) result_text="保持不变" ;; esac
    if ! (
        umask 077
        [ -n "${WORK_DIR:-}" ] && [ ! -L "$WORK_DIR" ] || exit 1
        mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR" || exit 1
        audit_file="$WORK_DIR/operations.log"
        for audit_path in "$audit_file" "$audit_file.1" "$audit_file.2" "$audit_file.3" "$audit_file.lock"; do
            [ ! -L "$audit_path" ] || exit 1
            if [ -e "$audit_path" ]; then
                [ -f "$audit_path" ] && [ "$(stat -c %h "$audit_path")" = 1 ] || exit 1
                chmod 600 "$audit_path" || exit 1
            fi
        done
        exec 8>"$audit_file.lock" || exit 1
        chmod 600 "$audit_file.lock" && flock -w 2 8 || exit 1
        if [ -f "$audit_file" ] && [ "$(stat -c %s "$audit_file")" -ge 1048576 ]; then
            rm -f "$audit_file.3" || exit 1
            [ ! -f "$audit_file.2" ] || mv -f "$audit_file.2" "$audit_file.3" || exit 1
            [ ! -f "$audit_file.1" ] || mv -f "$audit_file.1" "$audit_file.2" || exit 1
            mv -f "$audit_file" "$audit_file.1" || exit 1
        fi
        : >> "$audit_file" && chmod 600 "$audit_file" || exit 1
        printf '%s %s：%s EVENT=%s RESULT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$description" "$result_text" "$event" "$result" >> "$audit_file" || exit 1
    ) 2>/dev/null; then
        printf 'NTC 操作日志写入失败，业务结果保持原值 (NTC audit log unavailable EVENT=%s RESULT=%s)\n' "$event" "$result" >&2
    fi
    # Logging failures must never change the business result or the caller's shell options.
    return 0
}
# <<< ntc-common:audit <<<

read_current_crontab() {
    local current_crontab="" status=0
    current_crontab=$(LC_ALL=C crontab -l 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$current_crontab"
        return 0
    fi
    grep -Eqi 'no crontab for|no such file or directory' <<< "$current_crontab" && return 0
    printf '%s\n' '无法读取 root crontab。' >&2
    return 1
}

# >>> ntc-common:crontab-lock >>>
# 本区块由 tools/sync-common.sh 根据 src/common/crontab-lock.sh 生成，请改源文件后运行该脚本，勿直接修改。
acquire_root_crontab_lock() {
    mkdir -p "$(dirname "$ROOT_CRONTAB_LOCK_FILE")" || return 1
    exec 7>"$ROOT_CRONTAB_LOCK_FILE" || return 1
    if ! flock -w 15 7; then
        exec 7>&-
        return 1
    fi
}

release_root_crontab_lock() {
    flock -u 7 2>/dev/null || true
    exec 7>&-
}
# <<< ntc-common:crontab-lock <<<

read_root_crontab_locked() {
    # Crontab installs are atomic; a status snapshot needs no writer lock or files.
    read_current_crontab
}

tc_state_value() {
    local key="$1"
    if [ -f "$TC_STATE_FILE" ]; then
        grep "^${key}=" "$TC_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

tc_root_qdisc() {
    local interface="$1"
    local qdisc_state qdisc_line
    [ -n "$TC_BIN" ] && [ -n "$interface" ] || return 2
    qdisc_state=$("$TC_BIN" qdisc show dev "$interface" root 2>/dev/null) || return 2
    qdisc_line=$(awk 'NR == 1 { print; exit }' <<< "$qdisc_state")
    [ -n "$qdisc_line" ] || return 1
    printf '%s\n' "$qdisc_line"
}

tc_class_output() {
    local interface="$1"
    [ -n "$TC_BIN" ] && [ -n "$interface" ] || return 2
    "$TC_BIN" class show dev "$interface" 2>/dev/null || return 2
}

# >>> ntc-common:enforcement-state >>>
# 本区块由 tools/sync-common.sh 根据 src/common/enforcement-state.sh 生成，请改源文件后运行该脚本，勿直接修改。
enforcement_state_value() {
    local key="$1"
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        grep "^${key}=" "$ENFORCEMENT_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

write_enforcement_state_file() {
    local mode="$1"
    local until_epoch="$2"
    local reason="$3"
    local target_file="$4"
    local tmp_file="${target_file}.tmp.$$"

    {
        printf 'MODE=%s\n' "$mode"
        printf 'UNTIL_EPOCH=%s\n' "$until_epoch"
        printf 'REASON=%s\n' "$reason"
        printf 'UPDATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"
}

write_enforcement_state() {
    write_enforcement_state_file "$1" "$2" "$3" "$ENFORCEMENT_STATE_FILE"
}
# <<< ntc-common:enforcement-state <<<

# 系统里是否有待执行的计划关机。systemd-logind 安排的关机会写 /run/systemd/shutdown/scheduled（取消时删除），
# 各个 systemd 版本都有；shutdown --show 要 systemd 250 起才有，logind 的计划关机也没有常驻进程，
# 只看 --show 或 pgrep 会漏掉它（monitor 会每分钟重新安排关机，暂停/停用会误删 NTC 的关机记录），所以先看这个文件。
has_pending_shutdown() {
    [ ! -e "${SYSTEMD_SHUTDOWN_SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}" ] || return 0
    if shutdown --help 2>&1 | grep -q -- '--show'; then
        shutdown --show >/dev/null 2>&1
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -x shutdown >/dev/null 2>&1
    else
        return 1
    fi
}

shutdown_task_token_from_state() {
    local task_token
    task_token=$(grep '^TASK_TOKEN=' "$SHUTDOWN_STATE_FILE" 2>/dev/null |
        tail -n 1 | cut -d'=' -f2-)
    [[ "$task_token" =~ ^trafficcop-lite-[0-9A-Za-z-]{8,80}$ ]] || return 1
    printf '%s\n' "$task_token"
}

pending_shutdown_matches_owned_state() {
    local task_token wall_state
    has_pending_shutdown || return 1
    task_token=$(shutdown_task_token_from_state) || return 1
    if command -v busctl >/dev/null 2>&1; then
        wall_state=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager WallMessage 2>/dev/null || true)
        if [ -n "$wall_state" ] && grep -Fq "$task_token" <<< "$wall_state"; then
            return 0
        fi
    fi
    if [ -r "${SYSTEMD_SHUTDOWN_SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}" ] &&
       grep -Fq "$task_token" "${SYSTEMD_SHUTDOWN_SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 只取消 NTC 自己安排的计划关机（状态文件里的开机 ID 与任务标识都要对上），绝不取消别的程序安排的关机。
cancel_owned_shutdown() {
    local state_boot current_boot

    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        state_boot=$(grep '^BOOT_ID=' "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [ -n "$state_boot" ] && [ -n "$current_boot" ] && [ "$state_boot" != "$current_boot" ]; then
            rm -f "$SHUTDOWN_STATE_FILE" || { ui_err "无法删除关机记录 $SHUTDOWN_STATE_FILE。"; return 1; }
            ui_ok "已清理上次开机遗留的关机记录（本次开机的计划关机未受影响）。"
            return 0
        fi
        if { [ -z "$state_boot" ] || [ -z "$current_boot" ]; } && has_pending_shutdown; then
            ui_err "无法确认当前的计划关机是否由 NTC 安排，系统里的计划关机和 NTC 的关机记录都已保留。"
            return 1
        fi
        if has_pending_shutdown; then
            if ! pending_shutdown_matches_owned_state; then
                ui_err "当前的计划关机与 NTC 记录的任务标识不符（可能由其他程序安排），未取消；NTC 的关机记录已保留。"
                return 1
            fi
            if ! shutdown -c 2>/dev/null || has_pending_shutdown; then
                ui_err "无法取消 NTC 安排的计划关机，关机记录已保留。"
                return 1
            fi
            rm -f "$SHUTDOWN_STATE_FILE" || { ui_err "计划关机已取消，但无法删除关机记录 $SHUTDOWN_STATE_FILE。"; return 1; }
            ui_ok "已取消 NTC 安排的计划关机。"
            return 0
        fi
        rm -f "$SHUTDOWN_STATE_FILE" || { ui_err "无法删除关机记录 $SHUTDOWN_STATE_FILE。"; return 1; }
        ui_ok "已清理 NTC 的关机记录（当前没有待执行的计划关机）。"
    fi
}

# 启用前的安全窗口：在监控锁内撤销旧的整机限速、取消 NTC 自己安排的计划关机，再写入启用宽限。
# $1=宽限分钟数；$2=keep 时保留现有的暂停/宽限（已启用时补定时任务用），只撤销限速、处理关机。
# ENABLE_TC_CLEAR_ATTEMPTED：已尝试撤销限速；ENABLE_TC_CLEARED：限速确已撤销（启用失败时据此说明）。
begin_enable_grace() {
    local grace_minutes="${1:-10}" keep_state="${2:-}"
    local until_epoch result=0
    local enforcement_candidate="${ENFORCEMENT_STATE_FILE}.enable-candidate.$$"

    ENABLE_TC_CLEAR_ATTEMPTED=false
    ENABLE_TC_CLEARED=false
    if ! [[ "$grace_minutes" =~ ^[0-9]{1,4}$ ]] || [ $((10#$grace_minutes)) -lt 1 ] || [ $((10#$grace_minutes)) -gt 1440 ]; then
        grace_minutes=10
    fi
    grace_minutes=$((10#$grace_minutes))
    until_epoch=$(( $(date +%s) + grace_minutes * 60 ))
    rm -f "$enforcement_candidate"
    if [ "$keep_state" != keep ] &&
       ! write_enforcement_state_file "grace" "$until_epoch" "enable" "$enforcement_candidate"; then
        rm -f "$enforcement_candidate"
        return 1
    fi

    if ! acquire_monitor_cleanup_lock; then
        rm -f "$enforcement_candidate"
        return 1
    fi
    # 在同一监控锁内先撤销旧整机限速，再取消自有计划关机，最后提交宽限状态。
    # 因此成功返回时，“宽限期间只统计”与实际 TC/关机运行态一致。
    ENABLE_TC_CLEAR_ATTEMPTED=true
    clear_tc_rules || result=$?
    if [ "$result" -eq 0 ]; then
        ENABLE_TC_CLEARED=true
        cancel_owned_shutdown || result=$?
    fi
    if [ "$result" -eq 0 ] && [ "$keep_state" != keep ] &&
       ! mv -f "$enforcement_candidate" "$ENFORCEMENT_STATE_FILE"; then
        result=1
    fi
    release_monitor_cleanup_lock
    rm -f "$enforcement_candidate"
    return "$result"
}

# >>> ntc-common:ui >>>
# 本区块由 tools/sync-common.sh 根据 src/common/ui.sh 生成，请改源文件后运行该脚本，勿直接修改。
# ── 终端界面（与 Port Traffic Dog 2.1 的 src/16-ui.sh 同一套约定）──────────
# 标题粗体青色，编号青色，分隔线、组标题与提示变暗；状态用绿/黄/红。
# 只画横线、不画右边框：东亚歧义宽度按双宽显示的终端会把右边框挤乱。
# 宽度一律按“显示列数”计算（中日韩全角字符占 2 列）；bash 的 printf %-Ns 按字节补齐，不能用于中文。
# 只有标准输出是终端、没有设置 NO_COLOR、TERM 不是 dumb 时才输出颜色，日志和管道里没有控制序列。
# 四个脚本共用同一套颜色，并非每个脚本都用到全部颜色（SC2034 对整个代码块关闭）。
# shellcheck disable=SC2034
{
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[0;37m'
    BOLD='\033[1m'
    BOLD_CYAN='\033[1;36m'
    DIM='\033[2m'
    NC='\033[0m'
    if [ ! -t 1 ] || [ -n "${NO_COLOR+x}" ] || [ "${TERM:-dumb}" = dumb ]; then
        RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' WHITE='' BOLD='' BOLD_CYAN='' DIM='' NC=''
    fi
    UI_RULE_MAX=76
}

# 把 $2 的显示宽度写入变量 $1（不开子进程，供循环里使用）。
# 双宽：东亚宽/全角字符（Unicode East_Asian_Width 为 W/F），含常见 emoji；组合附加符与变体选择符为 0。
ui_measure() {
    local -n __ui_width_out=$1
    local __ui_text="$2" __ui_i __ui_c __ui_w=0 LC_CTYPE=C.UTF-8
    for ((__ui_i = 0; __ui_i < ${#__ui_text}; __ui_i++)); do
        printf -v __ui_c '%d' "'${__ui_text:__ui_i:1}"
        if (( __ui_c < 0x300 )); then
            __ui_w=$((__ui_w + 1))
        elif (( (__ui_c <= 0x36f) || (__ui_c >= 0x200b && __ui_c <= 0x200f) || (__ui_c >= 0xfe00 && __ui_c <= 0xfe0f) )); then
            continue
        elif (( (__ui_c >= 0x1100 && __ui_c <= 0x115f) || (__ui_c >= 0x2e80 && __ui_c <= 0xa4cf) ||
                (__ui_c >= 0xac00 && __ui_c <= 0xd7a3) || (__ui_c >= 0xf900 && __ui_c <= 0xfaff) ||
                (__ui_c >= 0xfe30 && __ui_c <= 0xfe4f) || (__ui_c >= 0xff00 && __ui_c <= 0xff60) ||
                (__ui_c >= 0xffe0 && __ui_c <= 0xffe6) || (__ui_c >= 0x1f300 && __ui_c <= 0x1f64f) ||
                (__ui_c >= 0x1f680 && __ui_c <= 0x1f6ff) || (__ui_c >= 0x1f900 && __ui_c <= 0x1f9ff) ||
                (__ui_c >= 0x1fa70 && __ui_c <= 0x1faff) || (__ui_c >= 0x20000 && __ui_c <= 0x3fffd) )); then
            __ui_w=$((__ui_w + 2))
        elif (( __ui_c >= 0x231a && __ui_c <= 0x2b55 )) &&
             (( (__ui_c >= 0x231a && __ui_c <= 0x231b) || (__ui_c >= 0x23e9 && __ui_c <= 0x23ec) || __ui_c == 0x23f0 ||
                __ui_c == 0x23f3 || (__ui_c >= 0x25fd && __ui_c <= 0x25fe) || (__ui_c >= 0x2614 && __ui_c <= 0x2615) ||
                (__ui_c >= 0x2648 && __ui_c <= 0x2653) || __ui_c == 0x267f || __ui_c == 0x2693 || __ui_c == 0x26a1 ||
                (__ui_c >= 0x26aa && __ui_c <= 0x26ab) || (__ui_c >= 0x26bd && __ui_c <= 0x26be) ||
                (__ui_c >= 0x26c4 && __ui_c <= 0x26c5) || __ui_c == 0x26ce || __ui_c == 0x26d4 || __ui_c == 0x26ea ||
                (__ui_c >= 0x26f2 && __ui_c <= 0x26f3) || __ui_c == 0x26f5 || __ui_c == 0x26fa || __ui_c == 0x26fd ||
                __ui_c == 0x2705 || (__ui_c >= 0x270a && __ui_c <= 0x270b) || __ui_c == 0x2728 || __ui_c == 0x274c ||
                __ui_c == 0x274e || (__ui_c >= 0x2753 && __ui_c <= 0x2755) || __ui_c == 0x2757 ||
                (__ui_c >= 0x2795 && __ui_c <= 0x2797) || __ui_c == 0x27b0 || __ui_c == 0x27bf ||
                (__ui_c >= 0x2b1b && __ui_c <= 0x2b1c) || __ui_c == 0x2b50 || __ui_c == 0x2b55 )); then
            __ui_w=$((__ui_w + 2))
        else
            __ui_w=$((__ui_w + 1))
        fi
    done
    __ui_width_out=$__ui_w
}

ui_width() {
    local w
    ui_measure w "$1"
    printf '%s' "$w"
}

# 左对齐补齐到 $2 列（超出时原样输出，不截断）。
ui_pad() {
    local w
    ui_measure w "$1"
    if [ "$w" -lt "$2" ]; then printf '%s%*s' "$1" $(($2 - w)) ''; else printf '%s' "$1"; fi
}

# 超过 $2 列时截断，末尾加“…”。
ui_truncate() {
    local text="$1" max="$2" out="" w=0 cw i ch
    ui_measure w "$text"
    if [ "$w" -le "$max" ]; then printf '%s' "$text"; return 0; fi
    w=0
    local LC_CTYPE=C.UTF-8
    for ((i = 0; i < ${#text}; i++)); do
        ch="${text:i:1}"
        ui_measure cw "$ch"
        [ $((w + cw)) -le $((max - 1)) ] || break
        out+="$ch"; w=$((w + cw))
    done
    printf '%s…' "$out"
}

# 终端列数：优先问标准输入/错误所连的终端（菜单里 stdout 常被 $(...) 捕获），其次 $COLUMNS，默认 80。
ui_columns() {
    local size="" columns=""
    if [ -t 0 ]; then size=$(stty size 2>/dev/null) || size=""
    elif [ -t 2 ]; then size=$(stty size <&2 2>/dev/null) || size=""   # 先把 stdin 指向终端，再丢弃错误输出
    fi
    columns="${size##* }"
    [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -ge 20 ] || columns="${COLUMNS:-80}"
    [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -ge 20 ] && [ "$columns" -le 500 ] || columns=80
    printf '%s' "$columns"
}

ui_rule() {
    local w line
    w=$(( $(ui_columns) - 2 ))
    [ "$w" -le "$UI_RULE_MAX" ] || w=$UI_RULE_MAX
    printf -v line '%*s' "$w" ''
    printf ' %b%s%b\n' "$DIM" "${line// /─}" "$NC"
}

# 小节标题：空一行，标题与可选副标题，下接分隔线。在终端里按宽度截断：先截副标题，放不下时只留标题。
ui_title() {
    local max tw
    max=$(ui_wrap_width)
    if [ "$max" -gt 0 ]; then max=$((max - 1)); else max=100000; fi
    ui_measure tw "$1"
    printf '\n %b%s%b' "$BOLD_CYAN" "$(ui_truncate "$1" "$max")" "$NC"
    if [ -n "${2:-}" ] && [ $((tw + 4)) -le "$max" ]; then
        printf ' %b·%b %s' "$DIM" "$NC" "$(ui_truncate "$2" $((max - tw - 3)))"
    fi
    printf '\n'
    ui_rule
}

# 菜单项：编号 文本 [变暗的附注]
ui_option() {
    printf '   %b%2s.%b %s' "$CYAN" "$1" "$NC" "$2"
    [ -z "${3:-}" ] || printf '  %b%s%b' "$DIM" "$3" "$NC"
    printf '\n'
}

# 折行宽度：标准输出（或 $1 指定的文件描述符）是终端、或显式设置了 COLUMNS 时按终端宽度折行；
# 输出到文件或管道时不折行（输出 0），日志和脚本解析拿到的仍是完整的一行。
ui_wrap_width() {
    if [ -t "${1:-1}" ] || [ -n "${COLUMNS:-}" ]; then
        ui_columns
    else
        printf '0'
    fi
}

# 把纯文本（不含颜色码）按显示宽度折成多行，每行不超过 $2 列（0 表示不折行），逐行输出。
# 优先在空格、中文字符之间和标点之后断行；闭合标点不放在行首；没有可断处（如很长的路径）才硬断。
ui_wrap() {
    local text="$1" max="${2:-0}" part line head rest w cw i ch brk
    local LC_CTYPE=C.UTF-8
    while IFS= read -r part; do
        if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -lt 1 ]; then
            printf '%s\n' "$part"
            continue
        fi
        ui_measure w "$part"
        if [ "$w" -le "$max" ]; then
            printf '%s\n' "$part"
            continue
        fi
        line=""
        w=0
        brk=0
        for ((i = 0; i < ${#part}; i++)); do
            ch="${part:i:1}"
            ui_measure cw "$ch"
            if [ $((w + cw)) -gt "$max" ] && [ -n "$line" ]; then
                case "$ch" in
                    '，'|'。'|'、'|'；'|'：'|'）'|'」'|'』'|'！'|'？'|')'|','|'.')
                        # 闭合标点不放在行首：把前一个字一起带到下一行。
                        if [ "${#line}" -ge 2 ]; then brk=$((${#line} - 1)); fi
                        ;;
                esac
                if [ "$brk" -gt 0 ]; then
                    head="${line:0:brk}"
                    rest="${line:brk}"
                else
                    head="$line"
                    rest=""
                fi
                head="${head%"${head##*[! ]}"}"
                rest="${rest#"${rest%%[! ]*}"}"
                printf '%s\n' "$head"
                line="$rest"
                ui_measure w "$line"
                brk=0
                if [ -z "$line" ] && [ "$ch" = " " ]; then
                    continue
                fi
            fi
            if [ "$cw" -ge 2 ] && [ -n "$line" ]; then
                brk=${#line}
            fi
            line+="$ch"
            w=$((w + cw))
            case "$ch" in
                ' '|'，'|'。'|'、'|'；'|'：'|'）'|'」'|'』'|'！'|'？'|'/') brk=${#line} ;;
                *) if [ "$cw" -ge 2 ]; then brk=${#line}; fi ;;
            esac
        done
        printf '%s\n' "$line"
    done <<< "$text"
}

# 键值行：键补齐到 $5 列（默认 8），$1 为键的颜色，$4 为值的颜色（可空）；值过长时折行，续行与值对齐。
ui_row() {
    local key_color="$1" key="$2" value="$3" value_color="${4:-}" kw="${5:-8}" max pad line first=true
    max=$(ui_wrap_width)
    if [ "$max" -gt 0 ]; then
        max=$((max - kw - 4))
        [ "$max" -ge 10 ] || max=10
    fi
    printf -v pad '%*s' $((kw + 4)) ''
    while IFS= read -r line; do
        if $first; then
            printf '  %b%s%b  %b%s%b\n' "$key_color" "$(ui_pad "$key" "$kw")" "$NC" "$value_color" "$line" \
                "${value_color:+$NC}"
            first=false
        else
            printf '%s%b%s%b\n' "$pad" "$value_color" "$line" "${value_color:+$NC}"
        fi
    done < <(ui_wrap "$value" "$max")
}

# 键值行：键变暗并补齐到 $3 列（默认 8）。
ui_kv() {
    ui_row "$DIM" "$1" "$2" "" "${3:-8}"
}

# 用量行：「已用 / 限额  进度条  百分比  附注」。放不下时先去掉进度条，附注（如「（12 分钟前）」）换到下一行。
ui_usage_kv() {
    local key="$1" text="$2" pct="$3" note="${4:-}" kw="${5:-8}" max w wn pad
    max=$(ui_wrap_width)
    if [ "$max" -gt 0 ]; then max=$((max - kw - 4)); else max=100000; fi
    ui_measure w "$text  ${pct}%"
    printf '  %b%s%b  %s' "$DIM" "$(ui_pad "$key" "$kw")" "$NC" "$text"
    if [ $((w + 12)) -le "$max" ]; then
        printf '  %s' "$(ui_bar "$pct")"
        w=$((w + 12))
    fi
    printf '  %s%%' "$pct"
    if [ -n "$note" ]; then
        ui_measure wn "$note"
        if [ $((w + 2 + wn)) -le "$max" ]; then
            printf '  %b%s%b' "$DIM" "$note" "$NC"
        else
            printf -v pad '%*s' $((kw + 4)) ''
            printf '\n%s%b%s%b' "$pad" "$DIM" "$note" "$NC"
        fi
    fi
    printf '\n'
}

# 提示与结果行：$1 文件描述符（决定是否折行），$2 前缀（可含颜色），$3 前缀显示宽度，$4 文字颜色（可空），
# $5 文字；文字按终端宽度折行，续行与文字对齐。
ui_message() {
    local fd="$1" prefix="$2" indent="$3" color="$4" text="$5" max pad line
    max=$(ui_wrap_width "$fd")
    if [ "$max" -gt 0 ]; then
        max=$((max - indent))
        [ "$max" -ge 10 ] || max=10
    fi
    printf -v pad '%*s' "$indent" ''
    while IFS= read -r line; do
        printf '%b%b%s%b\n' "$prefix" "$color" "$line" "${color:+$NC}"
        prefix="$pad"
    done < <(ui_wrap "$text" "$max")
}

ui_note() {
    ui_message 1 '  ' 2 "$DIM" "$1"
}

# 结果行：✓ 成功、! 提醒、✗ 失败（失败写到标准错误）。
ui_ok() {
    ui_message 1 "  ${GREEN}✓${NC} " 4 '' "$*"
}

ui_warn() {
    ui_message 1 "  ${YELLOW}!${NC} " 4 '' "$*"
}

ui_err() {
    ui_message 2 "  ${RED}✗${NC} " 4 '' "$*" >&2
}

# 读取菜单选择写入变量 $2，提示统一为“请选择 [0-N]”，$3 为附加说明。
# 读到 EOF 返回 1，调用方据此返回上一级。
ui_prompt() {
    local __ui_hint="0-$1"
    [ -z "${3:-}" ] || __ui_hint+="，$3"
    read -r -p " 请选择 [${__ui_hint}]: " "$2"
}

# 等用户按回车；读到 EOF 直接返回。
ui_pause() {
    local __ui_pause_answer
    read -r -p " 按回车继续…" __ui_pause_answer || printf '\n'
}

# 用量条：$1=百分比（整数，可超过 100），$2=格数（默认 10）。不足 75% 绿色，75%–89% 黄色，90% 起红色。
ui_bar() {
    local pct="${1:-0}" cells="${2:-10}" filled i full="" empty="" color
    [[ "$pct" =~ ^[0-9]{1,9}$ ]] || pct=0
    pct=$((10#$pct))
    if [ "$pct" -ge 90 ]; then color="$RED"; elif [ "$pct" -ge 75 ]; then color="$YELLOW"; else color="$GREEN"; fi
    filled=$(( (pct * cells + 50) / 100 ))
    [ "$filled" -le "$cells" ] || filled=$cells
    [ "$pct" -eq 0 ] || [ "$filled" -ge 1 ] || filled=1
    for ((i = 0; i < cells; i++)); do
        if [ "$i" -lt "$filled" ]; then full+="█"; else empty+="░"; fi
    done
    printf '%b%s%b%b%s%b' "$color" "$full" "$NC" "$DIM" "$empty" "$NC"
}

# 两组菜单，编号竖排：$1=左组标题 $2=右组标题 $3=左组项数，其后是全部菜单文字（编号从 1 起）。
# 两列放得下时左右并排（左组 1..k，右组 k+1..n），否则分组单列。“0. 退出/返回”由调用方输出。
ui_menu_groups() {
    local left="$1" right="$2" split="$3" columns n rows i lw=0 rw=0 w cell
    shift 3
    local -a labels=("$@")
    n=${#labels[@]}
    columns=$(ui_columns)
    for ((i = 0; i < n; i++)); do
        ui_measure w "${labels[i]}"
        if [ "$i" -lt "$split" ]; then [ "$w" -le "$lw" ] || lw=$w; else [ "$w" -le "$rw" ] || rw=$w; fi
    done
    cell=$((4 + lw + 4))   # 左列：编号“ 1. ”4 列 + 最长文字 + 列间距
    if [ $((3 + cell + 4 + rw)) -le "$columns" ]; then
        printf '   %b%s%s%b\n' "$DIM" "$(ui_pad "$left" "$cell")" "$right" "$NC"
        rows=$(( split > n - split ? split : n - split ))
        for ((i = 0; i < rows; i++)); do
            printf '   '
            if [ "$i" -lt "$split" ]; then
                printf '%b%2d.%b ' "$CYAN" $((i + 1)) "$NC"
                if [ $((split + i)) -lt "$n" ]; then
                    printf '%s' "$(ui_pad "${labels[i]}" $((lw + 4)))"
                else
                    printf '%s' "${labels[i]}"
                fi
            else
                printf '%*s' "$cell" ''
            fi
            [ $((split + i)) -ge "$n" ] || printf '%b%2d.%b %s' "$CYAN" $((split + i + 1)) "$NC" "${labels[split + i]}"
            printf '\n'
        done
    else
        printf '   %b%s%b\n' "$DIM" "$left" "$NC"
        for ((i = 0; i < split; i++)); do ui_option $((i + 1)) "${labels[i]}"; done
        printf '   %b%s%b\n' "$DIM" "$right" "$NC"
        for ((i = split; i < n; i++)); do ui_option $((i + 1)) "${labels[i]}"; done
    fi
}

# 清屏只在交互终端、非 dumb、未设置 NO_COLOR 时进行（clear 输出的是控制序列）。
menu_clear() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then clear 2>/dev/null || true; fi
}

# 状态级别对应的颜色（与 ntc_overall_status 的级别一致）：ok 绿、warn 黄、err 红，其余变暗。
ui_level_color() {
    case "${1:-}" in
        ok) printf '%s' "$GREEN" ;;
        warn) printf '%s' "$YELLOW" ;;
        err) printf '%s' "$RED" ;;
        *) printf '%s' "$DIM" ;;
    esac
}
# <<< ntc-common:ui <<<

# >>> ntc-common:input >>>
# 本区块由 tools/sync-common.sh 根据 src/common/input.sh 生成，请改源文件后运行该脚本，勿直接修改。
# ── 输入：读到 EOF 一律视为取消（返回 1），数字一律按十进制解析（允许前导零）─────────
# 去掉首尾空白。
ntc_trim() {
    local __trim_v="$1"
    __trim_v="${__trim_v#"${__trim_v%%[![:space:]]*}"}"
    __trim_v="${__trim_v%"${__trim_v##*[![:space:]]}"}"
    printf '%s' "$__trim_v"
}

# 整数，范围 [$2, $3]；输出规范值（08 → 8），不合法返回 1。
ntc_int() {
    local __int_v
    [[ "${1:-}" =~ ^[0-9]{1,9}$ ]] || return 1
    __int_v=$((10#$1))
    [ "$__int_v" -ge "$2" ] && [ "$__int_v" -le "$3" ] || return 1
    printf '%s' "$__int_v"
}

# 非负数（整数部分最多 9 位、小数最多 6 位）；输出去掉多余前导零的值，不合法返回 1。
ntc_decimal() {
    local __dec_int __dec_frac
    [[ "${1:-}" =~ ^([0-9]{1,9})(\.([0-9]{1,6}))?$ ]] || return 1
    __dec_int=$((10#${BASH_REMATCH[1]}))
    __dec_frac="${BASH_REMATCH[3]}"
    if [ -n "$__dec_frac" ]; then printf '%s.%s' "$__dec_int" "$__dec_frac"; else printf '%s' "$__dec_int"; fi
}

# ui_read 变量名 提示 [默认值]：显示“ 提示 [默认值]: ”，回车取默认值；EOF 返回 1。
ui_read() {
    local -n __ui_read_out="$1"
    local __ui_read_prompt="$2" __ui_read_value=""
    [ -z "${3:-}" ] || __ui_read_prompt+=" [$3]"
    if ! read -r -p " ${__ui_read_prompt}: " __ui_read_value; then
        printf '\n'
        return 1
    fi
    __ui_read_value=$(ntc_trim "$__ui_read_value")
    [ -n "$__ui_read_value" ] || __ui_read_value="${3:-}"
    __ui_read_out="$__ui_read_value"
}

# ui_confirm 问题 [y|n]：只认 y/yes/n/no（不分大小写），回车取默认值（缺省 n）；EOF 视为否。
ui_confirm() {
    local __ui_answer __ui_default="${2:-n}" __ui_hint='[y/N]'
    [ "$__ui_default" != y ] || __ui_hint='[Y/n]'
    while true; do
        if ! read -r -p " $1 $__ui_hint: " __ui_answer; then
            printf '\n'
            return 1
        fi
        __ui_answer=$(ntc_trim "$__ui_answer")
        [ -n "$__ui_answer" ] || __ui_answer="$__ui_default"
        case "${__ui_answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        printf '  请输入 y 或 n。\n'
    done
}

# ui_read_int 变量名 提示 默认值 最小 最大：直到输入合法为止；EOF 返回 1。
ui_read_int() {
    local -n __ui_int_out="$1"
    local __ui_int_raw __ui_int_norm
    while true; do
        ui_read __ui_int_raw "$2" "$3" || return 1
        if __ui_int_norm=$(ntc_int "$__ui_int_raw" "$4" "$5"); then
            __ui_int_out="$__ui_int_norm"
            return 0
        fi
        printf '  %b请输入 %s–%s 的整数。%b\n' "$YELLOW" "$4" "$5" "$NC"
    done
}

# ui_read_decimal 变量名 提示 默认值：非负数，直到输入合法为止；EOF 返回 1。取值范围由调用方再检查。
ui_read_decimal() {
    local -n __ui_dec_out="$1"
    local __ui_dec_raw __ui_dec_norm
    while true; do
        ui_read __ui_dec_raw "$2" "$3" || return 1
        if __ui_dec_norm=$(ntc_decimal "$__ui_dec_raw"); then
            __ui_dec_out="$__ui_dec_norm"
            return 0
        fi
        printf '  %b请输入数字，例如 500 或 1.5。%b\n' "$YELLOW" "$NC"
    done
}
# <<< ntc-common:input <<<

# >>> ntc-common:report >>>
# 本区块由 tools/sync-common.sh 根据 src/common/report.sh 生成，请改源文件后运行该脚本，勿直接修改。
# ── 状态文件读取与本期预测（主菜单仪表盘、ntc status、Telegram 日报共用同一套算法）──────
# 读取 KEY=VALUE 文件中最后一个 KEY 的值；文件不可读或没有该键时返回 1。
ntc_kv() {
    local __kv_line __kv_value="" __kv_found=1
    [ -r "$1" ] || return 1
    while IFS= read -r __kv_line || [ -n "$__kv_line" ]; do
        case "$__kv_line" in
            "$2="*) __kv_value="${__kv_line#*=}"; __kv_found=0 ;;
        esac
    done < "$1"
    printf '%s' "${__kv_value%$'\r'}"
    return "$__kv_found"
}

# 本地日期 YYYY-MM-DD 当天 00:00 的 epoch。
ntc_date_epoch() {
    [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    date -d "$1 00:00:00" +%s 2>/dev/null
}

# 本期预测。$1=已用 $2=执行阈值 $3=周期起始日 $4=周期最后一天（含） [$5=当前 epoch]
# 输出一行：已过天数 总天数 剩余天数 日均 预计期末用量 预计到达阈值的 epoch（0=已达到，-1=本期不会达到）。
# 期初不足 6 小时按 6 小时折算，避免刚开始几个小时的日均被放大。
ntc_forecast() {
    local start_epoch end_epoch now="${5:-}"
    [ -n "$now" ] || now=$(date +%s)
    start_epoch=$(ntc_date_epoch "$3") || return 1
    end_epoch=$(ntc_date_epoch "$4") || return 1
    end_epoch=$((end_epoch + 86400))
    [ "$end_epoch" -gt "$start_epoch" ] || return 1
    awk -v u="$1" -v t="$2" -v s="$start_epoch" -v e="$end_epoch" -v n="$now" 'BEGIN {
        if (u !~ /^[0-9]+(\.[0-9]+)?$/ || t !~ /^[0-9]+(\.[0-9]+)?$/ || n !~ /^[0-9]+$/) exit 1
        total = (e - s) / 86400
        elapsed = (n - s) / 86400
        if (elapsed < 0.25) elapsed = 0.25
        if (elapsed > total) elapsed = total
        left = (e - n) / 86400
        if (left < 0) left = 0
        avg = u / elapsed
        projected = avg * total
        hit = -1
        if (u + 0 >= t + 0) hit = 0
        else if (avg > 0 && projected > t + 0) hit = s + (t / avg) * 86400
        printf "%.2f %d %.2f %.3f %.2f %.0f\n", elapsed, int(total + 0.5), left, avg, projected, hit
    }'
}

# 百分比（向下取整）：$1=已用 $2=限额。
ntc_percent() {
    awk -v u="$1" -v l="$2" 'BEGIN {
        if (u !~ /^[0-9]+(\.[0-9]+)?$/ || l !~ /^[0-9]+(\.[0-9]+)?$/ || l + 0 <= 0) exit 1
        printf "%d\n", u * 100 / l
    }'
}

# 最多保留两位小数并去掉末尾的 0：12.3456 → 12.35，500.00 → 500。
ntc_num() {
    awk -v v="$1" 'BEGIN {
        if (v !~ /^-?[0-9]+(\.[0-9]+)?$/) exit 1
        s = sprintf("%.2f", v)
        sub(/\.?0+$/, "", s)
        if (s == "" || s == "-") s = "0"
        print s
    }'
}

# 字节换算成配置单位（decimal=GB，binary=GiB），保留两位小数。
ntc_bytes_to_unit() {
    awk -v b="$1" -v u="$2" 'BEGIN {
        if (b !~ /^[0-9]+$/) exit 1
        d = (u == "binary") ? 1073741824 : 1000000000
        printf "%.2f\n", b / d
    }'
}

ntc_unit_label() {
    if [ "${1:-binary}" = decimal ]; then printf 'GB'; else printf 'GiB'; fi
}

ntc_mode_label() {
    case "$1" in
        out) printf '出站' ;;
        in) printf '入站' ;;
        total) printf '出+入' ;;
        max) printf '出入取较大' ;;
        *) printf '%s' "$1" ;;
    esac
}

# 周期说明：$1=monthly|quarterly|yearly $2=起始日 $3=年度起始月
ntc_period_label() {
    case "$1" in
        monthly) printf '每月 %s 日重置' "$2" ;;
        quarterly) printf '每季度（1/4/7/10 月 %s 日）重置' "$2" ;;
        yearly) printf '每年 %s 月 %s 日重置' "${3:-1}" "$2" ;;
        *) printf '%s' "$1" ;;
    esac
}

# 剩余天数的说法：$1=剩余天数（可带小数）。
ntc_days_left_text() {
    awk -v d="$1" 'BEGIN { if (d + 0 < 1) print "不到 1 天"; else printf "%d 天\n", d }'
}

# 敏感值的显示形式（Telegram Token、Chat ID 等）：只露首尾各 4 个字符，8 个字符以内全部遮住。
ntc_mask() {
    local v="${1:-}"
    if [ -z "$v" ]; then printf '未设置'
    elif [ "${#v}" -le 8 ]; then printf '****'
    else printf '%s…%s' "${v:0:4}" "${v: -4}"
    fi
}

# 监控健康状况（读 monitor_health）：输出“级别<TAB>说明”，级别为 ok|error|off|unknown。
# $1=健康文件 [$2=当前 epoch] [$3=多少秒没更新算停摆，默认 600]
ntc_health_summary() {
    local file="$1" now="${2:-}" stale="${3:-600}" health reason updated age
    [ -n "$now" ] || now=$(date +%s)
    if ! health=$(ntc_kv "$file" HEALTH); then
        printf 'unknown\t还没有运行记录\n'
        return 0
    fi
    reason=$(ntc_kv "$file" REASON) || reason=""
    updated=$(ntc_kv "$file" UPDATED_EPOCH) || updated=""
    [[ "$updated" =~ ^[0-9]+$ ]] || updated=0
    age=$((now - updated))
    [ "$age" -ge 0 ] || age=0
    case "$health" in
        disabled) printf 'off\t监控已停用\n' ;;
        ok|error)
            if [ "$age" -gt "$stale" ]; then
                printf 'error\t已 %d 分钟没有运行，请检查 cron\n' $((age / 60))
            elif [ "$health" = ok ]; then
                printf 'ok\t运行正常（%d 分钟前检查过）\n' $((age / 60))
            else
                printf 'error\t%s\n' "${reason:-最近一次检查失败}"
            fi
            ;;
        *) printf 'unknown\t状态文件无法识别\n' ;;
    esac
}

# crontab 文本 $1 里是否有未注释、包含 $2 的条目。
ntc_cron_has_entry() {
    awk -v needle="$2" '!/^[[:space:]]*#/ && index($0, needle) { found = 1 } END { exit !found }' <<< "$1"
}

# Telegram 预警档位的实际取值，$1 为 Telegram 配置文件。规则与 Telegram 组件的 read_config 一致：
# 没有 WARN_PERCENTS 键 → 80,90（默认）；空或 off → off（关闭）；不是 1–99 的整数列表 → 按 80,90 执行。
ntc_tg_warn_percents() {
    local value
    if ! value=$(ntc_kv "$1" WARN_PERCENTS); then
        printf '80,90'
    elif [ -z "$value" ] || [ "${value,,}" = off ]; then
        printf 'off'
    elif [[ ! "$value" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] || [[ ",$value," =~ ,0{1,2}, ]]; then
        printf '80,90'
    else
        printf '%s' "$value"
    fi
}

# 综合状态（主菜单仪表盘与「状态详情」共用，按优先级取第一条）。
# $1=已停用 $2=能读取 root crontab $3=监控定时任务存在（三者取 true/false） $4=健康文件
# $5=用量状态（current_traffic_state 的 STATUS） $6=限速 kbit/s $7=宽限截止 epoch [$8=当前 epoch]
# 输出一行：级别<TAB>状态词<TAB>说明。级别为 ok|warn|err|off（调用方据此选颜色），说明可能为空。
ntc_overall_status() {
    local kind text hhmm
    if [ "$1" = true ]; then
        printf 'off\t○ 已停用\t不统计也不限速（在「限制执行」里启用）\n'
    elif [ "$2" != true ]; then
        printf 'warn\t! 状态未知\t无法读取 root crontab，不能确认监控是否在运行\n'
    elif [ "$3" != true ]; then
        printf 'warn\t! 未运行\t定时任务缺失（在「限制执行」里启用流量监控）\n'
    else
        IFS=$'\t' read -r kind text < <(ntc_health_summary "$4" "${8:-}")
        case "$kind:$5" in
            error:*) printf 'err\t✗ 异常\t%s\n' "$text" ;;
            unknown:*) printf 'warn\t… 等待首次检查\t定时任务每分钟检查一次\n' ;;
            *:limited) printf 'err\t● 已限速\t整机限速 %s kbit/s，进入新周期后自动解除\n' "${6:-?}" ;;
            *:shutdown) printf 'err\t● 已安排关机\t已达到阈值，按配置关机\n' ;;
            *:shutdown_external) printf 'warn\t! 已有关机计划\t系统里已有其他程序安排的关机\n' ;;
            *:grace)
                if [[ "${7:-}" =~ ^[1-9][0-9]*$ ]] && hhmm=$(date -d "@$7" '+%m-%d %H:%M' 2>/dev/null); then
                    printf 'warn\t● 宽限中\t到 %s，期间只统计、不限速\n' "$hhmm"
                else
                    printf 'warn\t● 宽限中\t期间只统计、不限速\n'
                fi
                ;;
            *:paused) printf 'warn\t● 已暂停限制\t流量照常统计（在「限制执行」里恢复）\n' ;;
            *) printf 'ok\t● 监控中\t\n' ;;
        esac
    fi
}
# <<< ntc-common:report <<<

# 运行依赖检查。$1=interactive：缺依赖且标准输入是终端时调用主脚本安装依赖；
# $1=batch（命令行参数）：只报告缺什么，不安装、不读输入。
machine_require_dependencies() {
    local mode="${1:-interactive}" command_name entry="$WORK_DIR/trafficcop-lite.sh" perms
    local missing=()
    for command_name in vnstat jq bc ip crontab flock curl tac pgrep pkill; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [ -n "$(find_tc_bin)" ] || missing+=(tc)
    if ! { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; } &&
       ! { [ -s /etc/ssl/cert.pem ] && [ -r /etc/ssl/cert.pem ]; }; then
        missing+=('@ca-certificates')
    fi
    [ "${#missing[@]}" -gt 0 ] || return 0
    ui_err "缺少运行依赖：${missing[*]}"
    if [ "$mode" = interactive ] && [ -t 0 ] && [ -f "$entry" ] && [ ! -L "$entry" ] &&
       [ "$(stat -c %u:%h -- "$entry" 2>/dev/null)" = 0:1 ] &&
       perms=$(stat -c %a -- "$entry") && (( (8#$perms & 0022) == 0 )) &&
       grep -Fqx '# BEGIN MANAGED DEPENDENCIES' "$entry"; then
        bash "$entry" --dependencies install || return 1
        for command_name in "${missing[@]}"; do
            if [ "$command_name" = tc ]; then [ -n "$(find_tc_bin)" ] || return 1
            elif [ "$command_name" = '@ca-certificates' ]; then
                { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; } ||
                    { [ -s /etc/ssl/cert.pem ] && [ -r /etc/ssl/cert.pem ]; } || return 1
            else command -v "$command_name" >/dev/null 2>&1 || return 1; fi
        done
        return 0
    fi
    ui_note "请在 ntc 主菜单的「依赖管理」里安装，或运行 sudo ntc --dependencies install。"
    return 1
}

# 检查网络接口
get_main_interface() {
    local main_interface
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        main_interface=$(grep '^MAIN_INTERFACE=' "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        if [ -n "$main_interface" ]; then
            echo "$main_interface"
            return
        fi
    fi
    ip route | grep default | awk '{print $5}' | head -n1
}

# 撤销 NTC 自己的整机限速：交给 monitor 的 --tc-clear-owned，它只动 NTC 记录在案的规则。
# monitor 的输出带时间戳、并已写入事件日志；屏幕上只显示最后一句结论（去掉时间戳）。
clear_tc_rules() {
    local output rc=0 detail
    if [ ! -f "$TC_STATE_FILE" ]; then
        ui_ok "当前没有 NTC 施加的整机限速。"
        return 0
    fi
    if [ ! -f "$SCRIPT_PATH" ]; then
        ui_err "找不到流量监控脚本 $SCRIPT_PATH，无法安全撤销整机限速。"
        return 1
    fi
    output=$(bash "$SCRIPT_PATH" --tc-clear-owned "限制执行" 2>&1) || rc=$?
    detail=$(printf '%s\n' "$output" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} //; s/^限制执行：//' |
        awk 'NF { line = $0 } END { print line }')
    if [ "$rc" -eq 0 ]; then
        ui_ok "${detail:-已撤销 NTC 的整机限速。}"
    else
        ui_err "撤销整机限速失败${detail:+：$detail}"
    fi
    return "$rc"
}

# >>> ntc-common:cleanup-lock >>>
# 本区块由 tools/sync-common.sh 根据 src/common/cleanup-lock.sh 生成，请改源文件后运行该脚本，勿直接修改。
acquire_monitor_cleanup_lock() {
    touch "$MONITOR_LOCK_FILE" || return 1
    chmod 600 "$MONITOR_LOCK_FILE" 2>/dev/null || true
    exec 9>"$MONITOR_LOCK_FILE"
    if ! flock -w 15 9; then
        exec 9>&-
        return 1
    fi
}

release_monitor_cleanup_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&-
}
# <<< ntc-common:cleanup-lock <<<

clear_tc_rules_with_lock() {
    local clear_status

    if ! acquire_monitor_cleanup_lock; then
        ui_err "另一个 NTC 操作正在进行（无法取得监控锁），未撤销整机限速。"
        return 1
    fi
    clear_tc_rules
    clear_status=$?
    release_monitor_cleanup_lock
    return "$clear_status"
}

# 移除监控定时任务（按监控脚本路径匹配，其他条目原样保留）。
remove_cron_job() {
    local current_crontab crontab_tmp

    CRON_JOB_REMOVED=false
    if ! acquire_root_crontab_lock; then
        ui_err "无法取得 NTC 的 crontab 锁，定时任务未改动。"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        ui_err "无法读取 root 的定时任务，未改动。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab_tmp="$(mktemp)"; then
        ui_err "无法创建临时文件，定时任务未改动。"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" 'index($0, script) == 0 { print }' \
        <<< "$current_crontab" > "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "生成新的定时任务列表失败，未改动。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp" 2>/dev/null; then
        rm -f "$crontab_tmp"
        ui_err "写入定时任务失败，监控定时任务未能移除。"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"
    # 停用中途失败时据此决定要不要把定时任务加回去（原来没有就不凭空加）。
    if awk -v script="$SCRIPT_PATH" 'index($0, script) > 0 { found = 1 } END { exit !found }' \
        <<< "$current_crontab"; then
        CRON_JOB_REMOVED=true
    fi

    release_root_crontab_lock
    if [ "$CRON_JOB_REMOVED" = true ]; then
        ui_ok "已移除流量监控的定时任务。"
    else
        ui_ok "本来就没有流量监控的定时任务，无需移除。"
    fi
}

# 添加监控定时任务（先去掉旧的同路径条目，再追加一行）。
add_cron_job() {
    local current_crontab cron_entry crontab_tmp

    if ! acquire_root_crontab_lock; then
        ui_err "无法取得 NTC 的 crontab 锁，定时任务未改动。"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        ui_err "无法读取 root 的定时任务，未改动。"
        release_root_crontab_lock
        return 1
    fi
    cron_entry="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 $CRON_COMMENT"
    if ! crontab_tmp="$(mktemp)"; then
        ui_err "无法创建临时文件，定时任务未改动。"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" '
        index($0, script) == 0 && $0 !~ /^[[:space:]]*$/ { print }
    ' <<< "$current_crontab" > "$crontab_tmp" \
        || ! printf '%s\n' "$cron_entry" >> "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "生成新的定时任务列表失败，未改动。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "写入定时任务失败，监控定时任务未添加。"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"

    release_root_crontab_lock
    ui_ok "已添加流量监控的定时任务（每分钟检查一次）。"
}

# 停用流量监控：移除定时任务 → 在监控锁内撤销 NTC 的整机限速 → 备份配置并写 DISABLED → 只取消 NTC 自己的计划关机。
# $1=interactive（菜单）| batch（命令行 --disable：不读输入，绝不取消别的程序安排的关机，只如实说明）。
# 停用中途失败：把刚删掉的定时任务加回去（原来就没有则不加），监控照常运行，不会留下没人解除的限速。$1=失败原因
disable_restore_cron() {
    if [ "${CRON_JOB_REMOVED:-false}" != true ]; then
        ui_err "停用未完成：$1。配置没有标记为停用。"
    elif add_cron_job > /dev/null 2>&1; then
        ui_err "停用未完成：$1。已恢复每分钟的检查任务，监控照常运行，配置没有标记为停用。"
    else
        ui_err "停用未完成：$1，而且每分钟的检查任务没能恢复。请在「限制执行」里重新启用流量监控（或运行 sudo ntc enable）。"
    fi
    ntc_operation_log machine-disable failure
}

# 停用是一个事务：先删每分钟的检查任务（删不掉就什么都不改）；之后在同一把监控锁内撤销整机限速、处理 NTC 的关机记录、
# 备份并写停用标记、清除宽限/暂停，任何一步失败都把定时任务加回去、不写停用标记。
# 1.x 删定时任务失败时跳过撤销限速却照写停用标记：监控看到停用就不再管，限速从此没人解除。
disable_machine_limit() {
    local mode="${1:-interactive}" has_error=false config_tmp written=false cancel_foreign=false

    # 旧版本安排关机时不写关机记录：没有 NTC 记录、系统里却确有计划关机时，无法确认归属。
    # 菜单里先问清楚（默认不取消），命令行绝不取消、只说明现状；问完才开始改动。
    if [ ! -f "$SHUTDOWN_STATE_FILE" ] && grep -q '^LIMIT_MODE=shutdown' "$CONFIG_FILE" 2>/dev/null \
        && has_pending_shutdown; then
        if [ "$mode" != interactive ]; then
            ui_warn "系统里有一个计划关机，NTC 没有它的记录，无法确认是 NTC 安排的，未取消；如需取消请运行 shutdown -c。"
        elif ui_confirm "系统里有一个计划关机，无法确认是 NTC 安排的。停用时一并取消它吗？" n; then
            cancel_foreign=true
        else
            ui_note "系统里的计划关机将保留。"
        fi
    fi

    # 1. 先删每分钟的检查任务。不 pkill 监控进程：下一步拿到监控锁即可保证没有实例处于 TC 事务中途
    #    （cron 的 --run 用 flock -n，拿不到锁立即退出）；pkill 会在 qdisc 替换与状态写入之间杀掉进程。
    if ! remove_cron_job; then
        ui_err "停用未执行：无法移除监控定时任务（见上方），配置、限速和计划关机都没有改动。"
        ntc_operation_log machine-disable failure
        return 1
    fi

    # 2. 同一把监控锁内：撤销整机限速 → 处理 NTC 的关机记录 → 备份并写停用标记 → 清除宽限/暂停。
    if ! acquire_monitor_cleanup_lock; then
        disable_restore_cron "另一个 NTC 操作正在进行（无法取得监控锁）"
        return 1
    fi
    if ! clear_tc_rules; then
        release_monitor_cleanup_lock
        disable_restore_cron "整机限速没能撤销（见上方）"
        return 1
    fi
    if ! cancel_owned_shutdown; then
        release_monitor_cleanup_lock
        disable_restore_cron "NTC 记录的计划关机没有处理完（见上方）"
        return 1
    fi
    if [ -f "$CONFIG_FILE" ] && ! grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        config_tmp="${CONFIG_FILE}.tmp.$$"
        # grep -v 一行都不剩时退出码是 1，不算失败。
        if cp "$CONFIG_FILE" "$BACKUP_CONFIG_FILE" \
            && { grep -v -E '^(DISABLED|DISABLED_TIME)=' "$CONFIG_FILE" || [ "$?" -eq 1 ]; } > "$config_tmp" \
            && { printf 'DISABLED=true\n'; printf 'DISABLED_TIME=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"; } >> "$config_tmp"; then
            chmod 600 "$BACKUP_CONFIG_FILE" "$config_tmp" 2>/dev/null || true
            if mv -f "$config_tmp" "$CONFIG_FILE"; then
                written=true
            fi
        fi
        if ! $written; then
            rm -f "$config_tmp"
            release_monitor_cleanup_lock
            disable_restore_cron "配置备份或停用标记写入失败"
            return 1
        fi
        ui_ok "已备份当前配置，并标记为停用。"
    elif [ -f "$CONFIG_FILE" ]; then
        if [ -f "$BACKUP_CONFIG_FILE" ]; then
            ui_ok "配置本来就是停用状态，保留原来的备份。"
        else
            ui_ok "配置本来就是停用状态。"
        fi
    fi
    rm -f "$ENFORCEMENT_STATE_FILE" || ui_warn "无法删除执行状态文件 $ENFORCEMENT_STATE_FILE（停用后不影响）。"
    release_monitor_cleanup_lock

    # 3. 菜单里同意取消的、无法确认归属的计划关机。
    if $cancel_foreign; then
        if ! shutdown -c 2>/dev/null; then
            ui_err "取消计划关机失败，请手动确认系统里的关机任务。"
            has_error=true
        elif has_pending_shutdown; then
            ui_err "已执行取消命令，但仍检测到计划关机，请手动处理。"
            has_error=true
        else
            ui_ok "已取消系统里的计划关机。"
        fi
    fi

    if $has_error; then
        ui_err "流量监控已停用，但系统里的计划关机没能取消（见上方）。"
        ntc_operation_log machine-disable failure
        return 1
    fi
    ui_ok "流量监控已停用：不再统计、限速或关机。"
    if [ -f "$BACKUP_CONFIG_FILE" ]; then
        ui_note "停用前的配置已备份；在「限制执行」里选「启用流量监控」或「从停用前的备份恢复配置」即可恢复。"
    elif [ -f "$CONFIG_FILE" ]; then
        ui_note "没有停用前的配置备份；在「限制执行」里选「启用流量监控」即可恢复。"
    else
        ui_note "没有停用前的配置备份，也还没有配置流量监控；需要时运行 sudo ntc config。"
    fi
    ntc_operation_log machine-disable success
}

rollback_enable_machine_limit() {
    local config_backup="$1"
    local enforcement_backup="$2"
    local had_enforcement="$3"
    local activation_from_disabled="$4"
    local config_tmp="${CONFIG_FILE}.enable-rollback.$$"
    local enforcement_tmp="${ENFORCEMENT_STATE_FILE}.enable-rollback.$$"
    local rollback_failed=false

    if ! cp -p "$config_backup" "$config_tmp" 2>/dev/null ||
       ! chmod 600 "$config_tmp" 2>/dev/null ||
       ! mv -f "$config_tmp" "$CONFIG_FILE"; then
        rm -f "$config_tmp"
        rollback_failed=true
    fi

    if [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = "true" ] &&
       [ "$activation_from_disabled" = "true" ]; then
        rm -f "$ENFORCEMENT_STATE_FILE" || rollback_failed=true
    elif [ "$had_enforcement" = "true" ]; then
        if ! cp -p "$enforcement_backup" "$enforcement_tmp" 2>/dev/null ||
           ! chmod 600 "$enforcement_tmp" 2>/dev/null ||
           ! mv -f "$enforcement_tmp" "$ENFORCEMENT_STATE_FILE"; then
            rm -f "$enforcement_tmp"
            rollback_failed=true
        fi
    elif ! rm -f "$ENFORCEMENT_STATE_FILE"; then
        rollback_failed=true
    fi

    # 启用失败采用 fail-open：恢复配置/执行控制，但不重新施加刚撤销的旧限速。
    # 这样即使原限速状态异常，也不会在失败回滚时再次锁住网络。
    if [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = "true" ]; then
        clear_tc_rules_with_lock >/dev/null 2>&1 || rollback_failed=true
    fi

    if $rollback_failed; then
        ntc_operation_log machine-rollback failure
        return 1
    fi
    rm -f "$config_backup" "$enforcement_backup"
    ntc_operation_log machine-rollback success
}

# 启用流量监控：建立 10 分钟启用宽限（同时撤销旧限速）→ 去掉停用标记 → 立即检查一次 → 添加定时任务。
# 任何一步失败都回滚配置与执行控制（fail-open：不重新施加刚撤销的旧限速），并如实说明停在哪一步。
# 启用失败、回滚成功后，配置与执行控制恢复成了什么样（1.x 一律说「配置和执行控制已恢复原样」）。
# $1=是否从停用状态启用 $2=启用前是否有宽限/暂停记录
enable_rollback_state_text() {
    if [ "$1" != true ]; then
        printf '%s' "配置和执行控制已恢复原样"
    elif [ "$2" = true ] && [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = true ]; then
        printf '%s' "配置已恢复为停用状态，停用期间留下的宽限/暂停记录已清除"
    else
        printf '%s' "配置已恢复为停用状态"
    fi
}

enable_machine_limit() {
    local enable_backup="$CONFIG_FILE.enable-backup.$$"
    local enforcement_backup="$ENFORCEMENT_STATE_FILE.enable-backup.$$"
    local config_tmp="${CONFIG_FILE}.tmp.$$"
    local had_enforcement=false
    local activation_from_disabled=false
    local keep_label="" state_text enf_mode enf_until

    if [ "${1:-}" = "--from-disabled-restore" ]; then
        activation_from_disabled=true
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        ui_err "尚未配置流量监控：运行 sudo ntc config 开始。"
        ntc_operation_log machine-enable failure
        return 1
    fi

    cp "$CONFIG_FILE" "$enable_backup" || {
        ui_err "无法备份当前配置（$enable_backup），未做任何改动。"
        ntc_operation_log machine-enable failure
        return 1
    }
    chmod 600 "$enable_backup" 2>/dev/null || true
    if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        activation_from_disabled=true
    fi
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        if ! cp -p "$ENFORCEMENT_STATE_FILE" "$enforcement_backup"; then
            rm -f "$enable_backup"
            ui_err "无法备份执行状态（$enforcement_backup），未做任何改动。"
            ntc_operation_log machine-enable failure
            return 1
        fi
        chmod 600 "$enforcement_backup" 2>/dev/null || true
        had_enforcement=true
    fi

    # 已启用时再启用（例如定时任务缺失后照提示补上）：未到期的暂停或宽限保持不变，不换成 10 分钟启用宽限
    # （1.x 会换掉，到期后恢复限速，关机模式下会安排关机）。从停用状态启用照旧先给启用宽限。
    if ! $activation_from_disabled && $had_enforcement; then
        enf_mode=$(ntc_kv "$ENFORCEMENT_STATE_FILE" MODE) || enf_mode=""
        enf_until=$(ntc_kv "$ENFORCEMENT_STATE_FILE" UNTIL_EPOCH) || enf_until=""
        case "$enf_mode" in
            paused) keep_label="暂停" ;;
            grace)
                if [[ "$enf_until" =~ ^[0-9]{1,12}$ ]] && [ "$enf_until" -gt "$(date +%s)" ]; then
                    keep_label="宽限"
                fi
                ;;
        esac
    fi

    # 1. 先保留当前禁用标记建立安全窗口。监控脚本据此可识别并清理
    # “父类已由 Dog 恢复、但 NTC 状态文件仍残留”的禁用态收尾场景。
    if ! begin_enable_grace 10 "${keep_label:+keep}"; then
        if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
            "$had_enforcement" "$activation_from_disabled"; then
            state_text=$(enable_rollback_state_text "$activation_from_disabled" "$had_enforcement")
            if [ "${ENABLE_TC_CLEARED:-false}" = "true" ]; then
                ui_err "启用失败：旧的整机限速已撤销，但没能处理计划关机或建立启用宽限（见上方）。"
                ui_note "${state_text}；旧 TC 限速保持撤销。"
            elif [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = "true" ]; then
                ui_err "启用失败：没能撤销旧的整机限速（见上方）。"
                ui_note "${state_text}；回滚时已再次撤销整机限速。"
            else
                ui_err "启用失败：无法建立启用宽限。"
                ui_note "原配置、执行控制和 TC 都没有改动。"
            fi
        else
            ui_err "启用失败，且回滚不完整：备份已保留（$enable_backup），请立即检查。"
        fi
        ntc_operation_log machine-enable failure
        return 1
    fi
    if [ -n "$keep_label" ]; then
        ui_ok "当前的${keep_label}保持不变（要恢复限制请选「恢复限制」，或运行 sudo ntc resume）。"
    else
        ui_ok "已设置 10 分钟启用宽限：期间只统计、不限速。"
    fi

    # 2. 旧 TC/关机状态已撤销后，再恢复配置文件（移除 DISABLED 标记）。
    if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        if ! grep -v -E '^(DISABLED|DISABLED_TIME)=' "$CONFIG_FILE" > "$config_tmp" \
            || ! chmod 600 "$config_tmp" 2>/dev/null \
            || ! mv -f "$config_tmp" "$CONFIG_FILE"; then
            rm -f "$config_tmp"
            if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
                "$had_enforcement" "$activation_from_disabled"; then
                ui_err "启用失败：无法去掉配置里的停用标记。"
                ui_note "$(enable_rollback_state_text "$activation_from_disabled" "$had_enforcement")；旧 TC 限速保持撤销。"
            else
                ui_err "启用失败，且回滚不完整：备份已保留（$enable_backup），请立即检查。"
            fi
            ntc_operation_log machine-enable failure
            return 1
        fi
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        ui_ok "已去掉配置里的停用标记。"
    fi

    # monitor 2.0 的 --run 不输出任何内容（日志只记事件）；--check 是同一轮检查，并打印一句结论。
    if ! cd "$WORK_DIR" || ! bash "$SCRIPT_PATH" --check; then
        if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
            "$had_enforcement" "$activation_from_disabled"; then
            ui_err "启用失败：首次检查没有通过（见上方）。"
            ui_note "$(enable_rollback_state_text "$activation_from_disabled" "$had_enforcement")；旧 TC 限速出于安全未恢复，也没有添加定时任务。"
        else
            ui_err "首次检查失败，且回滚不完整：备份已保留（$enable_backup），请立即检查。"
        fi
        ntc_operation_log machine-enable failure
        return 1
    fi

    # 3. 检查通过后再添加定时任务
    if ! add_cron_job; then
        if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
            "$had_enforcement" "$activation_from_disabled"; then
            ui_err "启用失败：定时任务没有添加成功。"
            ui_note "$(enable_rollback_state_text "$activation_from_disabled" "$had_enforcement")；旧 TC 限速出于安全未恢复。"
        else
            ui_err "定时任务添加失败，且回滚不完整：备份已保留（$enable_backup），请立即检查。"
        fi
        ntc_operation_log machine-enable failure
        return 1
    fi
    rm -f "$enable_backup" "$enforcement_backup"

    if [ -n "$keep_label" ]; then
        ui_ok "流量监控已启用：每分钟检查一次；当前的${keep_label}保持不变。"
    else
        ui_ok "流量监控已启用：每分钟检查一次；接下来 10 分钟只统计、不限速。"
    fi
    ntc_operation_log machine-enable success
}

# 用停用前的备份覆盖当前配置并启用监控；启用失败时换回恢复前的配置。
restore_machine_limit() {
    local restore_tmp="${CONFIG_FILE}.tmp.$$"
    local rollback_file="${CONFIG_FILE}.restore-backup.$$"
    local had_config=false
    local operation_from_disabled=false

    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        ui_err "没有找到停用前的备份配置，无法恢复；可运行 sudo ntc config 重新配置。"
        ntc_operation_log machine-restore failure
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null && operation_from_disabled=true
        if ! cp "$CONFIG_FILE" "$rollback_file" || ! chmod 600 "$rollback_file" 2>/dev/null; then
            rm -f "$rollback_file"
            ui_err "无法备份当前配置，未执行恢复。"
            ntc_operation_log machine-restore failure
            return 1
        fi
        had_config=true
    fi

    # 恢复配置文件
    if ! cp "$BACKUP_CONFIG_FILE" "$restore_tmp" || ! chmod 600 "$restore_tmp" 2>/dev/null || ! mv -f "$restore_tmp" "$CONFIG_FILE"; then
        rm -f "$restore_tmp"
        rm -f "$rollback_file"
        ui_err "备份配置写回失败，未启用监控。"
        ntc_operation_log machine-restore failure
        return 1
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    ui_ok "已用停用前的备份覆盖当前配置。"

    # 启用监控
    if { $operation_from_disabled && enable_machine_limit --from-disabled-restore; } ||
       { ! $operation_from_disabled && enable_machine_limit; }; then
        rm -f "$rollback_file"
        ntc_operation_log machine-restore success
        return 0
    fi

    if $had_config; then
        if mv -f "$rollback_file" "$CONFIG_FILE"; then
            chmod 600 "$CONFIG_FILE" 2>/dev/null || true
            ui_err "从备份恢复失败：监控没有启用，已换回恢复前的配置。"
        else
            ui_err "从备份恢复失败，且恢复前的配置没能换回；它保留在 $rollback_file。"
        fi
    elif rm -f "$CONFIG_FILE"; then
        ui_err "从备份恢复失败：监控没有启用，已移除这次恢复的配置。"
    else
        ui_err "从备份恢复失败，且无法移除这次恢复的配置，请手动检查 $CONFIG_FILE。"
    fi
    ntc_operation_log machine-restore failure
    return 1
}

# ── 执行控制：宽限、暂停、恢复、开机宽限、立即解除（取代 1.x 的「限制执行控制」子菜单）───────────
# 流量统计和定时任务照常运行；这里只决定达到阈值后是否真的限速或关机。
# 不带 _interactive 的函数供命令行使用：不读输入、不等确认。

# 宽限、暂停、恢复、开机宽限只对已配置且启用的流量监控有意义：停用时监控不统计也不限速，这些操作不会生效。
machine_require_active_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        ui_err "尚未配置流量监控：运行 sudo ntc config 开始。"
        return 1
    fi
    if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        ui_err "流量监控已停用（不统计也不限速），这项操作不会生效。请先在「限制执行」里启用流量监控，或运行 sudo ntc enable。"
        return 1
    fi
}

# 宽限与暂停共用：取监控锁 → 撤销 NTC 的整机限速 → 取消 NTC 自己安排的计划关机 → 写执行状态。
# 任何一步失败都不写执行状态，并说明停在哪一步。$1=grace|paused $2=截止 epoch（暂停为 0）$3=审计事件
machine_set_enforcement() {
    local mode="$1" until_epoch="$2" event="$3"
    if ! acquire_monitor_cleanup_lock; then
        ui_err "另一个 NTC 操作正在进行（无法取得监控锁），未做任何改动。"
        ntc_operation_log "$event" failure
        return 1
    fi
    if ! clear_tc_rules; then
        release_monitor_cleanup_lock
        ui_err "无法安全撤销当前的整机限速，执行状态未改动。"
        ntc_operation_log "$event" failure
        return 1
    fi
    if ! cancel_owned_shutdown; then
        release_monitor_cleanup_lock
        ui_err "计划关机没有处理完（见上方），宽限/暂停没有生效；整机限速已撤销，仍超额时下一分钟的检查会再次限速。"
        ntc_operation_log "$event" failure
        return 1
    fi
    if ! write_enforcement_state "$mode" "$until_epoch" manual; then
        release_monitor_cleanup_lock
        ui_err "执行状态写入失败（$ENFORCEMENT_STATE_FILE）：限速已撤销，但宽限/暂停没有生效，仍超额时下一分钟的检查会再次限速。"
        ntc_operation_log "$event" failure
        return 1
    fi
    release_monitor_cleanup_lock
    ntc_operation_log "$event" success
}

# 宽限 $1 分钟（1–1440）：期间只统计、不限速，到期后自动恢复限制。
machine_grace() {
    local minutes until_epoch until_text
    if ! minutes=$(ntc_int "${1:-}" 1 1440); then
        ui_err "宽限时间必须是 1–1440 的整数（分钟）。"
        return 2
    fi
    machine_require_active_config || return 1
    until_epoch=$(( $(date +%s) + minutes * 60 ))
    machine_set_enforcement grace "$until_epoch" enforcement-grace || return 1
    until_text=$(date -d "@$until_epoch" '+%m-%d %H:%M' 2>/dev/null) || until_text=""
    ui_ok "已宽限 $minutes 分钟${until_text:+（到 $until_text）}：期间只统计、不限速，到期后自动恢复限制。"
}

# 菜单：先问分钟数（读到输入结束即取消，不做任何改动），再撤销限速、写状态。
machine_grace_interactive() {
    local minutes
    machine_require_active_config || return 1
    ui_note "宽限期间流量照常统计，达到阈值也不限速、不关机；到期后自动恢复限制。"
    if ! ui_read_int minutes "宽限多少分钟（1–1440）" 10 1 1440; then
        ui_note "已取消，未做任何改动。"
        return 1
    fi
    machine_grace "$minutes"
}

# 暂停限制，直到手动恢复；已经暂停时不重复写状态。
machine_pause() {
    machine_require_active_config || return 1
    if [ "$(ntc_kv "$ENFORCEMENT_STATE_FILE" MODE)" = paused ]; then
        ui_ok "限制本来就处于暂停状态，未做改动。"
        return 0
    fi
    machine_set_enforcement paused 0 enforcement-pause || return 1
    ui_ok "已暂停限制：流量照常统计，达到阈值也不限速、不关机。"
    ui_note "恢复：在「限制执行」里选「恢复限制」，或运行 sudo ntc resume。"
}

# 恢复限制：去掉宽限/暂停，达到阈值后按配置执行（整机限速仍遵守开机宽限）。
machine_resume() {
    machine_require_active_config || return 1
    if [ ! -e "$ENFORCEMENT_STATE_FILE" ]; then
        ui_ok "当前没有宽限或暂停，限制本来就按配置执行。"
        return 0
    fi
    if ! acquire_monitor_cleanup_lock; then
        ui_err "另一个 NTC 操作正在进行（无法取得监控锁），未做任何改动。"
        ntc_operation_log enforcement-resume failure
        return 1
    fi
    if ! cancel_owned_shutdown; then
        release_monitor_cleanup_lock
        ui_err "无法处理 NTC 的关机记录（见上方），限制没有恢复。"
        ntc_operation_log enforcement-resume failure
        return 1
    fi
    if ! rm -f "$ENFORCEMENT_STATE_FILE"; then
        release_monitor_cleanup_lock
        ui_err "无法删除执行状态文件 $ENFORCEMENT_STATE_FILE，限制没有恢复。"
        ntc_operation_log enforcement-resume failure
        return 1
    fi
    release_monitor_cleanup_lock
    ui_ok "已恢复限制：达到阈值后按配置执行（整机限速仍遵守开机宽限）。"
    ntc_operation_log enforcement-resume success
}

# 开机宽限 $1 分钟（0–1440，0 = 开机后立即限速），只对整机限速有效；值没变时不写文件。
machine_set_boot_grace() {
    local minutes current config_tmp
    if ! minutes=$(ntc_int "${1:-}" 0 1440); then
        ui_err "开机宽限必须是 0–1440 的整数（分钟）。"
        return 2
    fi
    machine_require_active_config || return 1
    case "$(ntc_kv "$CONFIG_FILE" LIMIT_MODE)" in
        tc) ;;
        shutdown) ui_err "超额后的处理是关机；开机宽限只对整机限速有效，未修改。"; return 1 ;;
        *) ui_err "配置里的超额处理（LIMIT_MODE）不是整机限速，开机宽限未修改。"; return 1 ;;
    esac
    current=$(ntc_kv "$CONFIG_FILE" TC_BOOT_GRACE_MINUTES) || current=""
    if [ "$current" = "$minutes" ]; then
        ui_ok "开机宽限已是 $minutes 分钟，未修改。"
        return 0
    fi
    config_tmp="${CONFIG_FILE}.tmp.$$"
    if ! awk -v value="$minutes" '
        BEGIN { updated=0 }
        /^TC_BOOT_GRACE_MINUTES=/ { print "TC_BOOT_GRACE_MINUTES=" value; updated=1; next }
        { print }
        END { if (!updated) print "TC_BOOT_GRACE_MINUTES=" value }
    ' "$CONFIG_FILE" > "$config_tmp" \
        || ! chmod 600 "$config_tmp" 2>/dev/null \
        || ! mv -f "$config_tmp" "$CONFIG_FILE"; then
        rm -f "$config_tmp"
        ui_err "开机宽限写入失败，配置未改动。"
        ntc_operation_log boot-grace failure
        return 1
    fi
    if [ "$minutes" -eq 0 ]; then
        ui_ok "开机宽限已改为 0：开机后立即按配置限速。"
    else
        ui_ok "开机宽限已改为 $minutes 分钟：开机后这段时间内只统计、不限速。"
    fi
    ntc_operation_log boot-grace success
}

# 菜单：回车保留当前值，读到输入结束即取消；改动前确认。
machine_boot_grace_interactive() {
    local current minutes
    machine_require_active_config || return 1
    if [ "$(ntc_kv "$CONFIG_FILE" LIMIT_MODE)" != tc ]; then
        ui_warn "开机宽限只对整机限速有效；当前超额后的处理不是整机限速。"
        return 1
    fi
    current=$(ntc_int "$(ntc_kv "$CONFIG_FILE" TC_BOOT_GRACE_MINUTES)" 0 1440) || current=10
    ui_note "开机后这段时间内只统计、不限速，防止限速规则在开机时就把机器卡住（0 = 开机后立即限速）。"
    if ! ui_read_int minutes "开机宽限（分钟，0–1440）" "$current" 0 1440; then
        ui_note "已取消，未修改。"
        return 1
    fi
    if [ "$minutes" = "$current" ]; then
        ui_ok "开机宽限保持 $current 分钟，未修改。"
        return 0
    fi
    if ! ui_confirm "把开机宽限从 $current 分钟改为 $minutes 分钟？" y; then
        ui_note "已取消，未修改。"
        return 1
    fi
    machine_set_boot_grace "$minutes"
}

# 立即解除 NTC 当前的整机限速（不改执行状态）。
machine_clear_tc() {
    local had_state=false
    [ -f "$TC_STATE_FILE" ] && had_state=true
    clear_tc_rules_with_lock || return 1
    if $had_state; then
        ui_note "如果用量仍然超过阈值，下一分钟的检查会再次限速；想持续不限速，请用 sudo ntc grace <分钟> 或 sudo ntc pause。"
    fi
}

# 菜单：先说明只解除这一次，再确认（默认 n）。
machine_clear_tc_interactive() {
    if [ ! -f "$TC_STATE_FILE" ]; then
        ui_ok "当前没有 NTC 施加的整机限速，无需解除。"
        return 0
    fi
    ui_note "只解除这一次：如果用量仍然超过阈值，下一分钟的检查会再次限速。"
    ui_note "想持续不限速，请改用「宽限一段时间」或「暂停限制」。"
    if ! ui_confirm "立即解除当前的整机限速？" n; then
        ui_note "已取消，未做任何改动。"
        return 1
    fi
    clear_tc_rules_with_lock
}

machine_disable_interactive() {
    ui_note "停用后不再统计、限速或关机：移除每分钟的检查任务，撤销 NTC 的整机限速，取消 NTC 安排的计划关机；配置先备份。"
    if ! ui_confirm "停用流量监控？" n; then
        ui_note "已取消，未做任何改动。"
        return 1
    fi
    disable_machine_limit interactive
}

machine_enable_interactive() {
    machine_require_dependencies interactive || return 1
    enable_machine_limit
}

machine_restore_interactive() {
    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        ui_warn "没有找到停用前的备份配置（停用流量监控时才会生成）。"
        return 1
    fi
    ui_note "将用停用前备份的配置覆盖当前配置，然后启用流量监控（先给 10 分钟启用宽限）。"
    if ! ui_confirm "从停用前的备份恢复配置？" n; then
        ui_note "已取消，未做任何改动。"
        return 1
    fi
    machine_require_dependencies interactive || return 1
    restore_machine_limit
}

# 监控最近一次检查的结论：读 monitor_health（ntc_health_summary），不再从日志里找“自动化模式运行”行
# （monitor 2.0 的日志只记事件，不再每分钟写这一行）。输出一行“最近检查”。
show_monitor_task_status() {
    local level text color
    # 停用后定时任务已移除，monitor_health 停在最后一次的结果，不能再按「超过 10 分钟没运行」报错。
    if [ -n "${CONFIG_FILE:-}" ] && grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        ui_row "$DIM" "最近检查" "已停用，不再检查" "$DIM"
        return 0
    fi
    IFS=$'\t' read -r level text < <(ntc_health_summary "$WORK_DIR/monitor_health")
    case "$level" in
        ok) color="$GREEN" ;;
        error) color="$RED" ;;
        unknown) color="$YELLOW" ;;
        *) color="$DIM" ;;
    esac
    ui_row "$DIM" "最近检查" "$text" "$color"
}

# 状态快照（菜单标题与 --status 共用）：只读配置、执行状态、monitor_health 与 root crontab，不取锁、不写文件。
# 结果放在 MS_* 变量里；总体状态与主菜单仪表盘同一算法（ntc_overall_status）。
machine_status_collect() {
    local cron="" usage_status hhmm
    MS_NOW=$(date +%s)
    MS_CONFIGURED=false MS_DISABLED=false MS_DISABLED_TIME="" MS_LIMIT_MODE="" MS_SPEED="" MS_BOOT_GRACE=10
    if [ -f "$CONFIG_FILE" ]; then
        MS_CONFIGURED=true
        if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
            MS_DISABLED=true
            MS_DISABLED_TIME=$(ntc_kv "$CONFIG_FILE" DISABLED_TIME) || MS_DISABLED_TIME=""
        fi
        MS_LIMIT_MODE=$(ntc_kv "$CONFIG_FILE" LIMIT_MODE) || MS_LIMIT_MODE=""
        MS_SPEED=$(ntc_kv "$CONFIG_FILE" LIMIT_SPEED) || MS_SPEED=""
        MS_BOOT_GRACE=$(ntc_int "$(ntc_kv "$CONFIG_FILE" TC_BOOT_GRACE_MINUTES)" 0 1440) || MS_BOOT_GRACE=10
    fi
    MS_ENF_MODE=$(ntc_kv "$ENFORCEMENT_STATE_FILE" MODE) || MS_ENF_MODE=""
    MS_ENF_UNTIL=$(ntc_kv "$ENFORCEMENT_STATE_FILE" UNTIL_EPOCH) || MS_ENF_UNTIL=""
    MS_ENF_REASON=$(ntc_kv "$ENFORCEMENT_STATE_FILE" REASON) || MS_ENF_REASON=""

    MS_CRON_OK=true MS_CRON_ENTRY=false
    if cron=$(read_root_crontab_locked 2>/dev/null); then
        if ntc_cron_has_entry "$cron" "$SCRIPT_PATH"; then MS_CRON_ENTRY=true; fi
    else
        MS_CRON_OK=false
    fi
    usage_status=$(ntc_kv "$WORK_DIR/current_traffic_state" STATUS) || usage_status=""
    if ! $MS_CONFIGURED; then
        MS_LEVEL=off MS_WORD="○ 尚未配置" MS_DETAIL="运行 sudo ntc config 开始"
    else
        IFS=$'\t' read -r MS_LEVEL MS_WORD MS_DETAIL < <(ntc_overall_status "$MS_DISABLED" "$MS_CRON_OK" \
            "$MS_CRON_ENTRY" "$WORK_DIR/monitor_health" "$usage_status" "$MS_SPEED" "$MS_ENF_UNTIL" "$MS_NOW")
    fi

    # 执行控制的说法：MS_ENF_BRIEF 用于标题，MS_ENF_TEXT 用于状态行。
    # 停用优先于残留的宽限/暂停状态；宽限过期即视为按配置执行。
    MS_ENF_BRIEF="按配置执行" MS_ENF_TEXT="按配置执行"
    if ! $MS_CONFIGURED; then
        MS_ENF_BRIEF="尚未配置" MS_ENF_TEXT="尚未配置流量监控"
    elif $MS_DISABLED; then
        MS_ENF_BRIEF="已停用" MS_ENF_TEXT="已停用：不统计、不限速、不关机"
    elif [ "$MS_ENF_MODE" = paused ]; then
        MS_ENF_BRIEF="已暂停" MS_ENF_TEXT="已暂停，直到手动恢复"
        [ "$MS_ENF_REASON" != shutdown_reboot ] || MS_ENF_TEXT="已暂停（关机后重启保护），直到手动恢复"
    elif [ "$MS_ENF_MODE" = grace ] && [[ "$MS_ENF_UNTIL" =~ ^[0-9]{1,12}$ ]] && [ "$MS_ENF_UNTIL" -gt "$MS_NOW" ]; then
        hhmm=$(date -d "@$MS_ENF_UNTIL" '+%m-%d %H:%M' 2>/dev/null) || hhmm="?"
        MS_ENF_BRIEF="宽限中"
        MS_ENF_TEXT="宽限到 $hhmm（约剩 $(( (MS_ENF_UNTIL - MS_NOW + 59) / 60 )) 分钟）"
    fi
}

# 超额后的处理与开机宽限两行（菜单标题与状态共用）；需先运行 machine_status_collect。
machine_action_rows() {
    if [ "$MS_LIMIT_MODE" = shutdown ]; then
        ui_kv "执行方式" "关机"
        return 0
    fi
    ui_kv "执行方式" "整机限速 ${MS_SPEED:-?} kbit/s"
    if [ "$MS_BOOT_GRACE" -eq 0 ]; then
        ui_kv "开机宽限" "0（开机后立即限速）"
    else
        ui_kv "开机宽限" "$MS_BOOT_GRACE 分钟"
    fi
}

# 状态（--status 与「详细状态」共用）：只读，不取锁、不写文件、不改 TC。$1=标题（默认「限制执行状态」）。
show_status() {
    local color
    local interface state_interface qdisc_line state_qdisc_line state_speed state_schema state_provider class_output query_status
    local tc_text tc_color
    machine_status_collect
    ui_title "${1:-限制执行状态}" "$MS_ENF_BRIEF"
    color=$(ui_level_color "$MS_LEVEL")
    # 状态词与说明同一颜色；放不下时 ui_row 折行，续行与值对齐。
    ui_row "$DIM" "总体状态" "$MS_WORD${MS_DETAIL:+  $MS_DETAIL}" "$color"
    ui_kv "限制执行" "$MS_ENF_TEXT"
    [ -z "$MS_DISABLED_TIME" ] || ui_kv "停用时间" "$MS_DISABLED_TIME"
    if $MS_CONFIGURED; then
        machine_action_rows
    fi
    show_monitor_task_status
    if ! $MS_CRON_OK; then
        ui_kv "定时任务" "无法读取 root crontab"
    elif $MS_CRON_ENTRY; then
        ui_kv "定时任务" "已安装（每分钟检查一次）"
    else
        ui_kv "定时任务" "未安装"
    fi

    # TC：直接查询 NTC 记录的网卡（只读）；措辞与 ntc status 一致。
    tc_color="$YELLOW"
    interface=$(get_main_interface)
    state_interface="$(tc_state_value "INTERFACE")"
    if [ -z "$TC_BIN" ]; then
        tc_text="无法检测（未找到 tc 命令）"
    elif [ -n "$state_interface" ]; then
        qdisc_line="$(tc_root_qdisc "$state_interface")"
        query_status=$?
        if [ "$query_status" -eq 2 ]; then
            tc_text="无法检测（tc 查询失败）"
        else
            [ "$query_status" -eq 0 ] || qdisc_line=""
            state_schema="$(tc_state_value SCHEMA)"
            state_provider="$(tc_state_value PROVIDER)"
            state_speed="$(tc_state_value LIMIT_SPEED)"
            if [ "$state_schema" = "$TC_STATE_SCHEMA" ] && [ "$state_provider" = "$TC_STATE_PROVIDER" ]; then
                class_output="$(tc_class_output "$state_interface")"
                query_status=$?
                if [ "$query_status" -eq 2 ]; then
                    tc_text="无法检测（tc 查询失败）"
                elif echo "$qdisc_line" | grep -Eq '^qdisc htb 1:([[:space:]]|$)' &&
                     printf '%s\n' "$class_output" | grep -Eq '^class htb 1:1([[:space:]]|$)' &&
                     printf '%s\n' "$class_output" | grep -Eq '^class htb 1:30([[:space:]]|$)'; then
                    tc_text="NTC 整机限速生效中（$state_interface，${state_speed} kbit/s）"
                else
                    tc_text="NTC 的限速记录与当前 TC 层级不一致，请运行 sudo ntc self-check"
                fi
            elif echo "$qdisc_line" | grep -q " tbf "; then
                state_qdisc_line="$(tc_state_value "QDISC_LINE")"
                if { [ -n "$state_qdisc_line" ] && [ "$qdisc_line" = "$state_qdisc_line" ]; } \
                    || { [ -z "$state_qdisc_line" ] && [[ "$state_speed" =~ ^[0-9]+$ ]] && echo "$qdisc_line" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; }; then
                    tc_text="NTC 整机限速生效中（旧版 tbf）"
                else
                    tc_text="限速记录与当前 tbf 不一致（按外部规则保留）"
                fi
            else
                tc_text="NTC 有限速记录，但规则不在（下一轮检查会处理）"
            fi
        fi
    elif [ -f "$TC_STATE_FILE" ]; then
        tc_text="NTC 的限速记录无效（没有记录网卡）"
    elif [ -n "$interface" ]; then
        qdisc_line="$(tc_root_qdisc "$interface")"
        query_status=$?
        if [ "$query_status" -eq 2 ]; then
            tc_text="无法检测（tc 查询失败）"
        elif echo "$qdisc_line" | grep -q " tbf "; then
            tc_text="检测到外部 tbf（不是 NTC 的）"
        elif echo "$qdisc_line" | grep -Eq '^qdisc htb 1:([[:space:]]|$)'; then
            tc_text="NTC 未限速（统一 HTB 存在，没有整机上限）"
            tc_color="$GREEN"
        else
            tc_text="NTC 未限速"
            tc_color="$GREEN"
        fi
    else
        tc_text="NTC 未限速"
        tc_color="$GREEN"
    fi
    ui_row "$DIM" "TC 限速" "$tc_text" "$tc_color"

    if [ -f "$BACKUP_CONFIG_FILE" ]; then
        ui_kv "停用备份" "有（可从备份恢复）"
    else
        ui_kv "停用备份" "无"
    fi
}

# 详细状态检查
machine_vnstat_cmd() {
    local config_path=""
    config_path=$(cat "$VNSTAT_CONFIG_PATH_FILE" 2>/dev/null || true)
    if [ -n "$config_path" ] && [ "${config_path#/}" != "$config_path" ] && [ -f "$config_path" ]; then
        vnstat --config "$config_path" "$@"
    else
        vnstat "$@"
    fi
}

machine_vnstat_config_value() {
    local target="$1"
    machine_vnstat_cmd --showconfig 2>/dev/null | awk -v target="$target" '
        {
            key=$1
            sub(/^[;#]/, "", key)
            if (key == target) {
                print $NF
                exit
            }
        }
    '
}

machine_vnstat_daemon_is_running() {
    local comm_file
    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        [ "$(cat "$comm_file" 2>/dev/null)" = "vnstatd" ] && return 0
    done
    return 1
}

machine_normalize_vnstat_json_for_interface() {
    local vnstat_json="$1"
    local expected_interface="$2"

    [[ "$expected_interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    printf '%s' "$vnstat_json" | jq -ce --arg expected "$expected_interface" '
        def uint: type == "number" and . >= 0 and floor == .;
        def leap_year($year):
            ($year % 400 == 0) or (($year % 4 == 0) and ($year % 100 != 0));
        def month_days($year; $month):
            if $month == 2 then (if leap_year($year) then 29 else 28 end)
            elif $month == 4 or $month == 6 or $month == 9 or $month == 11 then 30
            else 31 end;
        def valid_date:
            type == "object" and
            (.year | uint) and .year >= 1970 and .year <= 9999 and
            (.month | uint) and .month >= 1 and .month <= 12 and
            (.day | uint) and .day >= 1 and .day <= month_days(.year; .month);
        select(.jsonversion == "2" or .jsonversion == 2) |
        select((.interfaces | type) == "array") |
        [.interfaces[] | select(.name == $expected)] as $matches |
        select(($matches | length) == 1) |
        $matches[0] as $interface |
        select(($interface | type) == "object") |
        select($interface.created.date | valid_date) |
        select(($interface.updated | type) == "object") |
        select(($interface.traffic | type) == "object") |
        select(($interface.traffic.day | type) == "array") |
        select(all($interface.traffic.day[];
            (.date | valid_date) and (.rx | uint) and (.tx | uint))) |
        {jsonversion: "2", interfaces: [$interface]}
    ' 2>/dev/null
}

machine_vnstat_data_is_fresh() {
    local vnstat_json="$1"
    local updated_epoch updated_text now age save_interval update_interval max_age

    command -v jq >/dev/null 2>&1 || return 1
    machine_vnstat_daemon_is_running || return 1
    updated_epoch=$(printf '%s' "$vnstat_json" |
        jq -r '.interfaces[0].updated.timestamp // empty' 2>/dev/null) || return 1
    if ! [[ "$updated_epoch" =~ ^[0-9]+$ ]]; then
        updated_text=$(printf '%s' "$vnstat_json" | jq -r '
            .interfaces[0].updated as $u |
            if ($u.date.year == null or $u.date.month == null or $u.date.day == null or
                $u.time.hour == null or $u.time.minute == null) then empty
            else "\($u.date.year)-\($u.date.month)-\($u.date.day) \($u.time.hour):\($u.time.minute):\($u.time.second // 0)" end
        ' 2>/dev/null) || return 1
        [ -n "$updated_text" ] || return 1
        if [ "$(machine_vnstat_config_value "UseUTC")" = "1" ]; then
            updated_epoch=$(TZ=UTC date -d "$updated_text" +%s 2>/dev/null) || return 1
        else
            updated_epoch=$(date -d "$updated_text" +%s 2>/dev/null) || return 1
        fi
    fi
    now=$(date +%s) || return 1
    save_interval=$(machine_vnstat_config_value "SaveInterval")
    update_interval=$(machine_vnstat_config_value "UpdateInterval")
    [[ "$save_interval" =~ ^[1-9][0-9]*$ && "$update_interval" =~ ^[1-9][0-9]*$ ]] || return 1
    max_age=$((save_interval * 60 + update_interval + 90))
    age=$((now - updated_epoch))
    [ "$age" -ge -300 ] && [ "$age" -le "$max_age" ]
}

# 详细状态：状态 + 配置文件 + 相关定时任务 + 最近事件 + vnStat 当前数据。只读。
show_detailed_status() {
    local cron_detail="" lines log_file="$WORK_DIR/traffic_monitor.log" interface vnstat_json line
    show_status "详细状态"

    printf '\n   %b%s%b\n' "$DIM" "配置文件 $CONFIG_FILE" "$NC"
    if [ -f "$CONFIG_FILE" ]; then
        sed 's/^/    /' "$CONFIG_FILE"
    else
        ui_note "配置文件不存在。"
    fi

    printf '\n   %b%s%b\n' "$DIM" "相关定时任务" "$NC"
    if ! cron_detail=$(read_root_crontab_locked 2>/dev/null); then
        ui_warn "无法读取 root crontab，无法列出定时任务。"
    else
        lines=$(awk -v dir="$WORK_DIR" '!/^[[:space:]]*#/ && index($0, dir) { print "    " $0 }' <<< "$cron_detail")
        if [ -n "$lines" ]; then printf '%s\n' "$lines"; else ui_note "没有相关定时任务。"; fi
    fi

    # monitor 2.0 的日志只记事件（配置变更、执行状态变化、限速下发与解除、错误与恢复等）。
    printf '\n   %b%s%b\n' "$DIM" "最近事件" "$NC"
    if [ -s "$log_file" ]; then
        tail -n 10 "$log_file" | sed 's/^/    /'
    else
        ui_note "还没有事件记录。"
    fi

    printf '\n   %b%s%b\n' "$DIM" "vnStat 当前数据" "$NC"
    if ! command -v vnstat >/dev/null 2>&1; then
        ui_note "vnStat 未安装。"
        return 0
    fi
    interface=$(get_main_interface)
    if [ -z "$interface" ]; then
        ui_note "无法确定网卡。"
        return 0
    fi
    vnstat_json=$(machine_vnstat_cmd -i "$interface" --json 2>/dev/null || true)
    if [ -n "$vnstat_json" ] &&
       vnstat_json=$(machine_normalize_vnstat_json_for_interface "$vnstat_json" "$interface") &&
       machine_vnstat_data_is_fresh "$vnstat_json"; then
        line=$(machine_vnstat_cmd -i "$interface" --oneline 2>/dev/null | head -n 1)
        if [ -n "$line" ]; then printf '    %s\n' "$line"; else ui_note "无法获取流量统计。"; fi
    else
        ui_note "vnStat 守护进程未运行，或数据库数据已过期。"
    fi
}

# 「限制执行」菜单页：标题 + 状态行 + 两组选项。只输出，不读输入、不清屏（清屏由 machine_menu 负责）。
show_menu() {
    local color detail
    machine_status_collect
    ui_title "限制执行" "$MS_ENF_BRIEF"
    if ! $MS_CONFIGURED; then
        ui_warn "尚未配置流量监控：运行 sudo ntc config 开始。"
    else
        # 共用的总体状态写的是“在「限制执行」里…”，在本菜单里直接给出选项编号。
        detail="${MS_DETAIL//在「限制执行」里启用/选 7 启用}"
        detail="${detail//在「限制执行」里恢复/选 3 恢复}"
        color=$(ui_level_color "$MS_LEVEL")
        ui_row "$DIM" "总体状态" "$MS_WORD${detail:+  $detail}" "$color"
        machine_action_rows
        case "$MS_ENF_BRIEF" in
            宽限中|已暂停) ui_kv "执行控制" "$MS_ENF_TEXT" ;;
        esac
    fi
    printf '\n'
    ui_menu_groups 临时调整 设置 4 宽限一段时间 暂停限制 恢复限制 立即解除当前限速 \
        开机宽限 停用流量监控 启用流量监控 从停用前的备份恢复配置 详细状态
    ui_rule
    ui_option 0 返回
}

# 菜单动作放进子 shell：动作里的 exit、cd 或锁的文件描述符都不会影响菜单本身。
menu_run() {
    ( "$@" )
    return 0
}

# 「限制执行」菜单（无参数运行，也是 ntc 主菜单的「限制执行」）。0 或输入结束直接退出，不再要求按回车。
machine_menu() {
    local choice n
    while true; do
        menu_clear
        show_menu
        if ! ui_prompt 9 choice; then
            printf '\n'
            return 0
        fi
        if ! n=$(ntc_int "$(ntc_trim "$choice")" 0 9); then
            ui_warn "无效选择，请输入 0–9。"
            sleep 1
            continue
        fi
        [ "$n" -ne 0 ] || return 0
        printf '\n'
        case "$n" in
            1) menu_run machine_grace_interactive ;;
            2) menu_run machine_pause ;;
            3) menu_run machine_resume ;;
            4) menu_run machine_clear_tc_interactive ;;
            5) menu_run machine_boot_grace_interactive ;;
            6) menu_run machine_disable_interactive ;;
            7) menu_run machine_enable_interactive ;;
            8) menu_run machine_restore_interactive ;;
            9) menu_run show_detailed_status ;;
        esac
        ui_pause
    done
}

show_machine_usage() {
    cat << EOF
用法：trafficcop-lite-machine-limit.sh [选项]        NTC「限制执行」v${SCRIPT_VERSION:-}
  （无参数）          打开「限制执行」菜单
  --status            查看限制执行状态（只读）
  --enable            启用流量监控（先给 10 分钟宽限，之后每分钟检查）
  --disable           停用流量监控：不统计、不限速、不关机（配置先备份）
  --pause             暂停限制，流量照常统计
  --resume            恢复限制
  --grace 分钟        宽限一段时间（1-1440），期间只统计、不限速
  --boot-grace 分钟   开机宽限（0-1440，0 = 开机后立即限速；只对整机限速有效）
  --clear-tc          立即解除 NTC 当前的整机限速（仍超额时下一分钟会再次限速）
  -h, --help          显示本帮助
命令行参数不读输入、不等确认。平时请用 ntc 命令：ntc pause、ntc resume、ntc grace 30、ntc enable、ntc disable。
EOF
}

machine_usage_error() {
    printf '%s\n\n' "$1" >&2
    show_machine_usage >&2
    return 2
}

# 入口：先解析参数（不碰任何文件；用法错误一律退出码 2），--help 不要求 root。
main() {
    local action minutes=""
    case "$#:${1:-}" in
        0:) action=menu ;;
        1:-h|1:--help) action=help ;;
        1:--status|1:--enable|1:--disable|1:--pause|1:--resume|1:--clear-tc) action="${1#--}" ;;
        2:--grace)
            if ! minutes=$(ntc_int "$2" 1 1440); then
                machine_usage_error "--grace 需要 1–1440 的分钟数（收到：$2）"
                return 2
            fi
            action=grace
            ;;
        2:--boot-grace)
            if ! minutes=$(ntc_int "$2" 0 1440); then
                machine_usage_error "--boot-grace 需要 0–1440 的分钟数（收到：$2）"
                return 2
            fi
            action=boot-grace
            ;;
        1:--grace|1:--boot-grace)
            machine_usage_error "$1 缺少分钟数"
            return 2
            ;;
        *)
            machine_usage_error "无法识别的参数，或参数个数不对：$*"
            return 2
            ;;
    esac
    if [ "$action" = help ]; then
        show_machine_usage
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        ui_err "请使用 root 权限运行（sudo）。"
        return 1
    fi
    if [ "$action" = status ]; then
        show_status < /dev/null
        return 0
    fi

    # 创建工作目录
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR" 2>/dev/null || true

    # 命令行参数不读输入、不等确认：标准输入一律接 /dev/null。
    case "$action" in
        enable)
            machine_require_dependencies batch < /dev/null || return 1
            enable_machine_limit < /dev/null
            ;;
        disable) disable_machine_limit batch < /dev/null ;;
        pause) machine_pause < /dev/null ;;
        resume) machine_resume < /dev/null ;;
        grace) machine_grace "$minutes" < /dev/null ;;
        boot-grace) machine_set_boot_grace "$minutes" < /dev/null ;;
        clear-tc) machine_clear_tc < /dev/null ;;
        *) machine_menu ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
