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
