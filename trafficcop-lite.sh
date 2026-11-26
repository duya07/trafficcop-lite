#!/bin/bash

# TrafficCop Lite - 独立版流量监控管理器
# 基于 ypq123456789/TrafficCop 的流量监控、Telegram 通知与机器限速功能整理。

SCRIPT_VERSION="2.0.0"
LAST_UPDATE="2026-11-19"

WORK_DIR="/etc/trafficcop-lite"
DEPENDENCY_STATE_DIR="${DEPENDENCY_STATE_DIR:-/var/lib/trafficcop-lite/dependencies}"
MONITOR_SCRIPT="trafficcop-lite-monitor.sh"
TELEGRAM_SCRIPT="trafficcop-lite-telegram.sh"
MACHINE_LIMIT_SCRIPT="trafficcop-lite-machine-limit.sh"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
MONITOR_LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
ROOT_CRONTAB_LOCK_FILE="${TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE:-$WORK_DIR/root-crontab.lock}"
INSTALL_CHANGED=false
TC_RECOVERY_RUNNER="${TRAFFIC_TOOLS_TC_RECOVERY_RUNNER:-/usr/local/sbin/traffic-tools-tc-recovery.sh}"
TC_RECOVERY_UNIT_FILE="${TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE:-/etc/systemd/system/traffic-tools-tc-recovery.service}"
TC_RECOVERY_SERVICE="traffic-tools-tc-recovery.service"
TC_RECOVERY_SYSTEMCTL="${TRAFFIC_TOOLS_SYSTEMCTL:-systemctl}"
SHORTCUT_PATH="/usr/local/bin/ntc"
LEGACY_NCL_SHORTCUT_PATH="/usr/local/bin/ncl"
LEGACY_TC_SHORTCUT_PATH="/usr/local/bin/tc"
REPO="${REPO:-duya07/trafficcop-lite}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"

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

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
    SOURCE_PATH="$(readlink "$SOURCE_PATH")"
    [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"

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

# Debian package names and the commands actually used by the four components.
dependency_manifest() {
    case "${1:-all}" in core|all) ;; *) return 2 ;; esac
    printf '%s\n' \
        'vnstat|vnstat|流量统计' \
        'jq|jq|JSON 解析' \
        'bc|bc|流量计算' \
        'iproute2|ip tc|网络和限速' \
        'cron|crontab|定时任务' \
        'util-linux|flock|互斥锁' \
        'procps|pgrep pkill|进程检查' \
        'curl|curl|下载和通知' \
        'ca-certificates|@ca-certificates|HTTPS 证书' \
        'coreutils|tac|基础工具' \
        'grep|grep|文本搜索' \
        'sed|sed|文本处理' \
        'mawk|awk|文本处理'
}

dependency_peer_uses_package() {
    [ -e /usr/local/bin/port-traffic-dog.sh ] || [ -L /usr/local/bin/port-traffic-dog.sh ] ||
        [ -e /etc/port-traffic-dog ] || [ -L /etc/port-traffic-dog ] || return 1
    # Keep shared and possibly transitive packages while Dog is installed.
    [ "${1%%:*}" != vnstat ]
}

dependency_removal_is_safe() {
    local path cron running pid status=0
    for path in "$WORK_DIR/trafficcop-lite.sh" "$WORK_DIR/$MONITOR_SCRIPT" \
        "$WORK_DIR/$TELEGRAM_SCRIPT" "$WORK_DIR/$MACHINE_LIMIT_SCRIPT"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            dependency_error '请先完整卸载 NTC，再卸载依赖。'
            return 1
        fi
    done
    if ! command -v crontab >/dev/null 2>&1 || ! command -v pgrep >/dev/null 2>&1; then
        dependency_error '无法确认 NTC 进程或 crontab，拒绝卸载依赖。'; return 1
    fi
    cron=$(read_current_crontab) || { dependency_error '无法读取 root crontab，拒绝卸载依赖。'; return 1; }
    if printf '%s\n' "$cron" | grep -Ev '^[[:space:]]*#' | grep -Eq 'trafficcop-lite[^[:space:]]*\.sh'; then
        dependency_error '仍有 NTC 定时任务，请先卸载。'; return 1
    fi
    running=$(pgrep -f -- "$WORK_DIR/trafficcop-lite(-monitor|-telegram|-machine-limit)?\.sh" 2>/dev/null) || status=$?
    if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
        dependency_error '无法确认 NTC 进程，拒绝卸载依赖。'; return 1
    fi
    if [ "$status" -eq 0 ] && [ -z "$running" ]; then
        dependency_error '无法确认 NTC 进程，拒绝卸载依赖。'; return 1
    fi
    for pid in $running; do
        [[ "$pid" =~ ^[0-9]+$ ]] || return 1
        [ "$pid" = "$$" ] || [ "$pid" = "$BASHPID" ] || {
            dependency_error '仍有 NTC 进程运行，请先停止。'; return 1;
        }
    done
    return 0
}

# Dependency changes are displayed directly; do not recreate the removed NTC config directory.
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

# Other package managers retain command-based installation without pretending to own packages.
dependency_package_manager() {
    local manager
    for manager in apt-get dnf yum apk pacman; do
        if command -v "$manager" >/dev/null 2>&1; then printf '%s\n' "$manager"; return 0; fi
    done
    return 1
}

dependency_non_apt_report() {
    local manager="$1" package tools description mapped
    DEPENDENCY_MISSING_PACKAGES=()
    printf '依赖检测（%s，非 Debian 系统不记录包归属）：\n' "$manager"
    while IFS='|' read -r package tools description; do
        if dependency_tools_available "$package" "$tools"; then
            printf '  [可用] %s：%s\n' "$package" "$description"
            continue
        fi
        mapped="$package"
        case "$manager:$package" in
            dnf:iproute2|yum:iproute2) mapped=iproute ;;
            dnf:cron|yum:cron|pacman:cron) mapped=cronie ;;
            dnf:procps|yum:procps|pacman:procps) mapped=procps-ng ;;
            apk:cron) mapped=dcron ;;
            apk:util-linux) mapped=util-linux-misc ;;
            *:mawk) mapped=gawk ;;
        esac
        printf '  [缺失] %s：%s\n' "$mapped" "$description"
        case " ${DEPENDENCY_MISSING_PACKAGES[*]} " in *" $mapped "*) ;; *) DEPENDENCY_MISSING_PACKAGES+=("$mapped") ;; esac
    done < <(dependency_manifest all)
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -eq 0 ]
}

dependency_install_for_host() {
    local yes="${1:-false}" manager answer
    manager=$(dependency_package_manager) || { dependency_error '未识别支持的包管理器。'; return 1; }
    if [ "$manager" = apt-get ]; then
        dependency_install_missing "$yes" all
        return $?
    fi
    dependency_non_apt_report "$manager" && return 0
    printf '仅安装缺失项：%s\n' "${DEPENDENCY_MISSING_PACKAGES[*]}"
    if [ "$yes" != true ]; then
        read -r -p '确认安装？[y/yes，默认 n]：' answer || return 1
        case "${answer,,}" in y|yes) ;; *) printf '安装已取消。\n'; return 1 ;; esac
    fi
    [ "$EUID" -eq 0 ] || { dependency_error '安装需要 root。'; return 1; }
    case "$manager" in
        dnf|yum) "$manager" install -y "${DEPENDENCY_MISSING_PACKAGES[@]}" || return 1 ;;
        apk) apk add --no-cache "${DEPENDENCY_MISSING_PACKAGES[@]}" || return 1 ;;
        pacman) pacman -S --needed --noconfirm "${DEPENDENCY_MISSING_PACKAGES[@]}" || return 1 ;;
        *) return 1 ;;
    esac
    dependency_non_apt_report "$manager" || { dependency_error '安装后仍有缺失命令。'; return 1; }
}

dependency_host_cli() {
    local manager
    manager=$(dependency_package_manager) || { dependency_error '未识别支持的包管理器。'; return 2; }
    if [ "$manager" = apt-get ]; then dependency_cli "$@"; return $?; fi
    case "${1:-check}" in
        check) [ "$#" -le 1 ] || return 2; dependency_non_apt_report "$manager" ;;
        install)
            case "${2:-}" in '') [ "$#" -le 1 ] && dependency_install_for_host false ;; --yes) [ "$#" -eq 2 ] && dependency_install_for_host true ;; *) return 2 ;; esac ;;
        owned|remove) dependency_error '非 Debian/Ubuntu 系统不支持依赖归属账本或自动卸载，请用系统包管理器处理。'; return 2 ;;
        *) dependency_error '用法：--dependencies check|install [--yes]|remove [--all] [--yes]|owned'; return 2 ;;
    esac
}

dependency_host_menu() {
    local manager choice
    manager=$(dependency_package_manager) || { dependency_error '未识别支持的包管理器。'; return 1; }
    if [ "$manager" = apt-get ]; then dependency_menu; return $?; fi
    while true; do
        printf '\n=== 依赖检测与安装 ===\n'
        dependency_non_apt_report "$manager" || true
        printf ' 1. 仅安装缺失依赖\n 0. 返回\n'
        read -r -p '请选择 [0-1]：' choice || return 0
        case "$choice" in 1) dependency_install_for_host false || true ;; 0) return 0 ;; *) printf '无效选择。\n' ;; esac
    done
}

run_tc_self_check() {
    local interface="${1:-}"
    local monitor_path="$WORK_DIR/$MONITOR_SCRIPT"

    [ -f "$monitor_path" ] || monitor_path="$SCRIPT_DIR/$MONITOR_SCRIPT"
    if [ ! -f "$monitor_path" ]; then
        echo -e "${RED}找不到 $MONITOR_SCRIPT，无法执行 TC 自检。${NC}"
        return 1
    fi
    if [ -n "$interface" ]; then
        bash "$monitor_path" --tc-self-check "$interface"
    else
        bash "$monitor_path" --tc-self-check
    fi
}

# Dog 与 NTC 共用同一个恢复入口和同一个 systemd oneshot，避免两边各自抢 root。
tc_recovery_systemd_available() {
    command -v "$TC_RECOVERY_SYSTEMCTL" >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

tc_recovery_unit_is_owned() {
    [ -f "$TC_RECOVERY_UNIT_FILE" ] &&
        grep -Fqx '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_UNIT_FILE" 2>/dev/null
}

tc_recovery_runner_is_owned() {
    [ -f "$TC_RECOVERY_RUNNER" ] &&
        grep -Fqx '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_RUNNER" 2>/dev/null
}

install_tc_recovery_service_files() {
    local runner_dir unit_dir runner_tmp unit_tmp
    runner_dir=$(dirname "$TC_RECOVERY_RUNNER")
    unit_dir=$(dirname "$TC_RECOVERY_UNIT_FILE")
    runner_tmp="${TC_RECOVERY_RUNNER}.tmp.$$"
    unit_tmp="${TC_RECOVERY_UNIT_FILE}.tmp.$$"

    if [ -e "$TC_RECOVERY_RUNNER" ] && ! tc_recovery_runner_is_owned; then
        echo "共享 TC 恢复入口已被其他文件占用: $TC_RECOVERY_RUNNER" >&2
        return 1
    fi
    if [ -e "$TC_RECOVERY_UNIT_FILE" ] && ! tc_recovery_unit_is_owned; then
        echo "共享 TC 恢复服务名已被其他 unit 占用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    mkdir -p "$runner_dir" || return 1
    if ! cat > "$runner_tmp" <<'EOF'
#!/bin/bash
# traffic-tools-tc-recovery-v1
set -euo pipefail

mode="${1:---auto}"
case "$mode" in
    --auto|--manual) ;;
    *) echo "usage: $0 [--auto|--manual]" >&2; exit 2 ;;
esac

dog_script=/usr/local/bin/port-traffic-dog.sh
dog_config=/etc/port-traffic-dog/config.json
ntc_monitor=/etc/trafficcop-lite/trafficcop-lite-monitor.sh
ntc_config=/etc/trafficcop-lite/traffic_monitor_config.txt
handled=false
result=0

# 入口在而配置不可读属于异常：必须报出来，不能静默跳过恢复。
# 此模板由 dog 与 ntc 共用，两边必须逐字一致，否则后运行的一方会覆盖先运行的一方。
if [ -r "$dog_script" ]; then
    if [ -r "$dog_config" ]; then
        bash "$dog_script" --recover-tc "$mode" || result=1
    else
        echo "port-traffic-dog 已安装但配置不可读，跳过 TC 恢复: $dog_config" >&2
        result=1
    fi
    handled=true
fi
if [ -r "$ntc_monitor" ]; then
    if [ -r "$ntc_config" ]; then
        bash "$ntc_monitor" --tc-recover-owned "$mode" || result=1
    else
        echo "trafficcop-lite 已安装但配置不可读，跳过 TC 恢复: $ntc_config" >&2
        result=1
    fi
    handled=true
fi

$handled || exit 0
exit "$result"
EOF
    then
        rm -f "$runner_tmp"
        return 1
    fi
    chmod 755 "$runner_tmp" || { rm -f "$runner_tmp"; return 1; }
    if ! cmp -s "$runner_tmp" "$TC_RECOVERY_RUNNER"; then
        mv -f "$runner_tmp" "$TC_RECOVERY_RUNNER" || { rm -f "$runner_tmp"; return 1; }
        INSTALL_CHANGED=true
    else
        rm -f "$runner_tmp"
    fi

    tc_recovery_systemd_available || return 0
    mkdir -p "$unit_dir" || return 1
    cat > "$unit_tmp" <<EOF || { rm -f "$unit_tmp"; return 1; }
# traffic-tools-tc-recovery-v1
[Unit]
Description=Recover Dog and TrafficCop Lite unified HTB
Wants=network-online.target
After=network-online.target vnstat.service

[Service]
Type=oneshot
ExecStart=$TC_RECOVERY_RUNNER --auto

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unit_tmp" || { rm -f "$unit_tmp"; return 1; }
    if ! cmp -s "$unit_tmp" "$TC_RECOVERY_UNIT_FILE"; then
        mv -f "$unit_tmp" "$TC_RECOVERY_UNIT_FILE" || { rm -f "$unit_tmp"; return 1; }
        INSTALL_CHANGED=true
        # 只有 unit 文件变化时才需要 daemon-reload（1.x 每次打开菜单都会执行一次）。
        "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || return 1
    else
        rm -f "$unit_tmp"
    fi
    return 0
}

tc_auto_recovery_state() {
    if ! tc_recovery_systemd_available; then
        echo "不可用（当前系统未运行 systemd）"
    elif [ -e "$TC_RECOVERY_UNIT_FILE" ] && ! tc_recovery_unit_is_owned; then
        echo "冲突（同名 unit 不属于 Dog/NTC）"
    elif [ -e "$TC_RECOVERY_RUNNER" ] && ! tc_recovery_runner_is_owned; then
        echo "冲突（恢复入口不属于 Dog/NTC）"
    elif [ -e "$TC_RECOVERY_UNIT_FILE" ] && [ ! -e "$TC_RECOVERY_RUNNER" ]; then
        echo "损坏（恢复入口缺失）"
    elif [ ! -e "$TC_RECOVERY_UNIT_FILE" ]; then
        echo "未启用"
    elif "$TC_RECOVERY_SYSTEMCTL" is-enabled --quiet "$TC_RECOVERY_SERVICE" 2>/dev/null; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

enable_tc_auto_recovery() {
    tc_recovery_systemd_available || {
        echo -e "${RED}当前系统未运行 systemd，无法启用开机自动恢复。${NC}"
        return 1
    }
    install_tc_recovery_service_files || return 1
    "$TC_RECOVERY_SYSTEMCTL" enable "$TC_RECOVERY_SERVICE" >/dev/null
}

disable_tc_auto_recovery() {
    tc_recovery_systemd_available || return 0
    [ ! -e "$TC_RECOVERY_UNIT_FILE" ] && return 0
    if ! tc_recovery_unit_is_owned; then
        echo "同名恢复 unit 不属于 Dog/NTC，拒绝停用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    "$TC_RECOVERY_SYSTEMCTL" disable "$TC_RECOVERY_SERVICE" >/dev/null 2>&1
}

cleanup_tc_recovery_files_if_unused() {
    if { [ -r /usr/local/bin/port-traffic-dog.sh ] && [ -r /etc/port-traffic-dog/config.json ]; } ||
       { [ -r /etc/trafficcop-lite/trafficcop-lite-monitor.sh ] && [ -r /etc/trafficcop-lite/traffic_monitor_config.txt ]; }; then
        return 0
    fi
    if [ -e "$TC_RECOVERY_UNIT_FILE" ]; then
        if ! tc_recovery_unit_is_owned; then
            echo "同名恢复 unit 不属于 Dog/NTC，已保留且未调用 systemctl: $TC_RECOVERY_UNIT_FILE" >&2
            return 1
        fi
        if tc_recovery_systemd_available; then
            "$TC_RECOVERY_SYSTEMCTL" disable --now "$TC_RECOVERY_SERVICE" >/dev/null 2>&1 || return 1
        fi
        rm -f "$TC_RECOVERY_UNIT_FILE" || return 1
    fi
    if tc_recovery_runner_is_owned; then
        rm -f "$TC_RECOVERY_RUNNER" || return 1
    fi
    if tc_recovery_systemd_available; then
        "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || return 1
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

ensure_work_dir() {
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR" 2>/dev/null || true
    [ ! -f "$WORK_DIR/traffic_monitor_config.txt" ] || chmod 600 "$WORK_DIR/traffic_monitor_config.txt" 2>/dev/null || true
    [ ! -f "$WORK_DIR/tg_notifier_config.txt" ] || chmod 600 "$WORK_DIR/tg_notifier_config.txt" 2>/dev/null || true
    [ ! -f "$TC_STATE_FILE" ] || chmod 600 "$TC_STATE_FILE" 2>/dev/null || true
    [ ! -f "$WORK_DIR/last_reset_period" ] || chmod 600 "$WORK_DIR/last_reset_period" 2>/dev/null || true
    [ ! -f "$WORK_DIR/current_traffic_state" ] || chmod 600 "$WORK_DIR/current_traffic_state" 2>/dev/null || true
    [ ! -f "$WORK_DIR/vnstat_daily_coverage_start" ] || chmod 600 "$WORK_DIR/vnstat_daily_coverage_start" 2>/dev/null || true
    [ ! -f "$WORK_DIR/last_traffic_notification" ] || chmod 600 "$WORK_DIR/last_traffic_notification" 2>/dev/null || true
    [ ! -f "$ENFORCEMENT_STATE_FILE" ] || chmod 600 "$ENFORCEMENT_STATE_FILE" 2>/dev/null || true
    [ ! -f "$SHUTDOWN_STATE_FILE" ] || chmod 600 "$SHUTDOWN_STATE_FILE" 2>/dev/null || true
}

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

verify_installed_scripts() {
    local script_name

    for script_name in "trafficcop-lite.sh" "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
        if [ ! -s "$WORK_DIR/$script_name" ] || ! bash -n "$WORK_DIR/$script_name" 2>/dev/null; then
            echo -e "${RED}安装后校验失败：$script_name${NC}"
            return 1
        fi
        if [ -z "$(script_version_from_file "$WORK_DIR/$script_name")" ]; then
            echo -e "${RED}安装后版本校验失败：$script_name${NC}"
            return 1
        fi
        if ! chmod +x "$WORK_DIR/$script_name"; then
            echo -e "${RED}无法设置脚本执行权限：$script_name${NC}"
            return 1
        fi
    done
}

copy_self_if_needed() {
    local self_path="$SOURCE_PATH"
    local dest="$WORK_DIR/trafficcop-lite.sh"
    local installed_version tmp_file

    if [ "$self_path" != "$WORK_DIR/trafficcop-lite.sh" ] && [ -f "$self_path" ]; then
        installed_version=$(script_version_from_file "$dest")
        if [ -n "$installed_version" ] && version_is_newer "$installed_version" "$SCRIPT_VERSION"; then
            echo -e "${YELLOW}! 已安装主脚本版本 $installed_version 高于当前副本 $SCRIPT_VERSION，已阻止降级。${NC}"
            return 0
        fi
        tmp_file="${dest}.install.$$"
        if ! cp "$self_path" "$tmp_file"; then
            rm -f "$tmp_file" 2>/dev/null || true
            echo -e "${RED}主脚本复制失败，已保留现有安装。${NC}"
            return 1
        fi
        if ! chmod +x "$tmp_file" || ! mv -f "$tmp_file" "$dest"; then
            rm -f "$tmp_file" 2>/dev/null || true
            echo -e "${RED}主脚本安装失败，已保留现有安装。${NC}"
            return 1
        fi
    fi
}

# ── 发布文件完整性 ───────────────────────────────────────────────
# 仓库根目录的 SHA256SUMS 覆盖四个脚本（tools/update-sums.sh 生成，回归测试核对一致性）。
# 校验文件优先从 RAW_BASE（默认 GitHub 直连）取得；只有直连失败才改用所选线路，此时只能发现
# 传输损坏，不能防止镜像篡改，会明确提示。
fetch_release_sums() {
    local base="$1" dest="$2"
    local direct="${RAW_BASE:-https://raw.githubusercontent.com/${REPO:-duya07/trafficcop-lite}/${BRANCH:-main}}"
    if download_url_to_file "$direct/SHA256SUMS" "$dest" 2>/dev/null && [ -s "$dest" ]; then
        return 0
    fi
    if [ "$base" != "$direct" ] && download_url_to_file "$base/SHA256SUMS" "$dest" 2>/dev/null && [ -s "$dest" ]; then
        echo -e "${YELLOW}! 无法直连取得校验文件，已改用当前线路；这只能发现传输损坏，不能防止镜像篡改。${NC}" >&2
        return 0
    fi
    rm -f "$dest" 2>/dev/null || true
    echo -e "${RED}无法取得 SHA256SUMS，已取消（不安装未经校验的脚本）。${NC}" >&2
    return 1
}

verify_release_file() {
    local name="$1" file="$2" sums="$3" want got
    want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$sums" 2>/dev/null)
    if ! [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then
        echo -e "${RED}SHA256SUMS 中没有 $name，已取消。${NC}" >&2
        return 1
    fi
    got=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [ "$want" != "$got" ]; then
        echo -e "${RED}$name 校验失败（期望 $want，实际 ${got:-无}）。可能是 CDN 缓存尚未同步，请稍后重试；已取消。${NC}" >&2
        return 1
    fi
}

download_component() {
    local script_name="$1"
    local dest="$WORK_DIR/$script_name"
    local url="$RAW_BASE/$script_name"
    local tmp_file="$WORK_DIR/.${script_name}.install.$$"
    local candidate_version installed_version

    echo -e "${YELLOW}正在下载 $script_name...${NC}"
    if ! download_url_to_file "$url" "$tmp_file"; then
        echo -e "${RED}下载失败：$script_name${NC}"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    local sums_file="$WORK_DIR/.SHA256SUMS.$$"
    if ! fetch_release_sums "$RAW_BASE" "$sums_file" ||
       ! verify_release_file "$script_name" "$tmp_file" "$sums_file"; then
        rm -f "$tmp_file" "$sums_file" 2>/dev/null || true
        return 1
    fi
    rm -f "$sums_file" 2>/dev/null || true

    if [ ! -s "$tmp_file" ]; then
        echo -e "${RED}下载文件为空：$script_name${NC}"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    if ! bash -n "$tmp_file" 2>/dev/null; then
        echo -e "${RED}语法检查失败：$script_name，已取消安装。${NC}"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    if ! validate_update_candidate "$script_name" "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    candidate_version=$(script_version_from_file "$tmp_file")
    if [ -z "$candidate_version" ]; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    if ! chmod +x "$tmp_file" || ! mv -f "$tmp_file" "$dest"; then
        rm -f "$tmp_file" 2>/dev/null || true
        echo -e "${RED}安装失败：$script_name，目标文件未通过复制/权限设置。${NC}"
        return 1
    fi
    installed_version=$(script_version_from_file "$dest")
    if [ ! -s "$dest" ] || [ ! -x "$dest" ] ||
       ! bash -n "$dest" 2>/dev/null || [ "$installed_version" != "$candidate_version" ]; then
        echo -e "${RED}安装失败：$script_name，目标文件校验失败。${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ 已下载/安装 $script_name${NC}"
}

download_url_to_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$dest" "$url"
    else
        echo -e "${RED}缺少 curl/wget，无法下载文件。${NC}"
        return 1
    fi
}

ensure_component() {
    local script_name="$1"
    local src="$SCRIPT_DIR/$script_name"
    local dest="$WORK_DIR/$script_name"
    local source_version installed_version tmp_file

    ensure_work_dir

    if [ -f "$src" ] && [ "$src" != "$dest" ]; then
        if ! bash -n "$src" 2>/dev/null; then
            echo -e "${RED}本地脚本语法检查失败：$src${NC}"
            return 1
        fi
        source_version=$(script_version_from_file "$src")
        if [ -z "$source_version" ]; then
            echo -e "${RED}无法识别本地脚本版本：$src${NC}"
            return 1
        fi
        installed_version=$(script_version_from_file "$dest")
        if [ -n "$source_version" ] && [ -n "$installed_version" ] \
            && bash -n "$dest" 2>/dev/null \
            && version_is_newer "$installed_version" "$source_version"; then
            echo -e "${YELLOW}! 已安装 $script_name 版本 $installed_version 高于当前副本 $source_version，已阻止降级。${NC}"
            return 0
        fi
        # 与已安装文件完全相同时不复制、不提示。
        if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
            chmod +x "$dest" 2>/dev/null || true
            return 0
        fi
        tmp_file="$WORK_DIR/.${script_name}.install.$$"
        if ! cp "$src" "$tmp_file" || ! chmod +x "$tmp_file" ||
           ! bash -n "$tmp_file" 2>/dev/null ||
           [ "$(script_version_from_file "$tmp_file")" != "$source_version" ] ||
           ! mv -f "$tmp_file" "$dest"; then
            rm -f "$tmp_file" 2>/dev/null || true
            echo -e "${RED}本地脚本安装失败：$script_name，已保留现有安装。${NC}"
            return 1
        fi
        installed_version=$(script_version_from_file "$dest")
        if [ ! -s "$dest" ] || [ ! -x "$dest" ] ||
           ! bash -n "$dest" 2>/dev/null || [ "$installed_version" != "$source_version" ]; then
            echo -e "${RED}本地脚本安装失败：$script_name，目标文件校验失败。${NC}"
            return 1
        fi
        INSTALL_CHANGED=true
        ui_ok "已安装/更新 $script_name"
        return 0
    fi

    if [ -f "$dest" ]; then
        installed_version=$(script_version_from_file "$dest")
        if bash -n "$dest" 2>/dev/null && [ -n "$installed_version" ]; then
            if ! chmod +x "$dest" || [ ! -x "$dest" ]; then
                echo -e "${RED}无法设置执行权限：$dest${NC}"
                return 1
            fi
            return 0
        fi
        echo -e "${YELLOW}! 已存在的 $script_name 语法或版本检查失败，将重新下载。${NC}"
    fi

    download_component "$script_name" || return 1
    INSTALL_CHANGED=true
}

install_all_components() {
    ensure_component "$MONITOR_SCRIPT" || return 1
    ensure_component "$TELEGRAM_SCRIPT" || return 1
    ensure_component "$MACHINE_LIMIT_SCRIPT" || return 1
    copy_self_if_needed || return 1
    if ! install_tc_recovery_service_files; then
        echo -e "${YELLOW}! 共享 TC 恢复入口安装失败；现有监控仍可使用，自动恢复暂不可用。${NC}"
    fi
}

install_shortcut_link() {
    if { [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; } \
        && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
        echo -e "${YELLOW}! $SHORTCUT_PATH 已被其他文件占用，未覆盖。${NC}"
        echo -e "${YELLOW}  这只是一个便捷入口，不影响功能。你仍可使用：sudo bash $WORK_DIR/trafficcop-lite.sh${NC}"
        echo -e "${YELLOW}  想恢复 sudo ntc：先移走 $SHORTCUT_PATH，再运行一次本脚本。${NC}"
        return 1
    fi

    if [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
        if ! mkdir -p "$(dirname "$SHORTCUT_PATH")" \
            || ! ln -sfn "$WORK_DIR/trafficcop-lite.sh" "$SHORTCUT_PATH" \
            || ! chmod +x "$WORK_DIR/trafficcop-lite.sh"; then
            echo -e "${RED}快捷命令安装失败，请使用：sudo bash $WORK_DIR/trafficcop-lite.sh${NC}"
            return 1
        fi
        INSTALL_CHANGED=true
        ui_ok "快捷命令已安装：sudo ntc"
    fi
    if [ "$(readlink "$LEGACY_NCL_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_NCL_SHORTCUT_PATH"
        INSTALL_CHANGED=true
        ui_ok "已清理旧快捷命令：$LEGACY_NCL_SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_TC_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_TC_SHORTCUT_PATH"
        INSTALL_CHANGED=true
        ui_ok "已清理旧快捷命令：$LEGACY_TC_SHORTCUT_PATH（系统 tc 命令：${TC_BIN:-未找到}）"
    fi
    return 0
}

install_shortcut() {
    INSTALL_CHANGED=false
    if ! install_all_components; then
        ntc_operation_log install failure
        return 1
    fi
    # 快捷命令只是便捷入口：被外部文件占用或装不上都不影响本项目可用，
    # 因此不能算作安装失败（否则主入口会在这里把用户挡在菜单外）。
    install_shortcut_link || true
    # 只有真的装了或换了文件才记一条安装审计（1.x 每次打开菜单都写一条“安装 NTC：成功”）。
    if [ "$INSTALL_CHANGED" = true ]; then
        ntc_operation_log install success
    fi
    return 0
}

source_has_complete_bundle() {
    local script_name

    for script_name in "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
        [ -f "$SCRIPT_DIR/$script_name" ] || return 1
    done
}

install_from_entrypoint() {
    if [ "$SOURCE_PATH" != "$WORK_DIR/trafficcop-lite.sh" ] && ! source_has_complete_bundle; then
        echo -e "${CYAN}检测到单文件安装入口，正在同步整套最新脚本...${NC}"
        update_scripts "$RAW_BASE"
        return $?
    fi

    install_shortcut
}

rollback_script_update() {
    local backup_dir="$1"
    shift
    local script_name
    local rollback_failed=false

    for script_name in "$@"; do
        if [ -f "$backup_dir/$script_name" ]; then
            cp -a "$backup_dir/$script_name" "$WORK_DIR/$script_name" || rollback_failed=true
        elif [ -f "$backup_dir/.absent-$script_name" ]; then
            rm -f "$WORK_DIR/$script_name" || rollback_failed=true
        else
            rollback_failed=true
        fi
    done

    if $rollback_failed; then
        ntc_operation_log update-rollback failure
        return 1
    fi
    ntc_operation_log update-rollback success
}

update_scripts() {
    local update_base="${1:-$RAW_BASE}"
    local scripts=("trafficcop-lite.sh" "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT")
    local temp_files=()
    local script_name tmp_file url backup_dir candidate_version
    local release_changed=false

    UPDATE_PREVIOUS_VERSION=$(script_version_from_file "$WORK_DIR/trafficcop-lite.sh")
    UPDATE_NEW_VERSION=""

    ensure_work_dir
    echo -e "${CYAN}正在更新 TrafficCop-Lite 脚本...${NC}"
    echo -e "${CYAN}更新源:${NC} $update_base"
    echo -e "${YELLOW}仅覆盖脚本文件；配置、日志、crontab 不会被覆盖。${NC}"
    echo ""

    local sums_file="$WORK_DIR/.SHA256SUMS.new.$$"
    if ! fetch_release_sums "$update_base" "$sums_file"; then
        ntc_operation_log update failure
        return 1
    fi
    temp_files+=("$sums_file")

    for script_name in "${scripts[@]}"; do
        url="$update_base/$script_name"
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        echo -e "${YELLOW}下载 $script_name...${NC}"

        if ! download_url_to_file "$url" "$tmp_file"; then
            echo -e "${RED}下载失败：$script_name${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi

        if [ ! -s "$tmp_file" ]; then
            echo -e "${RED}下载文件为空：$script_name${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi

        if ! verify_release_file "$script_name" "$tmp_file" "$sums_file"; then
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi

        if ! bash -n "$tmp_file" 2>/dev/null; then
            echo -e "${RED}语法检查失败：$script_name，已取消更新。${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi

        if ! validate_update_candidate "$script_name" "$tmp_file"; then
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi

        if [ "$script_name" = "trafficcop-lite.sh" ]; then
            candidate_version=$(script_version_from_file "$tmp_file")
            UPDATE_NEW_VERSION="$candidate_version"
        fi

        if [ ! -f "$WORK_DIR/$script_name" ] || ! cmp -s "$tmp_file" "$WORK_DIR/$script_name"; then
            release_changed=true
        fi

        temp_files+=("$tmp_file")
    done

    if ! $release_changed; then
        rm -f "${temp_files[@]}" 2>/dev/null || true
        verify_installed_scripts || { ntc_operation_log update failure; return 1; }
        install_shortcut_link || true
        # 脚本本体已校验通过；共享恢复文件写不进去只影响开机自动恢复，不能把更新判为失败（L2）。
        install_tc_recovery_service_files || ui_warn "共享 TC 自动恢复文件未能更新，开机自动恢复可能暂不可用。"
        echo ""
        echo -e "${GREEN}当前已是最新版本：${UPDATE_NEW_VERSION:-未知}${NC}"
        ntc_operation_log update unchanged
        return 0
    fi
    backup_dir="$WORK_DIR/backups/scripts-$(date +%Y%m%d-%H%M%S)-$$"
    if ! mkdir -p "$WORK_DIR/backups" || ! mkdir "$backup_dir"; then
        echo -e "${RED}无法创建脚本备份目录，已取消更新。${NC}"
        rm -f "${temp_files[@]}" 2>/dev/null || true
        ntc_operation_log update failure
        return 1
    fi

    for script_name in "${scripts[@]}"; do
        if [ -f "$WORK_DIR/$script_name" ]; then
            if ! cp -a "$WORK_DIR/$script_name" "$backup_dir/"; then
                echo -e "${RED}备份 $script_name 失败，已取消更新。${NC}"
                rm -f "${temp_files[@]}" 2>/dev/null || true
                ntc_operation_log update failure
                return 1
            fi
        elif ! : > "$backup_dir/.absent-$script_name"; then
            echo -e "${RED}记录 $script_name 的安装前状态失败，已取消更新。${NC}"
            rm -f "${temp_files[@]}" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi
    done
    for script_name in "${scripts[@]}"; do
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        if ! chmod +x "$tmp_file" || ! mv -f "$tmp_file" "$WORK_DIR/$script_name"; then
            echo -e "${RED}替换 $script_name 失败，正在恢复更新前脚本。${NC}"
            if ! rollback_script_update "$backup_dir" "${scripts[@]}"; then
                echo -e "${RED}部分脚本回滚失败，备份保留在：$backup_dir${NC}"
            fi
            rm -f "${temp_files[@]}" 2>/dev/null || true
            ntc_operation_log update failure
            return 1
        fi
        echo -e "${GREEN}✓ 已更新 $script_name${NC}"
    done

    if ! verify_installed_scripts; then
        echo -e "${RED}更新后的脚本校验失败，正在恢复更新前脚本。${NC}"
        if ! rollback_script_update "$backup_dir" "${scripts[@]}"; then
            echo -e "${RED}部分脚本回滚失败，备份保留在：$backup_dir${NC}"
        fi
        ntc_operation_log update failure
        return 1
    fi

    rm -f "$sums_file" 2>/dev/null || true
    # 脚本本体已校验通过，快捷命令装不上不改变“更新成功”这个事实。
    install_shortcut_link || true
    # 四个脚本都已替换并校验通过：共享恢复文件写不进去只是警告，不能把更新判为失败（L2）。
    install_tc_recovery_service_files || ui_warn "共享 TC 自动恢复文件未能更新，开机自动恢复可能暂不可用。"

    echo ""
    ui_ok "NTC 已更新：${UPDATE_PREVIOUS_VERSION:-未安装} → ${UPDATE_NEW_VERSION:-未知}"
    ui_note "旧脚本已备份到：$backup_dir"
    ui_note "命令行更新后请重新执行 sudo ntc；在菜单里更新会自动载入新版菜单。"
    ntc_operation_log update success
}

ntc_tc_status_kind() {
    case "${1:-}" in
        *"TC_SELF_CHECK=OK"*"MODEL=absent"*) echo "idle" ;;
        *"TC_SELF_CHECK=OK"*) echo "ok" ;;
        *"TC_SELF_CHECK=CONFLICT"*|*"TC_SELF_CHECK=DRIFT"*) echo "conflict" ;;
        *) echo "error" ;;
    esac
}

run_shared_tc_recovery() {
    local mode="${1:---manual}"
    install_tc_recovery_service_files || return 1
    bash "$TC_RECOVERY_RUNNER" "$mode"
}

remove_lite_cron() {
    local current_crontab crontab_tmp
    if ! acquire_root_crontab_lock; then
        echo -e "${RED}无法取得 TrafficCop-Lite crontab 锁，未作修改。${NC}"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        release_root_crontab_lock
        return 1
    fi
    if [ -n "$current_crontab" ]; then
        if ! crontab_tmp="$(mktemp)"; then
            echo -e "${RED}无法创建 crontab 临时文件，未作修改。${NC}"
            release_root_crontab_lock
            return 1
        fi
        chmod 600 "$crontab_tmp" 2>/dev/null || true
        if ! awk -v monitor="$WORK_DIR/$MONITOR_SCRIPT" -v telegram="$WORK_DIR/$TELEGRAM_SCRIPT" '
            index($0, monitor) == 0 && index($0, telegram) == 0 { print }
        ' <<< "$current_crontab" > "$crontab_tmp"; then
            rm -f "$crontab_tmp"
            echo -e "${RED}生成 crontab 候选内容失败，未作修改。${NC}"
            release_root_crontab_lock
            return 1
        fi
        if ! crontab "$crontab_tmp" 2>/dev/null; then
            rm -f "$crontab_tmp"
            echo -e "${RED}移除独立版 crontab 条目失败，已保留安装目录。${NC}"
            release_root_crontab_lock
            return 1
        fi
        rm -f "$crontab_tmp"
    fi
    release_root_crontab_lock
    return 0
}

# 只在持有监控锁之后调用。监控进程由该锁排除（cron 的 --run 用 flock -n，拿不到锁立即退出；
# 已在运行的实例会在锁上排队，不会处于 TC 事务中途），所以不再 pkill 监控脚本——
# 按命令行子串 pkill 会在 qdisc 替换与状态写入之间杀掉进程，也会误杀开机恢复和编辑器。
# Telegram 通知有自己的锁，只结束 cron 触发的实例（精确匹配命令行）。
stop_lite_processes() {
    pkill -f -- "^(/usr)?/bin/bash $WORK_DIR/$TELEGRAM_SCRIPT -cron\$" 2>/dev/null || true
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

clear_lite_tc_rules_interactive() {
    local config="$WORK_DIR/traffic_monitor_config.txt"
    local limit_mode=""
    local monitor_path="$WORK_DIR/$MONITOR_SCRIPT"

    if [ -f "$config" ]; then
        limit_mode="$(grep '^LIMIT_MODE=' "$config" | tail -1 | cut -d'=' -f2-)"
    fi

    if [ "$limit_mode" != "tc" ] && [ ! -f "$TC_STATE_FILE" ]; then
        echo "✓ 未检测到独立版 TC 限速配置"
        return
    fi

    if [ ! -f "$monitor_path" ]; then
        monitor_path="$SCRIPT_DIR/$MONITOR_SCRIPT"
    fi
    if [ ! -f "$monitor_path" ]; then
        echo -e "${RED}找不到 TrafficCop 监控脚本，无法安全清理统一 HTB。${NC}"
        return 1
    fi
    bash "$monitor_path" --tc-clear-owned "停止或卸载 TrafficCop-Lite"
}

# 系统里是否有待执行的计划关机。systemd-logind 安排的关机会写 /run/systemd/shutdown/scheduled（取消时删除），
# 各个 systemd 版本都有；shutdown --show 要 systemd 250 起才有，logind 的计划关机也没有常驻进程，
# 只看 --show 或 pgrep 会漏掉它（monitor 会每分钟重新安排关机，暂停/停用会误删 NTC 的关机记录），所以先看这个文件。
lite_has_pending_shutdown() {
    [ ! -e "${SYSTEMD_SHUTDOWN_SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}" ] || return 0
    if shutdown --help 2>&1 | grep -q -- '--show'; then
        shutdown --show >/dev/null 2>&1
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -x shutdown >/dev/null 2>&1
    else
        return 1
    fi
}

lite_shutdown_task_token_from_state() {
    local task_token
    task_token=$(grep '^TASK_TOKEN=' "$SHUTDOWN_STATE_FILE" 2>/dev/null |
        tail -n 1 | cut -d'=' -f2-)
    [[ "$task_token" =~ ^trafficcop-lite-[0-9A-Za-z-]{8,80}$ ]] || return 1
    printf '%s\n' "$task_token"
}

lite_pending_shutdown_matches_owned_state() {
    local task_token wall_state
    lite_has_pending_shutdown || return 1
    task_token=$(lite_shutdown_task_token_from_state) || return 1
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

cancel_shutdown_interactive() {
    local config="$WORK_DIR/traffic_monitor_config.txt"
    local state_boot current_boot

    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        state_boot=$(grep '^BOOT_ID=' "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [ -n "$state_boot" ] && [ -n "$current_boot" ] && [ "$state_boot" != "$current_boot" ]; then
            rm -f "$SHUTDOWN_STATE_FILE" || return 1
            echo "✓ 已清理上次开机遗留的关机状态，未触碰本次开机的计划关机"
            return 0
        fi
        if { [ -z "$state_boot" ] || [ -z "$current_boot" ]; } && lite_has_pending_shutdown; then
            echo -e "${RED}无法确认计划关机是否属于本脚本，已保留系统任务和状态文件。${NC}"
            return 1
        fi
        if ! lite_has_pending_shutdown; then
            rm -f "$SHUTDOWN_STATE_FILE" || return 1
            echo "✓ 已清理 NTC 的关机记录（当前没有待执行的计划关机）"
            return 0
        fi
        if ! lite_pending_shutdown_matches_owned_state; then
            echo -e "${RED}当前计划关机无法与本脚本任务标识匹配，已保留系统任务和状态文件。${NC}"
            return 1
        fi
        if ! shutdown -c 2>/dev/null || lite_has_pending_shutdown; then
            echo -e "${RED}无法取消本脚本记录的计划关机，已保留状态文件。${NC}"
            return 1
        fi
        rm -f "$SHUTDOWN_STATE_FILE" || return 1
        echo "✓ 已取消本脚本记录的计划关机"
        return 0
    fi
    # 没有 NTC 的关机记录、配置是关机模式：系统里的计划关机可能是旧版本安排的，也可能来自其他程序，无法确认归属。
    # 这里不提问、不读标准输入（卸载已在取锁前问过，--stop 不问）：只有 LITE_UNOWNED_SHUTDOWN_ANSWER=y 才取消，
    # 否则保留并说明；系统里没有待执行的关机时什么都不做，也不说「已取消」。
    grep -q '^LIMIT_MODE=shutdown' "$config" 2>/dev/null || return 0
    lite_has_pending_shutdown || return 0
    if [ "${LITE_UNOWNED_SHUTDOWN_ANSWER:-n}" != y ]; then
        echo -e "${YELLOW}系统里有一个计划关机，NTC 没有它的记录（可能是旧版本或其他程序安排的），已保留。${NC}"
        return 0
    fi
    if ! shutdown -c 2>/dev/null; then
        echo -e "${RED}取消计划关机失败，请先手动确认系统关机任务。${NC}"
        return 1
    fi
    if lite_has_pending_shutdown; then
        echo -e "${RED}取消命令执行后仍检测到计划关机，请先手动处理。${NC}"
        return 1
    fi
    echo "✓ 已取消计划关机"
}

# ── 2.0 界面：仪表盘、主菜单、子菜单与命令行 ───────────────────────────────
UPDATE_DIRECT_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
UPDATE_PROXY_BASE="https://v6.gh-proxy.org/https://raw.githubusercontent.com/${REPO}/${BRANCH}"
# 主菜单：1–5 流量监控，6–10 系统维护（两列时编号竖排）。
MAIN_MENU_LABELS=(状态详情 修改监控配置 限制执行 "Telegram 通知" 立即检查一次 查看日志 "更新 NTC" 依赖管理 "TC 冲突处理 / 自动恢复" "卸载 NTC")
MAIN_MENU_SPLIT=5

pause() {
    ui_pause
}

ntc_hostname() {
    local name=""
    name=$(hostname -s 2>/dev/null) || name=""
    [ -n "$name" ] || name=$(uname -n 2>/dev/null) || name=""
    printf '%s' "${name:-本机}"
}

# 只用 command -v 检查核心依赖命令（不调用 dpkg，菜单每次重绘都可以用）；缺失时输出包名并返回 1。
ntc_missing_tools() {
    local package tools missing=""
    while IFS='|' read -r package tools _; do
        [ -n "$package" ] || continue
        dependency_tools_available "$package" "$tools" >/dev/null 2>&1 || missing+="${missing:+ }$package"
    done < <(dependency_manifest core)
    [ -z "$missing" ] && return 0
    printf '%s' "$missing"
    return 1
}

dashboard_default_interface() {
    ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

# 未配置时仪表盘唯一的一次 vnStat 调用：本自然月的收发合计（字节，仅 vnStat 2.x 的 JSON）。
dashboard_month_bytes() {
    local iface="$1" json year month
    command -v vnstat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
    json=$(timeout 5 vnstat -i "$iface" --json m 2 2>/dev/null) || return 1
    year=$(date +%Y)
    month=$((10#$(date +%m)))
    jq -er --arg i "$iface" --argjson y "$year" --argjson m "$month" '
        [.interfaces[]? | select(.name == $i) | .traffic.month[]?
         | select(.date.year == $y and .date.month == $m) | (.rx + .tx)] | first // empty
    ' <<< "$json" 2>/dev/null
}

# 仪表盘：只读状态文件（未配置时外加一次 vnstat），不跑 TC 自检、不等任何锁。
show_dashboard() {
    local config="$WORK_DIR/traffic_monitor_config.txt" usage_file="$WORK_DIR/current_traffic_state"
    local tg_config="$WORK_DIR/tg_notifier_config.txt" now cron="" cron_ok=true
    local iface mode period day month unit limit tolerance lmode speed disabled partial
    local status usage threshold pstart pend updated pct age summary left_text
    local level word color detail cron_entry text until fc elapsed avg projected hit missing report_time warn
    now=$(date +%s)
    ui_title "TrafficCop Lite v$SCRIPT_VERSION" "$(ntc_hostname)"
    cron=$(read_current_crontab 2>/dev/null) || cron_ok=false

    if [ ! -f "$config" ]; then
        ui_row "$YELLOW" "○ 未配置" "流量监控尚未配置，输入 2 开始（约 1 分钟）"
        iface=$(dashboard_default_interface)
        if [ -n "$iface" ] && usage=$(dashboard_month_bytes "$iface") && usage=$(ntc_bytes_to_unit "$usage" decimal); then
            ui_kv "本月已用" "$(ntc_num "$usage") GB（$iface，vnStat 按自然月统计）"
        fi
    else
        iface=$(ntc_kv "$config" MAIN_INTERFACE) || iface="?"
        mode=$(ntc_kv "$config" TRAFFIC_MODE) || mode=total
        period=$(ntc_kv "$config" TRAFFIC_PERIOD) || period=monthly
        day=$(ntc_int "$(ntc_kv "$config" PERIOD_START_DAY)" 1 31) || day=""
        month=$(ntc_int "$(ntc_kv "$config" PERIOD_START_MONTH)" 1 12) || month=1
        unit=$(ntc_unit_label "$(ntc_kv "$config" TRAFFIC_UNIT)")
        limit=$(ntc_kv "$config" TRAFFIC_LIMIT) || limit=""
        tolerance=$(ntc_kv "$config" TRAFFIC_TOLERANCE) || tolerance=0
        lmode=$(ntc_kv "$config" LIMIT_MODE) || lmode=tc
        speed=$(ntc_kv "$config" LIMIT_SPEED) || speed=""
        disabled=$(ntc_kv "$config" DISABLED) || disabled=false
        partial=$(ntc_kv "$config" ALLOW_PARTIAL_HISTORY) || partial=false
        status=$(ntc_kv "$usage_file" STATUS) || status=""
        usage=$(ntc_kv "$usage_file" USAGE) || usage=""
        threshold=$(ntc_kv "$usage_file" LIMIT_THRESHOLD) || threshold=""
        pstart=$(ntc_kv "$usage_file" PERIOD_START) || pstart=""
        pend=$(ntc_kv "$usage_file" PERIOD_END) || pend=""
        updated=$(ntc_kv "$usage_file" UPDATED_EPOCH) || updated=""
        [ -n "$threshold" ] || threshold=$(awk -v l="$limit" -v t="$tolerance" \
            'BEGIN { if (l ~ /^[0-9]+(\.[0-9]+)?$/ && t ~ /^[0-9]+(\.[0-9]+)?$/) print l - t }')

        if [ -n "$day" ]; then
            summary="$iface · $(ntc_mode_label "$mode") · $(ntc_period_label "$period" "$day" "$month")"
        else
            summary="$iface · $(ntc_mode_label "$mode") · 配置异常：周期起始日必须为 1–31"
        fi
        if until=$(ntc_date_epoch "$pend"); then
            left_text=$(awk -v e="$((until + 86400))" -v n="$now" 'BEGIN { printf "%.2f", (e - n) / 86400 }')
            summary+="，还剩 $(ntc_days_left_text "$left_text")"
        fi

        cron_entry=false
        if $cron_ok && ntc_cron_has_entry "$cron" "$WORK_DIR/$MONITOR_SCRIPT"; then
            cron_entry=true
        fi
        until=$(ntc_kv "$ENFORCEMENT_STATE_FILE" UNTIL_EPOCH) || until=""
        IFS=$'\t' read -r level word detail < <(ntc_overall_status "$disabled" "$cron_ok" "$cron_entry" \
            "$WORK_DIR/monitor_health" "$status" "$speed" "$until" "$now")
        color=$(ui_level_color "$level")
        if [ -z "$detail" ]; then
            ui_row "$color" "$word" "$summary"
        else
            ui_row "$color" "$word" "$detail"
            ui_kv "周期" "$summary"
        fi

        if [ -n "$usage" ] && pct=$(ntc_percent "$usage" "$limit"); then
            text=""
            if [[ "$updated" =~ ^[0-9]+$ ]] && age=$(( (now - updated) / 60 )) && [ "$age" -ge 10 ]; then
                text="（${age} 分钟前）"
            fi
            ui_usage_kv "本期已用" "$(ntc_num "$usage") $unit / $(ntc_num "$limit") $unit" "$pct" "$text"
        else
            ui_kv "本期已用" "尚未统计（定时任务每分钟更新）"
        fi
        if [ "$lmode" = shutdown ]; then
            ui_kv "超额处理" "达到 $(ntc_num "$threshold" 2>/dev/null || printf '%s' "$threshold") $unit 后关机"
        else
            ui_kv "超额处理" "达到 $(ntc_num "$threshold" 2>/dev/null || printf '%s' "$threshold") $unit 后整机限速 ${speed:-?} kbit/s"
        fi
        if [ -n "$usage" ] && fc=$(ntc_forecast "$usage" "$threshold" "$pstart" "$pend" "$now"); then
            read -r elapsed _ _ avg projected hit <<< "$fc"
            if [ "$hit" = 0 ]; then
                :
            elif awk -v e="$elapsed" 'BEGIN { exit !(e < 1) }'; then
                ui_kv "本期预计" "本期刚开始，满一天后显示预计用量"
            elif [ "$hit" != -1 ]; then
                ui_row "$DIM" "本期预计" "约 $(ntc_num "$projected") $unit，按目前速度 $(date -d "@$hit" '+%m-%d' 2>/dev/null || echo '?') 达到阈值" "$YELLOW"
            else
                ui_kv "本期预计" "约 $(ntc_num "$projected") $unit（按本期日均 $(ntc_num "$avg") $unit）"
            fi
        fi
        [ "$partial" != true ] || ui_note "本期 vnStat 历史不完整，已用量可能偏低；进入新周期后恢复正常。"
    fi

    if [ ! -f "$tg_config" ]; then
        ui_kv "Telegram" "未配置（选 4 设置）"
    elif [ "$(ntc_kv "$tg_config" TG_DISABLED)" = true ]; then
        ui_kv "Telegram" "已停用"
    elif ! $cron_ok; then
        ui_kv "Telegram" "已配置（读不出 root crontab，不能确认是否在发送）"
    elif ! ntc_cron_has_entry "$cron" "$WORK_DIR/$TELEGRAM_SCRIPT"; then
        ui_kv "Telegram" "定时任务缺失，不会发送（选 4 打开时会自动补上）"
    else
        report_time=$(ntc_kv "$tg_config" DAILY_REPORT_TIME) || report_time=""
        warn=$(ntc_tg_warn_percents "$tg_config")
        if [ "$warn" = off ]; then warn="预警已关闭"; else warn="预警 ${warn//,/%、}%"; fi
        ui_kv "Telegram" "已启用${report_time:+，每日 $report_time 日报}；$warn"
    fi
    if ! missing=$(ntc_missing_tools); then
        ui_warn "缺少依赖：$missing（选 8 安装）"
    fi
    ui_rule
}

show_main_menu() {
    menu_clear
    show_dashboard
    ui_menu_groups 流量监控 系统维护 "$MAIN_MENU_SPLIT" "${MAIN_MENU_LABELS[@]}"
    ui_rule
    ui_option 0 退出
}

# 菜单动作放进子 shell：动作里的 exit、cd 或变量改动不会影响主菜单本身。
menu_run() {
    ( "$@" )
    return 0
}

main_menu() {
    local choice n
    while true; do
        show_main_menu
        if ! ui_prompt 10 choice; then
            printf '\n'
            return 0
        fi
        if ! n=$(ntc_int "$(ntc_trim "$choice")" 0 10); then
            ui_warn "无效选择，请输入 0–10。"
            sleep 1
            continue
        fi
        case "$n" in
            0) return 0 ;;
            1) menu_run show_status_detail ;;
            2) menu_run open_configure ;;
            3) menu_run open_component "$MACHINE_LIMIT_SCRIPT" ;;
            4) menu_run open_component "$TELEGRAM_SCRIPT" ;;
            5) menu_run run_check_now ;;
            6) menu_run view_logs ;;
            # 更新成功后要 exec 新版菜单，必须在当前 shell 里执行。
            7) update_scripts_interactive ;;
            8) menu_run dependency_host_menu ;;
            9) menu_run manage_tc_recovery ;;
            10) if uninstall_interactive; then return 0; fi ;;
        esac
    done
}

# 组件齐全时不输出任何内容；从安装目录以外运行（新下载或仓库副本）时才完整安装。
ensure_components_installed() {
    local name
    if [ "$SOURCE_PATH" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        for name in "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
            if [ ! -s "$WORK_DIR/$name" ] || [ ! -x "$WORK_DIR/$name" ]; then
                install_shortcut
                return $?
            fi
        done
        if [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
            install_shortcut_link || true
        fi
        return 0
    fi
    install_from_entrypoint
}

# 打开配置、限制执行、Telegram 之前：依赖命令齐全、组件已安装时什么也不输出。
ensure_runtime_ready() {
    if ! ntc_missing_tools >/dev/null; then
        dependency_install_for_host false || return 1
    fi
    ensure_components_installed
}

open_component() {
    local script_name="$1"
    shift
    if ! ensure_runtime_ready; then
        pause
        return 1
    fi
    bash "$WORK_DIR/$script_name" "$@"
}

# 已配置时 monitor 显示子菜单，每个动作后自己会停；未配置或已停用时它会在 NTC_MENU_PAUSE=1 下停一下再返回。
open_configure() {
    NTC_MENU_PAUSE=1 open_component "$MONITOR_SCRIPT" --configure
}

# 只读入口（状态、立即检查）只要求组件已安装，不触发依赖安装。
run_installed_component() {
    local script_name="$1"
    shift
    if [ ! -s "$WORK_DIR/$script_name" ]; then
        printf '%s\n' "NTC 尚未安装：运行 sudo ntc 后选择「修改监控配置」开始。" >&2
        return 1
    fi
    bash "$WORK_DIR/$script_name" "$@"
}

show_status_detail() {
    run_installed_component "$MONITOR_SCRIPT" --status
    pause
}

run_check_now() {
    run_installed_component "$MONITOR_SCRIPT" --check
    pause
}

tail_file() {
    local file="$1" title="$2" lines="${3:-40}"
    ui_title "$title" "最近 $lines 条，最新的在最下面"
    if [ -s "$file" ]; then
        tail -n "$lines" "$file"
    else
        ui_note "还没有记录（$file）"
    fi
}

show_logs_cli() {
    case "${1:-all}" in
        events|monitor) tail_file "$WORK_DIR/traffic_monitor.log" "事件日志" ;;
        telegram) tail_file "$WORK_DIR/tg_notifier_cron.log" "Telegram 通知日志" ;;
        operations) tail_file "$WORK_DIR/operations.log" "操作记录" ;;
        all)
            tail_file "$WORK_DIR/traffic_monitor.log" "事件日志"
            tail_file "$WORK_DIR/tg_notifier_cron.log" "Telegram 通知日志"
            tail_file "$WORK_DIR/operations.log" "操作记录"
            ;;
        *) printf '%s\n' '日志类型须为 events、telegram、operations 或 all。' >&2; return 2 ;;
    esac
}

view_logs() {
    local choice n cron
    while true; do
        menu_clear
        ui_title "查看日志"
        ui_option 1 "事件日志" "限速与解除、新周期、错误；正常时每小时一条"
        ui_option 2 "Telegram 通知日志"
        ui_option 3 "操作记录" "安装、更新、配置、启停"
        ui_option 4 "NTC 定时任务"
        ui_rule
        ui_option 0 返回
        ui_prompt 4 choice || return 0
        if ! n=$(ntc_int "$(ntc_trim "$choice")" 0 4); then
            ui_warn "无效选择，请输入 0–4。"
            sleep 1
            continue
        fi
        case "$n" in
            0) return 0 ;;
            1) show_logs_cli events ;;
            2) show_logs_cli telegram ;;
            3) show_logs_cli operations ;;
            4)
                ui_title "NTC 定时任务"
                if ! cron=$(read_current_crontab 2>/dev/null); then
                    ui_warn "无法读取 root crontab。"
                elif ! awk -v d="$WORK_DIR/" 'index($0, d)' <<< "$cron" | grep .; then
                    ui_note "没有 NTC 的定时任务。"
                fi
                ;;
        esac
        pause
    done
}

choose_update_base() {
    local choice n
    {
        ui_title "更新 NTC" "当前版本 $SCRIPT_VERSION"
        ui_option 1 "直连 GitHub"
        ui_option 2 "国内优先" "经 gh-proxy 镜像"
        ui_rule
        ui_option 0 返回
    } >&2
    # 读到 EOF 视为取消（1.x 会当作直连继续更新）。
    ui_prompt 2 choice "回车=1" || { printf '\n' >&2; return 1; }
    choice=$(ntc_trim "$choice")
    [ -n "$choice" ] || choice=1
    if ! n=$(ntc_int "$choice" 0 2); then
        ui_warn "无效选择。" >&2
        return 1
    fi
    case "$n" in
        1) printf '%s\n' "$UPDATE_DIRECT_BASE" ;;
        2) printf '%s\n' "$UPDATE_PROXY_BASE" ;;
        *) return 1 ;;
    esac
}

update_scripts_interactive() {
    local selected_base
    menu_clear
    if ! selected_base=$(choose_update_base); then
        ui_note "已取消更新。"
        pause
        return 0
    fi
    if update_scripts "$selected_base"; then
        ui_ok "正在载入新版菜单…"
        # exec 成功后不会回到这里；下一行只在 exec 失败时执行。
        # shellcheck disable=SC2093
        exec bash "$WORK_DIR/trafficcop-lite.sh"
        ui_err "新版菜单载入失败，请重新执行 sudo ntc。"
    fi
    pause
}

ntc_tc_status_label() {
    local status_output=""
    status_output=$(run_tc_self_check 2>/dev/null || true)
    case "$status_output" in
        *"TC_SELF_CHECK=OK"*"MODEL=absent"*) echo "未限速（没有 Dog/NTC 的 TC 规则）" ;;
        *"TC_SELF_CHECK=OK"*) echo "正常" ;;
        *"TC_SELF_CHECK=CONFLICT"*) echo "冲突（有外部或未知的 TC 配置）" ;;
        *"TC_SELF_CHECK=DRIFT"*) echo "异常（Dog/NTC 自己的规则已失效）" ;;
        *) echo "无法检测" ;;
    esac
}

show_tc_takeover_warning() {
    ui_err "当前 TC 配置可能已被其他程序修改。"
    printf '%s\n' "  继续会删除当前冲突的 TC/qdisc 配置，只重新建立 Dog/NTC 自己管理的规则；" \
        "  其他程序创建的 TC 配置不会保留。"
    ui_warn "如果其他 TC 管理脚本或服务还在，它们下次启动时仍可能覆盖 Dog/NTC，建议先卸载或停用。"
}

show_tc_auto_recovery_notice() {
    printf '%s\n' "  开启后，开机网络就绪时会检查一次 Dog/NTC 的 TC 规则：" \
        "  规则正常或当前没有需要恢复的规则时，不会修改 TC。" \
        "  只有默认 qdisc 缺失、或已识别的 Dog/NTC 统一层级失效时，才按现有状态重建；" \
        "  遇到外部或未知的 root qdisc 时不会自动接管，须在「TC 冲突处理 / 自动恢复」里手动确认。"
}

confirm_enable_tc_auto_recovery() {
    show_tc_auto_recovery_notice
    printf '\n'
    if ! ui_confirm "启用开机自动恢复？" n; then
        ui_note "未启用。"
        return 0
    fi
    if enable_tc_auto_recovery; then
        ui_ok "开机自动恢复已启用。"
    else
        ui_err "开机自动恢复启用失败。"
        return 1
    fi
}

tc_recovery_action() {
    local choice="$1" status_output status_kind confirm=""
    case "$choice" in
        1|2)
            status_output=$(run_tc_self_check 2>/dev/null || true)
            status_kind=$(ntc_tc_status_kind "$status_output")
            case "$status_kind" in
                ok|idle)
                    if [ "$status_kind" = ok ]; then
                        ui_ok "当前 TC 状态正常，无需强制重建。"
                    else
                        ui_note "当前没有需要恢复的 Dog/NTC TC 规则。"
                    fi
                    if [ "$choice" = 2 ]; then
                        printf '\n'
                        confirm_enable_tc_auto_recovery || true
                    fi
                    ;;
                conflict)
                    show_tc_takeover_warning
                    printf '\n'
                    if ! read -r -p " 确认接管并重建请输入 REBUILD: " confirm || [ "$confirm" != REBUILD ]; then
                        printf '\n'
                        ui_note "已取消。"
                    elif run_shared_tc_recovery --manual; then
                        ui_ok "TC 检测/重建完成。"
                        if [ "$choice" = 2 ]; then
                            if enable_tc_auto_recovery; then
                                ui_ok "开机自动恢复已启用。"
                            else
                                ui_err "TC 已重建，但开机自动恢复启用失败。"
                            fi
                        fi
                    else
                        ui_err "TC 重建失败，请运行 sudo ntc self-check 查看详情。"
                    fi
                    ;;
                *) ui_err "无法确认当前 TC 状态，未修改 qdisc。请先运行 sudo ntc self-check。" ;;
            esac
            ;;
        3) confirm_enable_tc_auto_recovery || true ;;
        4)
            if disable_tc_auto_recovery; then
                ui_ok "开机自动恢复已关闭。"
            else
                ui_err "开机自动恢复关闭失败；现有启用状态未被确认改变。"
            fi
            ;;
    esac
}

manage_tc_recovery() {
    local choice n
    while true; do
        menu_clear
        ui_title "TC 冲突处理 / 自动恢复"
        ui_kv "TC 状态" "$(ntc_tc_status_label)"
        ui_kv "自动恢复" "$(tc_auto_recovery_state)"
        ui_note "自动恢复是一个 systemd oneshot 服务，开机网络就绪后执行一次（与 Port Traffic Dog 共用）。"
        printf '\n'
        ui_option 1 "检测并按需重建 Dog/NTC 规则"
        ui_option 2 "检测并按需重建，同时启用开机自动恢复"
        ui_option 3 "启用开机自动恢复"
        ui_option 4 "关闭开机自动恢复"
        ui_rule
        ui_option 0 返回
        ui_prompt 4 choice || return 0
        if ! n=$(ntc_int "$(ntc_trim "$choice")" 0 4); then
            ui_warn "无效选择，请输入 0–4。"
            sleep 1
            continue
        fi
        [ "$n" -ne 0 ] || return 0
        printf '\n'
        tc_recovery_action "$n"
        pause
    done
}

# 停止监控和通知（旧参数 --stop）。先在监控锁内解除限速、取消计划关机，最后才删定时任务：
# 中途失败时监控仍在运行，不会出现“监控停了、限速却没人解除”的状态。
stop_all_services() {
    local has_error=false
    ui_title "停止 NTC 监控和通知"
    if ! acquire_monitor_cleanup_lock; then
        ui_err "无法取得监控锁，未作任何修改。"
        ntc_operation_log stop failure
        return 1
    fi
    stop_lite_processes
    clear_lite_tc_rules_interactive || has_error=true
    # --stop 不提问：NTC 没有记录的计划关机一律保留（只说明）。
    LITE_UNOWNED_SHUTDOWN_ANSWER=n cancel_shutdown_interactive || has_error=true
    if $has_error; then
        release_monitor_cleanup_lock
        ui_err "限速或计划关机未能安全解除；定时任务保持不变，监控继续运行。"
        ntc_operation_log stop failure
        return 1
    fi
    if ! remove_lite_cron; then
        release_monitor_cleanup_lock
        ui_err "无法移除定时任务：限速已解除，但监控仍在运行，仍超额时下一分钟会重新限速。"
        ntc_operation_log stop failure
        return 1
    fi
    release_monitor_cleanup_lock
    ui_ok "已移除 NTC 定时任务，监控和通知已停止；配置和状态文件保留。"
    ntc_operation_log stop success
    return 0
}

remove_shortcut_links() {
    local link
    for link in "$SHORTCUT_PATH" "$LEGACY_NCL_SHORTCUT_PATH" "$LEGACY_TC_SHORTCUT_PATH"; do
        if [ "$(readlink "$link" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
            rm -f "$link" && ui_ok "已删除快捷命令 $link"
        fi
    done
}

# 卸载。先问完所有问题，再按“备份 → 解除限速 → 取消计划关机 → 删除定时任务 → 删除目录”执行；
# 删除定时任务之前任何一步失败都会中止，监控照常运行（1.x 先删定时任务，之后失败会留下没人解除的限速）。
uninstall_lite() {
    local confirm="" keep_backup="" backup_dir="" cancel_unowned=""
    ui_title "卸载 NTC"
    ui_note "会删除：$WORK_DIR（可先备份）、NTC 的定时任务、限速规则和它安排的关机、快捷命令 ntc。"
    ui_note "不会卸载 vnstat、jq、bc 等系统软件包（之后可在依赖管理里处理）。"
    printf '\n'
    if ! read -r -p " 确认卸载请输入 UNINSTALL: " confirm || [ "$confirm" != UNINSTALL ]; then
        printf '\n'
        ui_note "已取消卸载。"
        return 1
    fi
    if [ -d "$WORK_DIR" ]; then
        if ! read -r -p " 删除前先备份配置和日志？[Y/n]: " keep_backup; then
            printf '\n'
            ui_note "已取消卸载。"
            return 1
        fi
        case "${keep_backup,,}" in n|no) keep_backup=n ;; *) keep_backup=y ;; esac
    fi

    # NTC 没有记录、又无法确认归属的计划关机（配置是关机模式）：在取锁之前和其他问题一起问完，默认保留。
    LITE_UNOWNED_SHUTDOWN_ANSWER=n
    if [ ! -f "$SHUTDOWN_STATE_FILE" ] && grep -q '^LIMIT_MODE=shutdown' "$WORK_DIR/traffic_monitor_config.txt" 2>/dev/null \
        && lite_has_pending_shutdown; then
        ui_warn "系统里有一个计划关机，NTC 没有它的记录（可能是旧版本或其他程序安排的）。"
        if ! read -r -p " 卸载时一并取消这个计划关机？[y/N]: " cancel_unowned; then
            printf '\n'
            ui_note "已取消卸载。"
            return 1
        fi
        case "${cancel_unowned,,}" in y|yes) LITE_UNOWNED_SHUTDOWN_ANSWER=y ;; esac
    fi

    if ! acquire_monitor_cleanup_lock; then
        ui_err "卸载已中止：无法取得监控锁，未作任何修改。"
        return 1
    fi
    if [ "$keep_backup" = y ]; then
        backup_dir="/etc/trafficcop-lite-backup-$(date +%Y%m%d-%H%M%S)"
        if ! mkdir -m 700 "$backup_dir" || ! cp -a "$WORK_DIR/." "$backup_dir/"; then
            release_monitor_cleanup_lock
            ui_err "卸载已中止：配置和日志备份失败，未作其他修改。"
            return 1
        fi
        chmod 700 "$backup_dir" 2>/dev/null || true
        ui_ok "已备份到 $backup_dir"
    fi
    stop_lite_processes
    if ! clear_lite_tc_rules_interactive; then
        release_monitor_cleanup_lock
        ui_err "卸载已中止：NTC 的限速未能安全解除；定时任务和配置都没有改动，监控照常运行。"
        return 1
    fi
    if ! cancel_shutdown_interactive; then
        release_monitor_cleanup_lock
        ui_err "卸载已中止：NTC 安排的关机未能安全取消；定时任务和配置都没有改动。"
        return 1
    fi
    if ! remove_lite_cron; then
        release_monitor_cleanup_lock
        ui_err "卸载已中止：无法移除定时任务。限速已解除，但监控仍在运行，仍超额时下一分钟会重新限速。"
        return 1
    fi
    ui_ok "已移除 NTC 定时任务"
    if [ -d "$WORK_DIR" ]; then
        if ! rm -rf "$WORK_DIR"; then
            release_monitor_cleanup_lock
            ui_err "删除 $WORK_DIR 失败：定时任务已移除、限速已解除，请手动检查该目录。"
            return 1
        fi
        ui_ok "已删除 $WORK_DIR"
    fi
    release_monitor_cleanup_lock
    remove_shortcut_links
    if ! cleanup_tc_recovery_files_if_unused; then
        ui_err "NTC 主体已删除，但共享 TC 自动恢复文件未能安全清理；卸载未完整完成。"
        return 1
    fi
    ui_ok "卸载完成。"
    return 0
}

# 菜单里的卸载：成功后询问是否顺便处理依赖，然后退出菜单。
uninstall_interactive() {
    menu_clear
    if ! uninstall_lite; then
        pause
        return 1
    fi
    printf '\n'
    if [ -t 0 ] && ui_confirm "要进入依赖管理，卸载 NTC 安装的软件包吗？" n; then
        dependency_host_menu || true
    fi
    return 0
}

component_display_version() {
    local file="$1" version
    version=$(sed -nE 's/^SCRIPT_VERSION="([0-9]+([.][0-9]+)*)".*/\1/p' "$file" 2>/dev/null | head -n 1)
    [ -n "$version" ] || version=$(script_version_from_file "$file")
    printf '%s' "${version:-未安装}"
}

show_versions() {
    local name
    printf 'NTC 主脚本 %s（%s）\n' "$SCRIPT_VERSION" "$LAST_UPDATE"
    for name in "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT"; do
        printf '%s %s\n' "$name" "$(component_display_version "$WORK_DIR/$name")"
    done
}

show_usage() {
    cat <<EOF
TrafficCop Lite（NTC）v$SCRIPT_VERSION：按月/季/年统计整机流量，超额后整机限速或关机。

用法: sudo ntc [命令]

  （无命令）                 打开菜单
  status [--json]            状态：用量、阈值、预测、执行状态、TC、定时任务、Telegram
  check                      立即检查一次（与每分钟的定时检查相同）
  config                     配置向导
  config show                显示当前配置
  config set 选项… [--yes]   不进菜单修改配置（sudo ntc config set --help 查看选项）
  pause | resume             暂停 / 恢复限制（流量照常统计）
  grace <分钟>               宽限一段时间，期间只统计、不限速
  enable | disable           启用 / 停用流量监控
  logs [events|telegram|operations]   查看日志
  telegram test|report       发送测试消息 / 立即发送一次日报
  update [--mirror]          更新 NTC（--mirror 走国内镜像）
  uninstall                  卸载 NTC
  self-check [网卡]          只读检查 TC 状态
  version                    显示各组件版本
  help                       显示本帮助

旧参数仍可用：--install [--yes]、--update、--uninstall、--stop、--logs [类型]、--config、
--self-check [网卡]、--recover-tc [--auto|--manual]、
--dependencies check|install [--yes]|remove [--all] [--yes]|owned
EOF
}

usage_error() {
    printf '%s\n\n' "未知命令或参数：$*" >&2
    show_usage >&2
    return 2
}

main() {
    local _ cmd="${1:-}" status
    if [ -z "${COLUMNS:-}" ] && [ -t 0 ] && command -v stty >/dev/null 2>&1; then
        read -r _ COLUMNS < <(stty size 2>/dev/null) || true
    fi
    case "$cmd" in
        help|--help|-h) show_usage; return 0 ;;
        --dependencies) shift; dependency_host_cli "$@"; return $? ;;
        # 已知子命令（含旧参数别名）。未知命令在要求 root、创建安装目录之前就报错退出 2。
        ''|version|--version|self-check|--self-check|--tc-self-check|logs|--logs|status|--config|--install|\
        uninstall|--uninstall|--stop|--recover-tc|update|--update|check|config|pause|resume|enable|disable|\
        grace|telegram) ;;
        *) usage_error "$@"; return 2 ;;
    esac
    check_root
    # 只读命令先于安装目录初始化执行，保留原始权限和空安装现场。
    case "$cmd" in
        version|--version) [ "$#" -eq 1 ] || { usage_error "$@"; return 2; }; show_versions; return 0 ;;
        self-check|--self-check|--tc-self-check) run_tc_self_check "${2:-}"; return $? ;;
        logs|--logs)
            [ "$#" -le 2 ] || { usage_error "$@"; return 2; }
            if [ -n "${2:-}" ] || [ ! -t 0 ]; then
                show_logs_cli "${2:-all}"
                return $?
            fi
            view_logs
            return $?
            ;;
        status) shift; run_installed_component "$MONITOR_SCRIPT" --status "$@"; return $? ;;
        --config) [ "$#" -eq 1 ] || { usage_error "$@"; return 2; }; run_installed_component "$MONITOR_SCRIPT" --config-show; return $? ;;
    esac
    ensure_work_dir

    case "$cmd" in
        '') ;;
        --install)
            case "${2:-}" in
                '') [ "$#" -eq 1 ] || return 2; dependency_install_for_host false || return $? ;;
                --yes) [ "$#" -eq 2 ] || return 2; dependency_install_for_host true || return $? ;;
                *) return 2 ;;
            esac
            install_from_entrypoint
            status=$?
            [ "$status" -eq 0 ] || return "$status"
            ui_ok "安装完成。以后可执行：sudo ntc"
            return 0
            ;;
        uninstall|--uninstall) [ "$#" -eq 1 ] || { usage_error "$@"; return 2; }; uninstall_lite; return $? ;;
        --stop) stop_all_services; return $? ;;
        --recover-tc) run_shared_tc_recovery "${2:---manual}"; return $? ;;
        update|--update)
            case "$#:${2:-}" in
                1:) update_scripts "$RAW_BASE" ;;
                2:--mirror) update_scripts "$UPDATE_PROXY_BASE" ;;
                *) usage_error "$@"; return 2 ;;
            esac
            return $?
            ;;
        check) [ "$#" -eq 1 ] || { usage_error "$@"; return 2; }; run_installed_component "$MONITOR_SCRIPT" --check; return $? ;;
        config)
            case "${2:-}" in
                '') [ "$#" -eq 1 ] || { usage_error "$@"; return 2; }
                    ensure_runtime_ready || return 1
                    bash "$WORK_DIR/$MONITOR_SCRIPT" --configure
                    return $?
                    ;;
                show) [ "$#" -eq 2 ] || { usage_error "$@"; return 2; }; run_installed_component "$MONITOR_SCRIPT" --config-show; return $? ;;
                set) shift 2; run_installed_component "$MONITOR_SCRIPT" --config-set "$@"; return $? ;;
                *) usage_error "$@"; return 2 ;;
            esac
            ;;
        pause|resume|enable|disable)
            [ "$#" -eq 1 ] || { usage_error "$@"; return 2; }
            run_installed_component "$MACHINE_LIMIT_SCRIPT" "--$cmd"
            return $?
            ;;
        grace)
            [ "$#" -eq 2 ] || { usage_error "$@"; return 2; }
            run_installed_component "$MACHINE_LIMIT_SCRIPT" --grace "$2"
            return $?
            ;;
        telegram)
            case "$#:${2:-}" in
                2:test) run_installed_component "$TELEGRAM_SCRIPT" --test ;;
                2:report) run_installed_component "$TELEGRAM_SCRIPT" --report ;;
                1:) ensure_runtime_ready || return 1; bash "$WORK_DIR/$TELEGRAM_SCRIPT" ;;
                *) usage_error "$@"; return 2 ;;
            esac
            return $?
            ;;
        *) usage_error "$@"; return 2 ;;
    esac

    # 无参数：进入菜单。依赖命令齐全且没有未完成的依赖事务时，顺带补齐组件和快捷命令（已齐全则不输出）。
    if ntc_missing_tools >/dev/null; then
        if [ "$(dependency_package_manager)" != apt-get ] || dependency_no_pending; then
            ensure_components_installed || true
        fi
    fi
    main_menu
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
