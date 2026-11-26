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
