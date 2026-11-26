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
