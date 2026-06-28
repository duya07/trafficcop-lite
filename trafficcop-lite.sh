#!/bin/bash

# TrafficCop Lite - 独立版流量监控管理器
# 基于 ypq123456789/TrafficCop 的流量监控、Telegram 通知与机器限速功能整理。

SCRIPT_VERSION="1.0.3"
LAST_UPDATE="2026-06-28"

WORK_DIR="/etc/trafficcop-lite"
MONITOR_SCRIPT="trafficcop-lite-monitor.sh"
TELEGRAM_SCRIPT="trafficcop-lite-telegram.sh"
MACHINE_LIMIT_SCRIPT="trafficcop-lite-machine-limit.sh"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
SHORTCUT_PATH="/usr/local/bin/ntc"
LEGACY_NCL_SHORTCUT_PATH="/usr/local/bin/ncl"
LEGACY_TC_SHORTCUT_PATH="/usr/local/bin/tc"
REPO="${REPO:-duya07/trafficcop-lite}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
WHITE='\033[0;37m'
NC='\033[0m'

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
    SOURCE_PATH="$(readlink "$SOURCE_PATH")"
    [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"

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

TC_BIN="$(find_tc_bin)"

pause() {
    echo ""
    read -r -p "按回车键继续..."
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

ensure_work_dir() {
    mkdir -p "$WORK_DIR"
}

copy_self_if_needed() {
    local self_path="$SOURCE_PATH"
    if [ "$self_path" != "$WORK_DIR/trafficcop-lite.sh" ] && [ -f "$self_path" ]; then
        cp "$self_path" "$WORK_DIR/trafficcop-lite.sh"
        chmod +x "$WORK_DIR/trafficcop-lite.sh"
    fi
}

download_component() {
    local script_name="$1"
    local dest="$WORK_DIR/$script_name"
    local url="$RAW_BASE/$script_name"
    local tmp_file="$WORK_DIR/.${script_name}.install.$$"

    echo -e "${YELLOW}正在下载 $script_name...${NC}"
    if ! download_url_to_file "$url" "$tmp_file"; then
        echo -e "${RED}下载失败：$script_name${NC}"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

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

    chmod +x "$tmp_file"
    mv -f "$tmp_file" "$dest"
    echo -e "${GREEN}✓ 已下载/安装 $script_name${NC}"
}

download_url_to_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo -e "${RED}缺少 curl/wget，无法下载文件。${NC}"
        return 1
    fi
}

ensure_component() {
    local script_name="$1"
    local src="$SCRIPT_DIR/$script_name"
    local dest="$WORK_DIR/$script_name"

    ensure_work_dir

    if [ -f "$src" ] && [ "$src" != "$dest" ]; then
        if ! bash -n "$src" 2>/dev/null; then
            echo -e "${RED}本地脚本语法检查失败：$src${NC}"
            return 1
        fi
        cp "$src" "$dest"
        chmod +x "$dest"
        echo -e "${GREEN}✓ 已安装/更新 $script_name${NC}"
        return 0
    fi

    if [ -f "$dest" ]; then
        if bash -n "$dest" 2>/dev/null; then
            chmod +x "$dest"
            return 0
        fi
        echo -e "${YELLOW}! 已存在的 $script_name 语法检查失败，将重新下载。${NC}"
    fi

    download_component "$script_name"
}

install_all_components() {
    ensure_component "$MONITOR_SCRIPT" || return 1
    ensure_component "$TELEGRAM_SCRIPT" || return 1
    ensure_component "$MACHINE_LIMIT_SCRIPT" || return 1
    copy_self_if_needed
}

install_shortcut() {
    install_all_components || return 1

    if [ -e "$SHORTCUT_PATH" ] && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
        echo -e "${YELLOW}! $SHORTCUT_PATH 已存在，未覆盖。${NC}"
        echo -e "${YELLOW}  你仍可使用：sudo bash $WORK_DIR/trafficcop-lite.sh${NC}"
        return 0
    fi

    mkdir -p "$(dirname "$SHORTCUT_PATH")"
    ln -sfn "$WORK_DIR/trafficcop-lite.sh" "$SHORTCUT_PATH"
    chmod +x "$WORK_DIR/trafficcop-lite.sh"
    echo -e "${GREEN}✓ 快捷命令已安装：sudo ntc${NC}"
    if [ "$(readlink "$LEGACY_NCL_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_NCL_SHORTCUT_PATH"
        echo -e "${GREEN}✓ 已清理旧快捷命令：$LEGACY_NCL_SHORTCUT_PATH${NC}"
    fi
    if [ "$(readlink "$LEGACY_TC_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_TC_SHORTCUT_PATH"
        echo -e "${GREEN}✓ 已清理旧快捷命令：$LEGACY_TC_SHORTCUT_PATH${NC}"
    fi
    if [ -n "$TC_BIN" ]; then
        echo -e "${CYAN}系统原 tc 命令路径：$TC_BIN${NC}"
    fi
}

run_component() {
    local script_name="$1"
    ensure_component "$script_name" || {
        pause
        return 1
    }
    bash "$WORK_DIR/$script_name"
}

manage_monitor() {
    echo -e "${CYAN}正在打开流量监控管理...${NC}"
    install_all_components || {
        pause
        return
    }
    bash "$WORK_DIR/$MONITOR_SCRIPT"
    pause
}

manage_telegram() {
    echo -e "${CYAN}正在打开 Telegram 通知管理...${NC}"
    install_all_components || {
        pause
        return
    }
    bash "$WORK_DIR/$TELEGRAM_SCRIPT"
    pause
}

manage_machine_limit() {
    echo -e "${CYAN}正在打开机器限速管理...${NC}"
    install_all_components || {
        pause
        return
    }
    bash "$WORK_DIR/$MACHINE_LIMIT_SCRIPT"
    pause
}

choose_update_base() {
    local direct_base="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    local proxy_base="https://v6.gh-proxy.org/https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    local source_choice

    echo -e "${CYAN}请选择更新线路${NC}" >&2
    menu_item "1" "直连" >&2
    menu_item "2" "国内优先" >&2
    menu_item "0" "返回" >&2
    echo "" >&2
    read -r -p "请输入选项: " source_choice

    case "$source_choice" in
        1|"")
            echo "$direct_base"
            ;;
        2)
            echo "$proxy_base"
            ;;
        0)
            return 1
            ;;
        *)
            echo -e "${RED}无效选择${NC}" >&2
            return 1
            ;;
    esac
}

update_scripts() {
    local update_base="${1:-$RAW_BASE}"
    local scripts=("trafficcop-lite.sh" "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT")
    local temp_files=()
    local script_name tmp_file url backup_dir

    ensure_work_dir
    echo -e "${CYAN}正在更新 TrafficCop-Lite 脚本...${NC}"
    echo -e "${CYAN}更新源:${NC} $update_base"
    echo -e "${YELLOW}仅覆盖脚本文件；配置、日志、crontab 不会被覆盖。${NC}"
    echo ""

    for script_name in "${scripts[@]}"; do
        url="$update_base/$script_name"
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        echo -e "${YELLOW}下载 $script_name...${NC}"

        if ! download_url_to_file "$url" "$tmp_file"; then
            echo -e "${RED}下载失败：$script_name${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            return 1
        fi

        if [ ! -s "$tmp_file" ]; then
            echo -e "${RED}下载文件为空：$script_name${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            return 1
        fi

        if ! bash -n "$tmp_file" 2>/dev/null; then
            echo -e "${RED}语法检查失败：$script_name，已取消更新。${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            return 1
        fi

        temp_files+=("$tmp_file")
    done

    backup_dir="$WORK_DIR/backups/scripts-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    for script_name in "${scripts[@]}"; do
        if [ -f "$WORK_DIR/$script_name" ]; then
            cp -a "$WORK_DIR/$script_name" "$backup_dir/"
        fi
    done

    for script_name in "${scripts[@]}"; do
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        chmod +x "$tmp_file"
        mv -f "$tmp_file" "$WORK_DIR/$script_name"
        echo -e "${GREEN}✓ 已更新 $script_name${NC}"
    done

    if [ -e "$SHORTCUT_PATH" ] && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
        echo -e "${YELLOW}! $SHORTCUT_PATH 已存在且不属于本脚本，已保留。${NC}"
    else
        mkdir -p "$(dirname "$SHORTCUT_PATH")"
        ln -sfn "$WORK_DIR/trafficcop-lite.sh" "$SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_NCL_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_NCL_SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_TC_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_TC_SHORTCUT_PATH"
    fi

    echo ""
    echo -e "${GREEN}脚本更新完成。旧脚本已备份到：$backup_dir${NC}"
    echo -e "${YELLOW}建议重新执行 sudo ntc 进入新版菜单。${NC}"
}

update_scripts_interactive() {
    local selected_base

    selected_base=$(choose_update_base) || {
        echo "已取消更新。"
        pause
        return
    }

    update_scripts "$selected_base"
    pause
}

show_status_line() {
    local monitor_cron="未设置"
    local telegram_cron="未设置"
    local config_state="未配置"

    if crontab -l 2>/dev/null | grep -F -q "$WORK_DIR/$MONITOR_SCRIPT"; then
        monitor_cron="已设置"
    fi
    if crontab -l 2>/dev/null | grep -F -q "$WORK_DIR/$TELEGRAM_SCRIPT"; then
        telegram_cron="已设置"
    fi
    if [ -f "$WORK_DIR/traffic_monitor_config.txt" ]; then
        config_state="已配置"
    fi

    local config_color="$YELLOW"
    local monitor_color="$YELLOW"
    local telegram_color="$YELLOW"

    [ "$config_state" = "已配置" ] && config_color="$GREEN"
    [ "$monitor_cron" = "已设置" ] && monitor_color="$GREEN"
    [ "$telegram_cron" = "已设置" ] && telegram_color="$GREEN"

    echo -e "${CYAN}工作目录:${NC} $WORK_DIR"
    echo -e "${CYAN}监控配置:${NC} ${config_color}${config_state}${NC}   ${CYAN}监控任务:${NC} ${monitor_color}${monitor_cron}${NC}   ${CYAN}TG任务:${NC} ${telegram_color}${telegram_cron}${NC}"
}

lite_is_leap_year() {
    local year="$1"
    if { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; } || [ $((year % 400)) -eq 0 ]; then
        return 0
    fi
    return 1
}

lite_days_in_month() {
    local year="$1"
    local month="$2"

    if ! [[ "$month" =~ ^[0-9]+$ ]]; then
        month=1
    fi
    month=$((10#$month))

    case "$month" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if lite_is_leap_year "$year"; then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo 31 ;;
    esac
}

lite_anchor_date() {
    local year="$1"
    local month="$2"
    local day="$3"
    local max_day

    if ! [[ "$month" =~ ^[0-9]+$ ]]; then
        month=1
    fi
    month=$((10#$month))
    if [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
        month=1
    fi

    if ! [[ "$day" =~ ^[0-9]+$ ]]; then
        day=1
    fi
    day=$((10#$day))
    if [ "$day" -lt 1 ]; then
        day=1
    fi

    max_day=$(lite_days_in_month "$year" "$month")
    if [ "$day" -gt "$max_day" ]; then
        day="$max_day"
    fi

    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
}

lite_date_num() {
    echo "$1" | tr -d '-'
}

lite_shift_month() {
    local year="$1"
    local month="$2"
    local offset="$3"
    local total shifted_year shifted_month

    month=$((10#$month))
    total=$((year * 12 + month - 1 + offset))
    shifted_year=$((total / 12))
    shifted_month=$((total % 12 + 1))

    printf "%04d %02d\n" "$shifted_year" "$shifted_month"
}

lite_previous_day() {
    local date_value="$1"
    local year rest month day prev_year prev_month prev_day

    year=${date_value%%-*}
    rest=${date_value#*-}
    month=${rest%%-*}
    day=${date_value##*-}

    year=$((10#$year))
    month=$((10#$month))
    day=$((10#$day))

    if [ "$day" -gt 1 ]; then
        printf "%04d-%02d-%02d\n" "$year" "$month" "$((day - 1))"
    else
        read -r prev_year prev_month <<< "$(lite_shift_month "$year" "$month" -1)"
        prev_day=$(lite_days_in_month "$prev_year" "$prev_month")
        printf "%04d-%02d-%02d\n" "$prev_year" "$((10#$prev_month))" "$prev_day"
    fi
}

lite_period_start_date() {
    local current_date current_month current_year current_num
    local anchor_this anchor_num period_year period_month quarter_month start_month

    current_date=$(date +%Y-%m-%d)
    current_month=$(date +%m)
    current_year=$(date +%Y)
    current_num=$(lite_date_num "$current_date")

    case "${TRAFFIC_PERIOD:-monthly}" in
        quarterly)
            quarter_month=$(( ((10#$current_month - 1) / 3) * 3 + 1 ))
            anchor_this=$(lite_anchor_date "$current_year" "$quarter_month" "${PERIOD_START_DAY:-1}")
            anchor_num=$(lite_date_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(lite_shift_month "$current_year" "$quarter_month" -3)"
                lite_anchor_date "$period_year" "$period_month" "${PERIOD_START_DAY:-1}"
            else
                echo "$anchor_this"
            fi
            ;;
        yearly)
            start_month="${PERIOD_START_MONTH:-1}"
            if [[ "$start_month" =~ ^[0-9]+$ ]]; then
                start_month=$((10#$start_month))
            else
                start_month=1
            fi
            if [ "$start_month" -lt 1 ] || [ "$start_month" -gt 12 ]; then
                start_month=1
            fi
            anchor_this=$(lite_anchor_date "$current_year" "$start_month" "${PERIOD_START_DAY:-1}")
            anchor_num=$(lite_date_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(lite_shift_month "$current_year" "$start_month" -12)"
                lite_anchor_date "$period_year" "$period_month" "${PERIOD_START_DAY:-1}"
            else
                echo "$anchor_this"
            fi
            ;;
        monthly|*)
            anchor_this=$(lite_anchor_date "$current_year" "$current_month" "${PERIOD_START_DAY:-1}")
            anchor_num=$(lite_date_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(lite_shift_month "$current_year" "$current_month" -1)"
                lite_anchor_date "$period_year" "$period_month" "${PERIOD_START_DAY:-1}"
            else
                echo "$anchor_this"
            fi
            ;;
    esac
}

lite_period_end_date() {
    local start_date start_year start_month next_year next_month next_anchor offset

    start_date=$(lite_period_start_date)
    start_year=${start_date%%-*}
    start_month=${start_date#*-}
    start_month=${start_month%%-*}

    case "${TRAFFIC_PERIOD:-monthly}" in
        quarterly) offset=3 ;;
        yearly) offset=12 ;;
        monthly|*) offset=1 ;;
    esac

    read -r next_year next_month <<< "$(lite_shift_month "$start_year" "$start_month" "$offset")"
    next_anchor=$(lite_anchor_date "$next_year" "$next_month" "${PERIOD_START_DAY:-1}")
    lite_previous_day "$next_anchor"
}

lite_period_label() {
    case "${1:-monthly}" in
        monthly) echo "月度" ;;
        quarterly) echo "季度" ;;
        yearly) echo "年度" ;;
        *) echo "未知周期" ;;
    esac
}

lite_mode_label() {
    case "${1:-total}" in
        out) echo "出站" ;;
        in) echo "进站" ;;
        total) echo "进站+出站" ;;
        max) echo "进出取大" ;;
        *) echo "未知模式" ;;
    esac
}

lite_compare_ge() {
    awk -v left="$1" -v right="$2" 'BEGIN { exit !(left >= right) }'
}

lite_usage_bar() {
    local percent="$1"
    local color="$2"
    local width=18
    local filled empty filled_part empty_part

    filled=$(awk -v p="$percent" -v w="$width" 'BEGIN { if (p < 0) p = 0; if (p > 100) p = 100; printf "%d", (p * w + 50) / 100 }')
    empty=$((width - filled))
    printf -v filled_part '%*s' "$filled" ''
    printf -v empty_part '%*s' "$empty" ''
    filled_part=${filled_part// /#}
    empty_part=${empty_part// /-}

    printf "%b[%b%s%b%s%b]" "$WHITE" "$color" "$filled_part" "$WHITE" "$empty_part" "$NC"
}

lite_current_usage_gb() {
    local start_date="$1"
    local end_date="$2"
    local start_num end_num vnstat_json usage_bytes rx_bytes tx_bytes

    if [ -z "${MAIN_INTERFACE:-}" ]; then
        return 1
    fi
    if ! command -v vnstat >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
        return 1
    fi

    vnstat_json=$(vnstat -i "$MAIN_INTERFACE" --json 2>/dev/null) || return 1
    if [ -z "$vnstat_json" ]; then
        return 1
    fi

    start_num=$(lite_date_num "$start_date")
    end_num=$(lite_date_num "$end_date")

    case "${TRAFFIC_MODE:-total}" in
        out)
            usage_bytes=$(printf '%s' "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .tx] | add // 0' 2>/dev/null) || return 1
            ;;
        in)
            usage_bytes=$(printf '%s' "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .rx] | add // 0' 2>/dev/null) || return 1
            ;;
        max)
            rx_bytes=$(printf '%s' "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .rx] | add // 0' 2>/dev/null) || return 1
            tx_bytes=$(printf '%s' "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .tx] | add // 0' 2>/dev/null) || return 1
            usage_bytes=$(awk -v rx="$rx_bytes" -v tx="$tx_bytes" 'BEGIN { if (rx >= tx) print rx; else print tx }')
            ;;
        total|*)
            usage_bytes=$(printf '%s' "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | (.rx + .tx)] | add // 0' 2>/dev/null) || return 1
            ;;
    esac

    if ! [[ "$usage_bytes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        return 1
    fi

    awk -v bytes="$usage_bytes" 'BEGIN { printf "%.3f", bytes / 1024 / 1024 / 1024 }'
}

show_traffic_overview() {
    local config_file="$WORK_DIR/traffic_monitor_config.txt"
    local start_date end_date period_label mode_label usage_gb percent usage_color bar limit_text

    if [ ! -s "$config_file" ]; then
        echo -e "${CYAN}流量概览:${NC} ${YELLOW}未配置${NC}"
        return
    fi

    local TRAFFIC_MODE="total"
    local TRAFFIC_PERIOD="monthly"
    local TRAFFIC_LIMIT=""
    local PERIOD_START_DAY="1"
    local PERIOD_START_MONTH="1"
    local MAIN_INTERFACE=""

    # shellcheck disable=SC1090
    if ! source "$config_file" 2>/dev/null; then
        echo -e "${CYAN}流量概览:${NC} ${YELLOW}配置读取失败${NC}"
        return
    fi

    case "$TRAFFIC_PERIOD" in
        monthly|quarterly|yearly) ;;
        *) TRAFFIC_PERIOD="monthly" ;;
    esac
    if ! [[ "$TRAFFIC_MODE" =~ ^(out|in|total|max)$ ]]; then
        TRAFFIC_MODE="total"
    fi
    if ! [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! lite_compare_ge "$TRAFFIC_LIMIT" "0.000001"; then
        TRAFFIC_LIMIT=""
    fi

    start_date=$(lite_period_start_date)
    end_date=$(lite_period_end_date)
    period_label=$(lite_period_label "$TRAFFIC_PERIOD")
    mode_label=$(lite_mode_label "$TRAFFIC_MODE")

    echo -e "${CYAN}流量周期:${NC} ${WHITE}${period_label} · ${mode_label}${NC}  ${WHITE}${start_date} ~ ${end_date}${NC}"

    if [ -z "$TRAFFIC_LIMIT" ]; then
        echo -e "${CYAN}已用/总量:${NC} ${YELLOW}总量配置异常${NC}"
        return
    fi

    limit_text=$(awk -v limit="$TRAFFIC_LIMIT" 'BEGIN { printf "%.3f", limit }')
    if ! usage_gb=$(lite_current_usage_gb "$start_date" "$end_date"); then
        echo -e "${CYAN}已用/总量:${NC} ${YELLOW}暂无法读取${NC} / ${WHITE}${limit_text} GB${NC}"
        return
    fi

    percent=$(awk -v used="$usage_gb" -v limit="$TRAFFIC_LIMIT" 'BEGIN { if (limit > 0) printf "%.1f", used / limit * 100; else printf "0.0" }')
    usage_color="$GREEN"
    if lite_compare_ge "$percent" "90"; then
        usage_color="$RED"
    elif lite_compare_ge "$percent" "75"; then
        usage_color="$YELLOW"
    fi
    bar=$(lite_usage_bar "$percent" "$usage_color")

    echo -e "${CYAN}已用/总量:${NC} ${usage_color}${usage_gb} GB${NC} / ${WHITE}${limit_text} GB${NC}  ${usage_color}${percent}%${NC} ${bar}"
}

menu_item() {
    local number="$1"
    local label="$2"
    local number_color="${3:-$PURPLE}"
    local label_color="${4:-$WHITE}"
    printf "${number_color}%2s)${NC} ${label_color}%s${NC}\n" "$number" "$label"
}

tail_file() {
    local file="$1"
    local title="$2"
    echo -e "${CYAN}${title}${NC}"
    if [ -f "$file" ]; then
        tail -80 "$file"
    else
        echo -e "${YELLOW}文件不存在：$file${NC}"
    fi
}

view_logs() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              查看日志                  ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo "1) 流量监控日志"
        echo "2) Telegram 通知日志"
        echo "3) 当前 crontab 相关条目"
        echo "0) 返回主菜单"
        echo ""
        read -r -p "请输入选项: " choice

        case "$choice" in
            1) tail_file "$WORK_DIR/traffic_monitor.log" "流量监控日志"; pause ;;
            2) tail_file "$WORK_DIR/tg_notifier_cron.log" "Telegram 通知日志"; pause ;;
            3)
                echo -e "${CYAN}TrafficCop-Lite 定时任务:${NC}"
                crontab -l 2>/dev/null | grep -F "$WORK_DIR" || echo "无相关定时任务"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

print_config_file() {
    local file="$1"
    local title="$2"
    echo -e "${CYAN}${title}${NC}"
    if [ -f "$file" ]; then
        sed -E 's/^(BOT_TOKEN=).*/\1********/; s/^(CHAT_ID=).*/\1********/' "$file"
    else
        echo -e "${YELLOW}配置不存在：$file${NC}"
    fi
}

view_config() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║             当前配置                   ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo "1) 流量监控配置"
        echo "2) Telegram 通知配置"
        echo "3) 独立版安装状态"
        echo "0) 返回主菜单"
        echo ""
        read -r -p "请输入选项: " choice

        case "$choice" in
            1) print_config_file "$WORK_DIR/traffic_monitor_config.txt" "流量监控配置"; pause ;;
            2) print_config_file "$WORK_DIR/tg_notifier_config.txt" "Telegram 通知配置"; pause ;;
            3) show_status_line; pause ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

remove_lite_cron() {
    local current_crontab
    current_crontab="$(crontab -l 2>/dev/null || true)"
    if [ -n "$current_crontab" ]; then
        printf '%s\n' "$current_crontab" \
            | grep -v -F "$WORK_DIR/$MONITOR_SCRIPT" \
            | grep -v -F "$WORK_DIR/$TELEGRAM_SCRIPT" \
            | crontab - 2>/dev/null || true
    fi
}

stop_lite_processes() {
    pkill -f "$WORK_DIR/$MONITOR_SCRIPT" 2>/dev/null || true
    pkill -f "$WORK_DIR/$TELEGRAM_SCRIPT" 2>/dev/null || true
}

clear_lite_tc_rules_interactive() {
    local config="$WORK_DIR/traffic_monitor_config.txt"
    local interface=""
    local limit_mode=""
    local state_interface=""
    local qdisc_line=""
    local state_qdisc_line=""
    local state_speed=""

    if [ -f "$config" ]; then
        interface="$(grep '^MAIN_INTERFACE=' "$config" | tail -1 | cut -d'=' -f2-)"
        limit_mode="$(grep '^LIMIT_MODE=' "$config" | tail -1 | cut -d'=' -f2-)"
    fi

    if { [ "$limit_mode" != "tc" ] || [ -z "$interface" ]; } && [ ! -f "$TC_STATE_FILE" ]; then
        echo "✓ 未检测到独立版 TC 限速配置"
        return
    fi

    if [ -z "$TC_BIN" ]; then
        echo -e "${YELLOW}未找到系统 tc 命令，跳过 TC 规则检查。${NC}"
        return
    fi

    if [ -f "$TC_STATE_FILE" ]; then
        state_interface="$(grep '^INTERFACE=' "$TC_STATE_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-)"
        if [ -z "$state_interface" ]; then
            rm -f "$TC_STATE_FILE"
            echo "✓ 已清理无效 TC 状态文件"
            return
        fi

        qdisc_line="$("$TC_BIN" qdisc show dev "$state_interface" root 2>/dev/null | head -n 1)"
        if echo "$qdisc_line" | grep -q " tbf "; then
            state_qdisc_line="$(grep '^QDISC_LINE=' "$TC_STATE_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-)"
            state_speed="$(grep '^LIMIT_SPEED=' "$TC_STATE_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-)"
            if [ -n "$state_qdisc_line" ] && [ "$qdisc_line" != "$state_qdisc_line" ]; then
                echo "检测到当前 tbf 与本脚本状态记录不一致，已保留现有规则并清理状态标记。"
                rm -f "$TC_STATE_FILE"
                return
            fi
            if [ -z "$state_qdisc_line" ]; then
                if ! echo "$state_speed" | grep -Eq '^[0-9]+$'; then
                    echo "检测到旧状态记录缺失限速速率，已保留现有规则并清理状态标记。"
                    rm -f "$TC_STATE_FILE"
                    return
                fi
                if ! echo "$qdisc_line" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; then
                    echo "检测到当前 tbf 速率与旧状态记录不一致，已保留现有规则并清理状态标记。"
                    rm -f "$TC_STATE_FILE"
                    return
                fi
            fi
            "$TC_BIN" qdisc del dev "$state_interface" root 2>/dev/null || true
            echo "✓ 已清理本脚本在接口 $state_interface 上应用的 TC 限速"
        else
            echo "✓ 接口 $state_interface 当前没有本脚本可清理的 tbf 规则"
        fi
        rm -f "$TC_STATE_FILE"
        return
    fi

    if ! "$TC_BIN" qdisc show dev "$interface" 2>/dev/null | grep -q "tbf"; then
        echo "✓ 接口 $interface 未发现 tbf 限速规则"
        return
    fi

    echo -e "${YELLOW}检测到接口 $interface 上存在 tbf 限速规则。${NC}"
    echo -e "${YELLOW}Linux 无法可靠区分该规则是否由本脚本创建，默认不清除以免影响系统其他限速。${NC}"
    read -r -p "确认清除该接口 root TC 规则？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        "$TC_BIN" qdisc del dev "$interface" root 2>/dev/null || true
        echo "✓ 已尝试清除 TC 规则"
    else
        echo "已保留 TC 规则"
    fi
}

cancel_shutdown_interactive() {
    local config="$WORK_DIR/traffic_monitor_config.txt"
    if grep -q '^LIMIT_MODE=shutdown' "$config" 2>/dev/null; then
        echo -e "${YELLOW}检测到独立版曾配置关机模式。${NC}"
        read -r -p "是否取消当前系统计划关机？[y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            shutdown -c 2>/dev/null || true
            echo "✓ 已尝试取消计划关机"
        fi
    fi
}

stop_all_services() {
    echo -e "${CYAN}正在停止 TrafficCop-Lite 服务...${NC}"
    stop_lite_processes
    echo "✓ 已停止独立版监控/通知进程"

    remove_lite_cron
    echo "✓ 已移除独立版 crontab 条目"

    clear_lite_tc_rules_interactive
    cancel_shutdown_interactive

    echo -e "${GREEN}独立版服务停止流程完成。${NC}"
    pause
}

uninstall_lite() {
    clear
    echo -e "${RED}${BOLD}卸载 TrafficCop-Lite${NC}"
    echo ""
    echo "只会处理独立版目录：$WORK_DIR"
    echo "不会删除 /root/TrafficCop，也不会卸载 vnstat/jq/bc/cron/iproute2 等系统软件包。"
    echo ""
    read -r -p "确认卸载？请输入 UNINSTALL 继续: " confirm
    if [ "$confirm" != "UNINSTALL" ]; then
        echo "已取消卸载。"
        pause
        return
    fi

    stop_lite_processes
    remove_lite_cron
    clear_lite_tc_rules_interactive
    cancel_shutdown_interactive

    if [ -d "$WORK_DIR" ]; then
        read -r -p "是否先备份配置和日志？[Y/n]: " keep_backup
        if [[ ! "$keep_backup" =~ ^[Nn]$ ]]; then
            local backup_dir
            backup_dir="/etc/trafficcop-lite-backup-$(date +%Y%m%d-%H%M%S)"
            cp -a "$WORK_DIR" "$backup_dir"
            echo "✓ 已备份到 $backup_dir"
        fi
        rm -rf "$WORK_DIR"
        echo "✓ 已删除 $WORK_DIR"
    else
        echo "独立版工作目录不存在，无需删除。"
    fi

    if [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$SHORTCUT_PATH"
        echo "✓ 已删除快捷命令 $SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_NCL_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_NCL_SHORTCUT_PATH"
        echo "✓ 已删除旧快捷命令 $LEGACY_NCL_SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_TC_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_TC_SHORTCUT_PATH"
        echo "✓ 已删除旧快捷命令 $LEGACY_TC_SHORTCUT_PATH"
    fi

    echo -e "${GREEN}卸载完成。${NC}"
    pause
}

show_main_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${BOLD}        TrafficCop Lite 独立管理工具        ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo -e "${PURPLE}版本: ${SCRIPT_VERSION}    更新: ${LAST_UPDATE}${NC}"
    echo ""
    show_status_line
    echo -e "${CYAN}快捷命令:${NC} sudo ntc"
    show_traffic_overview
    echo ""
    menu_item "1" "安装/管理流量监控"
    menu_item "2" "安装/管理 Telegram 通知"
    menu_item "3" "机器限速管理 (启用/禁用)"
    menu_item "4" "查看日志"
    menu_item "5" "查看当前配置"
    menu_item "6" "停止所有服务"
    menu_item "7" "更新脚本"
    menu_item "8" "卸载 TrafficCop-Lite" "$RED" "$RED"
    menu_item "0" "退出"
    echo ""
}

main() {
    check_root
    ensure_work_dir

    case "${1:-}" in
        --install)
            install_shortcut
            echo -e "${GREEN}安装完成。以后可执行：sudo ntc${NC}"
            exit 0
            ;;
        --uninstall)
            uninstall_lite
            exit 0
            ;;
        --stop)
            stop_all_services
            exit 0
            ;;
        --logs)
            view_logs
            exit 0
            ;;
        --config)
            view_config
            exit 0
            ;;
        --update)
            update_scripts "$RAW_BASE"
            exit $?
            ;;
        --help|-h)
            echo "TrafficCop Lite"
            echo "用法: sudo ntc [--install|--update|--uninstall|--stop|--logs|--config]"
            echo "无参数运行进入交互菜单。"
            exit 0
            ;;
    esac

    install_shortcut

    while true; do
        show_main_menu
        read -r -p "请输入选项: " choice
        case "$choice" in
            1) manage_monitor ;;
            2) manage_telegram ;;
            3) manage_machine_limit ;;
            4) view_logs ;;
            5) view_config ;;
            6) stop_all_services ;;
            7) update_scripts_interactive ;;
            8) uninstall_lite ;;
            0) echo -e "${GREEN}已退出 TrafficCop-Lite。${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择，请重新输入。${NC}"; sleep 1 ;;
        esac
    done
}

main "$@"
