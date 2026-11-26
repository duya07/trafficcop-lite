#!/bin/bash

# 设置 PATH 确保 cron 环境能找到所有命令
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本。"
    exit 1
fi

WORK_DIR="/etc/trafficcop-lite"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-monitor.sh"
LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
PERIOD_STATE_FILE="$WORK_DIR/last_reset_period"
RETENTION_STATE_FILE="$WORK_DIR/vnstat_daily_coverage_start"
VNSTAT_CONFIG_PATH_FILE="$WORK_DIR/vnstat_config_path"
USAGE_STATE_FILE="$WORK_DIR/current_traffic_state"
ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
ROOT_CRONTAB_LOCK_FILE="${TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE:-$WORK_DIR/root-crontab.lock}"
TC_HIERARCHY_LOCK_FILE="${TRAFFIC_TOOLS_TC_LOCK_FILE:-/run/lock/traffic-tools-tc.lock}"
TC_STATE_SCHEMA="traffic-tools-unified-htb-v1"
TC_STATE_PROVIDER="trafficcop-lite"
TC_PARENT_RATE="100gbit"
TC_DEFAULT_CLASS_RATE="1kbit"
TC_MARK_MASK=0xfffff000
VNSTAT_MAX_BANDWIDTH="${VNSTAT_MAX_BANDWIDTH:-0}"
VNSTAT_SAVE_INTERVAL=1
VNSTAT_CONFIG_TRANSACTION_ACTIVE=false
VNSTAT_TRANSACTION_DIR=""
VNSTAT_TRANSACTION_CONFIG_PATH=""
VNSTAT_TRANSACTION_INTERFACE=""
VNSTAT_TRANSACTION_INTERFACE_ADDED=false
VNSTAT_TRANSACTION_DAEMON_WAS_RUNNING=false
VNSTAT_TRANSACTION_SERVICE_MANAGER=""
VNSTAT_TRANSACTION_SERVICE_NAME=""
VNSTAT_TRANSACTION_HAD_RETENTION=false
VNSTAT_TRANSACTION_HAD_CONFIG_PATH_FILE=false
DOG_CONFIG_FILE="/etc/port-traffic-dog/config.json"
DOG_TC_OWNER_FILE="/etc/port-traffic-dog/tc-root-qdisc.owner"
# Dog 2.x 写出的 TC 类清单 tc-interop.json（与 config.json 同目录，见 dog_tc_manifest_file）。
# Dog 用下面的 schema 字符串判断已安装的 NTC 是否理解该清单；旧版 NTC 存在时 Dog 拒绝施加限速，
# 所以这一行不能删改。
DOG_TC_MANIFEST_SCHEMA="traffic-tools-dog-classes-v1"
HEALTH_STATE_FILE="$WORK_DIR/monitor_health"
# 2.0：每分钟一轮的日志只在状态变化时写入；上次写入时的状态指纹记在这里。
LOG_SIGNATURE_FILE="$WORK_DIR/monitor_log_signature"
TG_CONFIG_FILE="$WORK_DIR/tg_notifier_config.txt"
TC_RECOVERY_UNIT_FILE="${TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE:-/etc/systemd/system/traffic-tools-tc-recovery.service}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"
SCRIPT_VERSION="2.0.0"
DEPENDENCY_STATE_DIR="${DEPENDENCY_STATE_DIR:-/var/lib/trafficcop-lite/dependencies}"

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

dependency_manifest() {
    case "${1:-all}" in core|all) ;; *) return 2 ;; esac
    printf '%s\n' \
        'vnstat|vnstat|流量统计' 'jq|jq|JSON 解析' 'bc|bc|流量计算' \
        'iproute2|ip tc|网络和限速' 'cron|crontab|定时任务' \
        'util-linux|flock|互斥锁' 'procps|pgrep pkill|进程检查' 'curl|curl|下载和通知' \
        'ca-certificates|@ca-certificates|HTTPS 证书' 'coreutils|tac|基础工具' \
        'grep|grep|文本搜索' 'sed|sed|文本处理' 'mawk|awk|文本处理'
}
# The standalone monitor never exposes package removal.
dependency_removal_is_safe() { return 1; }
dependency_peer_uses_package() { return 0; }
dependency_audit() { :; }

# >>> ntc-common:deps >>>
# 本区块由 tools/sync-common.sh 根据 src/common/deps.sh 生成，请改源文件后运行该脚本，勿直接修改。
# BEGIN MANAGED DEPENDENCIES
# Shared reference implementation embedded into each standalone product; not sourced at runtime.
# Adapted from duya07/easy_Caddy dependency lifecycle, commit 843e7b4b686d5d191c9cd7dac7066a96fcbef5c1.
# Product hooks: dependency_manifest [core|all], dependency_peer_uses_package,
# dependency_removal_is_safe and dependency_audit. State remains outside application config.

dependency_error() { printf '依赖管理：%s\n' "$*" >&2; }
dependency_package_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$ ]]; }

dependency_installed() {
    local state
    state=$(dpkg-query -W -f='${db:Status-Status}\n' -- "$1" 2>/dev/null) || return 1
    [ "$state" = installed ]
}

dependency_tools_available() {
    local package="$1" tools="$2" tool
    if [ -z "$tools" ]; then dependency_installed "$package"; return; fi
    for tool in $tools; do
        case "$tool" in
            @ca-certificates)
                { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; } ||
                    { [ -s /etc/ssl/cert.pem ] && [ -r /etc/ssl/cert.pem ]; } || return 1
                ;;
            @nfqueue)
                # Python is reported separately; an already installed library can be rechecked after bootstrap.
                command -v python3 >/dev/null 2>&1 || return 3
                python3 -c 'import ctypes; ctypes.CDLL("libnetfilter_queue.so.1")' >/dev/null 2>&1 || return 1
                ;;
            tc) [ -n "$(find_tc_bin)" ] || return 1 ;;
            *) command -v "$tool" >/dev/null 2>&1 || return 1 ;;
        esac
    done
}

dependency_report() {
    local profile="${1:-all}" package tools description status package_state broken=0
    DEPENDENCY_MISSING_PACKAGES=()
    command -v dpkg-query >/dev/null 2>&1 || {
        dependency_error '完整依赖账本管理支持 Debian/Ubuntu；其他系统使用原有安装适配。'; return 2;
    }
    printf '依赖检测（命令与运行库实际可用性）：\n'
    dependency_no_pending || broken=1
    while IFS='|' read -r package tools description; do
        [ -n "$package" ] || continue
        package_state=$(dpkg-query -W -f='${db:Status-Status}\n' -- "$package" 2>/dev/null) || package_state=''
        case "$package_state" in
            unpacked|half-installed|half-configured|triggers-awaited|triggers-pending)
                printf '  [异常] %s：包状态为 %s，请先修复软件包。\n' "$package" "$package_state"
                broken=1
                continue ;;
        esac
        status=0
        dependency_tools_available "$package" "$tools" || status=$?
        if [ "$status" -eq 0 ]; then
            printf '  [可用] %s%s\n' "$package" "${description:+：$description}"
        elif [ "$status" -eq 3 ] && dependency_installed "$package"; then
            printf '  [待复检] %s：先安装 Python 3，再验证运行库。\n' "$package"
        elif dependency_installed "$package"; then
            printf '  [异常] %s：包已安装，但命令或运行库不可用；请检查 PATH 或修复软件包。\n' "$package"
            broken=1
        else
            printf '  [缺失] %s%s\n' "$package" "${description:+：$description}"
            DEPENDENCY_MISSING_PACKAGES+=("$package")
        fi
    done < <(dependency_manifest "$profile")
    [ "$broken" -eq 0 ] || return 2
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -eq 0 ]
}

dependency_safe_record() {
    local mode
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u:%h -- "$1")" = 0:1 ] || return 1
    mode=$(stat -c %a -- "$1") || return 1
    (( (8#$mode & 0077) == 0 ))
}

dependency_prepare_state() {
    local part current='' mode file
    [ "$EUID" -eq 0 ] || { dependency_error '安装或卸载需要 root。'; return 1; }
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
        dependency_error '需要 apt-get 和 flock；请先确认系统包管理器及基础工具。'; return 1
    fi
    [[ "$DEPENDENCY_STATE_DIR" == /* && "$DEPENDENCY_STATE_DIR" != / ]] || return 1
    local -a parts=()
    IFS=/ read -r -a parts <<< "$DEPENDENCY_STATE_DIR"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        case "$part" in .|..) return 1 ;; esac
        current+="/$part"
        [ ! -L "$current" ] || { dependency_error '依赖状态路径包含符号链接，已拒绝。'; return 1; }
        if [ -e "$current" ]; then
            [ -d "$current" ] && [ "$(stat -c %u -- "$current")" = 0 ] || return 1
            mode=$(stat -c %a -- "$current") || return 1
            (( (8#$mode & 0022) == 0 )) || { dependency_error '依赖路径上级目录可被其他用户写入，已拒绝。'; return 1; }
        fi
    done
    if [ -e "$DEPENDENCY_STATE_DIR" ]; then
        [ -d "$DEPENDENCY_STATE_DIR" ] && [ "$(stat -c %u -- "$DEPENDENCY_STATE_DIR")" = 0 ] || return 1
        mode=$(stat -c %a -- "$DEPENDENCY_STATE_DIR") || return 1
        (( (8#$mode & 0022) == 0 )) || { dependency_error '依赖目录可被其他用户写入，已拒绝。'; return 1; }
    else
        mkdir -p -- "$DEPENDENCY_STATE_DIR" || return 1
    fi
    chmod 700 -- "$DEPENDENCY_STATE_DIR" || return 1
    for file in installed-packages pending-before pending-plan lock; do
        if [ -e "$DEPENDENCY_STATE_DIR/$file" ] || [ -L "$DEPENDENCY_STATE_DIR/$file" ]; then
            dependency_safe_record "$DEPENDENCY_STATE_DIR/$file" || { dependency_error "不安全的依赖记录：$file"; return 1; }
        fi
    done
}

dependency_read_owned() {
    local package path="$DEPENDENCY_STATE_DIR/installed-packages"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then return 0; fi
    dependency_safe_record "$path" || { dependency_error '新增包账本不是安全的普通文件。'; return 1; }
    while IFS= read -r package || [ -n "$package" ]; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || { dependency_error '新增包账本含无效包名。'; return 1; }
        printf '%s\n' "$package"
    done < "$path"
}

dependency_snapshot() {
    local rows
    rows=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Essential}\t${Protected}\n') || return 1
    printf '%s\n' "$rows" | awk -F '\t' -v phase="${2:-after}" '
        (phase == "before" && $2 != "not-installed") || (phase == "after" && $2 == "installed") ||
        (phase == "remaining" && $2 != "not-installed" && $2 != "config-files") ||
        (phase == "incomplete" && $2 ~ /^(unpacked|half-installed|half-configured|triggers-awaited|triggers-pending)$/) {print $1}
    ' | LC_ALL=C sort -u > "$1" || return 1
    chmod 600 -- "$1"
}

dependency_save_owned() {
    local stage
    stage=$(mktemp "$DEPENDENCY_STATE_DIR/.owned.XXXXXX") || return 1
    if ! LC_ALL=C sort -u -- "$1" > "$stage" || ! chmod 600 -- "$stage" ||
       ! mv -f -- "$stage" "$DEPENDENCY_STATE_DIR/installed-packages"; then
        rm -f -- "$stage"
        dependency_error '新增包账本保存失败，事务快照已保留。'
        return 1
    fi
}

dependency_no_pending() {
    if [ -e "$DEPENDENCY_STATE_DIR/pending-before" ] || [ -L "$DEPENDENCY_STATE_DIR/pending-before" ] ||
       [ -e "$DEPENDENCY_STATE_DIR/pending-plan" ] || [ -L "$DEPENDENCY_STATE_DIR/pending-plan" ]; then
        dependency_error "发现未完成安装事务；请核对 $DEPENDENCY_STATE_DIR 的 pending-before/pending-plan，本次不自动认领或卸载。"
        return 1
    fi
}

dependency_install_missing() (
    umask 077
    local assume_yes="${1:-false}" profile="${2:-all}" status=0 answer stage plan owned package base native_arch changes rc=0 lock_fd incomplete=false
    dependency_no_pending || return 1
    dependency_report "$profile" || status=$?
    [ "$status" -ne 2 ] || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || { printf '依赖全部可用，无需安装；原有包不会记为新增。\n'; return 0; }
    printf '仅安装缺失项：\n'; printf '  %s\n' "${DEPENDENCY_MISSING_PACKAGES[@]}"
    if [ "$assume_yes" != true ]; then
        read -r -p '确认安装？[y/yes，默认 n]：' answer || return 1
        case "${answer,,}" in y|yes) ;; *) printf '安装已取消。\n'; return 1 ;; esac
    fi
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    chmod 600 -- "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || { dependency_error '依赖管理锁暂忙。'; return 1; }
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    status=0; dependency_report "$profile" || status=$?
    [ "$status" -ne 2 ] || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || return 0
    native_arch=$(dpkg --print-architecture) || { dependency_error '无法确认系统包架构。'; return 1; }
    [[ "$native_arch" =~ ^[a-z0-9-]+$ ]] || return 1
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.transaction.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    apt-get update || { dependency_error '软件包索引更新失败，未安装。'; return 1; }
    dependency_snapshot "$stage/before" before || return 1
    plan=$(LC_ALL=C apt-get --simulate --no-remove --no-install-recommends install -- "${DEPENDENCY_MISSING_PACKAGES[@]}") || return 1
    if printf '%s\n' "$plan" | grep -q '^Remv '; then dependency_error '安装计划包含删除，已停止。'; return 1; fi
    printf '%s\n' "$plan" | awk '$1 == "Inst" {print $2}' | LC_ALL=C sort -u > "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
    done < "$stage/plan"
    for package in "${DEPENDENCY_MISSING_PACKAGES[@]}"; do
        if ! grep -Fxq -- "$package" "$stage/plan" && ! grep -Fxq -- "$package:$native_arch" "$stage/plan"; then
            dependency_error "APT 计划未包含缺失包 $package，未执行安装。"; return 1
        fi
    done
    printf '安装计划（含传递依赖）：\n'; cat -- "$stage/plan"
    dependency_snapshot "$stage/recheck" before || return 1
    changes=$(LC_ALL=C comm -3 "$stage/before" "$stage/recheck") || return 1
    [ -z "$changes" ] || { dependency_error 'APT 计划期间软件包状态已变化，未执行安装，请重试。'; return 1; }
    install -m 600 -- "$stage/before" "$DEPENDENCY_STATE_DIR/pending-before" &&
        install -m 600 -- "$stage/plan" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    apt-get --no-remove --no-install-recommends install -y -- "${DEPENDENCY_MISSING_PACKAGES[@]}" || rc=$?
    dependency_snapshot "$stage/after" || { dependency_error '无法读取安装后状态，保留事务快照。'; return 1; }
    dependency_snapshot "$stage/incomplete" incomplete || { dependency_error '无法读取未完成包状态，保留事务快照。'; return 1; }
    printf '%s\n' "$owned" | sed '/^$/d' > "$stage/owned"
    LC_ALL=C comm -13 "$stage/before" "$stage/after" > "$stage/new" || return 1
    cut -d: -f1 "$stage/before" | LC_ALL=C sort -u > "$stage/before-bases" || return 1
    local -A planned=()
    while IFS= read -r package; do
        [ -n "$package" ] && planned["$package"]=1
    done < "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        base=${package%%:*}
        if [ "${planned[$package]:-0}" = 1 ] || [ "${planned[$base]:-0}" = 1 ] ||
           [ "${planned[$base:$native_arch]:-0}" = 1 ]; then incomplete=true; fi
    done < "$stage/incomplete"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        base=${package%%:*}
        grep -Fxq -- "$base" "$stage/before-bases" && continue
        if [ "${planned[$package]:-0}" = 1 ] ||
           { [[ "$package" == *:* ]] && [ "${package#*:}" = "$native_arch" ] && [ "${planned[$base]:-0}" = 1 ]; }; then
            printf '%s\n' "$package" >> "$stage/owned"
            printf '已记录本脚本新增依赖：%s\n' "$package"
        fi
    done < "$stage/new"
    dependency_save_owned "$stage/owned" || return 1
    if $incomplete; then
        dependency_error '安装后仍有未配置完成的计划包，已记录已安装项并保留事务快照；请人工核对。'
        dependency_audit dependency_install 1
        return 1
    fi
    rm -f -- "$DEPENDENCY_STATE_DIR/pending-before" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    if [ "$rc" -ne 0 ]; then
        dependency_error '安装未全部成功；实际已装的新包已记录，可重试或按账本卸载。'
        dependency_audit dependency_install "$rc"
        return "$rc"
    fi
    if ! dependency_report "$profile"; then
        dependency_error '安装命令已完成，但命令/运行库复检失败，未报告成功。'
        dependency_audit dependency_install 1
        return 1
    fi
    dependency_audit dependency_install 0
    printf '依赖安装并复检完成；已有依赖的归属保持不变。\n'
)

dependency_protected() {
    local flags base="${1%%:*}"
    case "$base" in bash|apt|dpkg|systemd*|libsystemd*|libpam*|libudev*|coreutils|findutils|grep|sed|mawk|gawk|util-linux|libc6|libc-bin|libgcc-s1|libstdc++6) return 0 ;; esac
    flags=$(dpkg-query -W -f='${Essential}\t${Protected}\n' -- "$1" 2>/dev/null) || return 0
    [[ "$flags" == *yes* ]]
}

dependency_retained_dependencies() {
    [ "$#" -gt 0 ] || return 0
    local records
    records=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Pre-Depends}, ${Depends}\n') || return 1
    # Keep every installed alternative and transitive dependency of a retained package.
    awk -F '\t' -v roots="$*" '
        function base(name) { sub(/:[A-Za-z0-9-]+$/, "", name); return name }
        $2 == "installed" { name=base($1); present[name]=1; deps[name]=deps[name] "," $3 }
        END {
            count=split(roots, initial, " "); last=0
            for (i=1; i<=count; i++) { name=base(initial[i]); if (!seen[name]++) queue[++last]=name }
            for (first=1; first<=last; first++) {
                name=queue[first]; print name
                count=split(deps[name], edges, /[,|]/)
                for (i=1; i<=count; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", edges[i]); split(edges[i], words, /[ \t]+/)
                    child=base(words[1]); if (present[child] && !seen[child]++) queue[++last]=child
                }
            }
        }' <<< "$records"
}

dependency_remove() (
    umask 077
    local scope="${1:-owned}" assume_yes="${2:-false}" owned candidates package package_state base native_arch plan answer stage records flags retained rc=0 lock_fd
    dependency_removal_is_safe || return 1
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    chmod 600 -- "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || return 1
    dependency_removal_is_safe || return 1
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    if [ "$scope" = all ]; then
        candidates=$(printf '%s\n%s\n' "$(dependency_manifest all | cut -d '|' -f1)" "$owned" | sed '/^$/d' | LC_ALL=C sort -u)
        printf '已选择全部相关依赖，包括安装前已有的包；系统基础包和另一脚本仍使用的包仍会保留。\n'
    else
        candidates="$owned"
        printf '卸载范围：仅本脚本新增并记录的依赖。\n'
    fi
    local -a selected=() removals=() protected_roots=() filtered=()
    local -A allowed=() required=()
    records=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Essential}\t${Protected}\n') || {
        dependency_error '无法读取已安装包的保护状态，已停止卸载。'; return 1;
    }
    while IFS='|' read -r package flags; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        base=${package%%:*}
        case "$base" in
            bash|apt|dpkg|systemd*|libsystemd*|libpam*|libudev*|coreutils|findutils|grep|sed|mawk|gawk|util-linux|libc6|libc-bin|libgcc-s1|libstdc++6) flags=yes ;;
        esac
        if [ "$flags" = yes ] || dependency_peer_uses_package "$package"; then protected_roots+=("$package"); fi
    done < <(awk -F '\t' '$2 == "installed" {print $1 "|" (($3 == "yes" || $4 == "yes") ? "yes" : "no")}' <<< "$records")
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        if ! dependency_installed "$package"; then
            package_state=$(dpkg-query -W -f='${db:Status-Status}\n' -- "$package" 2>/dev/null) || package_state=''
            case "$package_state" in unpacked|half-installed|half-configured|triggers-awaited|triggers-pending)
                dependency_error "包 $package 状态未完成，请先修复后再卸载。"; return 1 ;; esac
            continue
        fi
        if dependency_protected "$package"; then printf '保留系统基础/受保护包：%s\n' "$package"; protected_roots+=("$package"); continue; fi
        if dependency_peer_uses_package "$package"; then printf '保留另一脚本仍需使用的包：%s\n' "$package"; protected_roots+=("$package"); continue; fi
        selected+=("$package"); allowed["$package"]=1
    done <<< "$candidates"
    if [ "${#selected[@]}" -gt 0 ]; then
        retained=$(dependency_retained_dependencies "${protected_roots[@]}") || {
            dependency_error '无法读取受保护软件包的依赖，已停止卸载。'; return 1;
        }
        while IFS= read -r package; do
            [ -z "$package" ] || required["${package%%:*}"]=1
        done <<< "$retained"
        allowed=()
        for package in "${selected[@]}"; do
            if [ "${required[${package%%:*}]:-0}" = 1 ]; then
                printf '保留受保护/共享组件所需的依赖：%s\n' "$package"
            else
                filtered+=("$package"); allowed["$package"]=1
            fi
        done
        selected=("${filtered[@]}")
    fi
    [ "${#selected[@]}" -gt 0 ] || { printf '没有可卸载的新依赖；未改动系统软件包。\n'; return 0; }
    native_arch=$(dpkg --print-architecture) || { dependency_error '无法确认系统包架构。'; return 1; }
    [[ "$native_arch" =~ ^[a-z0-9-]+$ ]] || return 1
    plan=$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false remove -- "${selected[@]}") || return 1
    if printf '%s\n' "$plan" | grep -q '^Inst '; then dependency_error '卸载计划会安装其他包，已停止。'; return 1; fi
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        if [ "${allowed[$package]:-0}" != 1 ]; then
            case "$package" in
                *:"$native_arch") base=${package%:*}; if [ "${allowed[$base]:-0}" = 1 ]; then package=$base; fi ;;
                *:*) ;;
                *) base="$package:$native_arch"; if [ "${allowed[$base]:-0}" = 1 ]; then package=$base; fi ;;
            esac
        fi
        if [ "${allowed[$package]:-0}" != 1 ] || dependency_protected "$package" || dependency_peer_uses_package "$package"; then
            dependency_error "计划会额外删除范围外/受保护包 $package，已停止。"
            return 1
        fi
        removals+=("$package")
    done < <(printf '%s\n' "$plan" | awk '$1 == "Remv" {print $2}')
    [ "${#removals[@]}" -gt 0 ] || { printf '卸载计划为空，未改动软件包。\n'; return 0; }
    printf '本次将删除以下依赖，不执行 autoremove/purge：\n'; printf '  %s\n' "${removals[@]}"
    if [ "$assume_yes" != true ]; then
        read -r -p '确认卸载上述依赖？[y/yes，默认 n]：' answer || return 0
        case "${answer,,}" in y|yes) ;; *) printf '卸载已取消。\n'; return 0 ;; esac
    fi
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.uninstall.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    dependency_removal_is_safe || return 1
    for package in "${removals[@]}"; do
        if dependency_protected "$package" || dependency_peer_uses_package "$package"; then
            dependency_error "卸载前保护状态已变化：$package，已停止。"; return 1
        fi
    done
    apt-get -o APT::Get::AutomaticRemove=false remove -y -- "${removals[@]}" || rc=$?
    dependency_snapshot "$stage/remaining" remaining || { dependency_error '无法读取卸载后状态，原账本已保留。'; return 1; }
    cut -d: -f1 "$stage/remaining" | LC_ALL=C sort -u > "$stage/remaining-bases" || return 1
    : > "$stage/owned"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if grep -Fxq -- "${package%%:*}" "$stage/remaining-bases"; then printf '%s\n' "$package" >> "$stage/owned"; fi
    done <<< "$owned"
    dependency_save_owned "$stage/owned" || return 1
    for package in "${removals[@]}"; do
        if grep -Fxq -- "${package%%:*}" "$stage/remaining-bases"; then rc=1; fi
    done
    dependency_audit dependency_remove "$rc"
    [ "$rc" -eq 0 ] || { dependency_error '卸载未全部完成；剩余新增依赖已保留在账本中。'; return "$rc"; }
    printf '依赖卸载完成；范围外和原有依赖保持不变。\n'
)

dependency_cli() {
    local action="${1:-check}" scope=owned yes=false option
    [ "$#" -eq 0 ] || shift
    for option in "$@"; do
        case "$option" in --yes) yes=true ;; --all) scope=all ;; *) dependency_error "未知参数：$option"; return 2 ;; esac
    done
    case "$action" in
        check) [ "$scope" = owned ] && [ "$yes" = false ] || return 2; dependency_report all ;;
        install) [ "$scope" = owned ] || return 2; dependency_install_missing "$yes" all ;;
        remove) dependency_remove "$scope" "$yes" ;;
        owned) [ "$scope" = owned ] && [ "$yes" = false ] || return 2; dependency_read_owned ;;
        *) dependency_error '用法：--dependencies check|install [--yes]|remove [--all] [--yes]|owned'; return 2 ;;
    esac
}

dependency_menu() {
    local choice scope
    while true; do
        printf '\n=== 依赖检测、安装与卸载 ===\n'
        dependency_report all || true
        printf ' 1. 检测全部依赖（只读）\n 2. 仅安装缺失依赖\n 3. 查看本脚本新增包账本\n 4. 卸载依赖\n 0. 返回\n'
        read -r -p '请选择 [0-4]：' choice || return 0
        case "$choice" in
            1) dependency_report all || true ;;
            2) dependency_install_missing false all || true ;;
            3) dependency_read_owned || true; printf '账本位置：%s/installed-packages\n' "$DEPENDENCY_STATE_DIR" ;;
            4)
                read -r -p '范围：1 仅本脚本新增（默认），2 全部相关，0 取消：' scope || return 0
                case "$scope" in ''|1) dependency_remove owned false || true ;; 2) dependency_remove all false || true ;; 0) ;; *) printf '无效范围。\n' ;; esac
                ;;
            0) return 0 ;;
            *) printf '无效选择。\n' ;;
        esac
        read -r -p '按回车返回依赖管理...' choice || return 0
    done
}

# END MANAGED DEPENDENCIES
# <<< ntc-common:deps <<<

trim_log_file() {
    local file="$1"
    local max_lines="$2"
    local tmp_file

    [ -f "$file" ] || return 0
    [[ "$max_lines" =~ ^[1-9][0-9]*$ ]] || max_lines=5000
    local trim_at=$((max_lines + max_lines / 5))
    [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -le "$trim_at" ] && return 0

    tmp_file="${file}.tmp.$$"
    tail -n "$max_lines" "$file" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$file"
    rm -f "$tmp_file" 2>/dev/null || true
}

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






migrate_files() {
    mkdir -p "$WORK_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 使用独立工作目录: $WORK_DIR" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

vnstat_version_parts() {
    local version_output
    version_output=$(vnstat --version 2>&1 | head -n 1) || return 1
    printf '%s\n' "$version_output" | sed -n \
        's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p'
}

vnstat_daemon_config_path() {
    local comm_file pid cmdline_path="" detected_path="" argument expect_path=false
    local daemon_count=0

    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        [ "$(cat "$comm_file" 2>/dev/null)" = "vnstatd" ] || continue
        daemon_count=$((daemon_count + 1))
        cmdline_path=""
        expect_path=false
        pid=${comm_file#/proc/}
        pid=${pid%/comm}
        [ -r "/proc/$pid/cmdline" ] || continue
        while IFS= read -r argument; do
            if $expect_path; then
                cmdline_path="$argument"
                expect_path=false
                continue
            fi
            case "$argument" in
                --config) expect_path=true ;;
                --config=*) cmdline_path=${argument#--config=} ;;
            esac
        done < <(tr '\0' '\n' < "/proc/$pid/cmdline")
        [ -n "$cmdline_path" ] || continue
        if [ -n "$detected_path" ] && [ "$detected_path" != "$cmdline_path" ]; then
            return 2
        fi
        detected_path="$cmdline_path"
    done
    [ "$daemon_count" -le 1 ] || return 2
    [ -n "$detected_path" ] || return 1
    printf '%s\n' "$detected_path"
}

executable_install_prefix() {
    local executable="$1" resolved bin_dir bin_name prefix

    [ -n "$executable" ] && [ "${executable#/}" != "$executable" ] || return 1
    resolved=$(readlink -f "$executable" 2>/dev/null) || return 1
    [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
    bin_dir=${resolved%/*}
    bin_name=${bin_dir##*/}
    case "$bin_name" in
        bin|sbin) ;;
        *) return 1 ;;
    esac
    prefix=${bin_dir%/*}
    [ -n "$prefix" ] || prefix=/
    printf '%s\n' "$prefix"
}

vnstat_daemon_install_prefix() {
    local comm_file pid daemon_count=0 daemon_executable=""

    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        [ "$(cat "$comm_file" 2>/dev/null)" = "vnstatd" ] || continue
        daemon_count=$((daemon_count + 1))
        pid=${comm_file#/proc/}
        pid=${pid%/comm}
        daemon_executable=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || return 1
    done
    [ "$daemon_count" -eq 1 ] || return 1
    executable_install_prefix "$daemon_executable"
}

vnstat_cli_install_prefix() {
    local vnstat_path vnstatd_path vnstat_prefix vnstatd_prefix

    vnstat_path=$(command -v vnstat 2>/dev/null) || return 1
    vnstatd_path=$(command -v vnstatd 2>/dev/null) || return 1
    vnstat_prefix=$(executable_install_prefix "$vnstat_path") || return 1
    vnstatd_prefix=$(executable_install_prefix "$vnstatd_path") || return 1
    [ "$vnstat_prefix" = "$vnstatd_prefix" ] || return 1
    printf '%s\n' "$vnstat_prefix"
}

canonical_config_path() {
    local path="$1" resolved
    [ -n "$path" ] && [ "${path#/}" != "$path" ] || return 1
    resolved=$(readlink -f "$path" 2>/dev/null) || return 1
    path="$resolved"
    [ -f "$path" ] || return 1
    printf '%s\n' "$path"
}

resolve_vnstat_config_path() {
    local daemon_path="" daemon_status daemon_prefix cli_prefix
    local debug_output cli_path="" candidate resolved

    daemon_path=$(vnstat_daemon_config_path 2>/dev/null)
    daemon_status=$?
    if [ "$daemon_status" -eq 0 ]; then
        resolved=$(canonical_config_path "$daemon_path") || return 1
        VNSTAT_CONFIG_PATH="$resolved"
    elif [ "$daemon_status" -eq 2 ]; then
        return 1
    else
        # vnstatd 没有显式 --config 时，只有运行进程、vnstatd 命令和 vnstat
        # 客户端都能证明来自同一安装前缀，才可采用客户端报告的默认配置。
        daemon_prefix=$(vnstat_daemon_install_prefix) || return 1
        cli_prefix=$(vnstat_cli_install_prefix) || return 1
        [ "$daemon_prefix" = "$cli_prefix" ] || return 1
        debug_output=$(LC_ALL=C vnstat --debug --showconfig 2>&1) || return 1
        cli_path=$(printf '%s\n' "$debug_output" |
            sed -n 's/^Config file:[[:space:]]*//p' | tail -n 1)
        if [ -n "$cli_path" ]; then
            resolved=$(canonical_config_path "$cli_path") || return 1
            VNSTAT_CONFIG_PATH="$resolved"
        else
            for candidate in /etc/vnstat.conf /etc/vnstat/vnstat.conf /usr/local/etc/vnstat.conf; do
                if resolved=$(canonical_config_path "$candidate" 2>/dev/null); then
                    VNSTAT_CONFIG_PATH="$resolved"
                    break
                fi
            done
        fi
    fi
    [ -n "${VNSTAT_CONFIG_PATH:-}" ] || return 1
    if [ -f "$VNSTAT_CONFIG_PATH_FILE" ] &&
       [ "$(cat "$VNSTAT_CONFIG_PATH_FILE" 2>/dev/null)" = "$VNSTAT_CONFIG_PATH" ]; then
        return 0
    fi
    printf '%s\n' "$VNSTAT_CONFIG_PATH" > "${VNSTAT_CONFIG_PATH_FILE}.tmp.$$" || return 1
    chmod 600 "${VNSTAT_CONFIG_PATH_FILE}.tmp.$$" 2>/dev/null || true
    mv -f "${VNSTAT_CONFIG_PATH_FILE}.tmp.$$" "$VNSTAT_CONFIG_PATH_FILE" || {
        rm -f "${VNSTAT_CONFIG_PATH_FILE}.tmp.$$"
        return 1
    }
}

vnstat_cmd() {
    if [ -n "${VNSTAT_CONFIG_PATH:-}" ]; then
        vnstat --config "$VNSTAT_CONFIG_PATH" "$@"
    else
        vnstat "$@"
    fi
}

vnstat_config_value_from_file() {
    local config_path="$1"
    local target="$2"
    vnstat --config "$config_path" --showconfig 2>/dev/null | awk -v target="$target" '
        {
            raw=$1
            key=raw
            sub(/^[;#]/, "", key)
            if (key != target) next
            # vnStat 的 --showconfig 会先输出被注释掉的示例行、再输出实际生效行。
            # 注释值只当回退，否则两者不一致时会读到示例值（例如 #MaxBWeth0 8 与实际值 0）。
            if (raw ~ /^[;#]/) {
                if (fallback == "") fallback=$NF
                next
            }
            print $NF
            found=1
            exit
        }
        END {
            if (!found && fallback != "") print fallback
        }
    '
}

vnstat_config_value() {
    local target="$1"
    vnstat_cmd --showconfig 2>/dev/null | awk -v target="$target" '
        {
            raw=$1
            key=raw
            sub(/^[;#]/, "", key)
            if (key != target) next
            # 同 vnstat_config_value_from_file：注释示例行与生效行同时存在时，优先取生效行。
            if (raw ~ /^[;#]/) {
                if (fallback == "") fallback=$NF
                next
            }
            print $NF
            found=1
            exit
        }
        END {
            if (!found && fallback != "") print fallback
        }
    '
}

read_current_crontab() {
    # 错误输出放在临时目录：只读的 --status 也走这里，不能往安装目录写文件（安装目录也可能还不存在）。
    local error_file current_crontab status

    if ! error_file=$(mktemp "${TMPDIR:-/tmp}/ntc-crontab-read.XXXXXX" 2>/dev/null); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 读取当前 crontab 失败：无法创建临时文件" | tee -a "$LOG_FILE" >&2
        return 1
    fi
    current_crontab=$(LC_ALL=C crontab -l 2>"$error_file")
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$error_file"
        printf '%s\n' "$current_crontab"
        return 0
    fi
    if grep -Eqi 'no crontab for|no such file or directory' "$error_file" 2>/dev/null; then
        rm -f "$error_file"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') 读取当前 crontab 失败：$(cat "$error_file" 2>/dev/null)" | tee -a "$LOG_FILE" >&2
    rm -f "$error_file"
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
    local current_crontab="" status=0

    acquire_root_crontab_lock || return 1
    current_crontab=$(read_current_crontab) || status=$?
    release_root_crontab_lock
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$current_crontab"
}

align_timezone_with_vnstat() {
    local use_utc
    use_utc=$(vnstat_config_value "UseUTC")
    if [ "$use_utc" = "1" ]; then
        export TZ=UTC
    else
        unset TZ
    fi
}

vnstat_daemon_pids() {
    local comm_file pid
    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        [ "$(cat "$comm_file" 2>/dev/null)" = "vnstatd" ] || continue
        pid=${comm_file#/proc/}
        pid=${pid%/comm}
        [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s\n' "$pid"
    done
}

vnstat_daemon_is_running() {
    [ -n "$(vnstat_daemon_pids)" ]
}

start_vnstat_daemon_strict() {
    local service_name

    if command_exists systemctl && [ -d /run/systemd/system ]; then
        for service_name in vnstat vnstatd; do
            if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null |
                grep -q "^${service_name}\.service"; then
                run_privileged systemctl enable --now "${service_name}.service" >/dev/null 2>&1 || return 1
                systemctl is-active --quiet "${service_name}.service" 2>/dev/null || return 1
                vnstat_daemon_is_running
                return $?
            fi
        done
    elif command_exists rc-service; then
        for service_name in vnstat vnstatd; do
            [ -x "/etc/init.d/$service_name" ] || continue
            if command_exists rc-update; then
                run_privileged rc-update add "$service_name" default >/dev/null 2>&1 || return 1
            fi
            run_privileged rc-service "$service_name" start >/dev/null 2>&1 ||
                rc-service "$service_name" status >/dev/null 2>&1 || return 1
            vnstat_daemon_is_running
            return $?
        done
    elif command_exists service; then
        for service_name in vnstat vnstatd; do
            [ -x "/etc/init.d/$service_name" ] || continue
            run_privileged service "$service_name" start >/dev/null 2>&1 ||
                service "$service_name" status >/dev/null 2>&1 || return 1
            vnstat_daemon_is_running
            return $?
        done
    fi
    return 1
}

start_vnstat_daemon_temporarily() {
    local service_name

    VNSTAT_TRANSACTION_SERVICE_MANAGER=""
    VNSTAT_TRANSACTION_SERVICE_NAME=""
    if command_exists systemctl && [ -d /run/systemd/system ]; then
        for service_name in vnstat vnstatd; do
            if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null |
                grep -q "^${service_name}\.service"; then
                VNSTAT_TRANSACTION_SERVICE_MANAGER=systemd
                VNSTAT_TRANSACTION_SERVICE_NAME="$service_name"
                run_privileged systemctl start "${service_name}.service" >/dev/null 2>&1 || return 1
                systemctl is-active --quiet "${service_name}.service" 2>/dev/null || return 1
                vnstat_daemon_is_running || return 1
                return 0
            fi
        done
    elif command_exists rc-service; then
        for service_name in vnstat vnstatd; do
            [ -x "/etc/init.d/$service_name" ] || continue
            VNSTAT_TRANSACTION_SERVICE_MANAGER=openrc
            VNSTAT_TRANSACTION_SERVICE_NAME="$service_name"
            run_privileged rc-service "$service_name" start >/dev/null 2>&1 ||
                rc-service "$service_name" status >/dev/null 2>&1 || return 1
            vnstat_daemon_is_running || return 1
            return 0
        done
    elif command_exists service; then
        for service_name in vnstat vnstatd; do
            [ -x "/etc/init.d/$service_name" ] || continue
            VNSTAT_TRANSACTION_SERVICE_MANAGER=sysv
            VNSTAT_TRANSACTION_SERVICE_NAME="$service_name"
            run_privileged service "$service_name" start >/dev/null 2>&1 ||
                service "$service_name" status >/dev/null 2>&1 || return 1
            vnstat_daemon_is_running || return 1
            return 0
        done
    fi
    return 1
}

stop_transaction_vnstat_daemon() {
    local stop_status=0

    case "$VNSTAT_TRANSACTION_SERVICE_MANAGER" in
        systemd)
            run_privileged systemctl stop "${VNSTAT_TRANSACTION_SERVICE_NAME}.service" >/dev/null 2>&1 || stop_status=$?
            ;;
        openrc)
            run_privileged rc-service "$VNSTAT_TRANSACTION_SERVICE_NAME" stop >/dev/null 2>&1 || stop_status=$?
            ;;
        sysv)
            run_privileged service "$VNSTAT_TRANSACTION_SERVICE_NAME" stop >/dev/null 2>&1 || stop_status=$?
            ;;
        "") return 0 ;;
        *) return 1 ;;
    esac
    vnstat_daemon_is_running && return 1
    [ "$stop_status" -eq 0 ] || return 1
}

enable_transaction_vnstat_daemon() {
    case "$VNSTAT_TRANSACTION_SERVICE_MANAGER" in
        systemd)
            run_privileged systemctl enable "${VNSTAT_TRANSACTION_SERVICE_NAME}.service" >/dev/null 2>&1
            ;;
        openrc)
            command_exists rc-update || return 1
            run_privileged rc-update add "$VNSTAT_TRANSACTION_SERVICE_NAME" default >/dev/null 2>&1
            ;;
        sysv) return 0 ;;
        "") return 0 ;;
        *) return 1 ;;
    esac
}

ensure_vnstat_daemon_running() {
    vnstat_daemon_is_running && return 0
    if [ "${VNSTAT_CONFIG_TRANSACTION_ACTIVE:-false}" = "true" ]; then
        start_vnstat_daemon_temporarily
        return $?
    fi
    start_vnstat_daemon_strict
}

reload_vnstat_daemon() {
    local pids pid
    pids=$(vnstat_daemon_pids)
    if [ -n "$pids" ]; then
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            kill -HUP "$pid" 2>/dev/null || return 1
        done <<< "$pids"
        vnstat_daemon_is_running
        return $?
    fi
    start_vnstat_daemon_strict
}

ensure_vnstat_interface() {
    local interface="$1"
    if vnstat_cmd -i "$interface" --json >/dev/null 2>&1; then
        return 0
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') vnStat 尚未监控接口 $interface，正在添加。" | tee -a "$LOG_FILE"
    if ! vnstat_cmd --add -i "$interface" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法将接口 $interface 添加到 vnStat 数据库。" | tee -a "$LOG_FILE"
        return 1
    fi
    if [ "${VNSTAT_CONFIG_TRANSACTION_ACTIVE:-false}" = "true" ] &&
       [ "$interface" = "${VNSTAT_TRANSACTION_INTERFACE:-}" ]; then
        VNSTAT_TRANSACTION_INTERFACE_ADDED=true
    fi
    if ! ensure_vnstat_daemon_running || ! reload_vnstat_daemon; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法启动或重载 vnStat 服务。" | tee -a "$LOG_FILE"
        return 1
    fi
}

vnstat_max_bandwidth_valid() {
    local value="${1:-}"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    [ "${#value}" -le 5 ] || return 1
    value=$((10#$value))
    [ "$value" -le 50000 ]
}

prompt_vnstat_max_bandwidth() {
    local current="${VNSTAT_MAX_BANDWIDTH:-0}"
    local answer

    if ! vnstat_max_bandwidth_valid "$current"; then
        current=0
    else
        current=$((10#$current))
    fi

    while true; do
        read -r -p "请输入 vnStat 异常速率检查上限 (Mbit/s；0=关闭检查，默认0；直接回车保留当前值 $current): " answer || return 1
        answer=${answer:-$current}
        if vnstat_max_bandwidth_valid "$answer"; then
            VNSTAT_MAX_BANDWIDTH=$((10#$answer))
            return 0
        fi
        echo "输入无效，请输入 0-50000 的整数；0 表示关闭检查。"
    done
}

build_vnstat_config_candidate() {
    local source_path="$1"
    local candidate_path="$2"
    local interface="$3"
    local legacy_mode="$4"
    local update_interval_value="${5:-}"
    local daily_days_value="${6:-}"
    local max_key="MaxBW${interface}"

    awk -v max_key="$max_key" -v max_bw="$VNSTAT_MAX_BANDWIDTH" \
        -v save_interval="$VNSTAT_SAVE_INTERVAL" -v legacy="$legacy_mode" \
        -v update_value="$update_interval_value" -v daily_value="$daily_days_value" '
        function config_key(line,    text, parts, first, is_comment) {
            text=line
            sub(/^[[:space:]]*/, "", text)
            first=substr(text, 1, 1)
            is_comment=(first == ";" || first == "#")
            if (is_comment) {
                text=substr(text, 2)
                sub(/^[[:space:]]*/, "", text)
            }
            split(text, parts, /[[:space:]]+/)
            parsed_value=parts[2]
            parsed_comment=is_comment
            return parts[1]
        }
        function replaceable(key, target) {
            return key == target && (!parsed_comment || parsed_value ~ /^-?[0-9]+$/)
        }
        {
            key=config_key($0)
            if (replaceable(key, "SaveInterval")) {
                if (!seen_save) print "SaveInterval " save_interval
                seen_save=1
                next
            }
            if (legacy == "true" && replaceable(key, "BandwidthDetection")) {
                if (!seen_detection) print "BandwidthDetection 0"
                seen_detection=1
                next
            }
            if (legacy == "true" && replaceable(key, "MaxBandwidth")) {
                if (!seen_global_max) print "MaxBandwidth " max_bw
                seen_global_max=1
                next
            }
            if (replaceable(key, max_key)) {
                if (!seen_max) print max_key " " max_bw
                seen_max=1
                next
            }
            if (update_value != "" && replaceable(key, "UpdateInterval")) {
                if (!seen_update) print "UpdateInterval " update_value
                seen_update=1
                next
            }
            if (daily_value != "" && replaceable(key, "DailyDays")) {
                if (!seen_daily) print "DailyDays " daily_value
                seen_daily=1
                next
            }
            print
        }
        END {
            if (!seen_save) print "SaveInterval " save_interval
            if (legacy == "true") {
                if (!seen_detection) print "BandwidthDetection 0"
                if (!seen_global_max) print "MaxBandwidth " max_bw
            }
            if (!seen_max) print max_key " " max_bw
            if (update_value != "" && !seen_update) print "UpdateInterval " update_value
            if (daily_value != "" && !seen_daily) print "DailyDays " daily_value
        }
    ' "$source_path" > "$candidate_path"
}

vnstat_config_candidate_valid() {
    local candidate_path="$1"
    local interface="$2"
    local legacy_mode="$3"
    local update_interval_value="${4:-}"
    local daily_days_value="${5:-}"
    local value max_key="MaxBW${interface}"

    vnstat --config "$candidate_path" --showconfig >/dev/null 2>&1 || return 1
    value=$(vnstat_config_value_from_file "$candidate_path" "SaveInterval")
    [ "$value" = "$VNSTAT_SAVE_INTERVAL" ] || return 1
    if [ "$legacy_mode" = "true" ]; then
        [ "$(vnstat_config_value_from_file "$candidate_path" "BandwidthDetection")" = "0" ] || return 1
        [ "$(vnstat_config_value_from_file "$candidate_path" "MaxBandwidth")" = "$VNSTAT_MAX_BANDWIDTH" ] || return 1
    fi
    [ "$(vnstat_config_value_from_file "$candidate_path" "$max_key")" = "$VNSTAT_MAX_BANDWIDTH" ] || return 1
    value=$(vnstat_config_value_from_file "$candidate_path" "UpdateInterval")
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -le 60 ] || return 1
    if [ -n "$update_interval_value" ]; then
        [ "$value" = "$update_interval_value" ] || return 1
    fi
    if [ -n "$daily_days_value" ]; then
        [ "$(vnstat_config_value_from_file "$candidate_path" "DailyDays")" = "$daily_days_value" ] || return 1
    fi
}

rollback_vnstat_config_update() {
    local config_path="$1"
    local rollback_path="$2"
    local marker_backup="$3"
    local had_marker="$4"
    local rollback_failed=false

    if [ -f "$rollback_path" ]; then
        mv -f "$rollback_path" "$config_path" || rollback_failed=true
    else
        rollback_failed=true
    fi
    if [ -n "$marker_backup" ]; then
        if [ "$had_marker" = "true" ]; then
            mv -f "$marker_backup" "$RETENTION_STATE_FILE" || rollback_failed=true
        else
            rm -f "$RETENTION_STATE_FILE" || rollback_failed=true
        fi
    fi
    reload_vnstat_daemon || rollback_failed=true
    ! $rollback_failed
}

select_vnstat_backup_path() {
    local config_path canonical_path base_path candidate source_path index=0

    config_path="$1"
    canonical_path=$(canonical_config_path "$config_path") || return 1
    base_path="$WORK_DIR/vnstat.conf.before-trafficcop-lite"

    while [ "$index" -le 100 ]; do
        if [ "$index" -eq 0 ]; then
            candidate="$base_path"
        else
            candidate="${base_path}.${index}"
        fi
        source_path="${candidate}.source-path"

        [ ! -L "$candidate" ] && [ ! -L "$source_path" ] || return 1
        if [ -e "$candidate" ]; then
            [ -f "$candidate" ] || return 1
            if [ -f "$source_path" ] &&
               [ "$(cat "$source_path" 2>/dev/null)" = "$canonical_path" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
            index=$((index + 1))
            continue
        fi
        [ ! -e "$source_path" ] || return 1
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

apply_vnstat_config_update() {
    local config_path
    local interface="$2"
    local legacy_mode="$3"
    local update_interval_value="${4:-}"
    local daily_days_value="${5:-}"
    local update_marker="${6:-false}"
    local candidate_path rollback_path marker_tmp="" marker_backup="" had_marker=false
    local backup_path backup_source_path backup_tmp="" backup_source_tmp=""
    local mode owner group

    config_path=$(canonical_config_path "$1") || return 1

    candidate_path="${config_path}.trafficcop-lite.$$"
    rollback_path="${config_path}.trafficcop-lite.rollback.$$"
    cp -p "$config_path" "$rollback_path" || return 1
    build_vnstat_config_candidate "$rollback_path" "$candidate_path" "$interface" \
        "$legacy_mode" "$update_interval_value" "$daily_days_value" || {
        rm -f "$candidate_path" "$rollback_path"
        return 1
    }
    if ! vnstat_config_candidate_valid "$candidate_path" "$interface" "$legacy_mode" \
        "$update_interval_value" "$daily_days_value"; then
        rm -f "$candidate_path" "$rollback_path"
        return 1
    fi
    if cmp -s "$candidate_path" "$rollback_path"; then
        rm -f "$candidate_path" "$rollback_path"
        ensure_vnstat_daemon_running
        return $?
    fi

    backup_path=$(select_vnstat_backup_path "$config_path") || {
        rm -f "$candidate_path" "$rollback_path"
        return 1
    }
    backup_source_path="${backup_path}.source-path"
    if [ ! -f "$backup_path" ]; then
        backup_tmp="${backup_path}.tmp.$$"
        backup_source_tmp="${backup_source_path}.tmp.$$"
        cp -p "$rollback_path" "$backup_tmp" || {
            rm -f "$candidate_path" "$rollback_path" "$backup_tmp" "$backup_source_tmp"
            return 1
        }
        chmod 600 "$backup_tmp" || {
            rm -f "$candidate_path" "$rollback_path" "$backup_tmp" "$backup_source_tmp"
            return 1
        }
        printf '%s\n' "$config_path" > "$backup_source_tmp" || {
            rm -f "$candidate_path" "$rollback_path" "$backup_tmp" "$backup_source_tmp"
            return 1
        }
        chmod 600 "$backup_source_tmp" || {
            rm -f "$candidate_path" "$rollback_path" "$backup_tmp" "$backup_source_tmp"
            return 1
        }
        mv -f "$backup_tmp" "$backup_path" || {
            rm -f "$candidate_path" "$rollback_path" "$backup_tmp" "$backup_source_tmp"
            return 1
        }
        if ! mv -f "$backup_source_tmp" "$backup_source_path"; then
            rm -f "$backup_path" "$candidate_path" "$rollback_path" \
                "$backup_tmp" "$backup_source_tmp"
            return 1
        fi
    fi
    mode=$(stat -c '%a' "$rollback_path") || { rm -f "$candidate_path" "$rollback_path"; return 1; }
    owner=$(stat -c '%u' "$rollback_path") || { rm -f "$candidate_path" "$rollback_path"; return 1; }
    group=$(stat -c '%g' "$rollback_path") || { rm -f "$candidate_path" "$rollback_path"; return 1; }
    chmod "$mode" "$candidate_path" || { rm -f "$candidate_path" "$rollback_path"; return 1; }
    chown "$owner:$group" "$candidate_path" || { rm -f "$candidate_path" "$rollback_path"; return 1; }

    if [ "$update_marker" = "true" ]; then
        marker_tmp="${RETENTION_STATE_FILE}.tmp.$$"
        marker_backup="${RETENTION_STATE_FILE}.before-update.$$"
        date +%Y-%m-%d > "$marker_tmp" || {
            rm -f "$candidate_path" "$rollback_path" "$marker_tmp"
            return 1
        }
        chmod 600 "$marker_tmp" || { rm -f "$candidate_path" "$rollback_path" "$marker_tmp"; return 1; }
        if [ -f "$RETENTION_STATE_FILE" ]; then
            cp -p "$RETENTION_STATE_FILE" "$marker_backup" || {
                rm -f "$candidate_path" "$rollback_path" "$marker_tmp"
                return 1
            }
            had_marker=true
        fi
    fi

    if ! cmp -s "$config_path" "$rollback_path" || ! mv -f "$candidate_path" "$config_path"; then
        rm -f "$candidate_path" "$rollback_path" "$marker_tmp" "$marker_backup"
        return 1
    fi
    if ! reload_vnstat_daemon ||
       ! vnstat_config_candidate_valid "$config_path" "$interface" "$legacy_mode" \
            "$update_interval_value" "$daily_days_value"; then
        rm -f "$marker_tmp"
        if ! rollback_vnstat_config_update "$config_path" "$rollback_path" "$marker_backup" "$had_marker"; then
            echo "vnStat 新配置未生效，且自动回滚未完全成功；请立即检查 $config_path。" >&2
        fi
        return 1
    fi
    if [ "$update_marker" = "true" ] && ! mv -f "$marker_tmp" "$RETENTION_STATE_FILE"; then
        if ! rollback_vnstat_config_update "$config_path" "$rollback_path" "$marker_backup" "$had_marker"; then
            echo "vnStat 保留期标记写入失败，且自动回滚未完全成功；请立即检查。" >&2
        fi
        rm -f "$marker_tmp"
        return 1
    fi

    rm -f "$rollback_path" "$marker_backup"
    if [ "$legacy_mode" = "true" ]; then
        echo "vnStat 2.0-2.8 兼容模式：已关闭自动带宽检测，并同步设置全局 MaxBandwidth。"
    fi
    if [ "$VNSTAT_MAX_BANDWIDTH" -eq 0 ]; then
        echo "vnStat 已设置 SaveInterval=${VNSTAT_SAVE_INTERVAL}，异常速率检查已关闭（MaxBW=0）。"
    else
        echo "vnStat 已设置 SaveInterval=${VNSTAT_SAVE_INTERVAL}，异常速率检查上限=${VNSTAT_MAX_BANDWIDTH} Mbit/s。"
    fi
}

ensure_vnstat_runtime_config() {
    local interface="$1"
    local daily_days_value="${2:-}"
    local update_marker="${3:-false}"
    local version_parts major minor legacy_mode=false current_update update_interval_value=""

    [[ "$interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    vnstat_max_bandwidth_valid "$VNSTAT_MAX_BANDWIDTH" || {
        echo "vnStat 异常速率检查上限无效，必须是 0-50000 的整数。" >&2
        return 1
    }
    VNSTAT_MAX_BANDWIDTH=$((10#$VNSTAT_MAX_BANDWIDTH))
    # 先启动服务，再从实际 vnstatd 进程参数解析配置路径；这样即使服务通过
    # --config 使用自定义文件且调用前处于停止状态，也不会误改 CLI 默认配置。
    ensure_vnstat_daemon_running || return 1
    resolve_vnstat_config_path || {
        echo "无法确认 vnStat 守护进程实际使用的配置文件，拒绝修改猜测路径。" >&2
        return 1
    }
    align_timezone_with_vnstat
    version_parts=$(vnstat_version_parts) || return 1
    read -r major minor <<< "$version_parts"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    [ "$major" -ge 2 ] || return 1
    if [ "$major" -eq 2 ] && [ "$minor" -lt 9 ]; then
        legacy_mode=true
    fi
    current_update=$(vnstat_config_value "UpdateInterval")
    [[ "$current_update" =~ ^[0-9]+$ ]] || return 1
    if [ "$current_update" -gt 60 ]; then
        update_interval_value=60
    fi
    apply_vnstat_config_update "$VNSTAT_CONFIG_PATH" "$interface" "$legacy_mode" \
        "$update_interval_value" "$daily_days_value" "$update_marker"
}

ensure_vnstat_daily_retention() {
    local required_days current_days period_word
    case "$TRAFFIC_PERIOD" in
        monthly) required_days=40 period_word="每月" ;;
        quarterly) required_days=100 period_word="每季度" ;;
        yearly) required_days=400 period_word="每年" ;;
    esac
    current_days=$(vnstat_config_value "DailyDays")
    if [ "$current_days" = "-1" ] || { [[ "$current_days" =~ ^[0-9]+$ ]] && [ "$current_days" -ge "$required_days" ]; }; then
        return 0
    fi

    if [ "${CONFIG_ASSUME_YES:-false}" != "true" ]; then
        printf '\n'
        ui_note "vnStat 目前只保留 ${current_days:-未知} 天的日数据，${period_word}重置的周期至少需要 $required_days 天。"
        # 读到 EOF 与回答 n 一样取消（1.2.x 读到 EOF 会按“是”继续修改 vnStat）。
        if ! ui_confirm "由 NTC 把 vnStat 日数据保留期调整为 $required_days 天？" y; then
            echo "未调整 vnStat 日数据保留期，已取消本次配置；原监控配置不会被覆盖。"
            return 1
        fi
    fi

    ensure_vnstat_runtime_config "$MAIN_INTERFACE" "$required_days" true || return 1
    ui_ok "vnStat 日数据保留期已调整为 $required_days 天（原配置备份在 $WORK_DIR 下）。"
}

restore_file_snapshot() {
    local backup_path="$1"
    local had_file="$2"
    local target_path="$3"
    local restore_tmp="${target_path}.restore.$$"

    if [ "$had_file" = "true" ]; then
        [ -f "$backup_path" ] || return 1
        cp -p "$backup_path" "$restore_tmp" || { rm -f "$restore_tmp"; return 1; }
        mv -f "$restore_tmp" "$target_path" || { rm -f "$restore_tmp"; return 1; }
    else
        rm -f "$target_path" || return 1
    fi
}

cleanup_initial_vnstat_transaction_files() {
    [ -n "${VNSTAT_TRANSACTION_DIR:-}" ] || return 0
    rm -f "$VNSTAT_TRANSACTION_DIR/vnstat.conf" \
        "$VNSTAT_TRANSACTION_DIR/retention-state" \
        "$VNSTAT_TRANSACTION_DIR/config-path-file" 2>/dev/null || true
    rmdir "$VNSTAT_TRANSACTION_DIR" 2>/dev/null || true
    VNSTAT_TRANSACTION_DIR=""
}

rollback_initial_vnstat_transaction() {
    local rollback_failed=false

    [ "${VNSTAT_CONFIG_TRANSACTION_ACTIVE:-false}" = "true" ] || return 0
    if [ "${VNSTAT_TRANSACTION_INTERFACE_ADDED:-false}" = "true" ]; then
        if ! vnstat_cmd --remove -i "$VNSTAT_TRANSACTION_INTERFACE" >/dev/null 2>&1; then
            rollback_failed=true
        fi
    fi
    if [ -n "${VNSTAT_TRANSACTION_CONFIG_PATH:-}" ] &&
       ! restore_file_snapshot "$VNSTAT_TRANSACTION_DIR/vnstat.conf" true "$VNSTAT_TRANSACTION_CONFIG_PATH"; then
        rollback_failed=true
    fi
    if ! restore_file_snapshot "$VNSTAT_TRANSACTION_DIR/retention-state" \
        "$VNSTAT_TRANSACTION_HAD_RETENTION" "$RETENTION_STATE_FILE"; then
        rollback_failed=true
    fi

    if [ "${VNSTAT_TRANSACTION_DAEMON_WAS_RUNNING:-false}" = "true" ]; then
        reload_vnstat_daemon || rollback_failed=true
    else
        stop_transaction_vnstat_daemon || rollback_failed=true
    fi
    if ! restore_file_snapshot "$VNSTAT_TRANSACTION_DIR/config-path-file" \
        "$VNSTAT_TRANSACTION_HAD_CONFIG_PATH_FILE" "$VNSTAT_CONFIG_PATH_FILE"; then
        rollback_failed=true
    fi

    if [ "$VNSTAT_TRANSACTION_HAD_CONFIG_PATH_FILE" = "true" ]; then
        VNSTAT_CONFIG_PATH=$(cat "$VNSTAT_CONFIG_PATH_FILE" 2>/dev/null || true)
    else
        unset VNSTAT_CONFIG_PATH
    fi
    VNSTAT_CONFIG_TRANSACTION_ACTIVE=false
    VNSTAT_TRANSACTION_INTERFACE_ADDED=false
    if $rollback_failed; then
        echo "vnStat 配置事务未能完整回滚；证据保留在 $VNSTAT_TRANSACTION_DIR。" >&2
        return 1
    fi
    cleanup_initial_vnstat_transaction_files
}

begin_initial_vnstat_transaction() {
    local interface="$1"

    [ "${VNSTAT_CONFIG_TRANSACTION_ACTIVE:-false}" != "true" ] || return 1
    VNSTAT_TRANSACTION_DIR=$(mktemp -d "$WORK_DIR/.initial-config-transaction.XXXXXX") || return 1
    chmod 700 "$VNSTAT_TRANSACTION_DIR" 2>/dev/null || true
    VNSTAT_TRANSACTION_INTERFACE="$interface"
    VNSTAT_TRANSACTION_CONFIG_PATH=""
    VNSTAT_TRANSACTION_INTERFACE_ADDED=false
    VNSTAT_TRANSACTION_DAEMON_WAS_RUNNING=false
    VNSTAT_TRANSACTION_SERVICE_MANAGER=""
    VNSTAT_TRANSACTION_SERVICE_NAME=""
    VNSTAT_TRANSACTION_HAD_RETENTION=false
    VNSTAT_TRANSACTION_HAD_CONFIG_PATH_FILE=false

    if vnstat_daemon_is_running; then
        VNSTAT_TRANSACTION_DAEMON_WAS_RUNNING=true
    fi
    if [ -f "$RETENTION_STATE_FILE" ]; then
        cp -p "$RETENTION_STATE_FILE" "$VNSTAT_TRANSACTION_DIR/retention-state" || {
            cleanup_initial_vnstat_transaction_files
            return 1
        }
        VNSTAT_TRANSACTION_HAD_RETENTION=true
    fi
    if [ -f "$VNSTAT_CONFIG_PATH_FILE" ]; then
        cp -p "$VNSTAT_CONFIG_PATH_FILE" "$VNSTAT_TRANSACTION_DIR/config-path-file" || {
            cleanup_initial_vnstat_transaction_files
            return 1
        }
        VNSTAT_TRANSACTION_HAD_CONFIG_PATH_FILE=true
    fi

    VNSTAT_CONFIG_TRANSACTION_ACTIVE=true
    if ! ensure_vnstat_daemon_running || ! resolve_vnstat_config_path; then
        rollback_initial_vnstat_transaction ||
            echo "vnStat 初始化失败，且临时服务或路径状态未能完整回滚。" >&2
        return 1
    fi
    VNSTAT_TRANSACTION_CONFIG_PATH="$VNSTAT_CONFIG_PATH"
    if ! cp -p "$VNSTAT_TRANSACTION_CONFIG_PATH" "$VNSTAT_TRANSACTION_DIR/vnstat.conf"; then
        rollback_initial_vnstat_transaction ||
            echo "无法建立 vnStat 配置快照，且临时运行态未能完整回滚。" >&2
        return 1
    fi
}

commit_initial_vnstat_transaction() {
    [ "${VNSTAT_CONFIG_TRANSACTION_ACTIVE:-false}" = "true" ] || return 0
    if [ "${VNSTAT_TRANSACTION_DAEMON_WAS_RUNNING:-false}" != "true" ]; then
        vnstat_daemon_is_running || return 1
        # 这是事务最后一个可能失败的外部动作；成功后不再执行需要补偿的检查。
        enable_transaction_vnstat_daemon || return 1
    fi
    VNSTAT_CONFIG_TRANSACTION_ACTIVE=false
    VNSTAT_TRANSACTION_INTERFACE_ADDED=false
    cleanup_initial_vnstat_transaction_files
}

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 需要 root 权限或 sudo 才能安装依赖。" | tee -a "$LOG_FILE"
        return 1
    fi
}

add_package_once() {
    local package="$1"
    local existing
    for existing in "${packages_to_install[@]}"; do
        if [ "$existing" = "$package" ]; then
            return
        fi
    done
    packages_to_install+=("$package")
}

add_package_for_command() {
    local missing_command="$1"

    case "$PACKAGE_MANAGER:$missing_command" in
        *:@ca-certificates) add_package_once "ca-certificates" ;;
        apt:ip|apt:tc) add_package_once "iproute2" ;;
        apt:crontab) add_package_once "cron" ;;
        apt:flock) add_package_once "util-linux" ;;
        apt:tac) add_package_once "coreutils" ;;
        apt:pgrep|apt:pkill) add_package_once "procps" ;;
        apt:awk) add_package_once "mawk" ;;
        dnf:ip|dnf:tc|yum:ip|yum:tc) add_package_once "iproute" ;;
        dnf:crontab|yum:crontab) add_package_once "cronie" ;;
        dnf:flock|yum:flock) add_package_once "util-linux" ;;
        dnf:tac|yum:tac) add_package_once "coreutils" ;;
        dnf:pgrep|dnf:pkill|yum:pgrep|yum:pkill) add_package_once "procps-ng" ;;
        dnf:awk|yum:awk) add_package_once "gawk" ;;
        apk:ip|apk:tc) add_package_once "iproute2" ;;
        apk:crontab) add_package_once "dcron" ;;
        apk:flock) add_package_once "util-linux-misc" ;;
        apk:tac) add_package_once "coreutils" ;;
        apk:pgrep|apk:pkill) add_package_once "procps" ;;
        apk:awk) add_package_once "gawk" ;;
        pacman:ip|pacman:tc) add_package_once "iproute2" ;;
        pacman:crontab) add_package_once "cronie" ;;
        pacman:flock) add_package_once "util-linux" ;;
        pacman:tac) add_package_once "coreutils" ;;
        pacman:pgrep|pacman:pkill) add_package_once "procps-ng" ;;
        pacman:awk) add_package_once "gawk" ;;
        *) add_package_once "$missing_command" ;;
    esac
}

required_command_available() {
    local command_name="$1"

    if [ "$command_name" = "tc" ]; then
        [ -n "${TC_BIN:-}" ]
    elif [ "$command_name" = '@ca-certificates' ]; then
        { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; } ||
            { [ -s /etc/ssl/cert.pem ] && [ -r /etc/ssl/cert.pem ]; }
    else
        command_exists "$command_name"
    fi
}

detect_package_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists yum; then
        echo "yum"
    elif command_exists apk; then
        echo "apk"
    elif command_exists pacman; then
        echo "pacman"
    else
        echo ""
    fi
}

install_packages() {
    case "$PACKAGE_MANAGER" in
        apt)
            # Use the same bounded APT transaction as the main script even when run standalone.
            dependency_install_missing true core
            ;;
        dnf)
            run_privileged dnf install -y "$@"
            ;;
        yum)
            run_privileged yum install -y "$@"
            ;;
        apk)
            run_privileged apk add --no-cache "$@"
            ;;
        pacman)
            run_privileged pacman -S --needed --noconfirm "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_service_running() {
    local display_name="$1"
    shift
    local service_name

    if command_exists systemctl; then
        for service_name in "$@"; do
            if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "^${service_name}\.service"; then
                if run_privileged systemctl enable --now "${service_name}.service" >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
    fi
    if command_exists rc-service; then
        for service_name in "$@"; do
            if [ -x "/etc/init.d/$service_name" ]; then
                if command_exists rc-update; then
                    run_privileged rc-update add "$service_name" default >/dev/null 2>&1 || true
                fi
                if run_privileged rc-service "$service_name" start >/dev/null 2>&1 || rc-service "$service_name" status >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
    fi
    if command_exists service; then
        for service_name in "$@"; do
            if [ -x "/etc/init.d/$service_name" ] && { run_privileged service "$service_name" start >/dev/null 2>&1 || service "$service_name" status >/dev/null 2>&1; }; then
                return 0
            fi
        done
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') 提示：无法自动确认 $display_name 服务状态，请确保对应服务正在运行。" | tee -a "$LOG_FILE"
    return 1
}




check_and_install_packages() {
    local required_commands=("vnstat" "jq" "bc" "ip" "tc" "crontab" "flock" "curl" "tac" "pgrep" "pkill" "grep" "sed" "awk" "@ca-certificates")
    local command_name
    local missing_commands=()
    local packages_to_install=()
    local PACKAGE_MANAGER
    local vnstat_version vnstat_major

    # 重新发现固定路径下的 tc，避免脚本启动后安装成功却继续使用旧的空值。
    TC_BIN="$(find_tc_bin)"
    for command_name in "${required_commands[@]}"; do
        if ! required_command_available "$command_name"; then
            missing_commands+=("$command_name")
        fi
    done

    # 2.0：依赖齐全时什么都不输出（1.x 每次打开都打印版本、网卡与 vnStat 起始日期）。
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        PACKAGE_MANAGER="$(detect_package_manager)"
        if [ -z "$PACKAGE_MANAGER" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 缺少命令：${missing_commands[*]}，且未识别到支持的包管理器，请手动安装。" | tee -a "$LOG_FILE"
            return 1
        fi

        for command_name in "${missing_commands[@]}"; do
            add_package_for_command "$command_name"
        done

        echo "$(date '+%Y-%m-%d %H:%M:%S') 缺少命令：${missing_commands[*]}，将使用 $PACKAGE_MANAGER 安装：${packages_to_install[*]}" | tee -a "$LOG_FILE"
        if ! install_packages "${packages_to_install[@]}"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 依赖安装失败，请检查网络连接、包管理器和系统状态。" | tee -a "$LOG_FILE"
            return 1
        fi

        TC_BIN="$(find_tc_bin)"
        for command_name in "${required_commands[@]}"; do
            if ! required_command_available "$command_name"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 安装后仍缺少命令：$command_name，请手动检查。" | tee -a "$LOG_FILE"
                return 1
            fi
        done
    fi

    if ! ensure_service_running "cron" cron crond dcron cronie; then
        return 1
    fi
    if ! ensure_vnstat_daemon_running; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：无法确认 vnStat 守护进程正在运行。" | tee -a "$LOG_FILE"
        return 1
    fi

    # 验证系统 tc 命令是否可用；独立版的 tc 快捷命令不会用于限速。
    if [ -z "$TC_BIN" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：'tc' 命令不可用，无法安全启用 TC 限速。" | tee -a "$LOG_FILE"
        return 1
    fi

    vnstat_version=$(vnstat --version 2>&1 | head -n 1)
    vnstat_major=$(printf '%s\n' "$vnstat_version" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p')
    if ! [[ "$vnstat_major" =~ ^[0-9]+$ ]] || [ "$vnstat_major" -lt 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：需要 vnStat 2.x 或更高版本（当前：${vnstat_version:-未知}）。" | tee -a "$LOG_FILE"
        return 1
    fi
}


is_decimal() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

compare_decimal() {
    awk -v left="$1" -v right="$2" -v op="$3" 'BEGIN {
        if (op == "gt") exit !(left > right)
        if (op == "ge") exit !(left >= right)
        if (op == "lt") exit !(left < right)
        exit 1
    }'
}

validate_config() {
    local has_error=false

    case "${TRAFFIC_MODE:-}" in
        out|in|total|max) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_MODE 无效。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    case "${TRAFFIC_PERIOD:-}" in
        monthly|quarterly|yearly) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_PERIOD 无效。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    if ! is_decimal "${TRAFFIC_LIMIT:-}" || ! compare_decimal "$TRAFFIC_LIMIT" "0" "gt"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_LIMIT 必须大于 0。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    TRAFFIC_TOLERANCE="${TRAFFIC_TOLERANCE:-0}"
    if ! is_decimal "$TRAFFIC_TOLERANCE"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_TOLERANCE 必须是非负数字。" | tee -a "$LOG_FILE"
        has_error=true
    elif is_decimal "${TRAFFIC_LIMIT:-}" && compare_decimal "$TRAFFIC_TOLERANCE" "$TRAFFIC_LIMIT" "ge"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_TOLERANCE 必须小于 TRAFFIC_LIMIT。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    TRAFFIC_UNIT="${TRAFFIC_UNIT:-binary}"
    case "$TRAFFIC_UNIT" in
        decimal|binary) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_UNIT 无效。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    if [ "${PERIOD_START_DAY+x}" != "x" ]; then
        PERIOD_START_DAY=1
    elif [[ "$PERIOD_START_DAY" =~ ^(0?[1-9]|[12][0-9]|3[01])$ ]]; then
        PERIOD_START_DAY=$((10#$PERIOD_START_DAY))
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：PERIOD_START_DAY 必须是 1-31 的整数。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    PERIOD_START_MONTH="${PERIOD_START_MONTH:-1}"
    if ! [[ "$PERIOD_START_MONTH" =~ ^[0-9]+$ ]]; then
        PERIOD_START_MONTH=1
    fi
    PERIOD_START_MONTH=$((10#$PERIOD_START_MONTH))
    if [ "$PERIOD_START_MONTH" -lt 1 ] || [ "$PERIOD_START_MONTH" -gt 12 ]; then
        PERIOD_START_MONTH=1
    fi

    LIMIT_SPEED="${LIMIT_SPEED:-20}"
    if ! [[ "$LIMIT_SPEED" =~ ^[1-9][0-9]*$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：LIMIT_SPEED 必须是大于 0 的整数。" | tee -a "$LOG_FILE"
        has_error=true
    fi
    TC_BOOT_GRACE_MINUTES="${TC_BOOT_GRACE_MINUTES:-10}"
    # 前导零（如 08）按十进制解释；否则 $((08 * 60)) 会按八进制报错并中止整个脚本。
    if [[ "$TC_BOOT_GRACE_MINUTES" =~ ^[0-9]{1,4}$ ]] && [ $((10#$TC_BOOT_GRACE_MINUTES)) -le 1440 ]; then
        TC_BOOT_GRACE_MINUTES=$((10#$TC_BOOT_GRACE_MINUTES))
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TC_BOOT_GRACE_MINUTES 必须是 0-1440 的整数。" | tee -a "$LOG_FILE"
        has_error=true
    fi
    ALLOW_PARTIAL_HISTORY="${ALLOW_PARTIAL_HISTORY:-false}"
    case "$ALLOW_PARTIAL_HISTORY" in
        true|false) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：ALLOW_PARTIAL_HISTORY 必须是 true 或 false。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    DISABLED="${DISABLED:-false}"
    case "$DISABLED" in
        true|false) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：DISABLED 必须是 true 或 false。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    VNSTAT_MAX_BANDWIDTH="${VNSTAT_MAX_BANDWIDTH:-0}"
    if ! vnstat_max_bandwidth_valid "$VNSTAT_MAX_BANDWIDTH"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：VNSTAT_MAX_BANDWIDTH 必须是 0-50000 的整数，0 表示关闭检查。" | tee -a "$LOG_FILE"
        has_error=true
    else
        VNSTAT_MAX_BANDWIDTH=$((10#$VNSTAT_MAX_BANDWIDTH))
    fi

    if [ -z "${MAIN_INTERFACE:-}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：MAIN_INTERFACE 为空。" | tee -a "$LOG_FILE"
        has_error=true
    elif command_exists ip && ! ip link show "$MAIN_INTERFACE" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：网络接口不存在：$MAIN_INTERFACE" | tee -a "$LOG_FILE"
        has_error=true
    fi

    case "${LIMIT_MODE:-}" in
        tc|shutdown) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：LIMIT_MODE 无效。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    if [ "${LIMIT_MODE:-}" = "shutdown" ] && ! command_exists shutdown; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：关机模式需要系统 shutdown 命令。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    if $has_error; then
        return 1
    fi
    return 0
}

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        unset TRAFFIC_MODE TRAFFIC_PERIOD TRAFFIC_LIMIT TRAFFIC_TOLERANCE TRAFFIC_UNIT
        unset PERIOD_START_DAY PERIOD_START_MONTH LIMIT_SPEED MAIN_INTERFACE LIMIT_MODE
        unset ALLOW_PARTIAL_HISTORY TC_BOOT_GRACE_MINUTES VNSTAT_MAX_BANDWIDTH
        unset DISABLED DISABLED_TIME
        while IFS='=' read -r key value; do
            value=${value%$'\r'}
            case "$key" in
                TRAFFIC_MODE|TRAFFIC_PERIOD|TRAFFIC_LIMIT|TRAFFIC_TOLERANCE|TRAFFIC_UNIT|PERIOD_START_DAY|PERIOD_START_MONTH|LIMIT_SPEED|MAIN_INTERFACE|LIMIT_MODE|ALLOW_PARTIAL_HISTORY|TC_BOOT_GRACE_MINUTES|VNSTAT_MAX_BANDWIDTH|DISABLED|DISABLED_TIME)
                    printf -v "$key" '%s' "$value"
                    ;;
            esac
        done < "$CONFIG_FILE"
        validate_config
    else
        return 1
    fi
}

# 写入配置
write_config() {
    local tmp_file="${CONFIG_FILE}.tmp.$$"
    if ! cat > "$tmp_file" << EOF
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
TRAFFIC_TOLERANCE=$TRAFFIC_TOLERANCE
TRAFFIC_UNIT=${TRAFFIC_UNIT:-binary}
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
PERIOD_START_MONTH=${PERIOD_START_MONTH:-1}
LIMIT_SPEED=${LIMIT_SPEED:-20}
MAIN_INTERFACE=$MAIN_INTERFACE
LIMIT_MODE=$LIMIT_MODE
ALLOW_PARTIAL_HISTORY=${ALLOW_PARTIAL_HISTORY:-false}
TC_BOOT_GRACE_MINUTES=${TC_BOOT_GRACE_MINUTES:-10}
VNSTAT_MAX_BANDWIDTH=${VNSTAT_MAX_BANDWIDTH:-0}
EOF
    then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$CONFIG_FILE" || { rm -f "$tmp_file"; return 1; }
}

restore_monitor_config_snapshot() {
    local config_backup="$1"
    local had_config="$2"
    local enforcement_backup="$3"
    local had_enforcement="$4"
    local tc_backup="${5:-}"
    local had_tc="${6:-false}"
    local shutdown_backup="${7:-}"
    local had_shutdown="${8:-false}"
    local restore_failed=false

    if ! restore_file_snapshot "$config_backup" "$had_config" "$CONFIG_FILE"; then
        restore_failed=true
    fi
    if ! restore_file_snapshot "$enforcement_backup" "$had_enforcement" "$ENFORCEMENT_STATE_FILE"; then
        restore_failed=true
    fi
    if [ -n "$tc_backup" ] &&
       ! restore_file_snapshot "$tc_backup" "$had_tc" "$TC_STATE_FILE"; then
        restore_failed=true
    fi
    if [ -n "$shutdown_backup" ] &&
       ! restore_file_snapshot "$shutdown_backup" "$had_shutdown" "$SHUTDOWN_STATE_FILE"; then
        restore_failed=true
    fi

    if $restore_failed; then
        return 1
    fi
    return 0
}

CONFIG_SNAPSHOT_HAD_CONFIG=false
CONFIG_SNAPSHOT_HAD_ENFORCEMENT=false
CONFIG_SNAPSHOT_HAD_TC=false
CONFIG_SNAPSHOT_HAD_SHUTDOWN=false
CONFIG_SNAPSHOT_OLD_TC_ACTIVE=false
CONFIG_SNAPSHOT_OLD_TC_INTERFACE=""
CONFIG_SNAPSHOT_OLD_TC_SPEED=""
CONFIG_SNAPSHOT_OLD_SHUTDOWN_PENDING=false

snapshot_monitor_config_state() {
    local config_backup="$1"
    local enforcement_backup="$2"
    local tc_backup="$3"
    local shutdown_backup="$4"
    local saved_interface state_interface state_boot current_boot runtime_status

    CONFIG_SNAPSHOT_HAD_CONFIG=false
    CONFIG_SNAPSHOT_HAD_ENFORCEMENT=false
    CONFIG_SNAPSHOT_HAD_TC=false
    CONFIG_SNAPSHOT_HAD_SHUTDOWN=false
    CONFIG_SNAPSHOT_OLD_TC_ACTIVE=false
    CONFIG_SNAPSHOT_OLD_TC_INTERFACE=""
    CONFIG_SNAPSHOT_OLD_TC_SPEED=""
    CONFIG_SNAPSHOT_OLD_SHUTDOWN_PENDING=false

    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$config_backup" || return 1
        chmod 600 "$config_backup" 2>/dev/null || true
        CONFIG_SNAPSHOT_HAD_CONFIG=true
    fi
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        cp -p "$ENFORCEMENT_STATE_FILE" "$enforcement_backup" || return 1
        chmod 600 "$enforcement_backup" 2>/dev/null || true
        CONFIG_SNAPSHOT_HAD_ENFORCEMENT=true
    fi
    if [ -f "$TC_STATE_FILE" ]; then
        cp -p "$TC_STATE_FILE" "$tc_backup" || return 1
        chmod 600 "$tc_backup" 2>/dev/null || true
        CONFIG_SNAPSHOT_HAD_TC=true
        state_interface=$(tc_state_interface)
        if [ -n "$state_interface" ]; then
            saved_interface="${MAIN_INTERFACE:-}"
            MAIN_INTERFACE="$state_interface"
            owned_tc_limit_active
            runtime_status=$?
            MAIN_INTERFACE="$saved_interface"
            case "$runtime_status" in
                0)
                    CONFIG_SNAPSHOT_OLD_TC_ACTIVE=true
                    CONFIG_SNAPSHOT_OLD_TC_INTERFACE="$state_interface"
                    CONFIG_SNAPSHOT_OLD_TC_SPEED=$(tc_state_value LIMIT_SPEED)
                    [[ "$CONFIG_SNAPSHOT_OLD_TC_SPEED" =~ ^[1-9][0-9]*$ ]] || return 1
                    ;;
                1) ;;
                *) return 1 ;;
            esac
        fi
    fi
    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        cp -p "$SHUTDOWN_STATE_FILE" "$shutdown_backup" || return 1
        chmod 600 "$shutdown_backup" 2>/dev/null || true
        CONFIG_SNAPSHOT_HAD_SHUTDOWN=true
        state_boot=$(shutdown_state_value BOOT_ID)
        current_boot=$(current_boot_id)
        if [ -n "$state_boot" ] && [ -n "$current_boot" ] && [ "$state_boot" = "$current_boot" ] &&
           has_pending_shutdown; then
            if pending_shutdown_matches_owned_state; then
                CONFIG_SNAPSHOT_OLD_SHUTDOWN_PENDING=true
            else
                return 1
            fi
        elif { [ -z "$state_boot" ] || [ -z "$current_boot" ]; } && has_pending_shutdown; then
            return 1
        fi
    fi
}

restore_owned_tc_after_config_failure() {
    local tc_backup="$1"
    local saved_interface="${MAIN_INTERFACE:-}"
    local runtime_status

    [ "${CONFIG_SNAPSHOT_OLD_TC_ACTIVE:-false}" = "true" ] || return 0
    MAIN_INTERFACE="$CONFIG_SNAPSHOT_OLD_TC_INTERFACE"
    owned_tc_limit_active
    runtime_status=$?
    if [ "$runtime_status" -eq 0 ]; then
        MAIN_INTERFACE="$saved_interface"
        return 0
    elif [ "$runtime_status" -eq 2 ]; then
        MAIN_INTERFACE="$saved_interface"
        return 1
    fi

    if ! rm -f "$TC_STATE_FILE" ||
       ! apply_tc_limit "$CONFIG_SNAPSHOT_OLD_TC_SPEED"; then
        restore_file_snapshot "$tc_backup" true "$TC_STATE_FILE" >/dev/null 2>&1 || true
        MAIN_INTERFACE="$saved_interface"
        return 1
    fi
    MAIN_INTERFACE="$saved_interface"
}

restore_owned_shutdown_after_config_failure() {
    local shutdown_backup="$1"
    local task_token

    [ "${CONFIG_SNAPSHOT_OLD_SHUTDOWN_PENDING:-false}" = "true" ] || return 0
    if has_pending_shutdown; then
        pending_shutdown_matches_owned_state
        return $?
    fi
    restore_file_snapshot "$shutdown_backup" true "$SHUTDOWN_STATE_FILE" || return 1
    task_token=$(shutdown_task_token_from_state) || return 1
    shutdown -h +1 "TrafficCop-Lite[$task_token] 配置回滚：恢复原计划关机" >/dev/null 2>&1 || true
    pending_shutdown_matches_owned_state
}

rollback_monitor_config_transaction() {
    local config_backup="$1"
    local enforcement_backup="$2"
    local tc_backup="$3"
    local shutdown_backup="$4"
    local rollback_failed=false

    if ! restore_monitor_config_snapshot "$config_backup" "$CONFIG_SNAPSHOT_HAD_CONFIG" \
        "$enforcement_backup" "$CONFIG_SNAPSHOT_HAD_ENFORCEMENT" \
        "$tc_backup" "$CONFIG_SNAPSHOT_HAD_TC" \
        "$shutdown_backup" "$CONFIG_SNAPSHOT_HAD_SHUTDOWN"; then
        rollback_failed=true
    fi
    if [ "${CONFIG_TC_CLEAR_ATTEMPTED:-false}" = "true" ] &&
       ! restore_owned_tc_after_config_failure "$tc_backup"; then
        rollback_failed=true
    fi
    if [ "${CONFIG_SHUTDOWN_CLEAR_ATTEMPTED:-false}" = "true" ] &&
       ! restore_owned_shutdown_after_config_failure "$shutdown_backup"; then
        rollback_failed=true
    fi
    if ! rollback_initial_vnstat_transaction; then
        rollback_failed=true
    fi
    if [ "$CONFIG_SNAPSHOT_HAD_CONFIG" = "true" ] && ! read_config >/dev/null 2>&1; then
        rollback_failed=true
    fi

    if $rollback_failed; then
        ntc_operation_log config-rollback failure
        return 1
    fi
    rm -f "$config_backup" "$enforcement_backup" "$tc_backup" "$shutdown_backup"
    ntc_operation_log config-rollback success
}


date_num_to_iso() {
    local date_num="$1"
    printf '%s-%s-%s\n' "${date_num:0:4}" "${date_num:4:2}" "${date_num:6:2}"
}

get_vnstat_available_start() {
    local vnstat_json created_num earliest_num available_num trafficless_entries

    vnstat_json=$(vnstat_cmd -i "$MAIN_INTERFACE" --json 2>/dev/null) || return 1
    vnstat_json=$(normalize_vnstat_json_for_interface "$vnstat_json" "$MAIN_INTERFACE") || return 1
    vnstat_data_is_fresh "$vnstat_json" || return 1
    created_num=$(printf '%s' "$vnstat_json" | jq -r \
        '.interfaces[0].created.date | (.year * 10000 + .month * 100 + .day)' 2>/dev/null) || return 1
    earliest_num=$(printf '%s' "$vnstat_json" | jq -r \
        '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day)] | min // 0' 2>/dev/null) || return 1
    [[ "$created_num" =~ ^[0-9]{8}$ ]] || return 1

    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    available_num="$created_num"
    if [ "$trafficless_entries" != "0" ] \
        && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -gt "$available_num" ]; then
        available_num="$earliest_num"
    fi
    date_num_to_iso "$available_num"
}

history_incomplete_for_current_period() {
    local period_start available_start retention_start trafficless_entries
    local period_num available_num retention_num

    period_start=$(get_period_start_date) || return 2
    available_start=$(get_vnstat_available_start) || return 2
    retention_start=$(cat "$RETENTION_STATE_FILE" 2>/dev/null || true)
    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    period_num=${period_start//-/}
    available_num=${available_start//-/}
    retention_num=${retention_start//-/}

    [ "$available_num" -gt "$period_num" ] && return 0
    if [ "$trafficless_entries" = "0" ] && [ -n "$retention_start" ] \
        && { ! [[ "$retention_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$period_num" ]; }; then
        return 0
    fi
    return 1
}

configure_history_policy() {
    local period_start available_start available_num retention_start retention_num trafficless_entries
    local history_status

    ALLOW_PARTIAL_HISTORY=false
    history_incomplete_for_current_period
    history_status=$?
    case "$history_status" in
        0) ;;
        1) return 0 ;;
        *)
            echo "无法可靠读取 vnStat 历史起点，已取消本次配置；请确认 vnStat 服务和接口数据正常。"
            return 1
            ;;
    esac

    period_start=$(get_period_start_date)
    available_start=$(get_vnstat_available_start 2>/dev/null || echo "未知")
    retention_start=$(cat "$RETENTION_STATE_FILE" 2>/dev/null || true)
    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    available_num=${available_start//-/}
    retention_num=${retention_start//-/}
    if [ "$trafficless_entries" = "0" ] && [[ "$retention_num" =~ ^[0-9]{8}$ ]] \
        && { ! [[ "$available_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$available_num" ]; }; then
        available_start="$retention_start"
    fi
    # ntc config set 不提问：由 --allow-partial-history（或原配置里已确认过）决定。
    case "${CONFIG_PARTIAL_HISTORY:-ask}" in
        allow)
            ui_warn "vnStat 历史约从 $available_start 开始，不足以覆盖周期起点 $period_start；本期已用量会偏低。"
            ALLOW_PARTIAL_HISTORY=true
            return 0
            ;;
        deny)
            ui_err "vnStat 历史约从 $available_start 开始，不足以覆盖周期起点 $period_start，未保存；如接受本期统计偏低，请加 --allow-partial-history。"
            return 1
            ;;
    esac
    printf '\n'
    ui_warn "vnStat 历史不足以覆盖周期起点 $period_start。"
    ui_note "现有流量历史约从 $available_start 开始，此前的流量无法补回；继续的话本期已用量会偏低，"
    ui_note "限制仍按这个偏低的数字执行。主菜单会一直提示，直到进入历史完整的新周期。"
    if ! ui_confirm "按现有 vnStat 历史继续？" n; then
        echo "已取消配置；原配置未被覆盖。"
        return 1
    fi
    ALLOW_PARTIAL_HISTORY=true
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

shutdown_state_value() {
    local key="$1"
    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        grep "^${key}=" "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

clear_owned_shutdown_schedule() {
    local state_boot current_boot

    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        state_boot=$(grep '^BOOT_ID=' "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [ -n "$state_boot" ] && [ -n "$current_boot" ] && [ "$state_boot" != "$current_boot" ]; then
            rm -f "$SHUTDOWN_STATE_FILE" || return 1
            echo "$(date '+%Y-%m-%d %H:%M:%S') 已清理上次开机遗留的关机状态；未触碰本次开机的计划关机。" | tee -a "$LOG_FILE"
            return 0
        fi
        if { [ -z "$state_boot" ] || [ -z "$current_boot" ]; } && has_pending_shutdown; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法确认计划关机是否属于本脚本，已保留系统任务和状态文件。" | tee -a "$LOG_FILE"
            return 1
        fi
        if has_pending_shutdown; then
            if ! pending_shutdown_matches_owned_state; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 当前计划关机无法与本脚本任务标识匹配，已保留系统任务和状态文件。" | tee -a "$LOG_FILE"
                return 1
            fi
            if ! shutdown -c 2>/dev/null || has_pending_shutdown; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 无法取消本脚本记录的计划关机，已保留状态文件。" | tee -a "$LOG_FILE"
                return 1
            fi
        fi
        rm -f "$SHUTDOWN_STATE_FILE" || return 1
    fi
}

configure_post_save_enforcement() {
    local current_usage limit_threshold unit_label policy_choice grace_minutes=10 until_epoch
    local comparison_status desired_mode="" desired_reason="" desired_message=""
    local enforcement_candidate="${ENFORCEMENT_STATE_FILE}.config-candidate.$$"

    CONFIG_TC_CLEAR_ATTEMPTED=false
    CONFIG_SHUTDOWN_CLEAR_ATTEMPTED=false
    rm -f "$enforcement_candidate"

    if ! current_usage=$(get_traffic_usage); then
        echo "无法可靠读取当前流量，已取消本次配置；原监控配置不会被覆盖。"
        return 1
    fi
    if ! is_decimal "$current_usage"; then
        echo "当前流量格式无效，已取消本次配置；现有执行策略保持不变。"
        return 1
    fi
    [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && unit_label="GB" || unit_label="GiB"
    if ! limit_threshold=$(printf '%s - %s\n' "$TRAFFIC_LIMIT" "$TRAFFIC_TOLERANCE" | bc 2>/dev/null); then
        echo "无法可靠计算当前执行阈值，已取消本次配置；现有执行策略保持不变。"
        return 1
    fi
    case "$limit_threshold" in .*) limit_threshold="0$limit_threshold" ;; esac
    if ! is_decimal "$limit_threshold"; then
        echo "当前执行阈值格式无效，已取消本次配置；现有执行策略保持不变。"
        return 1
    fi
    compare_decimal "$limit_threshold" "0" "gt"
    comparison_status=$?
    if [ "$comparison_status" -ne 0 ]; then
        echo "当前执行阈值必须大于 0，已取消本次配置；现有执行策略保持不变。"
        return 1
    fi
    compare_decimal "$current_usage" "$limit_threshold" "ge"
    comparison_status=$?
    case "$comparison_status" in
        0) ;;
        1) desired_mode="none" ;;
        *)
            echo "无法可靠比较当前流量与执行阈值，已取消本次配置；现有执行策略保持不变。"
            return 1
            ;;
    esac

    if [ "$desired_mode" != "none" ]; then
        # 2.0：向导在显示摘要前已经问过（或 ntc config set 用 --when-over 指定），这里直接沿用；
        # 没有预设时才当场询问。
        case "${CONFIG_EXCEED_POLICY:-}" in
            now) policy_choice=2 ;;
            monitor) policy_choice=3 ;;
            grace:*)
                policy_choice=1
                grace_minutes=$(ntc_int "${CONFIG_EXCEED_POLICY#grace:}" 1 1440) || grace_minutes=10
                ;;
            *)
                echo ""
                echo "当前可统计流量为 $current_usage $unit_label，已经达到执行阈值 $limit_threshold $unit_label。"
                echo "为避免保存配置后突然限速或关机，请选择本次执行策略："
                ui_option 1 "宽限一段时间后再执行" "推荐"
                ui_option 2 "立即执行"
                ui_option 3 "仅监控，暂停执行限制" "稍后在「限制执行」里恢复"
                ui_read_int policy_choice "请选择" 1 1 3 || return 1
                if [ "$policy_choice" = 1 ]; then
                    ui_read_int grace_minutes "宽限分钟数" 10 1 1440 || return 1
                fi
                ;;
        esac
        case "$policy_choice" in
            2) desired_mode="none" ;;
            3)
                desired_mode="paused"
                desired_reason="manual"
                until_epoch=0
                desired_message="限制执行已暂停；流量统计和主页显示仍会继续。"
                ;;
            *)
                desired_mode="grace"
                desired_reason="config"
                until_epoch=$(( $(date +%s) + grace_minutes * 60 ))
                desired_message="已设置 $grace_minutes 分钟宽限；期间只统计流量，不执行限制。"
                ;;
        esac
    fi

    if [ "$desired_mode" != "none" ] &&
       ! write_enforcement_state_file "$desired_mode" "$until_epoch" "$desired_reason" "$enforcement_candidate"; then
        rm -f "$enforcement_candidate"
        return 1
    fi

    # 先撤销 TC；若它失败，计划关机尚未触碰。后续任何失败由外层配置事务补偿旧运行态。
    CONFIG_TC_CLEAR_ATTEMPTED=true
    if ! clear_owned_tc_rules "配置已更新"; then
        rm -f "$enforcement_candidate"
        return 1
    fi
    CONFIG_SHUTDOWN_CLEAR_ATTEMPTED=true
    if ! clear_owned_shutdown_schedule; then
        rm -f "$enforcement_candidate"
        return 1
    fi
    if [ "$desired_mode" = "none" ]; then
        rm -f "$ENFORCEMENT_STATE_FILE" || return 1
    elif ! mv -f "$enforcement_candidate" "$ENFORCEMENT_STATE_FILE"; then
        rm -f "$enforcement_candidate"
        return 1
    fi
    # 1.1.10–1.2.0 这里是 `[ -n "$desired_message" ] && echo`：没有提示语（用量低于阈值、或选择立即执行）
    # 时返回 1，导致首次配置整体回滚。
    if [ -n "$desired_message" ]; then
        ui_ok "$desired_message"
    fi
    return 0
}

# 向导输入中途结束（Ctrl-D、stdin 已关闭）：回滚已开始的 vnStat 事务并放弃本次配置。
# 1.2.0 及更早版本在这里要么死循环（有的还每轮写日志），要么用默认值继续保存。
cancel_config_on_eof() {
    echo "" >&2
    echo "输入已结束，已取消本次配置；原有配置保持不变。" >&2
    if ! rollback_initial_vnstat_transaction; then
        echo "vnStat 状态未能完整恢复。" >&2
    fi
    return 1
}

# 配置向导（ntc config、主菜单「修改监控配置」）：先问完全部问题，再准备 vnStat、按新配置预览本期用量、
# 显示摘要，确认后才保存。任何一步读到输入结束（Ctrl-D）都取消，原配置与 vnStat 状态保持不变。
initial_config() {
    local preview_usage preview_threshold

    CONFIG_TC_CLEAR_ATTEMPTED=false
    CONFIG_SHUTDOWN_CLEAR_ATTEMPTED=false
    CONFIG_EXCEED_POLICY=""
    if ! config_wizard_collect; then
        cancel_config_on_eof
        return 1
    fi
    config_prepare_vnstat || return 1
    if ! preview_usage=$(get_traffic_usage 2>/dev/null) || ! is_decimal "$preview_usage"; then
        ui_err "无法按新配置读取本期流量（vnStat 数据暂不可用），已取消本次配置；原配置未改动。"
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        return 1
    fi
    preview_threshold=$(config_threshold)
    if compare_decimal "$preview_usage" "$preview_threshold" ge; then
        if ! config_ask_exceed_policy "$preview_usage" "$preview_threshold"; then
            cancel_config_on_eof
            return 1
        fi
    else
        # 预览时还没到阈值；万一保存前的几秒内越过阈值，也先宽限 10 分钟，不在保存过程中再提问。
        CONFIG_EXCEED_POLICY="grace:10"
    fi
    config_show_summary "$preview_usage" "$preview_threshold"
    if ! ui_confirm "保存？" y; then
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        ui_note "已取消，原配置未改动。"
        return 1
    fi
    config_commit || return 1
    ui_ok "配置已保存。"
}

# 返回指定年月的周期锚点。若用户配置了不存在的日期（如 2 月 31 日），使用当月最后一天。
is_leap_year() {
    local year="$1"
    if { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; } || [ $((year % 400)) -eq 0 ]; then
        return 0
    fi
    return 1
}

days_in_month() {
    local year="$1"
    local month=$((10#$2))

    case "$month" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if is_leap_year "$year"; then
                echo 29
            else
                echo 28
            fi
            ;;
    esac
}

get_anchor_date() {
    local year="$1"
    local month=$((10#$2))
    local day=$((10#$3))
    local max_day

    max_day=$(days_in_month "$year" "$month")
    if [ "$day" -gt "$max_day" ]; then
        day="$max_day"
    fi

    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
}

date_to_num() {
    echo "$1" | tr -d '-'
}

shift_month() {
    local year="$1"
    local month=$((10#$2))
    local offset="$3"
    local total=$((year * 12 + month - 1 + offset))
    local shifted_year=$((total / 12))
    local shifted_month=$((total % 12 + 1))

    printf "%04d %02d\n" "$shifted_year" "$shifted_month"
}

previous_day() {
    local date_value="$1"
    local year=${date_value%%-*}
    local rest=${date_value#*-}
    local month=${rest%%-*}
    local day=${date_value##*-}

    year=$((10#$year))
    month=$((10#$month))
    day=$((10#$day))

    if [ "$day" -gt 1 ]; then
        printf "%04d-%02d-%02d\n" "$year" "$month" "$((day - 1))"
    else
        local prev_year prev_month prev_day
        read -r prev_year prev_month <<< "$(shift_month "$year" "$month" -1)"
        prev_day=$(days_in_month "$prev_year" "$prev_month")
        printf "%04d-%02d-%02d\n" "$prev_year" "$((10#$prev_month))" "$prev_day"
    fi
}

# 获取当前周期的起始日期
get_period_start_date() {
    local current_date current_month current_year
    local anchor_this anchor_num current_num period_year period_month

    current_date=$(date +%Y-%m-%d)
    current_month=$(date +%m)
    current_year=$(date +%Y)

    current_num=$(date_to_num "$current_date")

    case $TRAFFIC_PERIOD in
        monthly)
            anchor_this=$(get_anchor_date "$current_year" "$current_month" "$PERIOD_START_DAY")
            anchor_num=$(date_to_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(shift_month "$current_year" "$current_month" -1)"
                get_anchor_date "$period_year" "$period_month" "$PERIOD_START_DAY"
            else
                echo "$anchor_this"
            fi
            ;;
        quarterly)
            local quarter_month=$(( ((10#$current_month - 1) / 3) * 3 + 1 ))
            anchor_this=$(get_anchor_date "$current_year" "$quarter_month" "$PERIOD_START_DAY")
            anchor_num=$(date_to_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(shift_month "$current_year" "$quarter_month" -3)"
                get_anchor_date "$period_year" "$period_month" "$PERIOD_START_DAY"
            else
                echo "$anchor_this"
            fi
            ;;
        yearly)
            local start_month_num=$((10#${PERIOD_START_MONTH:-1}))
            anchor_this=$(get_anchor_date "$current_year" "$start_month_num" "$PERIOD_START_DAY")
            anchor_num=$(date_to_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(shift_month "$current_year" "$start_month_num" -12)"
                get_anchor_date "$period_year" "$period_month" "$PERIOD_START_DAY"
            else
                echo "$anchor_this"
            fi
            ;;
    esac
}

# 获取周期结束日期
get_period_end_date() {
    local start_date start_year start_month next_year next_month next_anchor offset

    start_date=$(get_period_start_date)
    start_year=${start_date%%-*}
    start_month=${start_date#*-}
    start_month=${start_month%%-*}

    case $TRAFFIC_PERIOD in
        monthly) offset=1 ;;
        quarterly) offset=3 ;;
        yearly) offset=12 ;;
    esac

    read -r next_year next_month <<< "$(shift_month "$start_year" "$start_month" "$offset")"
    next_anchor=$(get_anchor_date "$next_year" "$next_month" "$PERIOD_START_DAY")
    previous_day "$next_anchor"
}

normalize_vnstat_json_for_interface() {
    local vnstat_json="$1"
    local expected_interface="$2"

    [[ "$expected_interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    printf '%s' "$vnstat_json" | jq -ce --arg expected "$expected_interface" '
        def uint:
            type == "number" and . >= 0 and floor == .;
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

vnstat_data_is_fresh() {
    local vnstat_json="$1"
    local updated_epoch updated_text now age save_interval update_interval max_age use_utc

    vnstat_daemon_is_running || return 1
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
        use_utc=$(vnstat_config_value "UseUTC")
        if [ "$use_utc" = "1" ]; then
            updated_epoch=$(TZ=UTC date -d "$updated_text" +%s 2>/dev/null) || return 1
        else
            updated_epoch=$(date -d "$updated_text" +%s 2>/dev/null) || return 1
        fi
    fi
    now=$(date +%s) || return 1
    save_interval=$(vnstat_config_value "SaveInterval")
    update_interval=$(vnstat_config_value "UpdateInterval")
    [[ "$save_interval" =~ ^[1-9][0-9]*$ && "$update_interval" =~ ^[1-9][0-9]*$ ]] || return 1
    max_age=$((save_interval * 60 + update_interval + 90))
    age=$((now - updated_epoch))
    [ "$age" -ge -300 ] && [ "$age" -le "$max_age" ]
}

# 获取流量使用情况
get_traffic_usage() {
    local start_date end_date
    local start_num end_num vnstat_json usage_bytes rx_bytes tx_bytes divisor
    local created_num earliest_num daily_days required_days trafficless_entries retention_start retention_num
    local available_num available_start

    start_date=$(get_period_start_date)
    end_date=$(get_period_end_date)
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 周期开始日期: $start_date, 周期结束日期: $end_date" >&2
    
    # 使用 vnstat JSON API 获取每日流量数据
    if ! vnstat_json=$(vnstat_cmd -i "$MAIN_INTERFACE" --json 2>/dev/null); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnstat 执行失败，跳过本轮限速检查" >&2
        return 1
    fi
    
    if [ -z "$vnstat_json" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 无法获取 vnstat JSON 数据" >&2
        return 1
    fi
    if ! vnstat_json=$(normalize_vnstat_json_for_interface "$vnstat_json" "$MAIN_INTERFACE"); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnStat JSON 版本、接口或每日 rx/tx 字段无效，跳过本轮限速检查" >&2
        return 1
    fi
    if ! vnstat_data_is_fresh "$vnstat_json"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnStat 守护进程未运行或数据库更新时间过旧，跳过本轮限速检查" >&2
        return 1
    fi
    
    # 将日期转换为 YYYYMMDD 整数用于比较（兼容 vnstat 2.x 的 date 对象格式）
    start_num=$(echo "$start_date" | tr -d '-')
    end_num=$(echo "$end_date" | tr -d '-')

    created_num=$(echo "$vnstat_json" | jq -r '.interfaces[0].created.date | (.year * 10000 + .month * 100 + .day)' 2>/dev/null) || return 1
    earliest_num=$(echo "$vnstat_json" | jq -r '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day)] | min // 0' 2>/dev/null) || return 1
    case "$TRAFFIC_PERIOD" in
        monthly) required_days=40 ;;
        quarterly) required_days=100 ;;
        yearly) required_days=400 ;;
    esac
    daily_days=$(vnstat_config_value "DailyDays")
    if [ "$daily_days" != "-1" ] && { ! [[ "$daily_days" =~ ^[0-9]+$ ]] || [ "$daily_days" -lt "$required_days" ]; }; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnStat DailyDays=${daily_days:-未知}，不足以可靠统计当前周期（建议至少 $required_days）" >&2
        return 1
    fi
    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    retention_start=$(cat "$RETENTION_STATE_FILE" 2>/dev/null || true)
    retention_num=${retention_start//-/}
    if [ -z "$retention_start" ] && [ -f "$WORK_DIR/vnstat.conf.before-trafficcop-lite" ] \
        && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -ne 0 ]; then
        # 旧版没有记录调整 DailyDays 的日期，以最早日记录作为保守覆盖起点。
        retention_start="$earliest_num"
        retention_num="$earliest_num"
    fi
    if ! [[ "$created_num" =~ ^[0-9]{8}$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 无法确认 vnStat 数据起始日期" >&2
        return 1
    fi
    if [ "$created_num" -gt "$start_num" ] \
        || { [ "$trafficless_entries" = "0" ] && [ -n "$retention_start" ] && { ! [[ "$retention_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$start_num" ]; }; } \
        || { [ "$trafficless_entries" != "0" ] && { ! [[ "$earliest_num" =~ ^[0-9]+$ ]] || [ "$earliest_num" -eq 0 ] || [ "$earliest_num" -gt "$start_num" ]; }; }; then
        if [ "${ALLOW_PARTIAL_HISTORY:-false}" != "true" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnStat 日数据未完整覆盖周期起点 $start_date，拒绝按不完整数据限速" >&2
            return 1
        fi
        available_num="$created_num"
        if [ "$trafficless_entries" != "0" ] \
            && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -gt "$available_num" ]; then
            available_num="$earliest_num"
        fi
        if [ "$trafficless_entries" = "0" ] \
            && [[ "$retention_num" =~ ^[0-9]{8}$ ]] && [ "$retention_num" -gt "$available_num" ]; then
            available_num="$retention_num"
        fi
        available_start=$(date_num_to_iso "$available_num")
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告: 用户已确认按部分历史继续；仅统计 $available_start 以来的可用流量，周期早段流量未计入" >&2
    fi
    
    # 根据 TRAFFIC_MODE 累加对应的流量
    case $TRAFFIC_MODE in
        out)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .tx] | add // 0') || return 1
            ;;
        in)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .rx] | add // 0') || return 1
            ;;
        max)
            rx_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .rx] | add // 0') || return 1
            tx_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .tx] | add // 0') || return 1
            usage_bytes=$(awk -v rx="$rx_bytes" -v tx="$tx_bytes" 'BEGIN { if (rx >= tx) print rx; else print tx }')
            ;;
        # 兜底分支必须排在所有具体分支之后：放前面会抢先匹配 max，让 max 静默按 total 计算。
        total|*)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | (.rx + .tx)] | add // 0') || return 1
            ;;
    esac

    if ! [[ "$usage_bytes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: jq 返回了无效流量数据：${usage_bytes:-空}" >&2
        return 1
    fi

    if [ "$usage_bytes" != "0" ]; then
        [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && divisor=1000000000 || divisor=1073741824
        awk -v bytes="$usage_bytes" -v divisor="$divisor" 'BEGIN { printf "%.3f\n", bytes / divisor }'
    else
        echo "0.000"
    fi
}

tc_root_qdisc() {
    local qdisc_state qdisc_line
    qdisc_state=$("$TC_BIN" qdisc show dev "$1" root 2>/dev/null) || return 2
    qdisc_line=$(awk 'NR == 1 { print; exit }' <<< "$qdisc_state")
    [ -n "$qdisc_line" ] || return 1
    printf '%s\n' "$qdisc_line"
}

is_default_qdisc_line() {
    local qdisc_line="$1"
    local qdisc_type

    qdisc_type=$(printf '%s\n' "$qdisc_line" | awk '{print $2}')
    case "$qdisc_type" in
        ""|noqueue|fq_codel|pfifo_fast|mq|fq) return 0 ;;
        *) return 1 ;;
    esac
}

tc_file_is_secure() {
    local file="$1"
    local owner_uid mode

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner_uid=$(stat -c '%u' "$file" 2>/dev/null) || return 1
    [ "$owner_uid" = "$(id -u)" ] || return 1
    mode=$(stat -c '%a' "$file" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ]
}

tc_file_unique_value() {
    local file="$1"
    local key="$2"
    local count

    count=$(grep -Ec "^${key}=" "$file" 2>/dev/null || true)
    [ "$count" -eq 1 ] || return 1
    grep "^${key}=" "$file" | cut -d'=' -f2-
}

tc_file_optional_unique_value() {
    local file="$1"
    local key="$2"
    local count

    count=$(grep -Ec "^${key}=" "$file" 2>/dev/null || true)
    [ "$count" -le 1 ] || return 1
    if [ "$count" -eq 1 ]; then
        grep "^${key}=" "$file" | cut -d'=' -f2-
    fi
    return 0
}

tc_state_file_is_interpretable() {
    local key

    tc_file_is_secure "$TC_STATE_FILE" || return 1
    tc_file_unique_value "$TC_STATE_FILE" INTERFACE >/dev/null || return 1
    tc_file_unique_value "$TC_STATE_FILE" LIMIT_SPEED >/dev/null || return 1
    for key in SCHEMA PROVIDER QDISC_LINE BOOT_ID PERIOD_START APPLIED_AT IFB_INTERFACE; do
        tc_file_optional_unique_value "$TC_STATE_FILE" "$key" >/dev/null || return 1
    done
}

tc_state_value() {
    local key="$1"
    [ -e "$TC_STATE_FILE" ] || return 1
    tc_state_file_is_interpretable || return 1
    tc_file_optional_unique_value "$TC_STATE_FILE" "$key"
}

# 供未加载配置的 --self-check 使用；返回 0=禁用、1=启用/未配置、2=配置不可信。
trafficcop_config_is_disabled() {
    local disabled

    if [ -n "${DISABLED+x}" ]; then
        case "$DISABLED" in
            true) return 0 ;;
            false) return 1 ;;
            *) return 2 ;;
        esac
    fi
    [ -e "$CONFIG_FILE" ] || return 1
    tc_file_is_secure "$CONFIG_FILE" || return 2
    disabled=$(tc_file_optional_unique_value "$CONFIG_FILE" DISABLED) || return 2
    case "$disabled" in
        true) return 0 ;;
        ""|false) return 1 ;;
        *) return 2 ;;
    esac
}

tc_state_interface() {
    tc_state_value "INTERFACE"
}

acquire_tc_hierarchy_lock() {
    mkdir -p "$(dirname "$TC_HIERARCHY_LOCK_FILE")" || return 1
    exec 6>"$TC_HIERARCHY_LOCK_FILE" || return 1
    if ! flock -w 15 6; then
        exec 6>&-
        return 1
    fi
}

release_tc_hierarchy_lock() {
    flock -u 6 2>/dev/null || true
    exec 6>&-
}

normalize_tc_rate_to_bps() {
    local value="${1,,}"
    local number unit multiplier

    value=${value//[[:space:]]/}
    [[ "$value" =~ ^([0-9]+)(bit|kbit|mbit|gbit|tbit)$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        bit) multiplier=1 ;;
        kbit) multiplier=1000 ;;
        mbit) multiplier=1000000 ;;
        gbit) multiplier=1000000000 ;;
        tbit) multiplier=1000000000000 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$((number * multiplier))"
}

tc_class_line() {
    local interface="$1"
    local class_id="$2"
    local class_state class_line
    class_state=$("$TC_BIN" class show dev "$interface" 2>/dev/null) || return 2
    class_line=$(awk -v class_id="$class_id" \
        '$1 == "class" && $3 == class_id { print; exit }' <<< "$class_state")
    [ -n "$class_line" ] || return 1
    printf '%s\n' "$class_line"
}

tc_class_output() {
    local interface="$1"
    "$TC_BIN" class show dev "$interface" 2>/dev/null || return 2
}

tc_filter_output() {
    local interface="$1"
    "$TC_BIN" filter show dev "$interface" parent 1:0 2>/dev/null || return 2
}

tc_class_value() {
    local interface="$1"
    local class_id="$2"
    local key="$3"
    local class_line status value

    class_line=$(tc_class_line "$interface" "$class_id")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    value=$(awk -v key="$key" \
        '{ for (i = 1; i < NF; i++) if ($i == key) { print $(i + 1); exit } }' \
        <<< "$class_line")
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

tc_class_rate_matches() {
    local interface="$1"
    local class_id="$2"
    local expected_rate="$3"
    local expected_ceil="${4:-}"
    local actual_rate actual_ceil expected_bps actual_bps status

    actual_rate=$(tc_class_value "$interface" "$class_id" rate)
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    expected_bps=$(normalize_tc_rate_to_bps "$expected_rate") || return 1
    actual_bps=$(normalize_tc_rate_to_bps "$actual_rate") || return 1
    [ "$actual_bps" = "$expected_bps" ] || return 1
    if [ -n "$expected_ceil" ]; then
        actual_ceil=$(tc_class_value "$interface" "$class_id" ceil)
        status=$?
        [ "$status" -eq 0 ] || return "$status"
        expected_bps=$(normalize_tc_rate_to_bps "$expected_ceil") || return 1
        actual_bps=$(normalize_tc_rate_to_bps "$actual_ceil") || return 1
        [ "$actual_bps" = "$expected_bps" ] || return 1
    fi
}

tc_root_is_htb_handle_one() {
    local interface="$1"
    local qdisc_line status
    qdisc_line=$(tc_root_qdisc "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$qdisc_line" | grep -Eq '^qdisc htb 1:([[:space:]]|$)'
}

tc_root_has_default_30() {
    local interface="$1"
    local qdisc_line status
    qdisc_line=$(tc_root_qdisc "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$qdisc_line" | grep -Eq ' default (0x)?30([[:space:]]|$)'
}

tc_root_has_parent_class() {
    local interface="$1"
    local class_line status
    class_line=$(tc_class_line "$interface" "1:1")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$class_line" | grep -Eq '^class htb 1:1 root([[:space:]]|$)'
}

dog_owner_marker_matches() {
    local interface="$1"
    local recorded_interface="" recorded_machine_id="" machine_id=""

    [ -r "$DOG_TC_OWNER_FILE" ] || return 1
    IFS='|' read -r recorded_interface recorded_machine_id < "$DOG_TC_OWNER_FILE" || return 1
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    [ "$recorded_interface" = "$interface" ] && [ "$recorded_machine_id" = "$machine_id" ]
}

tc_state_is_unified_for_interface() {
    local interface="$1"
    [ "$(tc_state_value SCHEMA)" = "$TC_STATE_SCHEMA" ] &&
        [ "$(tc_state_value PROVIDER)" = "$TC_STATE_PROVIDER" ] &&
        [ "$(tc_state_interface)" = "$interface" ]
}

dog_bandwidth_to_tc() {
    local value="${1,,}" number unit

    [[ "$value" =~ ^([0-9]+)(kbps|mbps|gbps|kbit|mbit|gbit|bit)$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        kbps|kbit) printf '%skbit\n' "$number" ;;
        mbps|mbit) printf '%smbit\n' "$number" ;;
        gbps|gbit) printf '%sgbit\n' "$number" ;;
        bit) printf '%sbit\n' "$number" ;;
        *) return 1 ;;
    esac
}

# Dog 配置格式：1 = 1.5.x（.ports，无 schema），2 = 2.x（schema 2 + .monitors）。
# 文件不可读或格式无法识别时返回 1——不能把未知格式当成“没有 Dog 端口类”。
dog_config_schema() {
    [ -r "$DOG_CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 || return 1
    local schema
    schema=$(jq -r '
        if type != "object" then "unknown"
        elif .schema == 2 and (.monitors | type) == "object" then "2"
        elif (has("schema") | not) and (has("monitors") | not) and ((.ports // {}) | type) == "object" then "1"
        else "unknown" end' "$DOG_CONFIG_FILE" 2>/dev/null) || return 1
    case "$schema" in 1|2) printf '%s\n' "$schema" ;; *) return 1 ;; esac
}

# Dog 2.x：从 tc-interop.json 读取类清单，输出与 1.5.x 相同的四列（第一列为监控项 ID）。
# 出向统一是 fw mark 过滤器，后续按“区间/组”的 mark 路径校验。清单缺失、不安全或任何一项
# 不符合确定性公式（minor = 0x4000 + 编号，mark = 0x50000000 | minor<<12）时失败关闭。
dog_tc_manifest_file() {
    printf '%s\n' "${DOG_TC_MANIFEST_FILE:-${DOG_CONFIG_FILE%/*}/tc-interop.json}"
}

dog_manifest_class_records() {
    local raw id class_id rate mark minor tc_rate manifest
    manifest=$(dog_tc_manifest_file)
    tc_file_is_secure "$manifest" || return 1
    raw=$(jq -r --arg schema "${DOG_TC_MANIFEST_SCHEMA:-traffic-tools-dog-classes-v1}" '
        if .schema != $schema or (.classes | type) != "array" then error("manifest")
        elif ([.classes[].class_id] | length) != ([.classes[].class_id] | unique | length) then error("duplicate")
        else .classes[] |
            if (.id | type) != "string" or (.class_id | type) != "string" or (.rate | type) != "string" or
               (.mark | type) != "number" or .mark_mask != 4294963200 or .egress != "fw"
            then error("class") else [.id, .class_id, .rate, (.mark | tostring)] | @tsv end
        end' "$manifest" 2>/dev/null) || return 1
    [ -n "$raw" ] || return 0
    while IFS=$'\t' read -r id class_id rate mark; do
        [[ "$id" =~ ^m([1-9][0-9]{0,4})$ ]] || return 1
        minor=$((0x4000 + BASH_REMATCH[1]))
        [ "$minor" -le 65535 ] || return 1
        [ "$class_id" = "$(printf '1:%x' "$minor")" ] || return 1
        [[ "$mark" =~ ^[0-9]+$ ]] && [ "$mark" -eq $((0x50000000 | (minor << 12))) ] || return 1
        tc_rate=$(dog_bandwidth_to_tc "$rate") || return 1
        printf '%s\t%s\t%s\t%s\n' "$id" "$class_id" "$tc_rate" "$mark"
    done <<< "$raw"
}

dog_configured_class_records() {
    local schema
    schema=$(dog_config_schema) || return 1
    case "$schema" in
        1) dog_legacy_class_records ;;
        2) dog_manifest_class_records ;;
        *) return 1 ;;
    esac
}

# Dog 1.5.x：从 .ports 推导类清单（保持 1.1.x 行为）。
dog_legacy_class_records() {
    local port class_id rate mark_id start_port end_port generated_mark minor tc_rate raw_records

    [ -r "$DOG_CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 || return 1
    jq -e '(.ports // {}) | type == "object"' "$DOG_CONFIG_FILE" >/dev/null 2>&1 || return 1
    raw_records=$(jq -r '
        .ports // {} | to_entries[] |
        select((.value.enabled // true) == true) |
        select((.value.bandwidth_limit.enabled // false) == true) |
        select((.value.bandwidth_limit.rate // "unlimited") != "unlimited") |
        [.key, (if (.value.bandwidth_limit.class_id // "") == "" then "__none__"
                else .value.bandwidth_limit.class_id end),
         (.value.bandwidth_limit.rate // ""),
         ((.value.bandwidth_limit.mark_id // "") | tostring)] | @tsv
    ' "$DOG_CONFIG_FILE" 2>/dev/null) || return 1
    [ -n "$raw_records" ] || return 0
    while IFS=$'\t' read -r port class_id rate mark_id; do
        [ "$class_id" = "__none__" ] && class_id=""
        if [ -z "$class_id" ] && [[ "$port" == *,* ]]; then
            # Dog 写入配置后，端口组在首次实际应用前还没有可证明的 class_id；NTC 不凭空创建它。
            continue
        fi
        tc_rate=$(dog_bandwidth_to_tc "$rate") || return 1
        if ! [[ "$class_id" =~ ^1:([0-9a-fA-F]+)$ ]]; then
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                class_id=$(printf '1:%x' "$((0x1000 + port))")
            elif [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                start_port="${BASH_REMATCH[1]}"
                end_port="${BASH_REMATCH[2]}"
                generated_mark=$(((start_port * 1000 + end_port) % 65536))
                minor=$((0x2000 + generated_mark))
                [ "$minor" -le 65535 ] || return 1
                class_id=$(printf '1:%x' "$minor")
            else
                return 1
            fi
        fi
        if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]] || [[ "$port" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
            [[ "$mark_id" =~ ^[0-9]+$ ]] || return 1
        elif ! [[ "$port" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        printf '%s\t%s\t%s\t%s\n' "$port" "$class_id" "$tc_rate" "$mark_id"
    done <<< "$raw_records"
}

dog_configured_class_ids() {
    local records
    records=$(dog_configured_class_records) || return 1
    printf '%s\n' "$records" | awk -F '\t' 'NF >= 2 { print $2 }' | sort -u
}

dog_single_port_filters_complete() {
    local interface="$1"
    local port="$2"
    local class_id="$3"
    local filter_prio=$((port % 1000 + 1))
    local sport_hex dport_hex filter_json filter_ipv4 filter_ipv6

    sport_hex=$(printf '%x' "$((port << 16))")
    dport_hex=$(printf '%x' "$port")
    # iproute2 6.1 的 fw JSON printer 会混入非 JSON 文本；单端口无需读取它。
    # 按协议查询仍须完整验证全部 TCP/UDP 单端口分类器。
    filter_ipv4=$("$TC_BIN" -j filter show dev "$interface" parent 1:0 protocol ip 2>/dev/null) || return 2
    filter_ipv6=$("$TC_BIN" -j filter show dev "$interface" parent 1:0 protocol ipv6 2>/dev/null) || return 2
    # tc 会省略已由查询条件确定的 protocol；显式字段仍按原值校验。
    filter_json=$(printf '%s\n%s\n' "$filter_ipv4" "$filter_ipv6" |
        jq -cs 'if length == 2 and all(.[]; type == "array") then
            (.[0] | map(.protocol //= "ip")) + (.[1] | map(.protocol //= "ipv6"))
        else error("invalid filter arrays") end') || return 2
    jq -e \
        --arg class_id "$class_id" \
        --arg sport_hex "$sport_hex" \
        --arg dport_hex "$dport_hex" \
        --argjson port "$port" \
        --argjson tcp_pref "$filter_prio" \
        --argjson udp_pref "$((filter_prio + 1000))" '
        def normhex:
            tostring | ascii_downcase | sub("^0x"; "") | sub("^0+"; "") |
            if . == "" then "0" else . end;
        def u32_count($pref; $value; $mask):
            [.[] | select(
                .protocol == "ip" and .kind == "u32" and .pref == $pref and
                .options.flowid == $class_id and
                ((.options.match.value // "") | normhex) == ($value | normhex) and
                ((.options.match.mask // "") | normhex) == ($mask | normhex) and
                (.options.match.off // -1) == 20
            )] | length;
        def flower_count($proto; $key):
            [.[] | select(
                .protocol == "ipv6" and .kind == "flower" and
                .options.classid == $class_id and
                .options.keys.ip_proto == $proto and
                .options.keys[$key] == $port
            )] | length;
        u32_count($tcp_pref; $sport_hex; "ffff0000") == 1 and
        u32_count($tcp_pref; $dport_hex; "ffff") == 1 and
        u32_count($udp_pref; $sport_hex; "ffff0000") == 1 and
        u32_count($udp_pref; $dport_hex; "ffff") == 1 and
        flower_count("tcp"; "src_port") == 1 and
        flower_count("tcp"; "dst_port") == 1 and
        flower_count("udp"; "src_port") == 1 and
        flower_count("udp"; "dst_port") == 1
    ' <<< "$filter_json" >/dev/null
}

dog_port_range_filter_complete() {
    local interface="$1"
    local class_id="$2"
    local mark_id="$3"
    local mark_handle filter_state

    mark_handle=$(printf '0x%x/0x%x' "$mark_id" "$TC_MARK_MASK")
    filter_state=$("$TC_BIN" filter show dev "$interface" parent 1:0 2>/dev/null) || return 2
    [ "$(printf '%s\n' "$filter_state" |
        grep -F "handle $mark_handle" |
        grep -Fc "classid $class_id")" -eq 1 ]
}

dog_live_objects_match_config() {
    local interface="$1"
    local match_mode="${3:-strict}"
    local configured_records configured_ids class_output filter_output actual_ids filter_ids
    local port class_id expected_rate mark_id minor_hex minor expected_mark status class_line

    configured_records=$(dog_configured_class_records) || return 1
    configured_ids=$(printf '%s\n' "$configured_records" | awk -F '\t' 'NF >= 2 { print $2 }' | sort -u)
    class_output=$(tc_class_output "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    filter_output=$(tc_filter_output "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    actual_ids=$(printf '%s\n' "$class_output" |
        awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { print $3 }' |
        sort -u)
    filter_ids=$(printf '%s\n' "$filter_output" |
        grep -Eo '(flowid|classid)[[:space:]]+1:[0-9a-fA-F]+' |
        awk '{ print $2 }' | sort -u)

    while IFS= read -r class_id; do
        [ -z "$class_id" ] && continue
        printf '%s\n' "$configured_ids" | grep -Fqx "$class_id" || return 1
    done <<< "$actual_ids"
    while IFS= read -r class_id; do
        [ -z "$class_id" ] && continue
        printf '%s\n' "$configured_ids" | grep -Fqx "$class_id" || return 1
    done <<< "$filter_ids"
    if [ "$match_mode" != allow-missing ]; then
        while IFS= read -r class_id; do
            [ -z "$class_id" ] && continue
            printf '%s\n' "$actual_ids" | grep -Fqx "$class_id" || return 1
            printf '%s\n' "$filter_ids" | grep -Fqx "$class_id" || return 1
        done <<< "$configured_ids"
    fi

    while IFS=$'\t' read -r port class_id expected_rate mark_id; do
        [ -n "$port" ] || continue
        class_line=$(tc_class_line "$interface" "$class_id")
        status=$?
        # 只有查询成功且 class 确实缺失时才允许跳过；速率错误仍须失败关闭。
        if [ "$status" -eq 1 ] && [ "$match_mode" = allow-missing ]; then continue; fi
        [ "$status" -eq 0 ] || return "$status"
        tc_class_rate_matches "$interface" "$class_id" "$TC_DEFAULT_CLASS_RATE" "$expected_rate" || return $?
        # IFB 使用 Dog 自己的分类实现；这里验证 class 和 filter 引用，不复制分类器。
        if [ "${2:-}" = "classes" ]; then
            [[ "$class_line" == "class htb $class_id parent 1:1 "* ]] || return 1
            continue
        fi
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            dog_single_port_filters_complete "$interface" "$port" "$class_id"
            status=$?
        else
            # 1.5.x 的端口区间/组与 2.x 的全部监控项：出向都是 handle mark/0xfffff000 的 fw 过滤器。
            minor_hex=${class_id#1:}
            [[ "$minor_hex" =~ ^[0-9a-fA-F]+$ ]] || return 1
            minor=$((16#$minor_hex))
            expected_mark=$((0x50000000 | (minor << 12)))
            [[ "$mark_id" =~ ^[0-9]+$ ]] && [ "$mark_id" -eq "$expected_mark" ] || return 1
            dog_port_range_filter_complete "$interface" "$class_id" "$mark_id"
            status=$?
        fi
        [ "$status" -eq 0 ] || return "$status"
    done <<< "$configured_records"
}

tc_root_is_recognized_dog_htb() {
    local interface="$1"
    local status

    dog_owner_marker_matches "$interface" || return 1
    tc_root_is_htb_handle_one "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_root_has_default_30 "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_root_has_parent_class "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    dog_live_objects_match_config "$interface"
}

tc_root_is_unified_compatible() {
    local interface="$1"
    local status

    tc_root_is_htb_handle_one "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_root_has_default_30 "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_root_has_parent_class "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_state_is_unified_for_interface "$interface" && return 0
    tc_root_is_recognized_dog_htb "$interface"
}

dog_config_reserves_default_class() {
    local schema records
    [ -f "$DOG_CONFIG_FILE" ] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    # 格式无法识别或 2.x 清单无法读取时按“占用”处理，让调用方失败关闭。
    schema=$(dog_config_schema) || return 0
    if [ "$schema" = 2 ]; then
        records=$(dog_manifest_class_records) || return 0
        printf '%s\n' "$records" | awk -F '\t' '$2 == "1:30" { found=1 } END { exit found ? 0 : 1 }'
        return
    fi
    jq -e '
        [.ports // {} | to_entries[] |
            select((.value.bandwidth_limit.class_id // "") == "1:30")] |
        length > 0
    ' "$DOG_CONFIG_FILE" >/dev/null 2>&1
}

tc_default_class_is_safe() {
    local interface="$1"
    local default_line status

    dog_config_reserves_default_class && return 1
    default_line=$(tc_class_line "$interface" "1:30")
    status=$?
    [ "$status" -eq 2 ] && return 2
    [ "$status" -eq 1 ] && return 0
    printf '%s\n' "$default_line" | grep -Eq '^class htb 1:30 parent 1:1([[:space:]]|$)' &&
        tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE"
}

tc_has_other_consumers() {
    local interface="$1"
    local class_output filter_output status

    class_output=$(tc_class_output "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    if printf '%s\n' "$class_output" |
        awk '$1 == "class" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi
    filter_output=$(tc_filter_output "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ -n "$filter_output" ]
}

tc_legacy_tbf_is_owned() {
    local interface="$1"
    local qdisc_line="$2"
    local state_interface state_schema state_provider state_qdisc state_speed actual_rate

    printf '%s\n' "$qdisc_line" | grep -q ' tbf ' || return 1
    state_interface=$(tc_state_interface)
    state_schema=$(tc_state_value SCHEMA)
    state_provider=$(tc_state_value PROVIDER)
    state_qdisc=$(tc_state_value QDISC_LINE)
    state_speed=$(tc_state_value LIMIT_SPEED)
    [ "$state_interface" = "$interface" ] || return 1
    [ -z "$state_schema" ] || return 1
    [ -z "$state_provider" ] || [ "$state_provider" = "$TC_STATE_PROVIDER" ] || return 1
    [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] || return 1
    if [ -n "$state_qdisc" ]; then
        [ "$qdisc_line" = "$state_qdisc" ] || return 1
    fi
    actual_rate=$(printf '%s\n' "$qdisc_line" |
        awk '{ for (i = 1; i < NF; i++) if ($i == "rate") { print $(i + 1); exit } }')
    [ "$(normalize_tc_rate_to_bps "$actual_rate" 2>/dev/null)" = "$((state_speed * 1000))" ]
}

current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

write_tc_state() {
    local interface="$1"
    local speed="$2"
    local qdisc_line="$3"
    local state_file="${4:-$TC_STATE_FILE}"
    local ifb_interface="${5:-}"
    local period_start tmp_file

    period_start=$(get_period_start_date)
    tmp_file="${state_file}.tmp.$$"
    {
        printf 'SCHEMA=%s\n' "$TC_STATE_SCHEMA"
        printf 'PROVIDER=%s\n' "$TC_STATE_PROVIDER"
        printf 'INTERFACE=%s\n' "$interface"
        printf 'LIMIT_SPEED=%s\n' "$speed"
        [ -z "$ifb_interface" ] || printf 'IFB_INTERFACE=%s\n' "$ifb_interface"
        printf 'QDISC_LINE=%s\n' "$qdisc_line"
        printf 'BOOT_ID=%s\n' "$(current_boot_id)"
        printf 'PERIOD_START=%s\n' "$period_start"
        printf 'APPLIED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$state_file" || { rm -f "$tmp_file"; return 1; }
}

tc_verify_unified_hierarchy() {
    local interface="$1"
    local parent_rate="$2"
    local class_line status

    tc_root_is_htb_handle_one "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_root_has_default_30 "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_root_has_parent_class "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    class_line=$(tc_class_line "$interface" "1:30")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$class_line" |
        grep -Eq '^class htb 1:30 parent 1:1([[:space:]]|$)' || return 1
    tc_class_rate_matches "$interface" "1:1" "$parent_rate" "$parent_rate"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$parent_rate"
}

tc_replace_base_classes() {
    local interface="$1"
    local parent_rate="$2"
    local status

    normalize_tc_rate_to_bps "$parent_rate" >/dev/null 2>&1 || return 1
    tc_default_class_is_safe "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    "$TC_BIN" class replace dev "$interface" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_rate" 2>/dev/null || return 1
    "$TC_BIN" class replace dev "$interface" parent 1:1 classid 1:30 htb \
        rate "$TC_DEFAULT_CLASS_RATE" ceil "$parent_rate" 2>/dev/null
}

tc_state_allows_boot_rebuild() {
    local interface="$1"
    local state_boot_id boot_id state_schema state_provider state_speed

    [ "$(tc_state_interface)" = "$interface" ] || return 1
    state_schema=$(tc_state_value SCHEMA)
    state_provider=$(tc_state_value PROVIDER)
    if [ -z "$state_schema" ]; then
        [ -z "$state_provider" ] || return 1
    else
        [ "$state_schema" = "$TC_STATE_SCHEMA" ] &&
            [ "$state_provider" = "$TC_STATE_PROVIDER" ] || return 1
    fi
    state_speed=$(tc_state_value LIMIT_SPEED)
    [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] || return 1
    state_boot_id=$(tc_state_value BOOT_ID)
    boot_id=$(current_boot_id)
    [ -n "$state_boot_id" ] && [ -n "$boot_id" ] && [ "$state_boot_id" != "$boot_id" ]
}

# 只识别 Dog 已建立的 ifb0；绝不创建 IFB，也不调用会再次获取 TC 锁的 Dog 子进程。
# 父速率不参与归属判断，使正常 apply 可以修复可验证层级的速率漂移。
dog_ingress_redirect_complete() {
    local interface="$1" qdiscs filters
    qdiscs=$("$TC_BIN" qdisc show dev "$interface" 2>/dev/null) || return 2
    grep -Eq '^qdisc ingress ffff:([[:space:]]|$)' <<< "$qdiscs" || return 1
    filters=$("$TC_BIN" filter show dev "$interface" parent ffff: 2>/dev/null) || return 2
    awk '
        function check() {
            if (block ~ /match 00000000\/00000000 at 0/ &&
                tolower(block) ~ /mirred \(egress redirect to device ifb0\)/) {
                if (proto == "ip") ipv4++
                if (proto == "ipv6") ipv6++
            }
        }
        /^filter / {
            check(); block=$0; proto=""
            for (i=1; i<NF; i++) if ($i == "protocol") proto=$(i+1)
            next
        }
        { block=block "\n" $0 }
        END { check(); exit !(ipv4 == 1 && ipv6 == 1) }
    ' <<< "$filters"
}

tc_dog_ifb_device() {
    local interface="$1" match_mode="${2:-strict}" recorded="" records="" link_state status
    local owner_file="${DOG_TC_OWNER_FILE:-}" config_file="${DOG_CONFIG_FILE:-}"

    # 纯 NTC 不探测、更不会写入其他程序的 IFB。
    if [ ! -e "$owner_file" ] && [ ! -L "$owner_file" ] &&
       [ ! -e "$config_file" ] && [ ! -L "$config_file" ] &&
       ! grep -q '^IFB_INTERFACE=' "$TC_STATE_FILE" 2>/dev/null; then
        return 0
    fi
    if grep -q '^IFB_INTERFACE=' "$TC_STATE_FILE" 2>/dev/null; then
        recorded=$(tc_state_value IFB_INTERFACE) || return 1
        [ "$recorded" = ifb0 ] && tc_state_is_unified_for_interface "$interface" || return 1
    fi
    if [ -z "$recorded" ] && [ ! -e "$owner_file" ] && [ ! -L "$owner_file" ]; then
        # Dog 配置文件单独存在不等于 Dog 已接管 TC；允许 NTC 先独立管理出向。
        return 0
    fi
    tc_file_is_secure "$config_file" || return 1
    records=$(dog_configured_class_records) || return 1
    if [ -z "$recorded" ]; then
        tc_file_is_secure "$owner_file" && dog_owner_marker_matches "$interface" || return 1
    fi
    link_state=$(ip -j -d link show dev ifb0 2>/dev/null) || return 1
    jq -e 'length == 1 and .[0].ifname == "ifb0" and
        .[0].linkinfo.info_kind == "ifb" and (.[0].flags | index("UP") != null)' \
        <<< "$link_state" >/dev/null 2>&1 || return 1
    tc_root_is_htb_handle_one ifb0 && tc_root_has_default_30 ifb0 &&
        tc_root_has_parent_class ifb0 && tc_default_class_is_safe ifb0
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    dog_live_objects_match_config ifb0 classes "$match_mode"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    dog_ingress_redirect_complete "$interface"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' ifb0
}

tc_base_class_snapshot() {
    local interface="$1" class_id key value values=""
    for class_id in 1:1 1:30; do
        for key in rate ceil; do
            value=$(tc_class_value "$interface" "$class_id" "$key") || return $?
            normalize_tc_rate_to_bps "$value" >/dev/null || return 1
            values+="$value "
        done
    done
    printf '%s\n' "${values% }"
}

tc_restore_base_snapshot() {
    local interface="$1" snapshot="$2" parent_rate parent_ceil default_rate default_ceil
    local failed=0
    read -r parent_rate parent_ceil default_rate default_ceil <<< "$snapshot"
    "$TC_BIN" class replace dev "$interface" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_ceil" 2>/dev/null || failed=1
    "$TC_BIN" class replace dev "$interface" parent 1:1 classid 1:30 htb \
        rate "$default_rate" ceil "$default_ceil" 2>/dev/null || failed=1
    tc_class_rate_matches "$interface" 1:1 "$parent_rate" "$parent_ceil" || failed=1
    tc_class_rate_matches "$interface" 1:30 "$default_rate" "$default_ceil" || failed=1
    return "$failed"
}

tc_update_dog_ifb() {
    local interface="$1" device="$2" rate="$3" match_mode="${4:-strict}"
    [ -n "$device" ] || return 0
    tc_replace_base_classes "$device" "$rate" &&
        tc_verify_unified_hierarchy "$device" "$rate" &&
        dog_live_objects_match_config "$device" classes "$match_mode" &&
        dog_ingress_redirect_complete "$interface"
}

tc_verify_dog_ifb() {
    local interface="$1" rate="$2" device status
    device=$(tc_dog_ifb_device "$interface")
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ -n "$device" ] || return 0
    tc_verify_unified_hierarchy "$device" "$rate"
}

apply_tc_limit() {
    local speed="$1"
    local existing_qdisc state_interface mode=""
    local prepared_state="${TC_STATE_FILE}.prepared.$$"
    local old_parent_rate="" old_parent_ceil=""
    local old_default_line="" old_default_rate="" old_default_ceil=""
    local legacy_speed="" rollback_ok=false
    local query_status verify_status
    local ifb_device="" ifb_snapshot=""
    local state_schema="" state_provider="" state_speed=""

    if [ -z "$TC_BIN" ] || ! [[ "$speed" =~ ^[1-9][0-9]*$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 未找到系统 tc 命令，无法执行限速" | tee -a "$LOG_FILE"
        return 1
    fi

    if ! acquire_tc_hierarchy_lock; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法取得统一 TC 层级锁，未修改 qdisc。" | tee -a "$LOG_FILE"
        return 1
    fi

    state_interface=$(tc_state_interface)
    if { [ -e "$TC_STATE_FILE" ] || [ -L "$TC_STATE_FILE" ]; } && [ -z "$state_interface" ]; then
        echo "TC 状态无法安全解释，未修改 TC。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    fi
    if [ -n "$state_interface" ]; then
        state_schema=$(tc_state_value SCHEMA)
        state_provider=$(tc_state_value PROVIDER)
        state_speed=$(tc_state_value LIMIT_SPEED)
        if { [ -n "$state_schema" ] && [ "$state_schema" != "$TC_STATE_SCHEMA" ]; } ||
           { [ -n "$state_provider" ] && [ "$state_provider" != "$TC_STATE_PROVIDER" ]; } ||
           ! [[ "$state_speed" =~ ^[1-9][0-9]*$ ]]; then
            echo "TC 状态格式或归属无效，未修改 TC。" | tee -a "$LOG_FILE"
            release_tc_hierarchy_lock
            return 1
        fi
    fi
    if [ -n "$state_interface" ] && [ "$state_interface" != "$MAIN_INTERFACE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') TC 状态文件属于接口 $state_interface，当前配置接口为 $MAIN_INTERFACE，将先清理旧接口限速。" | tee -a "$LOG_FILE"
        if ! clear_owned_tc_rules_locked "配置接口已变更"; then
            release_tc_hierarchy_lock
            return 1
        fi
        state_interface=""
    fi

    existing_qdisc=$(tc_root_qdisc "$MAIN_INTERFACE")
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法读取 $MAIN_INTERFACE 的 root qdisc，未作任何 TC 修改。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    elif [ "$query_status" -eq 1 ]; then
        existing_qdisc=""
    fi
    if ! ifb_device=$(tc_dog_ifb_device "$MAIN_INTERFACE"); then
        echo "Dog 入向层级归属或运行态无法验证，未修改 TC。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    fi
    if [ -n "$ifb_device" ] && ! ifb_snapshot=$(tc_base_class_snapshot "$ifb_device"); then
        ntc_operation_log tc-apply failure
        release_tc_hierarchy_lock
        return 1
    fi

    tc_root_is_unified_compatible "$MAIN_INTERFACE"
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') TC 层级查询失败，未作任何 TC 修改。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    elif [ "$query_status" -eq 0 ]; then
        mode="existing"
        if tc_state_is_unified_for_interface "$MAIN_INTERFACE" &&
           [ "$(tc_state_value LIMIT_SPEED)" = "$speed" ]; then
            tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${speed}kbit" &&
                tc_verify_dog_ifb "$MAIN_INTERFACE" "${speed}kbit" &&
                [ "$(tc_state_value IFB_INTERFACE)" = "$ifb_device" ]
            verify_status=$?
            if [ "$verify_status" -eq 0 ]; then
                release_tc_hierarchy_lock
                echo "$(date '+%Y-%m-%d %H:%M:%S') 统一 HTB 整机限速规则保持生效" | tee -a "$LOG_FILE"
                return 0
            elif [ "$verify_status" -eq 2 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') TC 层级查询失败，未作任何 TC 修改。" | tee -a "$LOG_FILE"
                release_tc_hierarchy_lock
                return 1
            fi
        fi
        old_parent_rate=$(tc_class_value "$MAIN_INTERFACE" "1:1" rate)
        query_status=$?
        [ "$query_status" -eq 0 ] || mode=""
        old_parent_ceil=$(tc_class_value "$MAIN_INTERFACE" "1:1" ceil)
        query_status=$?
        [ "$query_status" -eq 0 ] || mode=""
        normalize_tc_rate_to_bps "$old_parent_rate" >/dev/null 2>&1 || mode=""
        normalize_tc_rate_to_bps "$old_parent_ceil" >/dev/null 2>&1 || mode=""
        old_default_line=$(tc_class_line "$MAIN_INTERFACE" "1:30")
        query_status=$?
        if [ "$query_status" -eq 2 ]; then
            mode=""
        elif [ "$query_status" -eq 1 ]; then
            old_default_line=""
        else
            old_default_rate=$(tc_class_value "$MAIN_INTERFACE" "1:30" rate)
            query_status=$?
            [ "$query_status" -eq 0 ] || mode=""
            old_default_ceil=$(tc_class_value "$MAIN_INTERFACE" "1:30" ceil)
            query_status=$?
            [ "$query_status" -eq 0 ] || mode=""
            normalize_tc_rate_to_bps "$old_default_rate" >/dev/null 2>&1 || mode=""
            normalize_tc_rate_to_bps "$old_default_ceil" >/dev/null 2>&1 || mode=""
        fi
    elif tc_legacy_tbf_is_owned "$MAIN_INTERFACE" "$existing_qdisc"; then
        mode="legacy-tbf"
        legacy_speed=$(tc_state_value LIMIT_SPEED)
    elif is_default_qdisc_line "$existing_qdisc"; then
        if [ -f "$TC_STATE_FILE" ] && ! tc_state_allows_boot_rebuild "$MAIN_INTERFACE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') TC 状态存在，但当前 root qdisc 在本次开机中已变化；为避免覆盖外部策略，已停止。" | tee -a "$LOG_FILE"
            release_tc_hierarchy_lock
            return 1
        fi
        mode="new"
    fi

    if [ -z "$mode" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到无法证明归属的 root qdisc：${existing_qdisc:-空}，未作修改。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    fi

    if ! write_tc_state "$MAIN_INTERFACE" "$speed" "" "$prepared_state" "$ifb_device"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法预写统一 HTB 状态，已拒绝修改系统 qdisc。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    fi

    if [ "$mode" != "existing" ] &&
       ! "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root handle 1: htb default 30 2>/dev/null; then
        rm -f "$prepared_state"
        release_tc_hierarchy_lock
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法创建统一 HTB root qdisc。" | tee -a "$LOG_FILE"
        return 1
    fi

    if tc_replace_base_classes "$MAIN_INTERFACE" "${speed}kbit" &&
       tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${speed}kbit" &&
       tc_update_dog_ifb "$MAIN_INTERFACE" "$ifb_device" "${speed}kbit" &&
       mv -f "$prepared_state" "$TC_STATE_FILE"; then
        release_tc_hierarchy_lock
        echo "$(date '+%Y-%m-%d %H:%M:%S') 统一 HTB 整机限速已应用，现有端口子类保持不变。" | tee -a "$LOG_FILE"
        ntc_operation_log tc-apply success
        return 0
    fi

    case "$mode" in
        existing)
            if "$TC_BIN" class replace dev "$MAIN_INTERFACE" parent 1: classid 1:1 htb \
                    rate "$old_parent_rate" ceil "$old_parent_ceil" 2>/dev/null; then
                if [ -n "$old_default_line" ]; then
                    "$TC_BIN" class replace dev "$MAIN_INTERFACE" parent 1:1 classid 1:30 htb \
                        rate "$old_default_rate" ceil "$old_default_ceil" 2>/dev/null && rollback_ok=true
                else
                    if "$TC_BIN" class del dev "$MAIN_INTERFACE" classid 1:30 2>/dev/null; then
                        tc_class_line "$MAIN_INTERFACE" "1:30" >/dev/null
                        query_status=$?
                        [ "$query_status" -eq 1 ] && rollback_ok=true
                    fi
                fi
            fi
            ;;
        legacy-tbf)
            if "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root tbf rate "${legacy_speed}kbit" \
                burst 32kbit latency 400ms 2>/dev/null; then
                rollback_ok=true
            fi
            ;;
        new)
            if "$TC_BIN" qdisc del dev "$MAIN_INTERFACE" root handle 1: 2>/dev/null; then
                rollback_ok=true
            else
                tc_root_is_htb_handle_one "$MAIN_INTERFACE"
                query_status=$?
                [ "$query_status" -eq 1 ] && rollback_ok=true
            fi
            ;;
    esac
    if $rollback_ok && [ "$mode" = existing ]; then
        tc_class_rate_matches "$MAIN_INTERFACE" 1:1 "$old_parent_rate" "$old_parent_ceil" || rollback_ok=false
        if [ -n "$old_default_line" ]; then
            tc_class_rate_matches "$MAIN_INTERFACE" 1:30 "$old_default_rate" "$old_default_ceil" || rollback_ok=false
        fi
    fi
    if [ -n "$ifb_device" ] && ! tc_restore_base_snapshot "$ifb_device" "$ifb_snapshot"; then
        rollback_ok=false
    fi

    if $rollback_ok; then
        rm -f "$prepared_state"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 统一 HTB 应用失败，已恢复修改前的 TC 状态。" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 严重错误：统一 HTB 回滚失败；预写状态保留在 $prepared_state。" | tee -a "$LOG_FILE"
    fi
    ntc_operation_log tc-apply failure
    release_tc_hierarchy_lock
    return 1
}

clear_owned_tc_rules_locked() {
    local TC_PARENT_RATE="${TC_PARENT_RATE:-100gbit}"
    local reason="$1"
    local state_interface qdisc_line state_speed state_schema state_provider
    local rollback_ok=false
    local query_status verify_status
    local ifb_device="" ifb_snapshot="" restore_parent_rate=""

    if [ -L "$TC_STATE_FILE" ]; then
        echo "$reason：TC 状态路径不可信，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    fi
    if [ ! -f "$TC_STATE_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：未发现本脚本 TC 状态标记，保留现有 qdisc。" | tee -a "$LOG_FILE"
        return 0
    fi

    state_interface=$(tc_state_interface)
    if [ -z "$state_interface" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 状态文件缺少接口，无法证明现有 qdisc 归属；已保留状态和规则。" | tee -a "$LOG_FILE"
        return 1
    fi

    if [ -z "$TC_BIN" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：未找到系统 tc 命令，无法清理本脚本限速。" | tee -a "$LOG_FILE"
        return 1
    fi

    qdisc_line=$(tc_root_qdisc "$state_interface")
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：无法读取 root qdisc，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    elif [ "$query_status" -eq 1 ]; then
        qdisc_line=""
    fi
    state_speed=$(tc_state_value LIMIT_SPEED)
    state_schema=$(tc_state_value SCHEMA)
    state_provider=$(tc_state_value PROVIDER)

    if [ -z "$state_schema" ]; then
        if is_default_qdisc_line "$qdisc_line" && tc_state_allows_boot_rebuild "$state_interface"; then
            if rm -f "$TC_STATE_FILE"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 已随重启消失，仅清理旧状态。" | tee -a "$LOG_FILE"
                return 0
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 已随重启消失，但状态文件删除失败。" | tee -a "$LOG_FILE"
            return 1
        fi
        if ! tc_legacy_tbf_is_owned "$state_interface" "$qdisc_line"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 与状态记录不一致，保留规则和状态。" | tee -a "$LOG_FILE"
            return 1
        fi
        if ! "$TC_BIN" qdisc del dev "$state_interface" root 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 清理失败，保留状态。" | tee -a "$LOG_FILE"
            return 1
        fi
        if rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已清理本脚本旧 TBF。" | tee -a "$LOG_FILE"
            return 0
        fi
        "$TC_BIN" qdisc replace dev "$state_interface" root tbf rate "${state_speed}kbit" \
            burst 32kbit latency 400ms 2>/dev/null || true
        return 1
    fi

    if [ "$state_schema" != "$TC_STATE_SCHEMA" ] || [ "$state_provider" != "$TC_STATE_PROVIDER" ] ||
       ! [[ "$state_speed" =~ ^[1-9][0-9]*$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 状态格式或归属无效，未修改 qdisc。" | tee -a "$LOG_FILE"
        return 1
    fi

    if [ "$(tc_state_value IFB_INTERFACE)" = ifb0 ] &&
       ! ip -j -d link show dev ifb0 >/dev/null 2>&1 &&
       { [ -z "$qdisc_line" ] || is_default_qdisc_line "$qdisc_line"; }; then
        # Dog 已清空物理 root 并删除 IFB；此时 IFB 已经完成清理，允许撤销 NTC 残留状态。
        ifb_device=""
    elif ! ifb_device=$(tc_dog_ifb_device "$state_interface" allow-missing); then
        echo "$reason：Dog 入向层级无法安全验证，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    fi
    if [ -n "$ifb_device" ] && ! ifb_snapshot=$(tc_base_class_snapshot "$ifb_device"); then
        return 1
    fi

    if is_default_qdisc_line "$qdisc_line"; then
        if tc_update_dog_ifb "$state_interface" "$ifb_device" "$TC_PARENT_RATE" allow-missing &&
           rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB 已不存在，仅清理本脚本状态。" | tee -a "$LOG_FILE"
            return 0
        fi
        if [ -n "$ifb_device" ]; then
            tc_restore_base_snapshot "$ifb_device" "$ifb_snapshot" ||
                echo "$reason：IFB 回滚失败，请立即检查。" | tee -a "$LOG_FILE"
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB 已不存在，但状态文件删除失败。" | tee -a "$LOG_FILE"
        return 1
    fi
    tc_root_is_unified_compatible "$state_interface"
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 层级查询失败，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    fi
    if [ "$query_status" -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB 与本脚本状态不一致，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    fi
    restore_parent_rate="${state_speed}kbit"
    tc_verify_unified_hierarchy "$state_interface" "${state_speed}kbit"
    verify_status=$?
    if [ "$verify_status" -eq 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 层级查询失败，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    elif [ "$verify_status" -ne 0 ]; then
        local disabled_status=0
        trafficcop_config_is_disabled || disabled_status=$?
        if [ "$disabled_status" -eq 0 ] &&
           tc_verify_unified_hierarchy "$state_interface" "$TC_PARENT_RATE"; then
            restore_parent_rate="$TC_PARENT_RATE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB 与本脚本状态不一致，保留规则和状态。" | tee -a "$LOG_FILE"
            return 1
        fi
    fi

    tc_has_other_consumers "$state_interface"
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：无法确认其他 TC 使用者，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    elif [ "$query_status" -eq 0 ]; then
        if { [ "$restore_parent_rate" = "$TC_PARENT_RATE" ] ||
             { tc_replace_base_classes "$state_interface" "$TC_PARENT_RATE" &&
               tc_verify_unified_hierarchy "$state_interface" "$TC_PARENT_RATE"; }; } &&
           tc_update_dog_ifb "$state_interface" "$ifb_device" "$TC_PARENT_RATE" allow-missing &&
           rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已撤销整机上限，现有端口子类、过滤器和入向 redirect 保持不变。" | tee -a "$LOG_FILE"
            return 0
        fi
        if tc_replace_base_classes "$state_interface" "$restore_parent_rate" >/dev/null 2>&1 &&
           tc_verify_unified_hierarchy "$state_interface" "$restore_parent_rate"; then
            rollback_ok=true
        fi
    else
        if ! tc_update_dog_ifb "$state_interface" "$ifb_device" "$TC_PARENT_RATE" allow-missing; then
            [ -z "$ifb_device" ] || tc_restore_base_snapshot "$ifb_device" "$ifb_snapshot" ||
                echo "$reason：IFB 回滚失败，请立即检查。" | tee -a "$LOG_FILE"
            return 1
        fi
        if ! "$TC_BIN" qdisc del dev "$state_interface" root handle 1: 2>/dev/null; then
            tc_root_is_htb_handle_one "$state_interface"
            query_status=$?
            if [ "$query_status" -ne 1 ] && [ -n "$ifb_device" ]; then
                tc_restore_base_snapshot "$ifb_device" "$ifb_snapshot" ||
                    echo "$reason：IFB 回滚失败，请立即检查。" | tee -a "$LOG_FILE"
            fi
            if [ "$query_status" -eq 2 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：root 清理后状态查询失败，保留状态。" | tee -a "$LOG_FILE"
                return 1
            elif [ "$query_status" -eq 0 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB root 清理失败，保留状态。" | tee -a "$LOG_FILE"
                return 1
            fi
        fi
        if rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已清理仅由 TrafficCop 使用的统一 HTB root。" | tee -a "$LOG_FILE"
            return 0
        fi
        if "$TC_BIN" qdisc replace dev "$state_interface" root handle 1: htb default 30 2>/dev/null &&
           tc_replace_base_classes "$state_interface" "$restore_parent_rate"; then
            rollback_ok=true
        fi
    fi
    if [ -n "$ifb_device" ] && ! tc_restore_base_snapshot "$ifb_device" "$ifb_snapshot"; then
        rollback_ok=false
    fi

    if $rollback_ok; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：状态文件删除失败，已恢复原整机限速。" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：状态文件删除失败且 TC 回滚失败，请立即检查。" | tee -a "$LOG_FILE"
    fi
    return 1
}

clear_owned_tc_rules() {
    local reason="$1"
    local result had_state=false
    { [ -e "$TC_STATE_FILE" ] || [ -L "$TC_STATE_FILE" ]; } && had_state=true

    if ! acquire_tc_hierarchy_lock; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：无法取得统一 TC 层级锁。" | tee -a "$LOG_FILE"
        ntc_operation_log tc-clear failure
        return 1
    fi
    clear_owned_tc_rules_locked "$reason"
    result=$?
    release_tc_hierarchy_lock
    if [ "$result" -ne 0 ]; then
        ntc_operation_log tc-clear failure
    elif $had_state; then
        ntc_operation_log tc-clear success
    fi
    return "$result"
}

# 监控健康状态（供 Telegram 判断“监控异常”）：HEALTH=ok|error|disabled，REASON 为单行摘要。
write_health_state() {
    local health="$1" reason="${2:-}" tmp_file="${HEALTH_STATE_FILE}.tmp.$$"
    reason=$(printf '%s' "$reason" | tr -d '\r' | tr '\n\t' '  ' | cut -c1-200)
    {
        printf 'HEALTH=%s\n' "$health"
        printf 'REASON=%s\n' "$reason"
        printf 'UPDATED_EPOCH=%s\n' "$(date +%s)"
    } > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$HEALTH_STATE_FILE" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
}

# 失败原因取自失败分支刚写入的最后一行日志（去掉时间戳）。
last_log_reason() {
    tail -n 1 "$LOG_FILE" 2>/dev/null | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} :? ?//'
}

write_usage_state() {
    local status="$1"
    local current_usage="$2"
    local limit_threshold="$3"
    local unit_label="$4"
    local tmp_file="${USAGE_STATE_FILE}.tmp.$$"

    {
        printf 'STATUS=%s\n' "$status"
        printf 'PERIOD_START=%s\n' "$(get_period_start_date)"
        printf 'PERIOD_END=%s\n' "$(get_period_end_date)"
        printf 'USAGE=%s\n' "$current_usage"
        printf 'TRAFFIC_LIMIT=%s\n' "$TRAFFIC_LIMIT"
        printf 'LIMIT_THRESHOLD=%s\n' "$limit_threshold"
        printf 'UNIT=%s\n' "$unit_label"
        printf 'UPDATED_EPOCH=%s\n' "$(date +%s)"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$USAGE_STATE_FILE" || { rm -f "$tmp_file"; return 1; }
}

# 系统里是否有待执行的计划关机。systemd-logind 安排的关机会写 /run/systemd/shutdown/scheduled（取消时删除），
# 各个 systemd 版本都有；shutdown --show 要 systemd 250 起才有，logind 的计划关机也没有常驻进程，
# 只看 --show 或 pgrep 会漏掉它（monitor 会每分钟重新安排关机，暂停/停用会误删 NTC 的关机记录），所以先看这个文件。
has_pending_shutdown() {
    [ ! -e "${SYSTEMD_SHUTDOWN_SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}" ] || return 0
    if shutdown --help 2>&1 | grep -q -- '--show'; then
        shutdown --show >/dev/null 2>&1
    elif command_exists pgrep; then
        pgrep -x shutdown >/dev/null 2>&1
    else
        return 1
    fi
}

shutdown_task_token_from_state() {
    local task_token
    task_token=$(shutdown_state_value TASK_TOKEN)
    [[ "$task_token" =~ ^trafficcop-lite-[0-9A-Za-z-]{8,80}$ ]] || return 1
    printf '%s\n' "$task_token"
}

pending_shutdown_matches_owned_state() {
    local task_token wall_state
    has_pending_shutdown || return 1
    task_token=$(shutdown_task_token_from_state) || return 1

    if command_exists busctl; then
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

new_shutdown_task_token() {
    local random_id
    random_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    if ! [[ "$random_id" =~ ^[0-9A-Fa-f-]{8,64}$ ]]; then
        random_id="$(date +%s)-${BASHPID:-$$}-${RANDOM}"
    fi
    printf 'trafficcop-lite-%s\n' "$random_id"
}

write_shutdown_state() {
    local period_start boot_id task_token
    local tmp_file="${SHUTDOWN_STATE_FILE}.tmp.$$"

    period_start=$(get_period_start_date)
    boot_id=$(current_boot_id)
    task_token=$(new_shutdown_task_token) || return 1
    [[ "$period_start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [ -n "$boot_id" ] || return 1

    {
        printf 'PERIOD_START=%s\n' "$period_start"
        printf 'BOOT_ID=%s\n' "$boot_id"
        printf 'TASK_TOKEN=%s\n' "$task_token"
        printf 'SCHEDULED_EPOCH=%s\n' "$(date +%s)"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$SHUTDOWN_STATE_FILE" || return 1
    SHUTDOWN_TASK_TOKEN="$task_token"
}

shutdown_reboot_guard_active() {
    local state_period state_boot current_period boot_id

    [ -f "$SHUTDOWN_STATE_FILE" ] || return 1
    state_period=$(shutdown_state_value "PERIOD_START")
    state_boot=$(shutdown_state_value "BOOT_ID")
    current_period=$(get_period_start_date)
    boot_id=$(current_boot_id)
    if [ -z "$state_period" ] || [ -z "$state_boot" ] || [ -z "$boot_id" ]; then
        return 2
    fi
    if [ "$state_period" != "$current_period" ]; then
        rm -f "$SHUTDOWN_STATE_FILE"
        return 1
    fi
    if [ -n "$state_boot" ] && [ -n "$boot_id" ] && [ "$state_boot" != "$boot_id" ]; then
        if ! write_enforcement_state "paused" "0" "shutdown_reboot"; then
            return 2
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到关机限制后的系统重启；同一周期已自动暂停再次关机，等待用户手动恢复。" | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

ENFORCEMENT_GUARD_MODE=""
ENFORCEMENT_GUARD_REASON=""
ENFORCEMENT_GUARD_REMAINING=0

enforcement_guard_active() {
    local mode until_epoch reason now

    ENFORCEMENT_GUARD_MODE=""
    ENFORCEMENT_GUARD_REASON=""
    ENFORCEMENT_GUARD_REMAINING=0
    [ -f "$ENFORCEMENT_STATE_FILE" ] || return 1
    mode=$(enforcement_state_value "MODE")
    until_epoch=$(enforcement_state_value "UNTIL_EPOCH")
    reason=$(enforcement_state_value "REASON")
    case "$mode" in
        paused)
            ENFORCEMENT_GUARD_MODE="paused"
            ENFORCEMENT_GUARD_REASON="$reason"
            return 0
            ;;
        grace)
            if ! [[ "$until_epoch" =~ ^[0-9]+$ ]]; then
                rm -f "$ENFORCEMENT_STATE_FILE"
                return 1
            fi
            now=$(date +%s)
            if [ "$now" -ge "$until_epoch" ]; then
                rm -f "$ENFORCEMENT_STATE_FILE"
                return 1
            fi
            ENFORCEMENT_GUARD_MODE="grace"
            ENFORCEMENT_GUARD_REASON="$reason"
            ENFORCEMENT_GUARD_REMAINING=$(( (until_epoch - now + 59) / 60 ))
            return 0
            ;;
        *)
            rm -f "$ENFORCEMENT_STATE_FILE"
            return 1
            ;;
    esac
}

owned_tc_limit_active() {
    local state_interface qdisc_line state_speed state_provider state_schema
    local query_status

    [ -f "$TC_STATE_FILE" ] || return 1
    state_interface=$(tc_state_interface)
    [ "$state_interface" = "$MAIN_INTERFACE" ] || return 1
    state_provider=$(tc_state_value PROVIDER)
    state_schema=$(tc_state_value SCHEMA)
    state_speed=$(tc_state_value LIMIT_SPEED)
    [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] || return 1
    qdisc_line=$(tc_root_qdisc "$state_interface")
    query_status=$?
    [ "$query_status" -eq 0 ] || return "$query_status"
    if [ "$state_schema" = "$TC_STATE_SCHEMA" ] && [ "$state_provider" = "$TC_STATE_PROVIDER" ]; then
        tc_root_is_unified_compatible "$state_interface"
        query_status=$?
        [ "$query_status" -eq 0 ] || return "$query_status"
        tc_verify_unified_hierarchy "$state_interface" "${state_speed}kbit" &&
            tc_verify_dog_ifb "$state_interface" "${state_speed}kbit"
        return $?
    fi
    tc_legacy_tbf_is_owned "$state_interface" "$qdisc_line"
}

TC_BOOT_GRACE_REMAINING=0

# 只看开机时长的开机宽限判断（不读 TC），开机自动恢复与每分钟的限速判断共用。
# 宽限内返回 0，并把剩余分钟数写入 TC_BOOT_GRACE_REMAINING。
boot_grace_window_active() {
    local grace_minutes uptime_seconds grace_seconds

    TC_BOOT_GRACE_REMAINING=0
    grace_minutes="${TC_BOOT_GRACE_MINUTES:-10}"
    [[ "$grace_minutes" =~ ^[0-9]{1,4}$ ]] || grace_minutes=10
    grace_minutes=$((10#$grace_minutes))
    [ "$grace_minutes" -le 1440 ] || grace_minutes=10
    [ "$grace_minutes" -gt 0 ] || return 1
    uptime_seconds=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null) || return 1
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || return 1
    grace_seconds=$((grace_minutes * 60))
    [ "$uptime_seconds" -lt "$grace_seconds" ] || return 1
    TC_BOOT_GRACE_REMAINING=$(( (grace_seconds - uptime_seconds + 59) / 60 ))
    return 0
}

tc_boot_grace_active() {
    boot_grace_window_active || return 1
    # 限速已经生效（例如宽限设置得比上次开机时长还长）就不再“宽限”。
    if owned_tc_limit_active; then
        TC_BOOT_GRACE_REMAINING=0
        return 1
    fi
    return 0
}


# 修改 check_and_limit_traffic 函数
check_and_limit_traffic() {
    local current_usage limit_threshold unit_label shutdown_guard_status comparison_status
    local limit_reached=false
    if [ "${DISABLED:-false}" = "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 监控已停用，跳过限速判断。" | tee -a "$LOG_FILE"
        return 0
    fi
    [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && unit_label="GB" || unit_label="GiB"

    if ! current_usage=$(get_traffic_usage); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法可靠读取当前流量，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
        return 1
    fi

    if ! limit_threshold=$(printf '%s - %s\n' "$TRAFFIC_LIMIT" "$TRAFFIC_TOLERANCE" | bc 2>/dev/null); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法计算流量阈值，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
        return 1
    fi
    case "$limit_threshold" in
        .*) limit_threshold="0$limit_threshold" ;;
    esac
    if ! is_decimal "$limit_threshold"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量阈值计算结果无效，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
        return 1
    fi

    compare_decimal "$limit_threshold" "0" "gt"
    comparison_status=$?
    case "$comparison_status" in
        0) ;;
        1)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到配置异常：限制阈值必须大于 0 $unit_label，本轮跳过限速判断" | tee -a "$LOG_FILE"
            return 1
            ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法校验流量阈值，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
            return 1
            ;;
    esac
    if ! is_decimal "$current_usage"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量格式无效，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
        return 1
    fi

    compare_decimal "$current_usage" "$limit_threshold" "ge"
    comparison_status=$?
    case "$comparison_status" in
        0) limit_reached=true ;;
        1) limit_reached=false ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法比较当前流量与阈值，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
            return 1
            ;;
    esac
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage $unit_label，限制流量: $limit_threshold $unit_label" | tee -a "$LOG_FILE"
    
    if $limit_reached; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制" | tee -a "$LOG_FILE"
        if [ "$LIMIT_MODE" = "shutdown" ]; then
            if [ -f "$TC_STATE_FILE" ] && ! clear_owned_tc_rules "关机模式不保留 TC 限速"; then
                return 1
            fi
            shutdown_reboot_guard_active
            shutdown_guard_status=$?
            if [ "$shutdown_guard_status" -eq 2 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 无法写入关机重启保护状态，本轮拒绝再次关机。" | tee -a "$LOG_FILE"
                return 1
            fi
        fi
        if enforcement_guard_active; then
            if [ "$ENFORCEMENT_GUARD_MODE" = "grace" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 当前处于执行宽限期，剩余约 $ENFORCEMENT_GUARD_REMAINING 分钟；本轮只统计，不执行限制。" | tee -a "$LOG_FILE"
                write_usage_state "grace" "$current_usage" "$limit_threshold" "$unit_label" || return 1
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 限制执行已暂停（原因：${ENFORCEMENT_GUARD_REASON:-manual}）；本轮只统计，不执行限制。" | tee -a "$LOG_FILE"
                write_usage_state "paused" "$current_usage" "$limit_threshold" "$unit_label" || return 1
            fi
            return 0
        fi
        if [ "$LIMIT_MODE" = "tc" ]; then
            if tc_boot_grace_active; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 系统仍在开机限速宽限期，剩余约 $TC_BOOT_GRACE_REMAINING 分钟；暂不下发 TC 限速。" | tee -a "$LOG_FILE"
                write_usage_state "grace" "$current_usage" "$limit_threshold" "$unit_label" || return 1
                return 0
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') 使用 TC 模式限速" | tee -a "$LOG_FILE"
            local safe_limit_speed="${LIMIT_SPEED:-20}"
            if ! [[ "$safe_limit_speed" =~ ^[1-9][0-9]*$ ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到限速值异常：$safe_limit_speed，本轮拒绝执行 TC 限速" | tee -a "$LOG_FILE"
                return 1
            fi
            if ! apply_tc_limit "$safe_limit_speed"; then
                return 1
            fi
            write_usage_state "limited" "$current_usage" "$limit_threshold" "$unit_label" || return 1
        elif [ "$LIMIT_MODE" = "shutdown" ]; then
            if pending_shutdown_matches_owned_state; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制，本脚本已提交计划关机，未重复提交或覆盖" | tee -a "$LOG_FILE"
            elif has_pending_shutdown; then
                # 存在非本脚本提交的计划关机（例如运维手动 shutdown）。按既有设计不覆盖他人计划，
                # 但也不能把这次动作记成自己的，否则状态文件与通知会谎报关机来源。
                # 注意：新状态值 shutdown_external 必须同步存在于 trafficcop-lite-telegram.sh 的
                # read_current_traffic_state 允许列表、状态显示映射与通知状态机中。
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制；检测到非本脚本提交的计划关机，按设计不覆盖，本轮不提交自己的关机" | tee -a "$LOG_FILE"
                write_usage_state "shutdown_external" "$current_usage" "$limit_threshold" "$unit_label" || return 1
                return 0
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制，系统将在 1 分钟后关机" | tee -a "$LOG_FILE"
                if ! write_shutdown_state; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 无法预写关机保护状态，本轮拒绝提交计划关机" | tee -a "$LOG_FILE"
                    return 1
                fi
                if ! shutdown -h +1 "TrafficCop-Lite[$SHUTDOWN_TASK_TOKEN] 流量超出限制，系统将在 1 分钟后关机"; then
                    if has_pending_shutdown; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') 关机命令返回失败但仍检测到计划任务，已保留归属状态供安全清理" | tee -a "$LOG_FILE"
                    elif ! rm -f "$SHUTDOWN_STATE_FILE"; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') 计划关机失败，且无法清理预写状态；下轮将继续安全核验" | tee -a "$LOG_FILE"
                    fi
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 计划关机失败" | tee -a "$LOG_FILE"
                    return 1
                fi
            fi
            write_usage_state "shutdown" "$current_usage" "$limit_threshold" "$unit_label" || return 1
        fi
    else
        if ! clear_owned_tc_rules "流量正常"; then
            return 1
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量正常，已完成限速状态检查" | tee -a "$LOG_FILE"
        write_usage_state "normal" "$current_usage" "$limit_threshold" "$unit_label" || return 1
    fi
}


# 检查是否需要重置限制
check_reset_limit() {
    local period_start last_reset_period tmp_file enforcement_reason

    period_start=$(get_period_start_date)
    last_reset_period=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)

    if [ "$last_reset_period" = "$period_start" ]; then
        return 0
    fi

    if ! clear_owned_shutdown_schedule; then
        return 1
    fi
    if [ -n "$last_reset_period" ]; then
        if ! clear_owned_tc_rules "新的流量周期开始"; then
            return 1
        fi
    fi
    rm -f "$USAGE_STATE_FILE"
    enforcement_reason=$(enforcement_state_value "REASON")
    if [ "$enforcement_reason" = "shutdown_reboot" ]; then
        rm -f "$ENFORCEMENT_STATE_FILE"
    fi

    tmp_file="${PERIOD_STATE_FILE}.tmp.$$"
    printf '%s\n' "$period_start" > "$tmp_file" || return 1
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$PERIOD_STATE_FILE" || { rm -f "$tmp_file"; return 1; }
    if [ -n "$last_reset_period" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到新的流量周期，已重置限制"| tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 已初始化当前流量周期状态"| tee -a "$LOG_FILE"
    fi
    return 0
}

resolve_tc_self_check_interface() {
    local requested_interface="${1:-}"
    local configured_interface="" state_interface="" detected_interface=""
    if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
        tc_file_is_secure "$CONFIG_FILE" || return 1
        configured_interface=$(tc_file_optional_unique_value "$CONFIG_FILE" MAIN_INTERFACE) || return 1
    fi

    if [ -n "$requested_interface" ]; then
        printf '%s\n' "$requested_interface"
        return 0
    fi
    state_interface=$(tc_state_interface)
    if [ -n "$configured_interface" ] && [ -n "$state_interface" ] &&
       [ "$configured_interface" != "$state_interface" ]; then
        return 1
    fi
    if [ -n "$configured_interface" ]; then
        printf '%s\n' "$configured_interface"
        return 0
    fi
    if [ -n "$state_interface" ]; then
        printf '%s\n' "$state_interface"
        return 0
    fi
    detected_interface=$(ip route show default 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); exit } }')
    [ -n "$detected_interface" ] || return 1
    printf '%s\n' "$detected_interface"
}

# 这是显式接管入口；普通 cron 的 apply_tc_limit 仍会对外部 root fail-closed。
# --auto 只恢复已有 NTC 状态，--manual 还允许在 TC 模式下清除首次发现的冲突。
recover_owned_tc_hierarchy() {
    local mode="${1:---manual}"
    case "$mode" in
        --auto|--manual) ;;
        *)
            echo "不支持的 TC 恢复模式: $mode" >&2
            ntc_operation_log tc-recover failure
            return 2
            ;;
    esac

    local disabled_status=0
    trafficcop_config_is_disabled || disabled_status=$?
    case "$disabled_status" in
        0)
            if [ "$mode" = "--auto" ]; then
                echo "TrafficCop 当前已禁用，不会自动恢复残留的整机上限。"
                return 0
            fi
            if [ -e "$TC_STATE_FILE" ]; then
                clear_owned_tc_rules "TrafficCop 已禁用"
                return $?
            fi
            echo "TrafficCop 当前已禁用，没有需要恢复的 TC 规则。"
            return 0
            ;;
        1) ;;
        *)
            echo "TrafficCop 配置无法安全解释，拒绝修改 TC。" >&2
            ntc_operation_log tc-recover failure
            return 1
            ;;
    esac

    [ -n "$TC_BIN" ] || {
        echo "未找到系统 tc 命令，无法恢复。" >&2
        ntc_operation_log tc-recover failure
        return 1
    }
    [[ "${MAIN_INTERFACE:-}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || {
        echo "TrafficCop 配置中的网卡无效，拒绝修改 TC。" >&2
        ntc_operation_log tc-recover failure
        return 1
    }

    local state_expected=false
    local state_interface=""
    local state_schema=""
    local state_provider=""
    local state_speed=""
    if [ -e "$TC_STATE_FILE" ]; then
        if ! tc_state_file_is_interpretable; then
            echo "TrafficCop TC 状态文件无法安全解释，拒绝删除 qdisc。" >&2
            ntc_operation_log tc-recover failure
            return 1
        fi
        state_interface=$(tc_state_interface)
        state_schema=$(tc_state_value SCHEMA)
        state_provider=$(tc_state_value PROVIDER)
        state_speed=$(tc_state_value LIMIT_SPEED)
        if [ "$state_interface" != "$MAIN_INTERFACE" ] ||
           [ "$state_schema" != "$TC_STATE_SCHEMA" ] ||
           [ "$state_provider" != "$TC_STATE_PROVIDER" ] ||
           ! [[ "$state_speed" =~ ^[1-9][0-9]*$ ]]; then
            echo "TrafficCop TC 状态文件无法安全解释，拒绝删除 qdisc。" >&2
            ntc_operation_log tc-recover failure
            return 1
        fi
        state_expected=true
    fi

    # 开机自动恢复时若仍在开机限速宽限期内，就不重建 NTC 的整机上限，只清理它的状态（2.0）。
    # Dog 的端口限速由共享 runner 先行重建，不受影响；宽限结束后每分钟的检查会重新限速。
    if [ "$mode" = "--auto" ] && [ "$state_expected" = "true" ] && [ "${LIMIT_MODE:-}" = "tc" ] &&
       boot_grace_window_active; then
        echo "仍在开机限速宽限期（剩余约 $TC_BOOT_GRACE_REMAINING 分钟），暂不恢复整机限速；宽限结束后每分钟的检查会重新限速。"
        clear_owned_tc_rules "开机宽限期内不恢复整机限速"
        return $?
    fi

    if [ "${LIMIT_MODE:-}" != "tc" ] && [ "$state_expected" = "false" ]; then
        echo "TrafficCop 当前不是 TC 限速模式，没有需要恢复的 TC 规则。"
        return 0
    fi
    if [ "$mode" = "--auto" ] && [ "$state_expected" = "false" ]; then
        echo "当前没有需要自动恢复的 TrafficCop TC 状态。"
        return 0
    fi

    if ! acquire_tc_hierarchy_lock; then
        echo "无法取得统一 TC 层级锁，未修改 qdisc。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi

    local qdisc_line query_status unified_status verify_status dog_status
    qdisc_line=$(tc_root_qdisc "$MAIN_INTERFACE")
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        release_tc_hierarchy_lock
        echo "无法读取当前 root qdisc，未作任何 TC 修改。" >&2
        ntc_operation_log tc-recover failure
        return 1
    elif [ "$query_status" -eq 1 ]; then
        qdisc_line=""
    fi
    tc_root_is_unified_compatible "$MAIN_INTERFACE"
    unified_status=$?
    if [ "$unified_status" -eq 2 ]; then
        release_tc_hierarchy_lock
        echo "TC 层级查询失败，未作任何 TC 修改。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi
    if [ "$state_expected" = "true" ] && [ "$unified_status" -eq 0 ]; then
        tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${state_speed}kbit"
        verify_status=$?
        if [ "$verify_status" -eq 2 ]; then
            release_tc_hierarchy_lock
            echo "TC 层级查询失败，未作任何 TC 修改。" >&2
            ntc_operation_log tc-recover failure
            return 1
        fi
        dog_status=0
        if [ -e "$DOG_CONFIG_FILE" ] || [ -L "$DOG_CONFIG_FILE" ]; then
            dog_live_objects_match_config "$MAIN_INTERFACE" || dog_status=$?
        fi
        if [ "$dog_status" -eq 2 ]; then
            release_tc_hierarchy_lock
            echo "Dog TC 层级查询失败，未作任何 TC 修改。" >&2
            ntc_operation_log tc-recover failure
            return 1
        elif [ "$dog_status" -eq 0 ]; then
            local ifb_device="" ifb_status=0
            ifb_device=$(tc_dog_ifb_device "$MAIN_INTERFACE") || ifb_status=$?
            if [ "$ifb_status" -ne 0 ]; then
                release_tc_hierarchy_lock
                echo "Dog 入向层级不完整或归属无法验证，请先由共享入口恢复 Dog。" >&2
                ntc_operation_log tc-recover failure
                return 1
            fi
            tc_verify_dog_ifb "$MAIN_INTERFACE" "${state_speed}kbit"
            ifb_status=$?
            if [ "$ifb_status" -eq 2 ]; then
                release_tc_hierarchy_lock
                ntc_operation_log tc-recover failure
                return 1
            elif [ "$verify_status" -eq 0 ] && [ "$ifb_status" -eq 0 ] &&
                 [ "$(tc_state_value IFB_INTERFACE)" = "$ifb_device" ]; then
                release_tc_hierarchy_lock
                echo "Dog/NTC TC 规则完整，无需重建。"
                return 0
            fi
            # 父速率漂移无需删树；释放锁后重用带两侧回滚的普通协调事务。
            release_tc_hierarchy_lock
            apply_tc_limit "$state_speed"
            local repair_status=$?
            if [ "$repair_status" -eq 0 ]; then ntc_operation_log tc-recover success; else ntc_operation_log tc-recover failure; fi
            return "$repair_status"
        fi
    fi

    # Dog 已恢复统一层级但 NTC 状态尚未建立时，不删树，交给现有全局限速逻辑原地协调。
    if [ "$state_expected" = "false" ] && [ "$unified_status" -eq 0 ]; then
        release_tc_hierarchy_lock
        check_and_limit_traffic
        return $?
    fi

    if [ "$mode" = "--auto" ] && [ "$unified_status" -ne 0 ] &&
       ! is_default_qdisc_line "$qdisc_line"; then
        release_tc_hierarchy_lock
        echo "自动恢复检测到外部或未知 root qdisc，拒绝接管；请使用 --manual 明确确认。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi

    # 其余情况下只要仍配置了 Dog 端口类，就必须由共享入口先恢复整棵树。
    local dog_classes=""
    if [ -e "$DOG_CONFIG_FILE" ] || [ -L "$DOG_CONFIG_FILE" ]; then
        if ! dog_classes=$(dog_configured_class_ids 2>/dev/null); then
            release_tc_hierarchy_lock
            echo "Dog 配置存在但无法安全解析，拒绝删除 qdisc。" >&2
            ntc_operation_log tc-recover failure
            return 1
        fi
    fi
    if [ -n "$dog_classes" ]; then
        release_tc_hierarchy_lock
        echo "检测到 Dog 端口限速配置，请使用共享 traffic-tools-tc-recovery 服务恢复。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi
    # 即使 Dog 配置/清单/owner 文件缺失，只要 htb 1: 树里还有 1:1、1:30 之外的类或任何过滤器，
    # 就说明另有使用者（通常是 Dog），删除 root 会连带删掉它们，必须拒绝。
    local consumer_status=1
    if tc_root_is_htb_handle_one "$MAIN_INTERFACE"; then
        tc_has_other_consumers "$MAIN_INTERFACE"
        consumer_status=$?
    fi
    if [ "$consumer_status" -ne 1 ]; then
        release_tc_hierarchy_lock
        echo "当前 HTB 树中还有 TrafficCop 之外的分类或过滤器（可能属于 Dog），拒绝删除 root qdisc；请先恢复或清理对应程序的规则。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi

    local recovery_ifb="" recovery_ifb_snapshot=""
    if ! recovery_ifb=$(tc_dog_ifb_device "$MAIN_INTERFACE") ||
       { [ -n "$recovery_ifb" ] && ! recovery_ifb_snapshot=$(tc_base_class_snapshot "$recovery_ifb"); }; then
        release_tc_hierarchy_lock
        echo "Dog 入向层级无法安全验证，未删除当前 qdisc。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi
    local prepared_state="${TC_STATE_FILE}.recovery.$$"
    if [ "$state_expected" = "true" ] &&
       ! write_tc_state "$MAIN_INTERFACE" "$state_speed" "" "$prepared_state" "$recovery_ifb"; then
        release_tc_hierarchy_lock
        echo "无法预写 TrafficCop TC 恢复状态，未删除当前 qdisc。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi

    if ! is_default_qdisc_line "$qdisc_line" &&
       ! "$TC_BIN" qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null; then
        rm -f "$prepared_state"
        release_tc_hierarchy_lock
        echo "无法删除当前冲突 root qdisc，TrafficCop 规则未重建。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi
    if [ -z "$recovery_ifb" ]; then rm -f "$DOG_TC_OWNER_FILE"; fi

    if [ "$state_expected" = "true" ]; then
        if "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root handle 1: htb default 30 2>/dev/null &&
           tc_replace_base_classes "$MAIN_INTERFACE" "${state_speed}kbit" &&
           tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${state_speed}kbit" &&
           tc_update_dog_ifb "$MAIN_INTERFACE" "$recovery_ifb" "${state_speed}kbit" &&
           mv -f "$prepared_state" "$TC_STATE_FILE"; then
            release_tc_hierarchy_lock
            echo "TrafficCop 统一 HTB 已按现有状态重建。"
            ntc_operation_log tc-recover success
            return 0
        fi
        local recovery_rollback_ok=true
        if [ -n "$recovery_ifb" ]; then
            tc_restore_base_snapshot "$recovery_ifb" "$recovery_ifb_snapshot" || recovery_rollback_ok=false
        fi
        if ! "$TC_BIN" qdisc del dev "$MAIN_INTERFACE" root handle 1: 2>/dev/null; then
            tc_root_is_htb_handle_one "$MAIN_INTERFACE"
            query_status=$?
            [ "$query_status" -eq 1 ] || recovery_rollback_ok=false
        fi
        if $recovery_rollback_ok; then
            rm -f "$prepared_state"
        else
            echo "TC 恢复事务回滚失败；预写状态保留在 $prepared_state。" >&2
        fi
        release_tc_hierarchy_lock
        echo "冲突 qdisc 已清除，但 TrafficCop 统一 HTB 未能完整重建。" >&2
        ntc_operation_log tc-recover failure
        return 1
    fi

    release_tc_hierarchy_lock
    # 首次冲突没有旧状态时，删除完成后重新计算流量；只有确实超额才创建 NTC 层级。
    check_and_limit_traffic
    local recovery_status=$?
    if [ "$recovery_status" -eq 0 ]; then ntc_operation_log tc-recover success; else ntc_operation_log tc-recover failure; fi
    return "$recovery_status"
}

tc_self_check() {
    local interface qdisc_line state_speed state_schema result=1
    local query_status verify_status default_status default_line disabled_status dog_status
    local success_message="" expected_ifb_rate="${TC_PARENT_RATE:-100gbit}"

    if [ -z "$TC_BIN" ]; then
        echo "TC_SELF_CHECK=ERROR REASON=tc-not-found"
        return 1
    fi
    if ! interface=$(resolve_tc_self_check_interface "${1:-}") ||
       ! [[ "$interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        echo "TC_SELF_CHECK=ERROR REASON=interface-unresolved"
        return 1
    fi
    if ! acquire_tc_hierarchy_lock; then
        echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=lock-timeout"
        return 1
    fi

    disabled_status=0
    trafficcop_config_is_disabled || disabled_status=$?
    if [ "$disabled_status" -eq 2 ]; then
        echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=trafficcop-config-invalid"
        release_tc_hierarchy_lock
        return 1
    fi
    if { [ -e "$TC_STATE_FILE" ] || [ -L "$TC_STATE_FILE" ]; } && ! tc_state_file_is_interpretable; then
        echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=trafficcop-state-invalid"
        release_tc_hierarchy_lock
        return 1
    fi
    if [ "$disabled_status" -eq 0 ] && [ -e "$TC_STATE_FILE" ]; then
        echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=disabled-trafficcop-state-remains ACTION=manual-rebuild"
        release_tc_hierarchy_lock
        return 1
    fi

    qdisc_line=$(tc_root_qdisc "$interface")
    query_status=$?
    if [ "$query_status" -eq 2 ]; then
        echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
        release_tc_hierarchy_lock
        return 1
    elif [ "$query_status" -eq 1 ]; then
        qdisc_line=""
    fi
    if is_default_qdisc_line "$qdisc_line"; then
        if [ -f "$TC_STATE_FILE" ]; then
            echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=state-without-unified-htb"
        else
            success_message="TC_SELF_CHECK=OK INTERFACE=$interface MODEL=absent"
            result=0
        fi
    elif printf '%s\n' "$qdisc_line" | grep -q ' tbf '; then
        if tc_legacy_tbf_is_owned "$interface" "$qdisc_line"; then
            success_message="TC_SELF_CHECK=OK INTERFACE=$interface MODEL=legacy-trafficcop-tbf ACTION=migrate-on-next-apply"
            result=0
        else
            echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=foreign-tbf"
        fi
    else
        tc_root_is_unified_compatible "$interface"
        query_status=$?
        if [ "$query_status" -eq 2 ]; then
            echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
        elif [ "$query_status" -ne 0 ]; then
            echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=foreign-root-qdisc"
        else
            tc_default_class_is_safe "$interface"
            default_status=$?
            if [ "$default_status" -eq 2 ]; then
                echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
            elif [ "$default_status" -ne 0 ]; then
                echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=reserved-class-1:30"
            elif tc_state_is_unified_for_interface "$interface"; then
                state_speed=$(tc_state_value LIMIT_SPEED)
                if [[ "$state_speed" =~ ^[1-9][0-9]*$ ]]; then
                    tc_verify_unified_hierarchy "$interface" "${state_speed}kbit"
                    verify_status=$?
                else
                    verify_status=1
                fi
                if [ "$verify_status" -eq 2 ]; then
                    echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
                elif [ "$verify_status" -eq 0 ]; then
                    dog_status=0
                    if [ -e "$DOG_CONFIG_FILE" ] || [ -L "$DOG_CONFIG_FILE" ]; then
                        dog_live_objects_match_config "$interface" || dog_status=$?
                    fi
                    if [ "$dog_status" -eq 2 ]; then
                        echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
                    elif [ "$dog_status" -ne 0 ]; then
                        echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=dog-port-rules-mismatch"
                    else
                        success_message="TC_SELF_CHECK=OK INTERFACE=$interface MODEL=$TC_STATE_SCHEMA OWNER=trafficcop-lite"
                        expected_ifb_rate="${state_speed}kbit"
                        result=0
                    fi
                else
                    echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=trafficcop-parent-mismatch"
                fi
            elif [ -f "$TC_STATE_FILE" ] && [ "$(tc_state_interface)" = "$interface" ]; then
                state_schema=$(tc_state_value SCHEMA)
                if [ -z "$state_schema" ]; then
                    echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=legacy-trafficcop-state-with-unified-htb ACTION=reapply-trafficcop-limit"
                else
                    echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=trafficcop-state-not-unified"
                fi
            else
                default_line=$(tc_class_line "$interface" "1:30")
                query_status=$?
                if [ "$query_status" -eq 2 ]; then
                    echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
                elif [ "$query_status" -eq 0 ] && [ -n "$default_line" ]; then
                    success_message="TC_SELF_CHECK=OK INTERFACE=$interface MODEL=$TC_STATE_SCHEMA OWNER=port-traffic-dog"
                    result=0
                else
                    success_message="TC_SELF_CHECK=OK INTERFACE=$interface MODEL=legacy-dog-htb ACTION=add-default-class-on-next-apply"
                    result=0
                fi
            fi
        fi
    fi
    if [ "$result" -eq 0 ]; then
        tc_verify_dog_ifb "$interface" "$expected_ifb_rate"
        verify_status=$?
        if [ "$verify_status" -eq 2 ]; then
            echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=tc-query-failed"
            result=1
        elif [ "$verify_status" -ne 0 ]; then
            echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=dog-ingress-mismatch"
            result=1
        else
            printf '%s\n' "$success_message"
        fi
    fi

    release_tc_hierarchy_lock
    return "$result"
}

setup_crontab() {
    local current_crontab cron_entry crontab_tmp

    if ! acquire_root_crontab_lock; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法取得 TrafficCop-Lite crontab 锁" | tee -a "$LOG_FILE"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        release_root_crontab_lock
        return 1
    fi
    cron_entry="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"

    if ! crontab_tmp="$(mktemp)"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法创建 crontab 临时文件，未作修改" | tee -a "$LOG_FILE"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" '
        index($0, script) == 0 && $0 !~ /^[[:space:]]*$/ { print }
    ' <<< "$current_crontab" > "$crontab_tmp" \
        || ! printf '%s\n' "$cron_entry" >> "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 生成 crontab 候选内容失败，未作修改" | tee -a "$LOG_FILE"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 设置失败" | tee -a "$LOG_FILE"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"

    release_root_crontab_lock
    echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 已设置，每分钟运行一次"| tee -a "$LOG_FILE"
}


# ════════════════════════════════════════════════════════════════════════════
# 2.0：日志只记事件、状态详情、配置向导与命令行
# ════════════════════════════════════════════════════════════════════════════

CONFIG_ASSUME_YES=false        # ntc config set --yes：vnStat 保留期调整与保存都不再询问
CONFIG_EXCEED_POLICY=""        # 保存时已超阈值的处理：grace:<分钟>|now|monitor；空表示当场询问
CONFIG_PARTIAL_HISTORY=ask     # vnStat 历史不足以覆盖周期起点时：ask 询问 | allow 继续 | deny 取消

# 非负小数的规范写法：去掉多余的前导零与末尾的 0（500.000 → 500，01.50 → 1.5）；不合法返回 1。
normalize_decimal() {
    local value
    value=$(ntc_decimal "${1:-}") || return 1
    if [[ "$value" == *.* ]]; then
        value="${value%"${value##*[!0]}"}"
        value="${value%.}"
    fi
    printf '%s' "$value"
}

# 提前量的默认值：限额大于 1 时为 1，否则为 0（保证默认值总小于限额）。
default_tolerance() {
    if compare_decimal "${1:-0}" 1 gt; then printf '1'; else printf '0'; fi
}

# 执行阈值 = 限额 − 提前量（用 awk 计算，不依赖 bc）。
config_threshold() {
    normalize_decimal "$(awk -v l="$TRAFFIC_LIMIT" -v t="${TRAFFIC_TOLERANCE:-0}" 'BEGIN { printf "%.6f", l - t }')"
}

# 默认路由所在网卡；没有默认路由时取第一块已启用的非回环网卡。只检测，不提问。
detect_main_interface() {
    local iface
    iface=$(ip route show default 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    if [ -z "$iface" ]; then
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{ sub(/@.*/, "", $2) } $2 != "lo" { print $2; exit }')
    fi
    [ -n "$iface" ] || return 1
    printf '%s\n' "$iface"
}

interface_exists() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] && ip link show "$1" >/dev/null 2>&1
}

# 可选的网卡（不含 lo），空格分隔。
list_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{ sub(/@.*/, "", $2) } $2 != "lo" { printf "%s%s", sep, $2; sep = " " }'
}

# 向导第 1 步：只收集答案，不改动任何东西。答案写入 MAIN_INTERFACE、TRAFFIC_* 等配置变量；
# 已有配置时每项默认取当前值。只有读到输入结束（EOF）才返回 1，输入不合法会重问。
config_wizard_collect() {
    local answer detected value default_choice unit_label tolerance_default

    ui_title "流量监控配置" "共 7 项；回车使用 [ ] 里的值，Ctrl-D 随时取消"

    detected="${MAIN_INTERFACE:-}"
    [ -n "$detected" ] || detected=$(detect_main_interface) || detected=""
    while true; do
        if [ -n "$detected" ]; then
            ui_read answer "1/7 网卡" "$detected" || return 1
        else
            ui_note "没有检测到默认路由。可用网卡：$(list_interfaces)"
            ui_read answer "1/7 网卡" || return 1
        fi
        if interface_exists "$answer"; then
            MAIN_INTERFACE="$answer"
            break
        fi
        ui_warn "网卡「${answer}」不存在。可用网卡：$(list_interfaces)"
    done

    printf '\n'
    ui_option 1 "出站" "只算上传"
    ui_option 2 "入站" "只算下载"
    ui_option 3 "出+入" "上传与下载相加"
    ui_option 4 "出入取较大" "上传、下载分别累计，取较大的一个"
    case "${TRAFFIC_MODE:-}" in
        out) default_choice=1 ;;
        in) default_choice=2 ;;
        max) default_choice=4 ;;
        *) default_choice=3 ;;
    esac
    ui_read_int value "2/7 统计方向" "$default_choice" 1 4 || return 1
    case "$value" in
        1) TRAFFIC_MODE=out ;;
        2) TRAFFIC_MODE=in ;;
        3) TRAFFIC_MODE=total ;;
        *) TRAFFIC_MODE=max ;;
    esac

    printf '\n'
    ui_option 1 "每月"
    ui_option 2 "每季度" "1/4/7/10 月"
    ui_option 3 "每年"
    case "${TRAFFIC_PERIOD:-}" in
        quarterly) default_choice=2 ;;
        yearly) default_choice=3 ;;
        *) default_choice=1 ;;
    esac
    ui_read_int value "3/7 重置周期" "$default_choice" 1 3 || return 1
    case "$value" in
        1) TRAFFIC_PERIOD=monthly ;;
        2) TRAFFIC_PERIOD=quarterly ;;
        *) TRAFFIC_PERIOD=yearly ;;
    esac
    if [ "$TRAFFIC_PERIOD" = yearly ]; then
        ui_read_int PERIOD_START_MONTH "    每年从几月开始" "${PERIOD_START_MONTH:-1}" 1 12 || return 1
    else
        PERIOD_START_MONTH=1
    fi
    ui_read_int PERIOD_START_DAY "    每期从几号开始（没有这一天的月份按月末算）" "${PERIOD_START_DAY:-1}" 1 31 || return 1

    printf '\n'
    ui_option 1 "GB" "十进制，1 GB = 1000³ 字节，服务商通常这样计"
    ui_option 2 "GiB" "二进制，1 GiB = 1024³ 字节"
    if [ "${TRAFFIC_UNIT:-decimal}" = binary ]; then default_choice=2; else default_choice=1; fi
    ui_read_int value "4/7 流量单位" "$default_choice" 1 2 || return 1
    if [ "$value" = 2 ]; then TRAFFIC_UNIT=binary; else TRAFFIC_UNIT=decimal; fi
    unit_label=$(ntc_unit_label "$TRAFFIC_UNIT")

    printf '\n'
    while true; do
        ui_read_decimal value "5/7 每期流量限额（$unit_label）" "${TRAFFIC_LIMIT:-}" || return 1
        if compare_decimal "$value" 0 gt; then
            TRAFFIC_LIMIT=$(normalize_decimal "$value")
            break
        fi
        ui_warn "限额必须大于 0。"
    done
    tolerance_default="${TRAFFIC_TOLERANCE:-$(default_tolerance "$TRAFFIC_LIMIT")}"
    while true; do
        ui_read_decimal value "6/7 提前量（$unit_label，用量达到「限额 − 提前量」就执行）" "$tolerance_default" || return 1
        if compare_decimal "$value" "$TRAFFIC_LIMIT" lt; then
            TRAFFIC_TOLERANCE=$(normalize_decimal "$value")
            break
        fi
        ui_warn "提前量必须小于限额 $TRAFFIC_LIMIT $unit_label。"
    done

    printf '\n'
    ui_option 1 "整机限速" "限速后仍能 SSH 登录处理"
    ui_option 2 "关机" "最省流量，需要到服务商面板开机"
    if [ "${LIMIT_MODE:-tc}" = shutdown ]; then default_choice=2; else default_choice=1; fi
    ui_read_int value "7/7 达到阈值后" "$default_choice" 1 2 || return 1
    if [ "$value" = 1 ]; then
        LIMIT_MODE=tc
        ui_read_int LIMIT_SPEED "    限速（kbit/s）" "${LIMIT_SPEED:-20}" 1 10000000 || return 1
        ui_read_int TC_BOOT_GRACE_MINUTES "    开机后几分钟内先不限速（防止开机即被限死；0 = 立即限速）" \
            "${TC_BOOT_GRACE_MINUTES:-10}" 0 1440 || return 1
    else
        LIMIT_MODE=shutdown
        LIMIT_SPEED="${LIMIT_SPEED:-20}"
        TC_BOOT_GRACE_MINUTES="${TC_BOOT_GRACE_MINUTES:-10}"
    fi
}

# 向导第 2 步：开始 vnStat 事务，确认 vnStat 正在统计这块网卡、日数据保留期够用、历史能覆盖周期起点。
# 任何一步失败都回滚 vnStat 事务。
config_prepare_vnstat() {
    if ! begin_initial_vnstat_transaction "$MAIN_INTERFACE"; then
        ui_err "无法开始 vnStat 配置事务，已取消本次配置；原配置未改动。"
        return 1
    fi
    if ! ensure_vnstat_runtime_config "$MAIN_INTERFACE" || ! ensure_vnstat_interface "$MAIN_INTERFACE"; then
        ui_err "vnStat 无法统计网卡 $MAIN_INTERFACE，已取消本次配置；原配置未改动。"
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        return 1
    fi
    if ! ensure_vnstat_daily_retention || ! configure_history_policy; then
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        return 1
    fi
}

# 保存时已达到新阈值：先问清楚这次怎么处理，结果写入 CONFIG_EXCEED_POLICY。EOF 返回 1。
config_ask_exceed_policy() {
    local usage="$1" threshold="$2" unit_label action value minutes
    unit_label=$(ntc_unit_label "$TRAFFIC_UNIT")
    if [ "$LIMIT_MODE" = shutdown ]; then action="关机"; else action="限速"; fi
    printf '\n'
    ui_warn "本期已用 $(ntc_num "$usage") $unit_label，已达到新的执行阈值 $(ntc_num "$threshold") $unit_label。"
    ui_note "为免保存后立刻${action}，请选择这次怎么处理："
    ui_option 1 "先宽限一段时间" "推荐"
    ui_option 2 "立即${action}"
    ui_option 3 "只统计，暂停执行" "之后在「限制执行」里恢复"
    ui_read_int value "请选择" 1 1 3 || return 1
    case "$value" in
        1)
            ui_read_int minutes "    宽限分钟数" 10 1 1440 || return 1
            CONFIG_EXCEED_POLICY="grace:$minutes"
            ;;
        2) CONFIG_EXCEED_POLICY=now ;;
        *) CONFIG_EXCEED_POLICY=monitor ;;
    esac
}

# 配置各项（向导摘要、ntc config show、修改配置菜单共用）。
config_summary_rows() {
    local unit_label
    unit_label=$(ntc_unit_label "${TRAFFIC_UNIT:-binary}")
    ui_kv "网卡" "$MAIN_INTERFACE"
    ui_kv "统计方向" "$(ntc_mode_label "$TRAFFIC_MODE")"
    ui_kv "重置周期" "$(ntc_period_label "$TRAFFIC_PERIOD" "${PERIOD_START_DAY:-1}" "${PERIOD_START_MONTH:-1}")"
    ui_kv "每期限额" "$(ntc_num "$TRAFFIC_LIMIT") $unit_label"
    ui_kv "提前量" "$(ntc_num "${TRAFFIC_TOLERANCE:-0}") $unit_label（用量达到 $(ntc_num "$(config_threshold)") $unit_label 时执行）"
    if [ "$LIMIT_MODE" = shutdown ]; then
        ui_kv "超额处理" "关机"
    else
        ui_kv "超额处理" "整机限速 ${LIMIT_SPEED:-20} kbit/s"
        if [ "${TC_BOOT_GRACE_MINUTES:-10}" = 0 ]; then
            ui_kv "开机宽限" "无（开机后立即按状态限速）"
        else
            ui_kv "开机宽限" "开机后 ${TC_BOOT_GRACE_MINUTES:-10} 分钟内不限速"
        fi
    fi
    if [ "${VNSTAT_MAX_BANDWIDTH:-0}" = 0 ]; then
        ui_kv "异常速率" "vnStat 不检查（0）"
    else
        ui_kv "异常速率" "vnStat 丢弃超过 ${VNSTAT_MAX_BANDWIDTH} Mbit/s 的读数"
    fi
    [ "${ALLOW_PARTIAL_HISTORY:-false}" != true ] || ui_kv "历史数据" "本期 vnStat 历史不完整，已确认按现有历史统计"
}

config_show_summary() {
    local usage="$1" threshold="$2" unit_label policy_text=""
    unit_label=$(ntc_unit_label "$TRAFFIC_UNIT")
    ui_title "确认配置"
    config_summary_rows
    if compare_decimal "$usage" "$threshold" ge; then
        case "$CONFIG_EXCEED_POLICY" in
            now) if [ "$LIMIT_MODE" = shutdown ]; then policy_text="保存后立即关机"; else policy_text="保存后立即限速"; fi ;;
            monitor) policy_text="保存后暂停执行，只统计" ;;
            grace:*) policy_text="保存后先宽限 ${CONFIG_EXCEED_POLICY#grace:} 分钟" ;;
        esac
        ui_kv "本期已用" "$(ntc_num "$usage") $unit_label，已达到阈值：$policy_text"
    else
        ui_kv "本期已用" "$(ntc_num "$usage") $unit_label，未达到阈值"
    fi
    printf '\n'
}

# 写进事件日志的一行配置说明。
config_oneline() {
    local unit_label action
    unit_label=$(ntc_unit_label "${TRAFFIC_UNIT:-binary}")
    if [ "$LIMIT_MODE" = shutdown ]; then action="超额关机"; else action="超额限速 ${LIMIT_SPEED:-20} kbit/s"; fi
    printf '%s %s，%s，限额 %s %s，提前量 %s %s，%s' "$MAIN_INTERFACE" "$(ntc_mode_label "$TRAFFIC_MODE")" \
        "$(ntc_period_label "$TRAFFIC_PERIOD" "${PERIOD_START_DAY:-1}" "${PERIOD_START_MONTH:-1}")" \
        "$TRAFFIC_LIMIT" "$unit_label" "${TRAFFIC_TOLERANCE:-0}" "$unit_label" "$action"
}

# 保存（向导与 ntc config set 共用）：快照 → 写配置 → 保存后的执行策略（清除旧限速与本脚本的关机计划，
# 按预设写入宽限或暂停）→ 提交 vnStat 事务。任何一步失败都回滚配置、执行策略、TC/关机状态与 vnStat。
# 调用前 vnStat 事务必须已经开始。
config_commit() {
    local config_backup="${CONFIG_FILE}.before-config.$$"
    local enforcement_backup="${ENFORCEMENT_STATE_FILE}.before-config.$$"
    local tc_backup="${TC_STATE_FILE}.before-config.$$"
    local shutdown_backup="${SHUTDOWN_STATE_FILE}.before-config.$$"
    local step="配置写入"

    CONFIG_TC_CLEAR_ATTEMPTED=false
    CONFIG_SHUTDOWN_CLEAR_ATTEMPTED=false
    if ! snapshot_monitor_config_state "$config_backup" "$enforcement_backup" \
        "$tc_backup" "$shutdown_backup"; then
        rm -f "$config_backup" "$enforcement_backup" "$tc_backup" "$shutdown_backup"
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        ui_err "无法建立修改前的快照（可能有无法确认归属的关机计划或 TC 状态），已取消保存；原配置未改动。"
        ntc_operation_log monitor-config failure
        return 1
    fi
    if write_config; then
        step="保存后的执行策略处理"
        if configure_post_save_enforcement; then
            step="vnStat 服务持久化"
            if commit_initial_vnstat_transaction; then
                rm -f "$config_backup" "$enforcement_backup" "$tc_backup" "$shutdown_backup"
                ntc_operation_log monitor-config success
                echo "$(date '+%Y-%m-%d %H:%M:%S') 监控配置已更新：$(config_oneline)" >> "$LOG_FILE"
                return 0
            fi
        fi
    fi
    if rollback_monitor_config_transaction "$config_backup" "$enforcement_backup" \
        "$tc_backup" "$shutdown_backup"; then
        ui_err "${step}失败，已恢复修改前的监控配置、执行策略与 vnStat 状态。"
    else
        ui_err "${step}失败，且无法完整恢复修改前状态；配置与运行态备份已保留，请立即检查。"
    fi
    ntc_operation_log monitor-config failure
    return 1
}

# root crontab 里是否有本脚本的 --run 任务（注释行不算）。
monitor_cron_present() {
    local cron
    cron=$(read_root_crontab_locked 2>/dev/null) || return 1
    ntc_cron_has_entry "$cron" "$SCRIPT_PATH --run"
}

# 保存之后：定时任务缺失才写入（不再每次重写 crontab），然后立即检查一轮，让主菜单马上有数据。
config_after_save() {
    if ! monitor_cron_present; then
        if setup_crontab >/dev/null; then
            ui_ok "已添加每分钟一次的检查任务。"
        else
            ui_err "定时任务写入失败：流量不会被自动检查，请稍后在 ntc 主菜单的「限制执行」里启用流量监控。"
        fi
    fi
    monitor_check_now || true
    return 0
}

# 只改 vnStat 异常速率上限：只动 vnStat 配置和本行配置，不重新评估限速、宽限或暂停。
save_vnstat_max_bandwidth() {
    local backup="${CONFIG_FILE}.before-config.$$"

    if ! begin_initial_vnstat_transaction "$MAIN_INTERFACE"; then
        ui_err "无法开始 vnStat 配置事务，未作修改。"
        return 1
    fi
    if ! cp -p "$CONFIG_FILE" "$backup"; then
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        ui_err "无法备份当前配置，未作修改。"
        return 1
    fi
    if ensure_vnstat_runtime_config "$MAIN_INTERFACE" && write_config && commit_initial_vnstat_transaction; then
        rm -f "$backup"
        ntc_operation_log monitor-config success
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnStat 异常速率上限已改为 ${VNSTAT_MAX_BANDWIDTH} Mbit/s（0 = 不检查）" >> "$LOG_FILE"
        return 0
    fi
    if restore_file_snapshot "$backup" true "$CONFIG_FILE" && rollback_initial_vnstat_transaction; then
        rm -f "$backup"
        ui_err "保存失败，已恢复原配置与 vnStat 设置。"
    else
        ui_err "保存失败，且未能完整恢复；原配置备份在 $backup。"
    fi
    ntc_operation_log monitor-config failure
    return 1
}

configure_vnstat_max_bandwidth() {
    local old="${VNSTAT_MAX_BANDWIDTH:-0}"
    ui_title "vnStat 异常速率上限" "高级"
    ui_note "vnStat 会丢弃超过这个速率的读数，用来过滤网卡计数器跳变造成的虚高流量。"
    ui_note "0 表示不检查（NTC 默认）；只在出现用量突然暴涨的误报时才需要设置。"
    printf '\n'
    if ! prompt_vnstat_max_bandwidth; then
        printf '\n'
        ui_note "已取消。"
        return 1
    fi
    if [ "$VNSTAT_MAX_BANDWIDTH" = "$old" ]; then
        ui_note "没有变化。"
        return 0
    fi
    if save_vnstat_max_bandwidth; then
        ui_ok "已保存：vnStat 异常速率上限 ${VNSTAT_MAX_BANDWIDTH} Mbit/s（0 = 不检查）。"
        return 0
    fi
    VNSTAT_MAX_BANDWIDTH="$old"
    return 1
}

# ntc config（主菜单「修改监控配置」）。
configure_menu() {
    local choice n rc=0
    # 由 ntc 主菜单调起时（NTC_MENU_PAUSE=1），不经过子菜单就结束的路径在返回前停一下，免得结果被主菜单重画盖掉；
    # 子菜单里的动作自己会停，命令行 ntc config 不停。
    if [ ! -f "$CONFIG_FILE" ]; then
        if initial_config; then config_after_save; else rc=1; fi
        [ "${NTC_MENU_PAUSE:-}" != 1 ] || ui_pause
        return "$rc"
    fi
    if ! read_config >/dev/null 2>&1; then
        ui_warn "现有配置文件有误，将重新配置（保存前不会改动原文件）。"
        if initial_config; then config_after_save; else rc=1; fi
        [ "${NTC_MENU_PAUSE:-}" != 1 ] || ui_pause
        return "$rc"
    fi
    if [ "${DISABLED:-false}" = "true" ]; then
        ui_title "流量监控配置" "已停用"
        config_summary_rows
        printf '\n'
        ui_warn "流量监控已停用：不会安装定时任务，也不会统计、限速或关机。"
        ui_note "如需继续监控或修改配置，请先在 ntc 主菜单的「限制执行」里选择启用。"
        [ "${NTC_MENU_PAUSE:-}" != 1 ] || ui_pause
        return 0
    fi
    while true; do
        menu_clear
        ui_title "修改监控配置"
        config_summary_rows
        printf '\n'
        ui_option 1 "修改配置" "逐项确认，回车保留当前值"
        ui_option 2 "vnStat 异常速率上限" "高级"
        ui_rule
        ui_option 0 "返回"
        if ! ui_prompt 2 choice; then
            printf '\n'
            return 0
        fi
        if ! n=$(ntc_int "$(ntc_trim "$choice")" 0 2); then
            ui_warn "无效选择，请输入 0–2。"
            sleep 1
            continue
        fi
        case "$n" in
            0) return 0 ;;
            1)
                if initial_config; then
                    config_after_save
                fi
                ui_pause
                ;;
            2)
                configure_vnstat_max_bandwidth
                ui_pause
                ;;
        esac
        # 菜单重画前重新读取，显示的就是刚保存（或回滚后）的配置。
        read_config >/dev/null 2>&1 || return 1
    done
}

# ntc config show：只读。
show_config() {
    local problems
    if [ ! -f "$CONFIG_FILE" ]; then
        ui_warn "尚未配置流量监控：运行 sudo ntc config 开始。"
        return 1
    fi
    if ! read_config >/dev/null 2>&1; then
        problems=$(read_config 2>&1 | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} //' |
            awk 'NF { printf "%s%s", sep, $0; sep = "；" }')
        ui_err "配置文件有误：${problems:-无法读取}"
        return 1
    fi
    ui_title "当前配置" "$CONFIG_FILE"
    config_summary_rows
    [ "${DISABLED:-false}" != true ] || ui_kv "状态" "已停用（在「限制执行」里启用）"
}

config_set_usage() {
    cat << 'EOF'
用法：ntc config set 参数… [--yes]
  --interface 网卡                    --mode out|in|total|max（出站/入站/出+入/取较大）
  --period monthly|quarterly|yearly   --start-day 1-31    --start-month 1-12（仅每年）
  --unit GB|GiB                       --limit 数值        --tolerance 数值（提前量）
  --action tc|shutdown                --speed kbit/s（1-10000000）
  --boot-grace 分钟（0-1440）          --vnstat-max-bw Mbit/s（0-50000，0 = 不检查）
  --when-over grace:分钟|now|monitor  保存时用量已达到阈值的处理（默认 grace:10）
  --allow-partial-history             vnStat 历史不足以覆盖周期起点时仍然保存
  --yes                               不再确认（vnStat 日数据保留期不足时自动调整）
未给出的项保持当前值；首次配置至少需要 --limit。参数也可写成 --limit=500。
示例：ntc config set --limit 500 --tolerance 1 --speed 50 --yes
EOF
}

config_set_error() {
    printf '%s\n' "ntc config set：$*" >&2
    printf '%s\n' "运行 ntc config set --help 查看参数。" >&2
}

# ntc config set：与向导相同的校验和保存事务，但不逐项提问。
config_set_cli() {
    local arg value had_config=false changed=false only_max_bw=true preview_usage preview_threshold

    if [ -f "$CONFIG_FILE" ]; then
        had_config=true
        if ! read_config >/dev/null 2>&1; then
            ui_err "现有配置文件有误，无法在它的基础上修改；请运行 sudo ntc config 重新配置。"
            return 1
        fi
        if [ "${DISABLED:-false}" = "true" ]; then
            ui_err "流量监控已停用：请先运行 sudo ntc enable（或在「限制执行」里启用）再修改配置。"
            return 1
        fi
    fi
    CONFIG_ASSUME_YES=false
    CONFIG_EXCEED_POLICY="grace:10"
    # 原配置已经确认过按不完整历史统计时沿用该确认，否则需要显式加参数。
    if [ "${ALLOW_PARTIAL_HISTORY:-false}" = "true" ]; then CONFIG_PARTIAL_HISTORY=allow; else CONFIG_PARTIAL_HISTORY=deny; fi

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            -y|--yes) CONFIG_ASSUME_YES=true; shift; continue ;;
            --allow-partial-history) CONFIG_PARTIAL_HISTORY=allow; shift; continue ;;
            -h|--help) config_set_usage; return 0 ;;
            --*=*) value="${arg#*=}"; arg="${arg%%=*}"; shift ;;
            --*)
                case "$arg" in
                    --interface|--mode|--period|--start-day|--start-month|--unit|--limit|--tolerance|--action|\
                    --speed|--boot-grace|--vnstat-max-bw|--when-over) ;;
                    *) config_set_error "无法识别的参数：$arg"; return 2 ;;
                esac
                if [ "$#" -lt 2 ]; then
                    config_set_error "$arg 需要一个值"
                    return 2
                fi
                value="$2"
                shift 2
                ;;
            *) config_set_error "无法识别的参数：$arg"; return 2 ;;
        esac
        case "$arg" in
            --when-over)
                case "$value" in
                    now|monitor) CONFIG_EXCEED_POLICY="$value" ;;
                    grace:*)
                        value=$(ntc_int "${value#grace:}" 1 1440) || { config_set_error "--when-over grace:分钟 的分钟数必须是 1–1440"; return 2; }
                        CONFIG_EXCEED_POLICY="grace:$value"
                        ;;
                    *) config_set_error "--when-over 只能是 grace:分钟、now 或 monitor"; return 2 ;;
                esac
                continue
                ;;
            --interface)
                interface_exists "$value" || { config_set_error "网卡不存在：$value（可用：$(list_interfaces)）"; return 2; }
                MAIN_INTERFACE="$value"
                ;;
            --mode)
                case "$value" in
                    out|in|total|max) TRAFFIC_MODE="$value" ;;
                    *) config_set_error "--mode 只能是 out、in、total 或 max"; return 2 ;;
                esac
                ;;
            --period)
                case "$value" in
                    monthly|m) TRAFFIC_PERIOD=monthly ;;
                    quarterly|q) TRAFFIC_PERIOD=quarterly ;;
                    yearly|y) TRAFFIC_PERIOD=yearly ;;
                    *) config_set_error "--period 只能是 monthly、quarterly 或 yearly"; return 2 ;;
                esac
                ;;
            --start-day)
                PERIOD_START_DAY=$(ntc_int "$value" 1 31) || { config_set_error "--start-day 必须是 1–31 的整数"; return 2; }
                ;;
            --start-month)
                PERIOD_START_MONTH=$(ntc_int "$value" 1 12) || { config_set_error "--start-month 必须是 1–12 的整数"; return 2; }
                ;;
            --unit)
                case "${value,,}" in
                    gb|decimal) TRAFFIC_UNIT=decimal ;;
                    gib|binary) TRAFFIC_UNIT=binary ;;
                    *) config_set_error "--unit 只能是 GB 或 GiB"; return 2 ;;
                esac
                ;;
            --limit)
                if ! value=$(normalize_decimal "$value") || ! compare_decimal "$value" 0 gt; then
                    config_set_error "--limit 必须是大于 0 的数字"
                    return 2
                fi
                TRAFFIC_LIMIT="$value"
                ;;
            --tolerance)
                TRAFFIC_TOLERANCE=$(normalize_decimal "$value") || { config_set_error "--tolerance 必须是不小于 0 的数字"; return 2; }
                ;;
            --action)
                case "$value" in
                    tc|limit) LIMIT_MODE=tc ;;
                    shutdown) LIMIT_MODE=shutdown ;;
                    *) config_set_error "--action 只能是 tc 或 shutdown"; return 2 ;;
                esac
                ;;
            --speed)
                LIMIT_SPEED=$(ntc_int "$value" 1 10000000) || { config_set_error "--speed 必须是 1–10000000 的整数（kbit/s）"; return 2; }
                ;;
            --boot-grace)
                TC_BOOT_GRACE_MINUTES=$(ntc_int "$value" 0 1440) || { config_set_error "--boot-grace 必须是 0–1440 的整数（分钟）"; return 2; }
                ;;
            --vnstat-max-bw)
                vnstat_max_bandwidth_valid "$value" || { config_set_error "--vnstat-max-bw 必须是 0–50000 的整数（Mbit/s）"; return 2; }
                VNSTAT_MAX_BANDWIDTH=$((10#$value))
                changed=true
                continue
                ;;
            *) config_set_error "无法识别的参数：$arg"; return 2 ;;
        esac
        changed=true
        only_max_bw=false
    done

    if ! $changed; then
        config_set_error "没有给出要修改的配置项"
        return 2
    fi
    if ! $had_config; then
        if [ -z "${TRAFFIC_LIMIT:-}" ]; then
            config_set_error "首次配置至少需要 --limit"
            return 2
        fi
        if [ -z "${MAIN_INTERFACE:-}" ] && ! MAIN_INTERFACE=$(detect_main_interface); then
            config_set_error "没有检测到默认网卡，请用 --interface 指定"
            return 2
        fi
        TRAFFIC_MODE="${TRAFFIC_MODE:-total}"
        TRAFFIC_PERIOD="${TRAFFIC_PERIOD:-monthly}"
        PERIOD_START_DAY="${PERIOD_START_DAY:-1}"
        TRAFFIC_UNIT="${TRAFFIC_UNIT:-decimal}"
        TRAFFIC_TOLERANCE="${TRAFFIC_TOLERANCE:-$(default_tolerance "$TRAFFIC_LIMIT")}"
        LIMIT_MODE="${LIMIT_MODE:-tc}"
        LIMIT_SPEED="${LIMIT_SPEED:-20}"
        TC_BOOT_GRACE_MINUTES="${TC_BOOT_GRACE_MINUTES:-10}"
        only_max_bw=false
    fi
    [ "$TRAFFIC_PERIOD" = yearly ] || PERIOD_START_MONTH=1
    PERIOD_START_MONTH="${PERIOD_START_MONTH:-1}"
    if ! compare_decimal "${TRAFFIC_TOLERANCE:-0}" "$TRAFFIC_LIMIT" lt; then
        config_set_error "提前量（${TRAFFIC_TOLERANCE:-0}）必须小于限额（$TRAFFIC_LIMIT）"
        return 2
    fi

    if $only_max_bw; then
        ui_title "修改 vnStat 异常速率上限"
        ui_kv "异常速率" "${VNSTAT_MAX_BANDWIDTH} Mbit/s（0 = 不检查）"
        if [ "$CONFIG_ASSUME_YES" != true ] && ! ui_confirm "保存？" y; then
            ui_note "已取消，原配置未改动。"
            return 1
        fi
        save_vnstat_max_bandwidth || return 1
        ui_ok "配置已保存。"
        return 0
    fi

    config_prepare_vnstat || return 1
    if ! preview_usage=$(get_traffic_usage 2>/dev/null) || ! is_decimal "$preview_usage"; then
        ui_err "无法按新配置读取本期流量（vnStat 数据暂不可用），未保存。"
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        return 1
    fi
    preview_threshold=$(config_threshold)
    config_show_summary "$preview_usage" "$preview_threshold"
    if [ "$CONFIG_ASSUME_YES" != true ] && ! ui_confirm "保存？" y; then
        rollback_initial_vnstat_transaction || ui_err "vnStat 状态未能完整恢复。"
        ui_note "已取消，原配置未改动。"
        return 1
    fi
    config_commit || return 1
    ui_ok "配置已保存。"
    config_after_save
}

# ── 日志只记事件 ─────────────────────────────────────────────────────────
# 每分钟一轮的输出先写进缓冲文件；状态变化、检查失败或出现新的失败原因时整段写进真实日志，同一失败最多
# 10 分钟写一次，一切正常时每小时写一行“运行正常”。1.x 每分钟写 5 行流水账，5000 行只能保留十几个小时。
ROUND_LOG_BUFFER=""
ROUND_REAL_LOG_FILE=""
ROUND_LOG_STATUS=""

round_log_begin() {
    ROUND_REAL_LOG_FILE="$LOG_FILE"
    ROUND_LOG_STATUS=""
    # 调用方持有监控锁，残留的缓冲文件只可能来自被强杀的旧进程。
    rm -f "$WORK_DIR"/.round-log.* 2>/dev/null || true
    ROUND_LOG_BUFFER=$(mktemp "$WORK_DIR/.round-log.XXXXXX" 2>/dev/null) || {
        ROUND_LOG_BUFFER=""
        return 1
    }
    chmod 600 "$ROUND_LOG_BUFFER" 2>/dev/null || true
    LOG_FILE="$ROUND_LOG_BUFFER"
}

# 本轮之后的状态指纹：只包含决定“发生了什么”的字段，不含每分钟都在变的用量和时间戳。
round_state_signature() {
    {
        printf 'rc=%s\n' "${1:-}"
        grep -E '^(STATUS|PERIOD_START)=' "$USAGE_STATE_FILE"
        cat "$ENFORCEMENT_STATE_FILE"
        grep -v '^APPLIED_AT=' "$TC_STATE_FILE"
        cat "$SHUTDOWN_STATE_FILE"
        grep -E '^(HEALTH|REASON)=' "$HEALTH_STATE_FILE"
        cat "$PERIOD_STATE_FILE"
    } 2>/dev/null | cksum | awk '{ print $1 "-" $2 }'
}

usage_status_label() {
    case "${1:-}" in
        normal) printf '流量正常' ;;
        limited) printf '已整机限速' ;;
        grace) printf '宽限中，只统计不限速' ;;
        paused) printf '已暂停限制，只统计不限速' ;;
        shutdown) printf '已安排关机' ;;
        shutdown_external) printf '系统已有其他关机计划，NTC 没有再提交关机' ;;
        *) printf '%s' "${1:-状态未知}" ;;
    esac
}

round_heartbeat_line() {
    local now_text status usage threshold unit
    now_text=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "${DISABLED:-false}" = "true" ]; then
        printf '%s 运行正常：流量监控已停用（NTC %s）\n' "$now_text" "$SCRIPT_VERSION"
        return 0
    fi
    status=$(ntc_kv "$USAGE_STATE_FILE" STATUS) || status=""
    usage=$(ntc_kv "$USAGE_STATE_FILE" USAGE) || usage="?"
    threshold=$(ntc_kv "$USAGE_STATE_FILE" LIMIT_THRESHOLD) || threshold="?"
    unit=$(ntc_kv "$USAGE_STATE_FILE" UNIT) || unit=""
    printf '%s 运行正常：本期已用 %s %s / 阈值 %s %s，%s（NTC %s）\n' "$now_text" "$usage" "$unit" "$threshold" "$unit" \
        "$(usage_status_label "$status")" "$SCRIPT_VERSION"
}

# 结束本轮：决定缓冲内容是否写进真实日志，再删除缓冲。可以重复调用（EXIT trap 兜底）。
round_log_finish() {
    local status="${1:-${ROUND_LOG_STATUS:-}}" buffer="${ROUND_LOG_BUFFER:-}" real="${ROUND_REAL_LOG_FILE:-}"
    local signature previous now last_write age=999999

    [ -n "$buffer" ] || return 0
    ROUND_LOG_BUFFER=""
    LOG_FILE="$real"
    [[ "$status" =~ ^[0-9]+$ ]] || status=interrupted
    signature=$(round_state_signature "$status")
    previous=$(cat "$LOG_SIGNATURE_FILE" 2>/dev/null || true)
    now=$(date +%s)
    if last_write=$(stat -c %Y "$real" 2>/dev/null) && [[ "$last_write" =~ ^[0-9]+$ ]]; then
        age=$((now - last_write))
    fi
    if [ "$signature" != "$previous" ] || { [ "$status" != 0 ] && [ "$age" -ge 600 ]; }; then
        [ ! -s "$buffer" ] || cat "$buffer" >> "$real"
        if printf '%s\n' "$signature" > "${LOG_SIGNATURE_FILE}.tmp.$$" 2>/dev/null; then
            mv -f "${LOG_SIGNATURE_FILE}.tmp.$$" "$LOG_SIGNATURE_FILE" 2>/dev/null ||
                rm -f "${LOG_SIGNATURE_FILE}.tmp.$$"
        fi
    elif [ "$status" = 0 ] && [ "$age" -ge 3600 ]; then
        round_heartbeat_line >> "$real"
    fi
    rm -f "$buffer"
}

# 一轮检查（cron 的 --run 与 ntc check 共用）。
run_monitor_round() {
    local run_status=0
    if ! read_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，请检查配置" | tee -a "$LOG_FILE"
        write_health_state error "配置文件读取失败" || true
        return 1
    fi
    if [ "${DISABLED:-false}" = "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 监控已标记为禁用，跳过自动检查" | tee -a "$LOG_FILE"
        write_health_state disabled "监控已禁用" || true
        return 0
    fi
    if ! ensure_vnstat_runtime_config "$MAIN_INTERFACE"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') vnStat 运行配置或服务校验失败，跳过本轮检查。" | tee -a "$LOG_FILE"
        write_health_state error "vnStat 运行配置或服务校验失败" || true
        return 1
    fi
    if ! check_reset_limit; then
        # 周期文件未更新，下一轮会重试；记录健康状态，避免 Telegram 静默。
        echo "$(date '+%Y-%m-%d %H:%M:%S') 新周期的限速/关机计划清理失败，下一轮重试。" | tee -a "$LOG_FILE"
        write_health_state error "新周期的限速/关机计划清理失败（TC 规则可能被其他程序占用，见 traffic_monitor.log）" || true
        return 1
    fi
    check_and_limit_traffic || run_status=$?
    if [ "$run_status" -eq 0 ]; then
        write_health_state ok "" || true
    else
        write_health_state error "$(last_log_reason)" || true
    fi
    return "$run_status"
}

# ntc check：与定时任务完全相同的一轮，之后在屏幕上给一句结论。
monitor_check_now() {
    local rc=0 status usage threshold unit reason text
    round_log_begin || true
    run_monitor_round > /dev/null 2>> "${ROUND_LOG_BUFFER:-/dev/null}" || rc=$?
    ROUND_LOG_STATUS="$rc"
    if [ "$rc" -ne 0 ]; then
        reason=$(ntc_kv "$HEALTH_STATE_FILE" REASON) || reason=""
        ui_err "检查失败：${reason:-原因见日志}"
        if [ -n "$ROUND_LOG_BUFFER" ] && [ -s "$ROUND_LOG_BUFFER" ]; then
            ui_note "本轮最后几行输出："
            tail -n 8 "$ROUND_LOG_BUFFER" | sed 's/^/    /'
        fi
    elif [ "${DISABLED:-false}" = "true" ]; then
        ui_warn "流量监控已停用：不统计也不限速（在 ntc 主菜单的「限制执行」里启用）。"
    else
        status=$(ntc_kv "$USAGE_STATE_FILE" STATUS) || status=""
        usage=$(ntc_kv "$USAGE_STATE_FILE" USAGE) || usage="?"
        threshold=$(ntc_kv "$USAGE_STATE_FILE" LIMIT_THRESHOLD) || threshold="?"
        unit=$(ntc_kv "$USAGE_STATE_FILE" UNIT) || unit=""
        text="本期已用 $(ntc_num "$usage" 2>/dev/null || printf '%s' "$usage") $unit / 阈值 $(ntc_num "$threshold" 2>/dev/null || printf '%s' "$threshold") $unit，$(usage_status_label "$status")"
        [ "$status" != limited ] || text+=" ${LIMIT_SPEED:-20} kbit/s"
        if [ "$status" = normal ]; then ui_ok "检查完成：$text。"; else ui_warn "检查完成：$text。"; fi
    fi
    round_log_finish "$rc"
    return "$rc"
}

# ── 状态详情（ntc status）：只读，不取锁、不写文件、不改 TC ─────────────────
# 1:4001 及以上（Dog 端口限速）的 HTB 类数量；读 `tc class show` 的输出。
count_dog_classes() {
    local kind id n=0
    while read -r kind _ id _; do
        [ "$kind" = class ] || continue
        [[ "$id" =~ ^1:([0-9a-f]{1,4})$ ]] || continue
        if [ $((16#${BASH_REMATCH[1]})) -ge 16385 ]; then
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}

enforcement_reason_label() {
    case "${1:-}" in
        manual) printf '手动' ;;
        config) printf '保存配置时选择' ;;
        shutdown_reboot) printf '关机后重启保护' ;;
        boot) printf '开机宽限' ;;
        "") printf '未注明原因' ;;
        *) printf '%s' "$1" ;;
    esac
}

status_collect() {
    local cron usage state_start updated
    ST_NOW=$(date +%s)
    ST_CONFIGURED=false
    ST_VALID=false
    ST_CONFIG_ERROR=""
    if [ -f "$CONFIG_FILE" ]; then
        ST_CONFIGURED=true
        if read_config >/dev/null 2>&1; then
            ST_VALID=true
        else
            ST_CONFIG_ERROR=$(read_config 2>&1 | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} //' |
                awk 'NF { printf "%s%s", sep, $0; sep = "；" }')
            [ -n "$ST_CONFIG_ERROR" ] || ST_CONFIG_ERROR="无法读取配置文件"
        fi
    fi
    # 只读取上次保存的 vnStat 配置路径；resolve_vnstat_config_path 会写文件，这里不用。
    VNSTAT_CONFIG_PATH=$(cat "$VNSTAT_CONFIG_PATH_FILE" 2>/dev/null || true)
    if [ -z "$VNSTAT_CONFIG_PATH" ] || [ ! -f "$VNSTAT_CONFIG_PATH" ]; then
        unset VNSTAT_CONFIG_PATH
    fi

    ST_PERIOD_START="" ST_PERIOD_END="" ST_THRESHOLD="" ST_USAGE="" ST_USAGE_SOURCE="" ST_USAGE_AGE=0
    ST_PERCENT="" ST_FORECAST=""
    if $ST_VALID; then
        align_timezone_with_vnstat
        ST_PERIOD_START=$(get_period_start_date)
        ST_PERIOD_END=$(get_period_end_date)
        ST_THRESHOLD=$(config_threshold)
        state_start=$(ntc_kv "$USAGE_STATE_FILE" PERIOD_START) || state_start=""
        updated=$(ntc_kv "$USAGE_STATE_FILE" UPDATED_EPOCH) || updated=""
        usage=$(ntc_kv "$USAGE_STATE_FILE" USAGE) || usage=""
        if [ "$state_start" = "$ST_PERIOD_START" ] && [[ "$updated" =~ ^[0-9]+$ ]] &&
           [ $((ST_NOW - updated)) -le 600 ] && is_decimal "$usage"; then
            ST_USAGE="$usage"
            ST_USAGE_SOURCE=state
            ST_USAGE_AGE=$(( (ST_NOW - updated) / 60 ))
        elif usage=$(get_traffic_usage 2>/dev/null) && is_decimal "$usage"; then
            ST_USAGE="$usage"
            ST_USAGE_SOURCE=live
        fi
        if [ -n "$ST_USAGE" ]; then
            ST_PERCENT=$(ntc_percent "$ST_USAGE" "$TRAFFIC_LIMIT") || ST_PERCENT=""
            ST_FORECAST=$(ntc_forecast "$ST_USAGE" "$ST_THRESHOLD" "$ST_PERIOD_START" "$ST_PERIOD_END" "$ST_NOW") ||
                ST_FORECAST=""
        fi
    fi

    ST_STATE_STATUS=$(ntc_kv "$USAGE_STATE_FILE" STATUS) || ST_STATE_STATUS=""
    ST_ENF_MODE=$(ntc_kv "$ENFORCEMENT_STATE_FILE" MODE) || ST_ENF_MODE=""
    ST_ENF_UNTIL=$(ntc_kv "$ENFORCEMENT_STATE_FILE" UNTIL_EPOCH) || ST_ENF_UNTIL=""
    ST_ENF_REASON=$(ntc_kv "$ENFORCEMENT_STATE_FILE" REASON) || ST_ENF_REASON=""
    IFS=$'\t' read -r ST_HEALTH ST_HEALTH_TEXT < <(ntc_health_summary "$HEALTH_STATE_FILE" "$ST_NOW")

    ST_CRON_OK=true
    ST_CRON_MONITOR=false
    ST_CRON_TELEGRAM=false
    if ! cron=$(read_current_crontab 2>/dev/null); then
        ST_CRON_OK=false
        cron=""
    fi
    if ntc_cron_has_entry "$cron" "$SCRIPT_PATH --run"; then ST_CRON_MONITOR=true; fi
    if ntc_cron_has_entry "$cron" "$WORK_DIR/trafficcop-lite-telegram.sh"; then ST_CRON_TELEGRAM=true; fi
    if ! $ST_CONFIGURED; then
        ST_LEVEL=off ST_WORD="○ 尚未配置" ST_DETAIL="运行 sudo ntc config 开始"
    elif [ -n "$ST_CONFIG_ERROR" ]; then
        ST_LEVEL=err ST_WORD="✗ 配置有误" ST_DETAIL="$ST_CONFIG_ERROR"
    else
        IFS=$'\t' read -r ST_LEVEL ST_WORD ST_DETAIL < <(ntc_overall_status "${DISABLED:-false}" "$ST_CRON_OK" \
            "$ST_CRON_MONITOR" "$HEALTH_STATE_FILE" "$ST_STATE_STATUS" "${LIMIT_SPEED:-}" "$ST_ENF_UNTIL" "$ST_NOW")
    fi

    ST_TG=none ST_TG_REPORT="" ST_TG_WARN=""
    if [ -f "$TG_CONFIG_FILE" ]; then
        if [ "$(ntc_kv "$TG_CONFIG_FILE" TG_DISABLED)" = true ]; then
            ST_TG=disabled
        elif $ST_CRON_TELEGRAM; then
            ST_TG=enabled
        else
            ST_TG=no-cron
        fi
        ST_TG_REPORT=$(ntc_kv "$TG_CONFIG_FILE" DAILY_REPORT_TIME) || ST_TG_REPORT=""
        # 与 Telegram 组件同一套规则：空或 off 是关闭，写坏的值按默认 80,90 执行。
        ST_TG_WARN=$(ntc_tg_warn_percents "$TG_CONFIG_FILE")
    fi

    ST_TC_ROOT="" ST_TC_ACTIVE=unknown ST_TC_DOG=""
    if [ -n "$TC_BIN" ] && [[ "${MAIN_INTERFACE:-}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        ST_TC_ROOT=$(tc_root_qdisc "$MAIN_INTERFACE" 2>/dev/null | awk '{ print $2 }')
        if [ -f "$TC_STATE_FILE" ]; then
            owned_tc_limit_active 2>/dev/null
            case $? in
                0) ST_TC_ACTIVE=yes ;;
                1) ST_TC_ACTIVE=no ;;
                *) ST_TC_ACTIVE=unknown ;;
            esac
        else
            ST_TC_ACTIVE=no
        fi
        ST_TC_DOG=$(tc_class_output "$MAIN_INTERFACE" 2>/dev/null | count_dog_classes)
    fi

    ST_RECOVERY=none
    if [ -f "$TC_RECOVERY_UNIT_FILE" ]; then
        if command_exists systemctl && systemctl is-enabled --quiet traffic-tools-tc-recovery.service 2>/dev/null; then
            ST_RECOVERY=enabled
        else
            ST_RECOVERY=disabled
        fi
    fi
    if ! command -v vnstat >/dev/null 2>&1; then
        ST_VNSTAT=missing
    elif vnstat_daemon_is_running; then
        ST_VNSTAT=running
    else
        ST_VNSTAT=stopped
    fi
    if [ -f "$DOG_CONFIG_FILE" ]; then ST_DOG=true; else ST_DOG=false; fi
}

status_print_human() {
    local unit_label color text elapsed left avg projected hit hhmm warn_text tc_text
    ui_title "状态详情" "$(hostname -s 2>/dev/null || uname -n)"
    if ! $ST_CONFIGURED; then
        ui_warn "尚未配置流量监控：运行 sudo ntc config，或在 ntc 主菜单选「修改监控配置」。"
    elif [ -n "$ST_CONFIG_ERROR" ]; then
        ui_err "配置文件有误：$ST_CONFIG_ERROR"
    else
        color=$(ui_level_color "$ST_LEVEL")
        ui_row "$DIM" "状态" "$ST_WORD${ST_DETAIL:+  $ST_DETAIL}" "$color"
        unit_label=$(ntc_unit_label "$TRAFFIC_UNIT")
        ui_kv "网卡" "$MAIN_INTERFACE · $(ntc_mode_label "$TRAFFIC_MODE")"
        text="$(ntc_period_label "$TRAFFIC_PERIOD" "$PERIOD_START_DAY" "$PERIOD_START_MONTH")：$ST_PERIOD_START 至 $ST_PERIOD_END"
        if [ -n "$ST_FORECAST" ]; then
            read -r elapsed _ left avg projected hit <<< "$ST_FORECAST"
            text+="，还剩 $(ntc_days_left_text "$left")"
        fi
        ui_kv "周期" "$text"
        if [ -n "$ST_USAGE" ]; then
            text=""
            if [ "$ST_USAGE_SOURCE" = live ]; then
                text="（刚从 vnStat 读取）"
            elif [ "$ST_USAGE_AGE" -ge 1 ]; then
                text="（${ST_USAGE_AGE} 分钟前）"
            fi
            if [ -n "$ST_PERCENT" ]; then
                ui_usage_kv "本期已用" "$(ntc_num "$ST_USAGE") $unit_label / $(ntc_num "$TRAFFIC_LIMIT") $unit_label" \
                    "$ST_PERCENT" "$text"
            else
                ui_kv "本期已用" "$(ntc_num "$ST_USAGE") $unit_label / $(ntc_num "$TRAFFIC_LIMIT") $unit_label${text:+  $text}"
            fi
        else
            ui_kv "本期已用" "暂时无法读取（vnStat 数据不可用）"
        fi
        ui_kv "执行阈值" "$(ntc_num "$ST_THRESHOLD") $unit_label（限额 − 提前量 $(ntc_num "$TRAFFIC_TOLERANCE") $unit_label）"
        if [ -n "$ST_FORECAST" ]; then
            if [ "$hit" = 0 ]; then
                ui_kv "本期预计" "已达到阈值"
            elif awk -v e="$elapsed" 'BEGIN { exit !(e < 1) }'; then
                ui_kv "本期预计" "本期刚开始，满一天后显示预计用量"
            elif [ "$hit" != -1 ]; then
                ui_row "$DIM" "本期预计" "约 $(ntc_num "$projected") $unit_label，按目前速度 $(date -d "@$hit" '+%m-%d %H:%M' 2>/dev/null || echo '?') 达到阈值" "$YELLOW"
            else
                ui_kv "本期预计" "约 $(ntc_num "$projected") $unit_label（按本期日均 $(ntc_num "$avg") $unit_label），本期不会达到阈值"
            fi
        fi
        if [ "$LIMIT_MODE" = shutdown ]; then
            ui_kv "超额处理" "关机"
        elif [ "${TC_BOOT_GRACE_MINUTES:-10}" -gt 0 ]; then
            ui_kv "超额处理" "整机限速 ${LIMIT_SPEED} kbit/s；开机后 ${TC_BOOT_GRACE_MINUTES} 分钟内不限速"
        else
            ui_kv "超额处理" "整机限速 ${LIMIT_SPEED} kbit/s"
        fi
        case "$ST_ENF_MODE" in
            grace)
                if [[ "$ST_ENF_UNTIL" =~ ^[0-9]+$ ]] && hhmm=$(date -d "@$ST_ENF_UNTIL" '+%m-%d %H:%M' 2>/dev/null); then
                    if [ "$ST_ENF_UNTIL" -gt "$ST_NOW" ]; then text="宽限到 $hhmm"; else text="宽限已于 $hhmm 结束"; fi
                else
                    text="宽限中"
                fi
                ui_kv "执行策略" "$text（$(enforcement_reason_label "$ST_ENF_REASON")）"
                ;;
            paused) ui_kv "执行策略" "已暂停（$(enforcement_reason_label "$ST_ENF_REASON")），只统计不执行" ;;
            *) ui_kv "执行策略" "按配置执行" ;;
        esac
        ui_kv "最近检查" "$ST_HEALTH_TEXT"
        [ "${ALLOW_PARTIAL_HISTORY:-false}" != true ] || ui_note "本期 vnStat 历史不完整，已用量可能偏低；进入新周期后恢复正常。"
    fi

    if ! $ST_CRON_OK; then
        ui_kv "定时任务" "无法读取 root crontab"
    else
        text="监控：$($ST_CRON_MONITOR && printf '已安装' || printf '未安装')"
        text+="；Telegram：$($ST_CRON_TELEGRAM && printf '已安装' || printf '未安装')"
        ui_kv "定时任务" "$text"
    fi
    case "$ST_TG" in
        none) ui_kv "Telegram" "未配置" ;;
        disabled) ui_kv "Telegram" "已停用" ;;
        no-cron) ui_kv "Telegram" "已配置，但定时任务缺失（不会发送）" ;;
        *)
            if [ "${ST_TG_WARN:-80,90}" = off ]; then
                warn_text="用量预警已关闭"
            else
                warn_text="用量预警 $(printf '%s' "${ST_TG_WARN:-80,90}" | sed 's/,/%、/g')%"
            fi
            ui_kv "Telegram" "已启用${ST_TG_REPORT:+；每日 $ST_TG_REPORT 日报}；$warn_text"
            ;;
    esac
    if [ -z "$TC_BIN" ]; then
        ui_kv "TC" "未找到 tc 命令"
    elif [ -n "${MAIN_INTERFACE:-}" ]; then
        case "$ST_TC_ACTIVE" in
            yes) tc_text="NTC 整机限速生效中（$(ntc_kv "$TC_STATE_FILE" LIMIT_SPEED) kbit/s）" ;;
            no)
                if [ -f "$TC_STATE_FILE" ]; then
                    tc_text="NTC 有限速记录，但规则不在（下一轮检查会处理）"
                else
                    tc_text="NTC 未限速"
                fi
                ;;
            *) tc_text="NTC 限速状态无法确认（运行 ntc self-check 查看）" ;;
        esac
        [ -z "$ST_TC_DOG" ] || [ "$ST_TC_DOG" = 0 ] || tc_text+="；Dog 端口限速 ${ST_TC_DOG} 个"
        ui_kv "TC" "$tc_text；根队列 ${ST_TC_ROOT:-无}"
    fi
    case "$ST_RECOVERY" in
        enabled) ui_kv "自动恢复" "已启用（开机时检查 Dog/NTC 的 TC 规则）" ;;
        disabled) ui_kv "自动恢复" "已安装，未启用" ;;
        *) ui_kv "自动恢复" "未启用" ;;
    esac
    case "$ST_VNSTAT" in
        running) ui_kv "vnStat" "守护进程运行中" ;;
        stopped) ui_kv "vnStat" "守护进程未运行：流量无法统计" ;;
        *) ui_kv "vnStat" "未安装" ;;
    esac
    if $ST_DOG; then ui_kv "Dog" "已安装（与 NTC 共用 TC 层级）"; else ui_kv "Dog" "未安装"; fi
}

status_print_json() {
    local elapsed="" left="" avg="" projected="" hit="" unit=""
    if ! command -v jq >/dev/null 2>&1; then
        echo "输出 JSON 需要 jq。" >&2
        return 1
    fi
    [ -z "$ST_FORECAST" ] || read -r elapsed _ left avg projected hit <<< "$ST_FORECAST"
    [ -z "${TRAFFIC_UNIT:-}" ] || unit=$(ntc_unit_label "$TRAFFIC_UNIT")
    jq -n \
        --arg version "$SCRIPT_VERSION" --arg now "$ST_NOW" \
        --arg configured "$ST_CONFIGURED" --arg config_error "$ST_CONFIG_ERROR" --arg disabled "${DISABLED:-false}" \
        --arg level "$ST_LEVEL" --arg word "$ST_WORD" --arg detail "$ST_DETAIL" --arg state "$ST_STATE_STATUS" \
        --arg interface "${MAIN_INTERFACE:-}" --arg mode "${TRAFFIC_MODE:-}" --arg period "${TRAFFIC_PERIOD:-}" \
        --arg start_day "${PERIOD_START_DAY:-}" --arg start_month "${PERIOD_START_MONTH:-}" \
        --arg period_start "$ST_PERIOD_START" --arg period_end "$ST_PERIOD_END" --arg days_left "$left" \
        --arg unit "$unit" --arg usage "$ST_USAGE" --arg usage_source "$ST_USAGE_SOURCE" \
        --arg limit "${TRAFFIC_LIMIT:-}" --arg tolerance "${TRAFFIC_TOLERANCE:-}" --arg threshold "$ST_THRESHOLD" \
        --arg percent "$ST_PERCENT" --arg elapsed "$elapsed" --arg avg "$avg" --arg projected "$projected" --arg hit "$hit" \
        --arg action "${LIMIT_MODE:-}" --arg speed "${LIMIT_SPEED:-}" --arg boot_grace "${TC_BOOT_GRACE_MINUTES:-}" \
        --arg enf_mode "$ST_ENF_MODE" --arg enf_until "$ST_ENF_UNTIL" --arg enf_reason "$ST_ENF_REASON" \
        --arg health "$ST_HEALTH" --arg health_text "$ST_HEALTH_TEXT" \
        --arg cron_ok "$ST_CRON_OK" --arg cron_monitor "$ST_CRON_MONITOR" --arg cron_telegram "$ST_CRON_TELEGRAM" \
        --arg tg "$ST_TG" --arg tg_report "$ST_TG_REPORT" --arg tg_warn "$ST_TG_WARN" \
        --arg tc_root "$ST_TC_ROOT" --arg tc_active "$ST_TC_ACTIVE" --arg tc_dog "$ST_TC_DOG" \
        --arg recovery "$ST_RECOVERY" --arg vnstat "$ST_VNSTAT" --arg max_bw "${VNSTAT_MAX_BANDWIDTH:-}" \
        --arg dog "$ST_DOG" --arg partial "${ALLOW_PARTIAL_HISTORY:-false}" '
        def num: if . == "" then null else (tonumber? // null) end;
        def str: if . == "" then null else . end;
        def flag: . == "true";
        {
          version: $version,
          generated_epoch: ($now | num),
          configured: ($configured | flag),
          config_error: ($config_error | str),
          disabled: ($disabled | flag),
          status: {level: ($level | str), label: ($word | str), detail: ($detail | str), state: ($state | str)},
          interface: ($interface | str),
          mode: ($mode | str),
          period: {type: ($period | str), start_day: ($start_day | num), start_month: ($start_month | num),
                   start: ($period_start | str), end: ($period_end | str), days_left: ($days_left | num)},
          unit: ($unit | str),
          usage: ($usage | num),
          usage_source: ($usage_source | str),
          limit: ($limit | num),
          tolerance: ($tolerance | num),
          threshold: ($threshold | num),
          percent: ($percent | num),
          forecast: (if $projected == "" then null else
                      {days_elapsed: ($elapsed | num), avg_per_day: ($avg | num), projected: ($projected | num),
                       reached: (($hit | num) == 0),
                       reach_epoch: (($hit | num) as $h | if $h == null or $h <= 0 then null else $h end)} end),
          action: {type: ($action | str), speed_kbit: ($speed | num), boot_grace_minutes: ($boot_grace | num)},
          enforcement: {mode: (($enf_mode | str) // "normal"), until_epoch: ($enf_until | num), reason: ($enf_reason | str)},
          health: {state: ($health | str), text: ($health_text | str)},
          cron: {readable: ($cron_ok | flag), monitor: ($cron_monitor | flag), telegram: ($cron_telegram | flag)},
          telegram: {state: $tg, daily_report_time: ($tg_report | str), warn_percents: ($tg_warn | str)},
          tc: {root_qdisc: ($tc_root | str),
               ntc_limit_active: (if $tc_active == "unknown" then null else ($tc_active == "yes") end),
               dog_classes: ($tc_dog | num)},
          tc_auto_recovery: $recovery,
          vnstat: {daemon: $vnstat, max_bandwidth_mbit: ($max_bw | num)},
          dog_installed: ($dog | flag),
          partial_history: ($partial | flag)
        }'
}

monitor_status() {
    local json=false
    case "$#:${1:-}" in
        0:) ;;
        1:--json) json=true ;;
        *)
            echo "用法：trafficcop-lite-monitor.sh --status [--json]" >&2
            return 2
            ;;
    esac
    status_collect
    if $json; then
        status_print_json
    else
        status_print_human
    fi
}

# ── 入口 ────────────────────────────────────────────────────────────────
# 取监控锁（fd 9）。cron：拿不到就静默退出（上一轮或配置向导还在运行，返回 3）；
# 开机恢复与交互操作最多等 15 秒。
monitor_take_lock() {
    touch "${LOCK_FILE}"
    chmod 600 "$LOCK_FILE" 2>/dev/null || true
    exec 9>"${LOCK_FILE}"
    case "${1:-interactive}" in
        cron)
            flock -n 9 || return 3
            ;;
        recover)
            if ! flock -w 15 9; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 另一个脚本实例长时间占用监控锁，TC 恢复未执行。" | tee -a "$LOG_FILE"
                return 1
            fi
            ;;
        *)
            if ! flock -w 15 9; then
                ui_err "另一个 NTC 操作正在进行（每分钟的检查或另一处配置），请稍后再试。"
                return 1
            fi
            ;;
    esac
    trap 'round_log_finish; trim_log_file "$LOG_FILE" "$LOG_MAX_LINES"; flock -u 9 2>/dev/null || true' EXIT
}

show_monitor_usage() {
    cat << 'EOF'
用法：trafficcop-lite-monitor.sh [选项]
  （无参数）、--configure   修改监控配置；尚未配置时直接进入向导
  --config-show             显示当前配置
  --config-set 参数…        不提问地修改配置（--config-set --help 查看参数）
  --status [--json]         状态详情（只读）
  --check                   立即检查一次（与每分钟的定时任务相同）
  --run                     定时任务入口（每分钟一次；日志只记事件）
  --self-check [网卡]       只读检查 TC 规则
  --tc-clear-owned [原因]   清除 NTC 自己的 TC 限速
  --tc-recover-owned [--auto|--manual]   按状态重建 NTC 的 TC 限速（开机恢复用）
  -h, --help                显示本帮助
平时请用 ntc 命令：ntc status、ntc check、ntc config …
EOF
}

main() {
    local rc=0
    case "${1:-}" in
        -h|--help)
            show_monitor_usage
            return 0
            ;;
        --self-check|--tc-self-check)
            tc_self_check "${2:-}"
            return $?
            ;;
        --tc-clear-owned)
            clear_owned_tc_rules "${2:-手动清理}"
            return $?
            ;;
        --status)
            shift
            LOG_FILE=/dev/null
            monitor_status "$@"
            return $?
            ;;
        --config-show)
            if [ "$#" -ne 1 ]; then
                echo "用法：trafficcop-lite-monitor.sh --config-show" >&2
                return 2
            fi
            LOG_FILE=/dev/null
            show_config
            return $?
            ;;
        --config-set)
            case "${2:-}" in
                -h|--help) config_set_usage; return 0 ;;
            esac
            ;;
        --check)
            if [ "$#" -ne 1 ]; then
                echo "用法：trafficcop-lite-monitor.sh --check" >&2
                return 2
            fi
            ;;
        ""|--configure)
            if [ "$#" -gt 1 ]; then
                echo "用法：trafficcop-lite-monitor.sh [--configure]" >&2
                return 2
            fi
            ;;
        --run|--cron|--tc-recover-owned) ;;
        *)
            echo "无法识别的参数：$1" >&2
            show_monitor_usage >&2
            return 2
            ;;
    esac

    # 在脚本开始时调用迁移函数
    migrate_files
    cd "$WORK_DIR" || exit 1

    case "${1:-}" in
        --run|--cron)
            monitor_take_lock cron || return 0
            round_log_begin || true
            run_monitor_round > /dev/null 2>> "${ROUND_LOG_BUFFER:-/dev/null}" || rc=$?
            round_log_finish "$rc"
            return "$rc"
            ;;
        --tc-recover-owned)
            monitor_take_lock recover || return 1
            if ! read_config; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，未修改 TC。" | tee -a "$LOG_FILE"
                return 1
            fi
            # 与 --run 一致：周期边界按 vnStat 的 UseUTC 计算（只读，不修改 vnStat 配置）。
            align_timezone_with_vnstat
            recover_owned_tc_hierarchy "${2:---manual}"
            return $?
            ;;
        --check)
            monitor_take_lock || return 1
            if [ ! -f "$CONFIG_FILE" ]; then
                ui_warn "尚未配置流量监控：运行 sudo ntc config 开始。"
                return 1
            fi
            monitor_check_now
            return $?
            ;;
        --config-set)
            shift
            monitor_take_lock || return 1
            if ! check_and_install_packages; then
                ui_err "依赖检查未通过，未修改配置。"
                return 1
            fi
            config_set_cli "$@"
            return $?
            ;;
        *)
            monitor_take_lock || return 1
            if ! check_and_install_packages; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 依赖检查未通过，已停止后续配置和限速检查。" | tee -a "$LOG_FILE"
                return 1
            fi
            configure_menu
            return $?
            ;;
    esac
}



# Sourcing exposes functions without creating files, installing traps or running a menu.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        # 只读命令不创建工作目录、不改权限。
        --self-check|--tc-self-check|--status|--config-show|-h|--help) ;;
        *)
            umask 077
            mkdir -p "$WORK_DIR"
            chmod 700 "$WORK_DIR" 2>/dev/null || true
            [ ! -f "$LOG_FILE" ] || chmod 600 "$LOG_FILE" 2>/dev/null || true
            ;;
    esac
    main "$@"
    exit $?
fi
