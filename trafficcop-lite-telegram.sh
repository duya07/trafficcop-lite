#!/bin/bash

# 需要 root；只看帮助（--help/-h）时例外。
if [[ "${BASH_SOURCE[0]}" == "$0" ]] && [ "$(id -u)" -ne 0 ]; then
    case "$#:${1:-}" in
        1:-h|1:--help) ;;
        *)
            echo "请使用 root 权限运行此脚本。" >&2
            exit 1
            ;;
    esac
fi

# 设置新的工作目录
WORK_DIR="/etc/trafficcop-lite"

# 更新文件路径
CONFIG_FILE="$WORK_DIR/tg_notifier_config.txt"
LAST_NOTIFICATION_FILE="$WORK_DIR/last_traffic_notification"
LAST_DAILY_REPORT_FILE="$WORK_DIR/last_daily_report"
PERIOD_STATE_FILE="$WORK_DIR/last_reset_period"
USAGE_STATE_FILE="$WORK_DIR/current_traffic_state"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-telegram.sh"
CRON_LOG="$WORK_DIR/tg_notifier_cron.log"
TG_LOCK_FILE="$WORK_DIR/tg_notifier.lock"
ROOT_CRONTAB_LOCK_FILE="${TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE:-$WORK_DIR/root-crontab.lock}"
CRON_LOG_MAX_LINES="${CRON_LOG_MAX_LINES:-2000}"
TG_DEBUG="${TG_DEBUG:-false}"
MONITOR_HEALTH_FILE="$WORK_DIR/monitor_health"
MONITOR_ALERT_STATE_FILE="$WORK_DIR/last_monitor_alert"
MONITOR_ALERT_INTERVAL="${MONITOR_ALERT_INTERVAL:-21600}"   # 同一异常最多每 6 小时提醒一次
MONITOR_STALE_SECONDS="${MONITOR_STALE_SECONDS:-600}"       # 健康状态超过 10 分钟未更新视为监控未运行
SCRIPT_VERSION="2.0.0"

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

# 此函数只由 EXIT trap 调用，ShellCheck 无法沿字符串形式的 trap 识别调用关系。
# shellcheck disable=SC2317,SC2329
trim_log_file() {
    local file="$1"
    local max_lines="$2"
    local tmp_file

    if [ ! -f "$file" ]; then
        return
    fi
    if ! [[ "$max_lines" =~ ^[1-9][0-9]*$ ]]; then
        max_lines=2000
    fi
    local trim_at=$((max_lines + max_lines / 5))
    if [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -le "$trim_at" ]; then
        return
    fi

    tmp_file="${file}.tmp.$$"
    tail -n "$max_lines" "$file" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$file"
    rm -f "$tmp_file" 2>/dev/null || true
}

log_cron() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" >> "$CRON_LOG"
}

debug_log() {
    if [ "${TG_DEBUG:-false}" = "true" ]; then
        log_cron "[调试] $*"
    fi
}

# 防止两个 Telegram 任务同时运行：cron 不等待（$1 省略或为 0），菜单与命令行最多等 $1 秒。
# 每分钟的例行运行不写日志，只有真正撞上锁时才记一行。
check_running() {
    local wait_seconds="${1:-0}"

    exec 8>"$TG_LOCK_FILE"
    chmod 600 "$TG_LOCK_FILE" 2>/dev/null || true
    if { [ "$wait_seconds" -gt 0 ] && ! flock -w "$wait_seconds" 8; } \
        || { [ "$wait_seconds" -eq 0 ] && ! flock -n 8; }; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 另一个 Telegram 任务正在运行，本次跳过" >> "$CRON_LOG"
        ui_warn "另一个 Telegram 通知任务正在运行，请稍后重试。"
        exec 8>&-
        return 1
    fi
    trap 'flock -u 8 2>/dev/null || true; trim_log_file "$CRON_LOG" "$CRON_LOG_MAX_LINES"' EXIT
}

release_running_lock() {
    flock -u 8 2>/dev/null || true
    exec 8>&-
    trap 'trim_log_file "$CRON_LOG" "$CRON_LOG_MAX_LINES"' EXIT
}

run_with_telegram_lock() {
    local status

    check_running 15 || return 1
    "$@"
    status=$?
    release_running_lock
    return "$status"
}

# 检查运行依赖。$1=cron|cli|interactive：只有菜单（interactive）且标准输入是终端时才提议安装；
# cron 与 --test/--report（cli）只说明缺什么，绝不安装、不读输入。
check_runtime_dependencies() {
    local command_name entry="$WORK_DIR/trafficcop-lite.sh" mode="${1:-}" perms
    local missing_commands=()

    for command_name in curl crontab flock sed awk; do
        command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
    done
    if ! { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; } &&
       ! { [ -s /etc/ssl/cert.pem ] && [ -r /etc/ssl/cert.pem ]; }; then
        missing_commands+=('@ca-certificates')
    fi
    [ "${#missing_commands[@]}" -gt 0 ] || return 0
    ui_err "缺少运行依赖：${missing_commands[*]}"
    # Never install packages in a cron invocation or execute an untrusted helper.
    if [ "$mode" = interactive ] && [ -t 0 ] && [ -f "$entry" ] && [ ! -L "$entry" ] &&
       [ "$(stat -c %u:%h -- "$entry" 2>/dev/null)" = 0:1 ] &&
       perms=$(stat -c %a -- "$entry") && (( (8#$perms & 0022) == 0 )) &&
       grep -Fqx '# BEGIN MANAGED DEPENDENCIES' "$entry"; then
        bash "$entry" --dependencies install || return 1
        for command_name in "${missing_commands[@]}"; do
            if [ "$command_name" = '@ca-certificates' ]; then
                { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -r /etc/ssl/certs/ca-certificates.crt ]; } ||
                    { [ -s /etc/ssl/cert.pem ] && [ -r /etc/ssl/cert.pem ]; } || return 1
            else
                command -v "$command_name" >/dev/null 2>&1 || return 1
            fi
        done
        return 0
    fi
    ui_note "请在 ntc 主菜单的「依赖管理」里安装，或运行 sudo ntc --dependencies install。" >&2
    return 1
}

read_current_crontab() {
    local error_file="$WORK_DIR/.crontab-read-error.$$"
    local current_crontab status

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

    log_cron "读取当前 crontab 失败：$(cat "$error_file" 2>/dev/null)"
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

is_valid_timezone() {
    local timezone="$1"

    case "$timezone" in
        ""|/*|*..*) return 1 ;;
        UTC|GMT) return 0 ;;
    esac
    [ -f "/usr/share/zoneinfo/$timezone" ]
}

decode_legacy_config_value() {
    local encoded="$1"
    local decoded=""
    local char

    if [ "$encoded" = "''" ] || [ "$encoded" = '""' ]; then
        return 0
    fi
    if [ "${encoded:0:2}" = "\$'" ] && [ "${encoded: -1}" = "'" ] && [ "${#encoded}" -ge 3 ]; then
        encoded=${encoded:2:${#encoded}-3}
        printf '%b' "$encoded"
        return 0
    fi

    while [ -n "$encoded" ]; do
        char=${encoded:0:1}
        if [ "$char" = "\\" ] && [ "${#encoded}" -ge 2 ]; then
            decoded+="${encoded:1:1}"
            encoded=${encoded:2}
        else
            decoded+="$char"
            encoded=${encoded:1}
        fi
    done
    printf '%s' "$decoded"
}

# 读取配置。成功返回 0；失败返回 1，原因写入 TG_CONFIG_ERROR（菜单、命令行各自显示，cron 只记日志）。
# 2.0 新增可选项 WARN_PERCENTS（阈值预警档位）：旧配置没有该键时取默认 80,90；off 或空表示关闭；
# 手工改坏时按默认值执行，原值放进 TG_WARN_INVALID 供菜单提示——档位写错不应连带停掉其他通知。
read_config() {
    local key raw_value value
    local config_format="legacy"
    local warn_seen=false

    TG_CONFIG_ERROR=""
    TG_WARN_INVALID=""
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        TG_CONFIG_ERROR="还没有配置"
        return 1
    fi

    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    unset BOT_TOKEN CHAT_ID DAILY_REPORT_TIME REPORT_TIMEZONE MACHINE_NAME TG_DISABLED WARN_PERCENTS
    # 旧配置没有开关字段时保持原行为：自动通知默认开启。
    while IFS='=' read -r key raw_value || [ -n "$key$raw_value" ]; do
        raw_value=${raw_value%$'\r'}
        if [ "$key" = "CONFIG_FORMAT" ]; then
            if [ "$raw_value" != "plain-v2" ]; then
                TG_CONFIG_ERROR="不支持的配置格式：$raw_value"
                return 1
            fi
            config_format="$raw_value"
            continue
        fi
        case "$key" in
            BOT_TOKEN|CHAT_ID|DAILY_REPORT_TIME|REPORT_TIMEZONE|MACHINE_NAME|TG_DISABLED|WARN_PERCENTS)
                if [ "$config_format" = "plain-v2" ]; then
                    value="$raw_value"
                elif ! value=$(decode_legacy_config_value "$raw_value"); then
                    TG_CONFIG_ERROR="旧格式配置无法解析"
                    return 1
                fi
                [ "$key" != WARN_PERCENTS ] || warn_seen=true
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    REPORT_TIMEZONE="${REPORT_TIMEZONE:-Asia/Shanghai}"
    TG_DISABLED="${TG_DISABLED:-false}"
    if ! $warn_seen; then
        WARN_PERCENTS="80,90"
    elif [ -z "$WARN_PERCENTS" ] || [ "${WARN_PERCENTS,,}" = off ]; then
        WARN_PERCENTS="off"
    elif [[ ! "$WARN_PERCENTS" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] || [[ ",$WARN_PERCENTS," =~ ,0{1,2}, ]]; then
        TG_WARN_INVALID="$WARN_PERCENTS"
        WARN_PERCENTS="80,90"
    fi

    # 检查必要的配置项是否都存在
    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ] || [ -z "${MACHINE_NAME:-}" ] || [ -z "${DAILY_REPORT_TIME:-}" ]; then
        TG_CONFIG_ERROR="配置不完整"
        return 1
    fi
    case "$BOT_TOKEN$CHAT_ID$MACHINE_NAME$DAILY_REPORT_TIME$REPORT_TIMEZONE" in
        *$'\n'*|*$'\r'*)
            TG_CONFIG_ERROR="配置包含非法换行"
            return 1
            ;;
    esac
    if [[ ! "$DAILY_REPORT_TIME" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        TG_CONFIG_ERROR="每日报告时间格式无效：$DAILY_REPORT_TIME"
        return 1
    fi
    if ! is_valid_timezone "$REPORT_TIMEZONE"; then
        TG_CONFIG_ERROR="报告时区无效：$REPORT_TIMEZONE"
        return 1
    fi
    case "$TG_DISABLED" in
        true|false) ;;
        *)
            TG_CONFIG_ERROR="自动通知开关的值无效：$TG_DISABLED"
            return 1
            ;;
    esac

    return 0
}

# 写入配置
write_config_value() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$value"
}

# 原子写入整份配置（成功时不输出，由调用方说明结果）。
write_config() {
    local tmp_file="${CONFIG_FILE}.tmp.$$"
    if ! {
        printf 'CONFIG_FORMAT=plain-v2\n'
        write_config_value "BOT_TOKEN" "$BOT_TOKEN"
        write_config_value "CHAT_ID" "$CHAT_ID"
        write_config_value "DAILY_REPORT_TIME" "$DAILY_REPORT_TIME"
        write_config_value "REPORT_TIMEZONE" "${REPORT_TIMEZONE:-Asia/Shanghai}"
        write_config_value "MACHINE_NAME" "$MACHINE_NAME"
        write_config_value "TG_DISABLED" "${TG_DISABLED:-false}"
        write_config_value "WARN_PERCENTS" "${WARN_PERCENTS:-80,90}"
    } > "$tmp_file"; then
        rm -f "$tmp_file"
        ntc_operation_log telegram-config failure
        return 1
    fi
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$CONFIG_FILE" || { rm -f "$tmp_file"; ntc_operation_log telegram-config failure; return 1; }
    ntc_operation_log telegram-config success
}

# 规范化预警档位：「90, 80，80」→「80,90」（去重、按数值排序，可用中英文逗号、顿号或空格分隔）；
# off、关闭或空输出 off。每档须是 1–99 的整数，任何一项不合法都返回 1。
normalize_warn_percents() {
    local raw item value out=""
    local -a items=() seen=()

    raw=$(ntc_trim "${1:-}")
    case "${raw,,}" in
        ''|off|关闭)
            printf 'off'
            return 0
            ;;
    esac
    raw="${raw//，/,}"
    raw="${raw//、/,}"
    raw="${raw// /,}"
    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        [ -n "$item" ] || continue
        value=$(ntc_int "$item" 1 99) || return 1
        seen[value]=1
    done
    for value in "${!seen[@]}"; do
        out+="${out:+,}$value"
    done
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# 预警档位的显示形式：80,90 → 80%、90%；off → 已关闭。
warn_percents_label() {
    local value="${1:-}"
    if [ -z "$value" ] || [ "$value" = off ]; then
        printf '已关闭'
    else
        printf '%s%%' "${value//,/%、}"
    fi
}

# 依次询问 Bot Token、Chat ID、机器名，结果写入 NEW_BOT_TOKEN、NEW_CHAT_ID、NEW_MACHINE_NAME。
# 回车保留当前值；Token、Chat ID 只显示遮挡后的形式。任何一步读到 EOF 返回 1（视为取消）。
prompt_bot_settings() {
    local answer hint default_name

    NEW_BOT_TOKEN="${BOT_TOKEN:-}"
    NEW_CHAT_ID="${CHAT_ID:-}"
    NEW_MACHINE_NAME="${MACHINE_NAME:-}"

    while true; do
        hint="Bot Token（向 @BotFather 申请）"
        [ -z "$NEW_BOT_TOKEN" ] || hint+=" [当前 $(ntc_mask "$NEW_BOT_TOKEN")，回车保留]"
        ui_read answer "$hint" || return 1
        if [ -z "$answer" ]; then
            [ -z "$NEW_BOT_TOKEN" ] || break
            ui_warn "Bot Token 不能为空。"
        elif [[ "$answer" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            NEW_BOT_TOKEN="$answer"
            break
        else
            ui_warn "格式不对：Token 形如 123456789:AAH…（数字、冒号，后面是字母数字）。"
        fi
    done

    while true; do
        hint="Chat ID（个人或群组的数字 ID，频道可填 @用户名）"
        [ -z "$NEW_CHAT_ID" ] || hint+=" [当前 $(ntc_mask "$NEW_CHAT_ID")，回车保留]"
        ui_read answer "$hint" || return 1
        if [ -z "$answer" ]; then
            [ -z "$NEW_CHAT_ID" ] || break
            ui_warn "Chat ID 不能为空。"
        elif [[ "$answer" =~ ^-?[0-9]+$ || "$answer" =~ ^@[A-Za-z0-9_]{4,}$ ]]; then
            NEW_CHAT_ID="$answer"
            break
        else
            ui_warn "格式不对：Chat ID 是一串数字（群组以 -100 开头），或频道的 @用户名。"
        fi
    done

    default_name="${NEW_MACHINE_NAME:-${HOSTNAME:-}}"
    while true; do
        ui_read answer "机器名（显示在每条消息开头）" "$default_name" || return 1
        [ -z "$answer" ] || break
        ui_warn "机器名不能为空。"
    done
    NEW_MACHINE_NAME="$answer"
}

# 询问每日报告时间与时区，结果写入 NEW_REPORT_TIME、NEW_REPORT_TIMEZONE；回车保留方括号里的值。EOF 返回 1。
prompt_report_schedule() {
    local answer hour minute

    NEW_REPORT_TIME="${DAILY_REPORT_TIME:-08:00}"
    NEW_REPORT_TIMEZONE="${REPORT_TIMEZONE:-Asia/Shanghai}"
    while true; do
        ui_read answer "每日报告时间（24 小时制 HH:MM）" "$NEW_REPORT_TIME" || return 1
        if [[ "$answer" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
            hour=$((10#${BASH_REMATCH[1]}))
            minute=$((10#${BASH_REMATCH[2]}))
            if [ "$hour" -le 23 ] && [ "$minute" -le 59 ]; then
                printf -v NEW_REPORT_TIME '%02d:%02d' "$hour" "$minute"
                break
            fi
        fi
        ui_warn "时间格式不对，例如 08:00 或 21:30。"
    done
    while true; do
        ui_read answer "报告时区（例如 Asia/Shanghai、UTC）" "$NEW_REPORT_TIMEZONE" || return 1
        if is_valid_timezone "$answer"; then
            NEW_REPORT_TIMEZONE="$answer"
            break
        fi
        ui_warn "找不到时区「$answer」，请填 /usr/share/zoneinfo 下的名称，例如 Asia/Shanghai。"
    done
}

# 首次设置（菜单「开始设置」）：机器人与机器名、每日报告时间与时区；预警档位先用默认值，菜单里可改。
# 摘要确认后保存并启用定时任务，最后询问是否发送测试消息。任何一步读到 EOF 都不保存。
initial_config() {
    local status=0

    ui_title "设置 Telegram 通知" "回车使用方括号里的值"
    if ! prompt_bot_settings || ! prompt_report_schedule; then
        ui_warn "已取消，配置未保存。"
        return 1
    fi
    WARN_PERCENTS="${WARN_PERCENTS:-80,90}"
    printf '\n'
    ui_kv "机器人" "Token $(ntc_mask "$NEW_BOT_TOKEN") · Chat ID $(ntc_mask "$NEW_CHAT_ID")"
    ui_kv "机器名" "$NEW_MACHINE_NAME"
    ui_kv "每日报告" "$NEW_REPORT_TIME（$NEW_REPORT_TIMEZONE）"
    ui_kv "阈值预警" "$(warn_percents_label "$WARN_PERCENTS")（之后可在菜单里修改）"
    if ! ui_confirm "保存？" y; then
        ui_warn "已取消，配置未保存。"
        return 1
    fi
    BOT_TOKEN="$NEW_BOT_TOKEN"
    CHAT_ID="$NEW_CHAT_ID"
    MACHINE_NAME="$NEW_MACHINE_NAME"
    DAILY_REPORT_TIME="$NEW_REPORT_TIME"
    REPORT_TIMEZONE="$NEW_REPORT_TIMEZONE"
    # 先以「停用」保存，定时任务装好后再切到启用：中途失败时菜单如实显示「已停用」。
    TG_DISABLED=true
    if ! write_config; then
        ui_err "保存失败：无法写入 $CONFIG_FILE。"
        return 1
    fi
    ui_ok "配置已保存。"
    if ! run_with_telegram_lock enable_telegram_notifications; then
        status=1
        ui_warn "自动通知还没有启用，稍后可在本菜单选「启用通知」重试。"
    fi
    if ui_confirm "现在发送一条测试消息？" y; then
        run_with_telegram_lock send_test_message || true
    fi
    return "$status"
}

# 菜单「设置机器人与机器名」：回车保留当前值；有改动时摘要确认后保存，保存后询问是否发送测试消息。
configure_bot() {
    local old_token="${BOT_TOKEN:-}" old_chat="${CHAT_ID:-}" old_name="${MACHINE_NAME:-}"

    ui_title "设置机器人与机器名" "回车保留当前值"
    if ! prompt_bot_settings; then
        ui_warn "已取消，配置未改动。"
        return 1
    fi
    if [ "$NEW_BOT_TOKEN" = "$old_token" ] && [ "$NEW_CHAT_ID" = "$old_chat" ] &&
       [ "$NEW_MACHINE_NAME" = "$old_name" ]; then
        ui_ok "没有改动。"
        return 0
    fi
    printf '\n'
    ui_kv "机器人" "Token $(ntc_mask "$NEW_BOT_TOKEN") · Chat ID $(ntc_mask "$NEW_CHAT_ID")"
    ui_kv "机器名" "$NEW_MACHINE_NAME"
    if ! ui_confirm "保存？" y; then
        ui_warn "已取消，配置未改动。"
        return 1
    fi
    BOT_TOKEN="$NEW_BOT_TOKEN"
    CHAT_ID="$NEW_CHAT_ID"
    MACHINE_NAME="$NEW_MACHINE_NAME"
    if ! write_config; then
        BOT_TOKEN="$old_token"
        CHAT_ID="$old_chat"
        MACHINE_NAME="$old_name"
        ui_err "保存失败：无法写入 $CONFIG_FILE，配置保持原样。"
        return 1
    fi
    ui_ok "已保存。"
    if ui_confirm "现在发送一条测试消息？" y; then
        run_with_telegram_lock send_test_message || true
    fi
    return 0
}

# 菜单「每日报告时间与时区」：只改配置里的日报时间——定时任务每分钟运行一次，不需要改。
edit_report_schedule() {
    local old_time="${DAILY_REPORT_TIME:-}" old_zone="${REPORT_TIMEZONE:-}" today now_time last_sent

    ui_title "每日报告时间与时区" "回车保留当前值"
    if ! prompt_report_schedule; then
        ui_warn "已取消，配置未改动。"
        return 1
    fi
    if [ "$NEW_REPORT_TIME" = "$old_time" ] && [ "$NEW_REPORT_TIMEZONE" = "$old_zone" ]; then
        ui_ok "没有改动。"
        return 0
    fi
    printf '\n'
    ui_kv "每日报告" "$NEW_REPORT_TIME（$NEW_REPORT_TIMEZONE）"
    if ! ui_confirm "保存？" y; then
        ui_warn "已取消，配置未改动。"
        return 1
    fi
    DAILY_REPORT_TIME="$NEW_REPORT_TIME"
    REPORT_TIMEZONE="$NEW_REPORT_TIMEZONE"
    if ! write_config; then
        DAILY_REPORT_TIME="$old_time"
        REPORT_TIMEZONE="$old_zone"
        ui_err "保存失败：无法写入 $CONFIG_FILE，配置保持原样。"
        return 1
    fi
    ui_ok "每日报告时间已改为 $DAILY_REPORT_TIME（$REPORT_TIMEZONE）。"
    if [ "${TG_DISABLED:-false}" = true ]; then
        ui_note "自动通知目前已停用，启用后才会按时发送。"
        return 0
    fi
    today=$(TZ="$REPORT_TIMEZONE" date +%Y-%m-%d)
    now_time=$(TZ="$REPORT_TIMEZONE" date +%H:%M)
    last_sent=$(cat "$LAST_DAILY_REPORT_FILE" 2>/dev/null || true)
    if [ "$last_sent" = "$today" ]; then
        ui_note "今天的日报已经发过，新时间从明天起生效。"
    elif [[ "$now_time" < "$DAILY_REPORT_TIME" ]]; then
        ui_note "今天 $DAILY_REPORT_TIME 发送。"
    else
        ui_note "今天的发送时间已过且还没发过，一分钟内会补发今天的日报。"
    fi
    return 0
}

# 菜单「阈值预警档位」：本期用量越过某一档时推送一次（每期每档一次）；输入 off 关闭。
edit_warn_percents() {
    local answer value current="${WARN_PERCENTS:-80,90}"

    ui_title "阈值预警档位" "本期用量越过某档时推送一次，每期每档只发一次"
    ui_note "填 1–99 的整数，用逗号分隔，例如 80,90；填 off 关闭预警。"
    while true; do
        if ! ui_read answer "预警档位（%）" "$current"; then
            ui_warn "已取消，配置未改动。"
            return 1
        fi
        if value=$(normalize_warn_percents "$answer"); then
            break
        fi
        ui_warn "格式不对：每档是 1–99 的整数，例如 80,90；或填 off。"
    done
    if [ "$value" = "$current" ] && [ -z "${TG_WARN_INVALID:-}" ]; then
        ui_ok "没有改动。"
        return 0
    fi
    printf '\n'
    ui_kv "阈值预警" "$(warn_percents_label "$value")"
    if ! ui_confirm "保存？" y; then
        ui_warn "已取消，配置未改动。"
        return 1
    fi
    WARN_PERCENTS="$value"
    if ! write_config; then
        WARN_PERCENTS="$current"
        ui_err "保存失败：无法写入 $CONFIG_FILE，配置保持原样。"
        return 1
    fi
    ui_ok "阈值预警已改为：$(warn_percents_label "$value")。"
}

# 菜单「启用通知 / 停用通知」：按当前状态二选一；停用需要确认（默认否）。
toggle_notifications() {
    if [ "${TG_DISABLED:-false}" = true ]; then
        run_with_telegram_lock enable_telegram_notifications
        return
    fi
    ui_note "停用后不再自动推送限速、预警、日报和监控异常；配置保留，测试消息和立即日报仍可用。"
    if ! ui_confirm "停用 Telegram 自动通知？" n; then
        ui_warn "已取消，通知保持启用。"
        return 1
    fi
    run_with_telegram_lock disable_telegram_notifications
}

# 发送一条 Telegram 消息。Token 只经标准输入交给 curl（不出现在进程参数里）。
# 失败时返回 1，并把可读的原因写入 TG_SEND_ERROR（菜单与 --test 用它说明为什么失败）。
# 不用 curl -f：保留 Telegram 的 HTTP 状态码与错误说明，才能区分 Token 无效、会话不对、被限流等情况。
telegram_send_message() {
    local message="$1"
    local response status=0 http_code body description
    local api_url curl_url

    TG_SEND_ERROR=""
    message="${message//%0A/$'\n'}"
    api_url="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    curl_url="${api_url//\\/\\\\}"
    curl_url="${curl_url//\"/\\\"}"

    response=$(printf 'url = "%s"\n' "$curl_url" | curl -sS --connect-timeout 10 --max-time 30 --config - -X POST \
        -w '\n%{http_code}' \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$message" 2>/dev/null) || status=$?
    if [ "$status" -ne 0 ]; then
        case "$status" in
            6) TG_SEND_ERROR="无法解析 api.telegram.org（DNS 失败）" ;;
            7) TG_SEND_ERROR="连不上 api.telegram.org（网络不通或被拦截）" ;;
            28) TG_SEND_ERROR="连接 Telegram 超时" ;;
            35|51|58|59|60|77|83|90|91) TG_SEND_ERROR="TLS 握手或证书校验失败（检查系统时间与 ca-certificates）" ;;
            *) TG_SEND_ERROR="curl 返回错误码 $status" ;;
        esac
        return 1
    fi
    # 最后一行是 -w 输出的 HTTP 状态码，前面是响应正文。
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"
    [ "$body" != "$response" ] || body=""
    if [ "$http_code" = 200 ] && printf '%s\n' "$body" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
        return 0
    fi
    description=$(printf '%s\n' "$body" | sed -n 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    case "$http_code" in
        200) TG_SEND_ERROR="Telegram 返回了意外的响应" ;;
        401|404) TG_SEND_ERROR="Bot Token 无效" ;;
        400) TG_SEND_ERROR="Chat ID 不对，或机器人还没有加入该会话" ;;
        403) TG_SEND_ERROR="机器人无权向该会话发消息（可能被屏蔽或已被移出群组）" ;;
        429) TG_SEND_ERROR="发送太频繁，被 Telegram 限流" ;;
        5[0-9][0-9]) TG_SEND_ERROR="Telegram 服务暂时不可用（HTTP $http_code）" ;;
        *) TG_SEND_ERROR="Telegram 返回了意外的响应（HTTP ${http_code:-未知}）" ;;
    esac
    [ -z "$description" ] || TG_SEND_ERROR+="（Telegram：$description）"
    return 1
}

# 发送限速警告
send_throttle_warning() {
    local message="⚠️ [${MACHINE_NAME}]限速警告：流量已达到限制，已启动 TC 模式限速。"
    telegram_send_message "$message"
}

# 发送限速解除通知
send_throttle_lifted() {
    local message="✅ [${MACHINE_NAME}]限速解除：流量已恢复正常，所有限制已清除。"
    telegram_send_message "$message"
}

# 发送新周期开始通知
send_new_cycle_notification() {
    local message="🔄 [${MACHINE_NAME}]新周期开始：新的流量统计周期已开始，之前的限速（如果有）已自动解除。"
    telegram_send_message "$message"
}

# 发送关机警告
send_shutdown_warning() {
    local message="🚨 [${MACHINE_NAME}]关机警告：流量已达到严重限制，系统已进入计划关机状态！"
    telegram_send_message "$message"
}

# 测试消息正文：顺带说明当前的日报时间与预警档位，便于确认设置。
build_test_message() {
    printf '🔔 [%s]测试消息\n收到这条消息，说明 NTC 的 Telegram 通知可以正常推送。\n' "$MACHINE_NAME"
    if [ "${TG_DISABLED:-false}" = true ]; then
        printf '自动通知：已停用（限速、预警、日报都不会自动推送）\n'
    else
        printf '每日报告：%s（%s）\n' "$DAILY_REPORT_TIME" "${REPORT_TIMEZONE:-Asia/Shanghai}"
        printf '阈值预警：%s\n' "$(warn_percents_label "${WARN_PERCENTS:-80,90}")"
    fi
}

# 发送测试消息并在屏幕上说明结果（菜单、--test、设置完成后）。由 run_with_telegram_lock 间接调用。
# shellcheck disable=SC2317,SC2329
send_test_message() {
    if telegram_send_message "$(build_test_message)"; then
        log_cron "测试消息发送成功"
        ui_ok "测试消息已发送，请在 Telegram 里查看。"
        return 0
    fi
    log_cron "测试消息发送失败：${TG_SEND_ERROR:-原因未知}"
    ui_err "测试消息发送失败：${TG_SEND_ERROR:-原因未知}。"
    return 1
}

# 通知状态文件（last_traffic_notification），键值格式：
#   STATUS=上次通知过的状态（正常/限速/关机/外部关机计划/宽限/暂停）
#   CYCLE_EVENT=已处理过的周期起始日（last_reset_period 的值，「新周期开始」每期只推一次）
#   WARN_PERIOD=阈值预警记录所属的周期起始日；WARN_SENT=该周期已发过（或已跳过）的档位，如 80,90
# 1.x 写的文件没有 WARN_* 键，视为本期还没发过预警；更早的单行格式只能取出状态。
# 结果：LAST_STATUS、LAST_CYCLE_EVENT、LAST_WARN_PERIOD、LAST_WARN_SENT，
#       NOTIFICATION_STATE_FORMAT=none（没有文件）|legacy（单行旧格式）|v2（键值格式）。
read_notification_state() {
    local line key value had_status=false

    LAST_STATUS=""
    LAST_CYCLE_EVENT=""
    LAST_WARN_PERIOD=""
    LAST_WARN_SENT=""
    NOTIFICATION_STATE_FORMAT=none
    [ -f "$LAST_NOTIFICATION_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            STATUS) LAST_STATUS="$value"; had_status=true ;;
            CYCLE_EVENT) LAST_CYCLE_EVENT="$value" ;;
            WARN_PERIOD) LAST_WARN_PERIOD="$value" ;;
            WARN_SENT) LAST_WARN_SENT="$value" ;;
        esac
    done < "$LAST_NOTIFICATION_FILE"
    if $had_status; then
        NOTIFICATION_STATE_FORMAT=v2
    else
        NOTIFICATION_STATE_FORMAT=legacy
        LAST_STATUS=$(tail -n 1 "$LAST_NOTIFICATION_FILE" | cut -d' ' -f3-)
    fi
}

# 写通知状态：$1=状态 $2=周期 $3=预警所属周期 $4=已发档位。
write_notification_state() {
    local tmp_file="${LAST_NOTIFICATION_FILE}.tmp.$$"

    if ! {
        printf 'STATUS=%s\n' "$1"
        printf 'CYCLE_EVENT=%s\n' "$2"
        printf 'WARN_PERIOD=%s\n' "${3:-}"
        printf 'WARN_SENT=%s\n' "${4:-}"
        printf 'UPDATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$LAST_NOTIFICATION_FILE" || { rm -f "$tmp_file"; return 1; }
}

write_daily_report_state() {
    local report_date="$1"
    local tmp_file="${LAST_DAILY_REPORT_FILE}.tmp.$$"

    printf '%s\n' "$report_date" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$LAST_DAILY_REPORT_FILE" || { rm -f "$tmp_file"; return 1; }
}

read_current_traffic_state() {
    local key value now age period_state

    CURRENT_TRAFFIC_STATUS=""
    CURRENT_TRAFFIC_PERIOD_START=""
    CURRENT_TRAFFIC_PERIOD_END=""
    CURRENT_TRAFFIC_USAGE=""
    CURRENT_TRAFFIC_LIMIT=""
    CURRENT_TRAFFIC_THRESHOLD=""
    CURRENT_TRAFFIC_UNIT=""
    CURRENT_TRAFFIC_UPDATED_EPOCH=""

    [ -s "$USAGE_STATE_FILE" ] || return 1
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            STATUS) CURRENT_TRAFFIC_STATUS="$value" ;;
            PERIOD_START) CURRENT_TRAFFIC_PERIOD_START="$value" ;;
            PERIOD_END) CURRENT_TRAFFIC_PERIOD_END="$value" ;;
            USAGE) CURRENT_TRAFFIC_USAGE="$value" ;;
            TRAFFIC_LIMIT) CURRENT_TRAFFIC_LIMIT="$value" ;;
            LIMIT_THRESHOLD) CURRENT_TRAFFIC_THRESHOLD="$value" ;;
            UNIT) CURRENT_TRAFFIC_UNIT="$value" ;;
            UPDATED_EPOCH) CURRENT_TRAFFIC_UPDATED_EPOCH="$value" ;;
        esac
    done < "$USAGE_STATE_FILE"

    case "$CURRENT_TRAFFIC_STATUS" in
        normal|limited|shutdown|shutdown_external|grace|paused) ;;
        *) return 1 ;;
    esac
    [[ "$CURRENT_TRAFFIC_PERIOD_START" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_PERIOD_END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_USAGE" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_LIMIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_UPDATED_EPOCH" =~ ^[0-9]+$ ]] || return 1
    case "$CURRENT_TRAFFIC_UNIT" in
        GB|GiB) ;;
        *) return 1 ;;
    esac

    now=$(date +%s) || return 1
    age=$((now - CURRENT_TRAFFIC_UPDATED_EPOCH))
    [ "$age" -ge -60 ] && [ "$age" -le 300 ] || return 1
    period_state=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)
    [ -z "$period_state" ] || [ "$period_state" = "$CURRENT_TRAFFIC_PERIOD_START" ]
}

# 执行状态的说法（日报用）。
traffic_status_label() {
    case "${1:-}" in
        normal) printf '正常' ;;
        limited) printf '已限速' ;;
        shutdown) printf '已计划关机' ;;
        shutdown_external) printf '有外部关机计划' ;;
        grace) printf '宽限中（暂不限速）' ;;
        paused) printf '已暂停限制（只统计）' ;;
        *) printf '%s' "${1:-未知}" ;;
    esac
}

# 超额后的动作（读流量监控配置），用来在消息里解释「执行阈值」；读不到时不输出。
limit_action_text() {
    local config="$WORK_DIR/traffic_monitor_config.txt" mode speed
    mode=$(ntc_kv "$config" LIMIT_MODE) || return 0
    case "$mode" in
        shutdown) printf '达到后关机' ;;
        tc)
            speed=$(ntc_kv "$config" LIMIT_SPEED) || speed=""
            if [[ "$speed" =~ ^[0-9]+$ ]]; then
                printf '达到后整机限速 %s kbit/s' "$speed"
            else
                printf '达到后整机限速'
            fi
            ;;
    esac
}

# 「执行阈值」一行（需先 read_current_traffic_state 成功）。
threshold_line() {
    local action
    action=$(limit_action_text)
    printf '执行阈值：%s %s%s\n' "$(ntc_num "$CURRENT_TRAFFIC_THRESHOLD")" "$CURRENT_TRAFFIC_UNIT" "${action:+（$action）}"
}

# 本期概况（日报与预警共用）：本期起止与剩余天数、预计期末用量；按目前速度本期会达到执行阈值时写出预计日期。
# 期初不足一天时日均不可靠，和主菜单一样不给预计。$1=当前 epoch（省略为现在，测试时固定）。
traffic_period_lines() {
    local now="${1:-}" fc elapsed left avg projected hit unit="$CURRENT_TRAFFIC_UNIT"
    [ -n "$now" ] || now=$(date +%s)
    if ! fc=$(ntc_forecast "$CURRENT_TRAFFIC_USAGE" "$CURRENT_TRAFFIC_THRESHOLD" \
        "$CURRENT_TRAFFIC_PERIOD_START" "$CURRENT_TRAFFIC_PERIOD_END" "$now"); then
        printf '本期：%s 至 %s\n' "$CURRENT_TRAFFIC_PERIOD_START" "$CURRENT_TRAFFIC_PERIOD_END"
        return 0
    fi
    read -r elapsed _ left avg projected hit <<< "$fc"
    printf '本期：%s 至 %s，还剩 %s\n' "$CURRENT_TRAFFIC_PERIOD_START" "$CURRENT_TRAFFIC_PERIOD_END" \
        "$(ntc_days_left_text "$left")"
    if awk -v e="$elapsed" 'BEGIN { exit !(e < 1) }'; then
        printf '预计期末：本期刚开始，满一天后给出预计\n'
        return 0
    fi
    printf '预计期末：约 %s %s（按本期日均 %s %s）\n' "$(ntc_num "$projected")" "$unit" "$(ntc_num "$avg")" "$unit"
    if [ "$hit" != 0 ] && [ "$hit" != -1 ]; then
        printf '按目前速度，预计 %s 前后达到执行阈值\n' "$(date -d "@$hit" '+%Y-%m-%d' 2>/dev/null || printf '?')"
    fi
}

# 阈值预警正文。$1=越过的档位 [$2=当前 epoch]
build_threshold_warning_message() {
    local percent
    percent=$(ntc_percent "$CURRENT_TRAFFIC_USAGE" "$CURRENT_TRAFFIC_LIMIT") || percent="?"
    printf '⚠️ [%s]流量预警：本期用量已达到 %s%%\n\n' "$MACHINE_NAME" "$1"
    printf '已用：%s / %s %s（%s%%）\n' "$(ntc_num "$CURRENT_TRAFFIC_USAGE")" "$(ntc_num "$CURRENT_TRAFFIC_LIMIT")" \
        "$CURRENT_TRAFFIC_UNIT" "$percent"
    threshold_line
    traffic_period_lines "${2:-}"
}

# 日报正文（需先 read_current_traffic_state 成功）。$1=当前 epoch（空为现在）
build_daily_report_message() {
    local percent
    percent=$(ntc_percent "$CURRENT_TRAFFIC_USAGE" "$CURRENT_TRAFFIC_LIMIT") || percent="?"
    printf '📊 [%s]每日流量报告\n\n🖥️ 机器总流量：\n' "$MACHINE_NAME"
    printf '当前使用：%s %s（%s%%）\n' "$(ntc_num "$CURRENT_TRAFFIC_USAGE")" "$CURRENT_TRAFFIC_UNIT" "$percent"
    printf '流量限制：%s %s\n' "$(ntc_num "$CURRENT_TRAFFIC_LIMIT")" "$CURRENT_TRAFFIC_UNIT"
    threshold_line
    printf '执行状态：%s\n' "$(traffic_status_label "$CURRENT_TRAFFIC_STATUS")"
    traffic_period_lines "${1:-}"
}

# 合并两组档位（逗号分隔），去重并按数值排序。
merge_warn_levels() {
    local item out=""
    local -a items=() seen=()
    IFS=',' read -r -a items <<< "${1:-},${2:-}"
    for item in "${items[@]}"; do
        item=$(ntc_int "$item" 1 99) || continue
        seen[item]=1
    done
    for item in "${!seen[@]}"; do
        out+="${out:+,}$item"
    done
    printf '%s' "$out"
}

# check_and_notify 的内部辅助：写入 $1–$4，并更新调用方记下的「状态文件当前内容」（saved_*）。
commit_notification_state() {
    write_notification_state "$1" "$2" "$3" "$4" || return 1
    saved_status="$1"
    saved_cycle="$2"
    saved_warn_period="$3"
    saved_warn_sent="$4"
    force_write=false
}

# 发送状态变化通知并记日志。$1=throttle|shutdown|lifted
send_status_notification() {
    local label status=0
    case "$1" in
        throttle) label="限速通知"; send_throttle_warning || status=$? ;;
        shutdown) label="关机通知"; send_shutdown_warning || status=$? ;;
        lifted) label="限速解除通知"; send_throttle_lifted || status=$? ;;
        *) return 1 ;;
    esac
    if [ "$status" -ne 0 ]; then
        log_cron "${label}发送失败，下次运行重试：${TG_SEND_ERROR:-原因未知}"
        return 1
    fi
    log_cron "${label}发送成功"
}

# 阈值预警（只由 check_and_notify 调用，读写它的 next_* 局部变量）：本期用量越过某档时推送一次。
# 同时越过多档只发最高的一档，其余一并记为已发；新周期（PERIOD_START 变化）重新计。
# 中途新加的、低于已发最高档的档位只记录不补发；限额中途调大时，本期已发过的档位不再重复。
check_threshold_warnings() {
    local percent level top=0 crossed="" previous_sent message
    local -a levels=()

    [ "${WARN_PERCENTS:-off}" != off ] || return 0
    percent=$(ntc_percent "$CURRENT_TRAFFIC_USAGE" "$CURRENT_TRAFFIC_LIMIT") || return 0
    if [ "$next_warn_period" != "$CURRENT_TRAFFIC_PERIOD_START" ]; then
        next_warn_period="$CURRENT_TRAFFIC_PERIOD_START"
        next_warn_sent=""
    fi
    IFS=',' read -r -a levels <<< "$WARN_PERCENTS"
    for level in "${levels[@]}"; do
        level=$(ntc_int "$level" 1 99) || continue
        [ "$percent" -ge "$level" ] || continue
        crossed+="${crossed:+,}$level"
        [ "$level" -le "$top" ] || top="$level"
    done
    [ "$top" -gt 0 ] || return 0
    previous_sent="$next_warn_sent"
    next_warn_sent=$(merge_warn_levels "$previous_sent" "$crossed")
    if [[ ",$previous_sent," == *",$top,"* ]]; then
        return 0
    fi
    message=$(build_threshold_warning_message "$top")
    # 先记为已发再推送：状态文件写不进去时这一轮不发，避免每分钟重复推送。
    if ! commit_notification_state "$next_status" "$next_cycle" "$next_warn_period" "$next_warn_sent"; then
        next_warn_sent="$previous_sent"
        log_cron "通知状态文件写入失败，本轮不发 ${top}% 预警（避免重复推送）"
        return 1
    fi
    if telegram_send_message "$message"; then
        log_cron "${top}% 用量预警发送成功（本期已用 ${percent}%）"
        return 0
    fi
    # 撤回记录（由 check_and_notify 末尾写回），下次运行重试。
    next_warn_sent="$previous_sent"
    log_cron "${top}% 用量预警发送失败，下次运行重试：${TG_SEND_ERROR:-原因未知}"
    return 1
}

# 每分钟一次：新周期开始、限速/关机/解除、阈值预警。只有真正发生的事件才写日志。
# 该推一次的通知都先记状态、再发送，发送失败再撤回：状态文件写不进去时宁可这一轮不发，
# 也不会每分钟重复推送。有任何一条没发出去返回 1（下次运行重试），不打印「检查完成」之类的提示。
check_and_notify() {
    local cycle_event current_status="" traffic_ok=false failed=false status_kind=""
    local next_status next_cycle next_warn_period next_warn_sent
    local saved_status saved_cycle saved_warn_period saved_warn_sent force_write=false

    cycle_event=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)
    cycle_event=${cycle_event%$'\r'}
    [[ "$cycle_event" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || cycle_event=""

    if read_current_traffic_state; then
        traffic_ok=true
        case "$CURRENT_TRAFFIC_STATUS" in
            shutdown) current_status="关机" ;;
            shutdown_external) current_status="外部关机计划" ;;
            limited) current_status="限速" ;;
            normal) current_status="正常" ;;
            grace) current_status="宽限" ;;
            paused) current_status="暂停" ;;
        esac
    else
        debug_log "实时流量状态不存在、无效或已过期，本轮不发状态通知"
    fi

    read_notification_state
    next_status="$LAST_STATUS"
    next_cycle="$LAST_CYCLE_EVENT"
    next_warn_period="$LAST_WARN_PERIOD"
    next_warn_sent="$LAST_WARN_SENT"
    saved_status="$LAST_STATUS"
    saved_cycle="$LAST_CYCLE_EVENT"
    saved_warn_period="$LAST_WARN_PERIOD"
    saved_warn_sent="$LAST_WARN_SENT"
    # 第一次运行或更早的单行旧格式：本轮结束时写成键值格式。
    [ "$NOTIFICATION_STATE_FORMAT" = v2 ] || force_write=true

    # 新周期：只有记录过上一个周期、且周期确实变了才推送。没有记录时（第一次运行、更早的旧状态文件，
    # 或先配好 Telegram、后配监控——监控第一次写周期文件）只记下当前周期，不推送。
    if [ -n "$cycle_event" ] && [ "$cycle_event" != "$LAST_CYCLE_EVENT" ]; then
        if [ -z "$LAST_CYCLE_EVENT" ]; then
            next_cycle="$cycle_event"
        elif ! commit_notification_state "$next_status" "$cycle_event" "$next_warn_period" "$next_warn_sent"; then
            log_cron "通知状态文件写入失败，本轮不发送通知（避免重复推送）"
            return 1
        elif send_new_cycle_notification; then
            next_cycle="$cycle_event"
            next_status="正常"
            log_cron "新周期通知发送成功（本期从 $cycle_event 开始）"
        else
            failed=true
            log_cron "新周期通知发送失败，下次运行重试：${TG_SEND_ERROR:-原因未知}"
        fi
    fi

    # 新周期通知没发出去时，这一轮的其他通知也先不发，保证先后顺序。
    if ! $failed; then
        case "$current_status" in
            限速) [ "$next_status" = 限速 ] || status_kind=throttle ;;
            关机|外部关机计划) [ "$next_status" = "$current_status" ] || status_kind=shutdown ;;
            正常)
                case "$next_status" in
                    限速|关机|外部关机计划) status_kind=lifted ;;
                    *) next_status="正常" ;;
                esac
                ;;
            宽限|暂停) next_status="$current_status" ;;
        esac
        if [ -n "$status_kind" ]; then
            if ! commit_notification_state "$current_status" "$next_cycle" "$next_warn_period" "$next_warn_sent"; then
                log_cron "通知状态文件写入失败，本轮不发送通知（避免重复推送）"
                return 1
            fi
            if send_status_notification "$status_kind"; then
                next_status="$current_status"
            else
                failed=true
            fi
        fi
        if $traffic_ok && ! check_threshold_warnings; then
            failed=true
        fi
    fi

    # 写回最终状态：包括撤回没发出去的记录。
    if $force_write || [ "$next_status" != "$saved_status" ] || [ "$next_cycle" != "$saved_cycle" ] ||
       [ "$next_warn_period" != "$saved_warn_period" ] || [ "$next_warn_sent" != "$saved_warn_sent" ]; then
        if ! write_notification_state "$next_status" "$next_cycle" "$next_warn_period" "$next_warn_sent"; then
            log_cron "通知状态文件写入失败"
            return 1
        fi
    fi
    if $failed; then
        return 1
    fi
    return 0
}

# Telegram 定时任务条目。主脚本卸载时按脚本路径匹配，格式与 1.x 相同。
telegram_cron_entry() {
    printf '* * * * * %s -cron >/dev/null 2>&1 # TrafficCop-Lite Telegram' "$SCRIPT_PATH"
}

# 写入唯一一条每分钟任务（先清掉本脚本的旧条目）。成功时不输出，返回值只取决于写入本身
# （L3：1.2.x 写完后还为显示重读一次 crontab，那次重读失败会把已经成功的写入报成失败）。
setup_cron() {
    local correct_entry current_crontab crontab_tmp

    correct_entry=$(telegram_cron_entry)
    if ! acquire_root_crontab_lock; then
        ui_err "无法取得 NTC 的 crontab 锁，定时任务未修改。"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        ui_err "读取当前 crontab 失败，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab_tmp="$(mktemp)"; then
        ui_err "无法创建 crontab 临时文件，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" '
        index($0, script) == 0 && $0 !~ /^[[:space:]]*$/ { print }
    ' <<< "$current_crontab" > "$crontab_tmp" \
        || ! printf '%s\n' "$correct_entry" >> "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "生成 crontab 候选内容失败，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "写入 crontab 失败，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"
    release_root_crontab_lock
    return 0
}

# 删除本脚本的定时任务（成功时不输出）。
remove_telegram_cron() {
    local current_crontab crontab_tmp

    if ! acquire_root_crontab_lock; then
        ui_err "无法取得 NTC 的 crontab 锁，定时任务未修改。"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        ui_err "读取当前 crontab 失败，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab_tmp="$(mktemp)"; then
        ui_err "无法创建 crontab 临时文件，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" '
        index($0, script) == 0 && $0 !~ /^[[:space:]]*$/ { print }
    ' <<< "$current_crontab" > "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "生成 crontab 候选内容失败，定时任务未修改。"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        ui_err "删除 Telegram 定时任务失败。"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"
    release_root_crontab_lock
    return 0
}

# 定时任务现状：ok（恰好一条、格式正确）、missing（没有）、drift（重复或格式不对）、unreadable（读不出 crontab）。
telegram_cron_state() {
    local current entry line total=0 exact=0

    entry=$(telegram_cron_entry)
    if ! current=$(read_root_crontab_locked 2>/dev/null); then
        printf 'unreadable'
        return 0
    fi
    while IFS= read -r line; do
        [[ "$line" == *"$SCRIPT_PATH"* ]] || continue
        total=$((total + 1))
        [ "$line" != "$entry" ] || exact=$((exact + 1))
    done <<< "$current"
    if [ "$total" -eq 0 ]; then
        printf 'missing'
    elif [ "$total" -eq 1 ] && [ "$exact" -eq 1 ]; then
        printf 'ok'
    else
        printf 'drift'
    fi
}

# 打开菜单时核对定时任务与开关是否一致：只在不一致时改写 root crontab，不打印 crontab 内容。
# 启用但条目缺失（例如主菜单停止过服务）时按 1.x 的习惯自动补建；结果写入 TG_CRON_NOTE、TG_CRON_FIXED 供菜单显示。
sync_telegram_cron() {
    local state

    TG_CRON_NOTE=""
    TG_CRON_FIXED=false
    state=$(telegram_cron_state)
    if [ "${TG_DISABLED:-false}" = true ]; then
        case "$state" in
            missing) ;;
            unreadable) TG_CRON_NOTE="读不出 root crontab，无法确认定时任务是否已清除。" ;;
            *)
                if ! remove_telegram_cron >/dev/null 2>&1; then
                    TG_CRON_NOTE="通知已停用，但残留的定时任务没能清除（它运行时会自动跳过）。"
                fi
                ;;
        esac
        return 0
    fi
    case "$state" in
        ok) ;;
        unreadable) TG_CRON_NOTE="读不出 root crontab，无法确认定时任务是否存在。" ;;
        *)
            if setup_cron >/dev/null 2>&1; then
                TG_CRON_FIXED=true
                log_cron "定时任务缺失或格式不对，打开菜单时已自动修复"
            else
                TG_CRON_NOTE="自动通知已启用，但定时任务缺失，自动补建失败；可先停用再启用重试。"
            fi
            ;;
    esac
}

# 以下两个函数由 run_with_telegram_lock 间接调用。
# 启用：先装定时任务、再把开关写成启用——中间若 cron 恰好触发，读到的仍是「停用」，会安全跳过。
# shellcheck disable=SC2317,SC2329
enable_telegram_notifications() {
    if ! setup_cron; then
        ui_err "自动通知启用失败（定时任务没有写入），仍保持停用。"
        ntc_operation_log telegram-enable failure
        return 1
    fi
    TG_DISABLED=false
    if ! write_config; then
        TG_DISABLED=true
        if remove_telegram_cron >/dev/null 2>&1; then
            ui_err "自动通知启用失败（无法写入 $CONFIG_FILE），已撤销刚建的定时任务，仍保持停用。"
        else
            ui_err "自动通知启用失败（无法写入 $CONFIG_FILE），刚建的定时任务也没能撤销；它运行时读到「停用」会自动跳过。"
        fi
        ntc_operation_log telegram-enable failure
        return 1
    fi
    ui_ok "自动通知已启用：限速与解除、新周期、阈值预警、每日报告和监控异常会自动推送。"
    ntc_operation_log telegram-enable success
}

# 停用：先把开关写成停用，再删定时任务；删除失败时残留任务读到「停用」也会跳过。
# shellcheck disable=SC2317,SC2329
disable_telegram_notifications() {
    TG_DISABLED=true
    if ! write_config; then
        TG_DISABLED=false
        ui_err "停用失败（无法写入 $CONFIG_FILE），通知仍在运行。"
        ntc_operation_log telegram-disable failure
        return 1
    fi
    if ! remove_telegram_cron; then
        ui_warn "已停用（配置已改），但定时任务没能删除；它运行时读到「停用」会自动跳过。"
        ntc_operation_log telegram-disable failure
        return 1
    fi
    ui_ok "自动通知已停用；配置保留，可随时在本菜单重新启用。"
    ntc_operation_log telegram-disable success
}

# 读取监控健康状态：MONITOR_HEALTH（ok|error|disabled）、MONITOR_HEALTH_REASON、MONITOR_HEALTH_AGE。
# 文件不存在返回 1（监控尚未以 1.2+ 运行过，无法判断，不提醒）。
read_monitor_health() {
    local key value updated="" now
    MONITOR_HEALTH=""; MONITOR_HEALTH_REASON=""; MONITOR_HEALTH_AGE=""
    [ -s "$MONITOR_HEALTH_FILE" ] || return 1
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            HEALTH) MONITOR_HEALTH="$value" ;;
            REASON) MONITOR_HEALTH_REASON="${value:0:200}" ;;
            UPDATED_EPOCH) updated="$value" ;;
        esac
    done < "$MONITOR_HEALTH_FILE"
    case "$MONITOR_HEALTH" in ok|error|disabled) ;; *) return 1 ;; esac
    [[ "$updated" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s) || return 1
    MONITOR_HEALTH_AGE=$((now - updated))
}

# 监控异常提醒：监控报告错误，或健康状态长时间未更新（cron 未运行、脚本被删等）时提醒，
# 按 MONITOR_ALERT_INTERVAL 限频；恢复后发送一次“已恢复”。监控被主动禁用时不提醒。
check_monitor_health() {
    local reason="" now last_alert=0
    read_monitor_health || return 0
    if [ "$MONITOR_HEALTH" = disabled ]; then
        rm -f "$MONITOR_ALERT_STATE_FILE"
        return 0
    fi
    if [ "$MONITOR_HEALTH_AGE" -gt "$MONITOR_STALE_SECONDS" ]; then
        reason="监控已 $((MONITOR_HEALTH_AGE / 60)) 分钟没有运行，请检查 cron 与 traffic_monitor.log"
    elif [ "$MONITOR_HEALTH" = error ]; then
        reason="${MONITOR_HEALTH_REASON:-监控本轮执行失败，详见 traffic_monitor.log}"
    fi
    if [ -z "$reason" ]; then
        if [ -s "$MONITOR_ALERT_STATE_FILE" ]; then
            if telegram_send_message "✅ [${MACHINE_NAME}]监控已恢复正常。"; then
                rm -f "$MONITOR_ALERT_STATE_FILE"
                log_cron "监控恢复通知发送成功"
            else
                log_cron "监控恢复通知发送失败，将在下次任务重试"
                return 1
            fi
        fi
        return 0
    fi
    now=$(date +%s) || return 1
    last_alert=$(cat "$MONITOR_ALERT_STATE_FILE" 2>/dev/null || echo 0)
    [[ "$last_alert" =~ ^[0-9]+$ ]] || last_alert=0
    [ $((now - last_alert)) -ge "$MONITOR_ALERT_INTERVAL" ] || return 0
    if telegram_send_message "⚠️ [${MACHINE_NAME}]流量监控异常：${reason}%0A限速/关机判断可能未执行，请尽快检查。"; then
        local tmp_file="${MONITOR_ALERT_STATE_FILE}.tmp.$$"
        printf '%s\n' "$now" > "$tmp_file" && chmod 600 "$tmp_file" 2>/dev/null; mv -f "$tmp_file" "$MONITOR_ALERT_STATE_FILE"
        log_cron "监控异常提醒发送成功"
    else
        log_cron "监控异常提醒发送失败，将在下次任务重试"
        return 1
    fi
}

# 生成并发送一份日报（cron 定时与手动共用），结果写入 DAILY_REPORT_RESULT：
#   sent 已发送；unavailable_sent 实时状态不可用而监控已报告异常，发了一份「状态不可用」日报
#   （cron 视为今天已发，不再每分钟重试）；no_data 没有可用数据（监控尚未以 1.2+ 运行，稍后重试）；failed 发送失败。
daily_report() {
    local message why now

    DAILY_REPORT_RESULT=failed
    if ! read_current_traffic_state; then
        if read_monitor_health && [ "$MONITOR_HEALTH" != ok ]; then
            why="${MONITOR_HEALTH_REASON:-监控未运行}"
            if [ "$MONITOR_HEALTH" = disabled ]; then
                why="监控已停用"
            fi
            if [ "$MONITOR_HEALTH_AGE" -gt "$MONITOR_STALE_SECONDS" ]; then
                why="监控已 $((MONITOR_HEALTH_AGE / 60)) 分钟没有运行"
            fi
            log_cron "实时流量状态不可用（$why），发送状态不可用日报"
            if telegram_send_message "📊 [${MACHINE_NAME}]每日流量报告"$'\n\n'"实时流量状态不可用：${why}"; then
                DAILY_REPORT_RESULT=unavailable_sent
                return 0
            fi
            log_cron "状态不可用日报发送失败：${TG_SEND_ERROR:-原因未知}"
            return 1
        fi
        DAILY_REPORT_RESULT=no_data
        return 1
    fi
    now=$(date +%s)
    message=$(build_daily_report_message "$now")
    if telegram_send_message "$message"; then
        DAILY_REPORT_RESULT=sent
        return 0
    fi
    log_cron "日报发送失败：${TG_SEND_ERROR:-原因未知}"
    return 1
}

# cron：到了报告时间（REPORT_TIMEZONE）且今天还没发过就发日报。先写「今天已发」再发送，发送失败再撤回：
# 记录写不进去时宁可不发，也不会每分钟重复推送。
run_cron_daily_report() {
    local current_time current_date last_report_date

    current_time=$(TZ="$REPORT_TIMEZONE" date +%H:%M)
    current_date=$(TZ="$REPORT_TIMEZONE" date +%Y-%m-%d)
    last_report_date=$(cat "$LAST_DAILY_REPORT_FILE" 2>/dev/null || true)
    if [[ "$current_time" < "$DAILY_REPORT_TIME" ]] || [ "$last_report_date" = "$current_date" ]; then
        return 0
    fi
    if ! write_daily_report_state "$current_date"; then
        log_cron "日报状态文件写入失败，今天的日报暂不发送（避免重复推送）"
        return 1
    fi
    if daily_report; then
        log_cron "每日报告发送成功"
        return 0
    fi
    if [ -n "$last_report_date" ]; then
        write_daily_report_state "$last_report_date" || log_cron "撤回日报记录失败，今天的日报不会再重试"
    else
        rm -f "$LAST_DAILY_REPORT_FILE" || log_cron "撤回日报记录失败，今天的日报不会再重试"
    fi
    if [ "${DAILY_REPORT_RESULT:-failed}" = no_data ]; then
        # 监控还没有数据时每分钟都会走到这里，只在设定的那一分钟记一行。
        [ "$current_time" != "$DAILY_REPORT_TIME" ] || log_cron "暂无可用的实时流量数据，日报等监控运行后再发"
    else
        log_cron "每日报告发送失败，下次运行重试"
    fi
    return 1
}

# 立即发送一次日报（菜单与 --report）。不改 cron 的「今天已发」记录：手动发一次多半只是想看看数据，
# 不应让当天的定时日报因此跳过。由 run_with_telegram_lock 间接调用。
# shellcheck disable=SC2317,SC2329
send_report_now() {
    daily_report
    case "${DAILY_REPORT_RESULT:-failed}" in
        sent)
            log_cron "手动日报发送成功"
            ui_ok "日报已发送。"
            return 0
            ;;
        unavailable_sent)
            log_cron "手动日报：实时流量状态不可用，已发送状态不可用日报"
            ui_warn "实时流量状态不可用，已发送一份「状态不可用」的日报。"
            return 0
            ;;
        no_data)
            ui_err "没有可用的实时流量数据（流量监控可能还没运行或状态已过期），日报未发送。"
            return 1
            ;;
    esac
    ui_err "日报发送失败：${TG_SEND_ERROR:-原因未知}。"
    return 1
}

telegram_usage() {
    cat <<EOF
NTC Telegram 通知 v$SCRIPT_VERSION

用法: trafficcop-lite-telegram.sh [选项]

  （无参数）   打开 Telegram 通知菜单
  --test       发送一条测试消息
  --report     立即发送一次日报（不影响定时日报）
  -cron        定时任务入口（每分钟运行一次，启用通知时自动安装）
  -h, --help   显示本帮助

一般通过 ntc 使用：sudo ntc telegram test、sudo ntc telegram report。
EOF
}

# 画菜单（不读输入）。$1=true 已配置 / false 未配置。所需状态由 telegram_menu 事先准备：
# TG_CONFIG_ERROR、TG_WARN_INVALID（read_config），TG_CRON_NOTE、TG_CRON_FIXED（sync_telegram_cron），TG_TRAFFIC_READY。
telegram_menu_render() {
    local subtitle

    if [ "${1:-false}" != true ]; then
        ui_title "Telegram 通知" "未配置"
        ui_note "设置后自动推送：限速与解除、新周期开始、用量预警、每日流量报告、监控异常。"
        if [ -n "${TG_CONFIG_ERROR:-}" ] && [ "${TG_CONFIG_ERROR:-}" != "还没有配置" ]; then
            ui_warn "现有配置不能用（${TG_CONFIG_ERROR}），需要重新设置。"
        fi
        printf '\n'
        ui_option 1 "开始设置" "Bot Token、Chat ID、机器名、日报时间"
        ui_rule
        ui_option 0 "返回"
        return 0
    fi

    if [ "${TG_DISABLED:-false}" = true ]; then
        subtitle="已停用，不自动推送（日报时间 ${DAILY_REPORT_TIME:-?}，${REPORT_TIMEZONE:-?}）"
    else
        subtitle="已启用，每日 ${DAILY_REPORT_TIME:-?}（${REPORT_TIMEZONE:-?}）发送日报"
    fi
    ui_title "Telegram 通知" "$subtitle"
    ui_kv "机器人" "Token $(ntc_mask "${BOT_TOKEN:-}") · Chat ID $(ntc_mask "${CHAT_ID:-}")"
    ui_kv "机器名" "${MACHINE_NAME:-}"
    if [ "${WARN_PERCENTS:-off}" = off ]; then
        ui_kv "预警档位" "已关闭"
    else
        ui_kv "预警档位" "$(warn_percents_label "$WARN_PERCENTS")（每期每档推送一次）"
    fi
    if [ -n "${TG_WARN_INVALID:-}" ]; then
        ui_warn "预警档位配置「${TG_WARN_INVALID}」无效，暂按 80%、90% 执行，请重新设置。"
    fi
    if [ -n "${TG_CRON_NOTE:-}" ]; then
        ui_warn "$TG_CRON_NOTE"
    fi
    if [ "${TG_CRON_FIXED:-false}" = true ]; then
        ui_note "定时任务缺失，打开菜单时已按「已启用」自动补建。"
    fi
    if [ "${TG_DISABLED:-false}" != true ] && [ "${TG_TRAFFIC_READY:-true}" != true ]; then
        ui_note "流量监控还没有可用数据，日报和阈值预警要等监控正常运行后才会发送。"
    fi
    printf '\n'
    printf '   %b%s%b\n' "$DIM" "设置" "$NC"
    ui_option 1 "设置机器人与机器名"
    ui_option 2 "每日报告时间与时区"
    ui_option 3 "阈值预警档位"
    printf '   %b%s%b\n' "$DIM" "操作" "$NC"
    ui_option 4 "发送测试消息"
    ui_option 5 "立即发送一次日报" "不影响定时日报"
    if [ "${TG_DISABLED:-false}" = true ]; then
        ui_option 6 "启用通知"
    else
        ui_option 6 "停用通知"
    fi
    ui_rule
    ui_option 0 "返回"
}

# 菜单（无参数运行）。作为 ntc 主菜单的「Telegram 通知」被调起时，「0. 返回」或 EOF 即退出本脚本，
# 主菜单接着显示（不再要求按回车）。
telegram_menu() {
    local choice n max configured

    TG_CRON_NOTE=""
    TG_CRON_FIXED=false
    if read_config; then
        sync_telegram_cron
    fi
    while true; do
        configured=false
        if read_config; then
            configured=true
            TG_TRAFFIC_READY=false
            if read_current_traffic_state; then
                TG_TRAFFIC_READY=true
            fi
        fi
        menu_clear
        telegram_menu_render "$configured"
        max=1
        [ "$configured" != true ] || max=6
        if ! ui_prompt "$max" choice; then
            printf '\n'
            return 0
        fi
        if ! n=$(ntc_int "$(ntc_trim "$choice")" 0 "$max"); then
            ui_warn "无效选择，请输入 0–$max。"
            sleep 1
            continue
        fi
        case "$configured:$n" in
            *:0) return 0 ;;
            false:1) initial_config || true ;;
            true:1) configure_bot || true ;;
            true:2) edit_report_schedule || true ;;
            true:3) edit_warn_percents || true ;;
            true:4) run_with_telegram_lock send_test_message || true ;;
            true:5) run_with_telegram_lock send_report_now || true ;;
            true:6) toggle_notifications || true ;;
        esac
        ui_pause
    done
}

# 入口。无参数：菜单；-cron：定时任务；--test / --report：发测试消息 / 立即发日报（不读标准输入）。
main() {
    case "$#:${1:-}" in
        0:|1:-cron|1:--test|1:--report) ;;
        1:-h|1:--help)
            telegram_usage
            return 0
            ;;
        *)
            printf '未知参数：%s\n\n' "$*" >&2
            telegram_usage >&2
            return 2
            ;;
    esac
    debug_log "进入主任务，参数=${1:-（无）}"

    case "${1:-}" in
        -cron)
            check_runtime_dependencies cron || return 1
            check_running || return 1
            if ! read_config; then
                log_cron "Telegram 配置不可用（${TG_CONFIG_ERROR:-原因未知}），跳过本轮"
                return 1
            fi
            if [ "${TG_DISABLED:-false}" = "true" ]; then
                debug_log "Telegram 自动通知已停用，跳过本轮"
                return 0
            fi
            check_and_notify || debug_log "本轮有通知没有发出，下次运行重试"
            check_monitor_health || debug_log "监控健康提醒没有完整发出"
            run_cron_daily_report || debug_log "日报这一轮没有发出"
            return 0
            ;;
        --test|--report)
            check_runtime_dependencies cli || return 1
            if ! read_config; then
                ui_err "Telegram 通知还不能用：${TG_CONFIG_ERROR:-配置不可用}。请先在 ntc 主菜单的「Telegram 通知」里设置。"
                return 1
            fi
            if [ "$1" = --test ]; then
                run_with_telegram_lock send_test_message
            else
                run_with_telegram_lock send_report_now
            fi
            return
            ;;
    esac

    check_runtime_dependencies interactive || return 1
    telegram_menu
}


# Sourcing only defines functions; no directory, log, trap or notification is initialized.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # 只看帮助或参数不对时不建目录、不写日志（有效参数与 main 里的分支保持一致）。
    case "$#:${1:-}" in
        0:|1:-cron|1:--test|1:--report)
            umask 077
            mkdir -p "$WORK_DIR"
            chmod 700 "$WORK_DIR" 2>/dev/null || true
            [ ! -f "$CRON_LOG" ] || chmod 600 "$CRON_LOG" 2>/dev/null || true
            cd "$WORK_DIR" || exit 1
            trap 'trim_log_file "$CRON_LOG" "$CRON_LOG_MAX_LINES"' EXIT
            ;;
    esac
    main "$@"
    exit $?
fi
