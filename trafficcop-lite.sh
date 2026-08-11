#!/bin/bash

# TrafficCop Lite - 独立版流量监控管理器
# 基于 ypq123456789/TrafficCop 的流量监控、Telegram 通知与机器限速功能整理。

SCRIPT_VERSION="1.1.2"
LAST_UPDATE="2026-08-11"

WORK_DIR="/etc/trafficcop-lite"
MONITOR_SCRIPT="trafficcop-lite-monitor.sh"
TELEGRAM_SCRIPT="trafficcop-lite-telegram.sh"
MACHINE_LIMIT_SCRIPT="trafficcop-lite-machine-limit.sh"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
MONITOR_LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
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

    echo -e "${RED}读取当前 crontab 失败，已中止操作：$(cat "$error_file" 2>/dev/null)${NC}" >&2
    rm -f "$error_file"
    return 1
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

copy_self_if_needed() {
    local self_path="$SOURCE_PATH"
    local dest="$WORK_DIR/trafficcop-lite.sh"
    local installed_version

    if [ "$self_path" != "$WORK_DIR/trafficcop-lite.sh" ] && [ -f "$self_path" ]; then
        installed_version=$(script_version_from_file "$dest")
        if [ -n "$installed_version" ] && version_is_newer "$installed_version" "$SCRIPT_VERSION"; then
            echo -e "${YELLOW}! 已安装主脚本版本 $installed_version 高于当前副本 $SCRIPT_VERSION，已阻止降级。${NC}"
            return 0
        fi
        cp "$self_path" "$dest"
        chmod +x "$dest"
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
    local source_version installed_version

    ensure_work_dir

    if [ -f "$src" ] && [ "$src" != "$dest" ]; then
        if ! bash -n "$src" 2>/dev/null; then
            echo -e "${RED}本地脚本语法检查失败：$src${NC}"
            return 1
        fi
        source_version=$(script_version_from_file "$src")
        installed_version=$(script_version_from_file "$dest")
        if [ -n "$source_version" ] && [ -n "$installed_version" ] \
            && bash -n "$dest" 2>/dev/null \
            && version_is_newer "$installed_version" "$source_version"; then
            echo -e "${YELLOW}! 已安装 $script_name 版本 $installed_version 高于当前副本 $source_version，已阻止降级。${NC}"
            return 0
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
    local script_name restore_name tmp_file url backup_dir rollback_failed

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
    if ! mkdir -p "$backup_dir"; then
        echo -e "${RED}无法创建脚本备份目录，已取消更新。${NC}"
        rm -f "${temp_files[@]}" 2>/dev/null || true
        return 1
    fi

    for script_name in "${scripts[@]}"; do
        if [ -f "$WORK_DIR/$script_name" ]; then
            if ! cp -a "$WORK_DIR/$script_name" "$backup_dir/"; then
                echo -e "${RED}备份 $script_name 失败，已取消更新。${NC}"
                rm -f "${temp_files[@]}" 2>/dev/null || true
                return 1
            fi
        fi
    done

    for script_name in "${scripts[@]}"; do
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        if ! chmod +x "$tmp_file" || ! mv -f "$tmp_file" "$WORK_DIR/$script_name"; then
            echo -e "${RED}替换 $script_name 失败，正在恢复更新前脚本。${NC}"
            rollback_failed=false
            for restore_name in "${scripts[@]}"; do
                if [ -f "$backup_dir/$restore_name" ]; then
                    cp -a "$backup_dir/$restore_name" "$WORK_DIR/$restore_name" || rollback_failed=true
                else
                    rm -f "$WORK_DIR/$restore_name" || rollback_failed=true
                fi
            done
            rm -f "${temp_files[@]}" 2>/dev/null || true
            if $rollback_failed; then
                echo -e "${RED}部分脚本回滚失败，备份保留在：$backup_dir${NC}"
            fi
            return 1
        fi
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
    echo -e "${YELLOW}命令行更新后请重新执行 sudo ntc；交互更新将自动载入新版菜单。${NC}"
}

update_scripts_interactive() {
    local selected_base

    selected_base=$(choose_update_base) || {
        echo "已取消更新。"
        pause
        return
    }

    if update_scripts "$selected_base"; then
        echo -e "${GREEN}正在载入新版菜单...${NC}"
        exec bash "$WORK_DIR/trafficcop-lite.sh"
        echo -e "${RED}新版菜单载入失败，请重新执行 sudo ntc。${NC}"
    fi
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

lite_vnstat_config_value() {
    local target="$1"
    vnstat --showconfig 2>/dev/null | awk -v target="$target" '
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

lite_vnstat_available_start() {
    local vnstat_json created_num earliest_num available_num trafficless_entries

    [ -n "${MAIN_INTERFACE:-}" ] || return 1
    vnstat_json=$(vnstat -i "$MAIN_INTERFACE" --json 2>/dev/null) || return 1
    created_num=$(printf '%s' "$vnstat_json" | jq -r \
        '.interfaces[0].created.date | (.year * 10000 + .month * 100 + .day)' 2>/dev/null) || return 1
    earliest_num=$(printf '%s' "$vnstat_json" | jq -r \
        '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day)] | min // 0' 2>/dev/null) || return 1
    [[ "$created_num" =~ ^[0-9]{8}$ ]] || return 1

    trafficless_entries=$(lite_vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    available_num="$created_num"
    if [ "$trafficless_entries" != "0" ] \
        && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -gt "$available_num" ]; then
        available_num="$earliest_num"
    fi
    printf '%s-%s-%s\n' "${available_num:0:4}" "${available_num:4:2}" "${available_num:6:2}"
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
    local start_num end_num vnstat_json usage_bytes rx_bytes tx_bytes divisor
    local created_num earliest_num daily_days required_days trafficless_entries retention_start retention_num

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

    created_num=$(printf '%s' "$vnstat_json" | jq -r '.interfaces[0].created.date | (.year * 10000 + .month * 100 + .day)' 2>/dev/null) || return 1
    earliest_num=$(printf '%s' "$vnstat_json" | jq -r '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day)] | min // 0' 2>/dev/null) || return 1
    case "${TRAFFIC_PERIOD:-monthly}" in
        monthly) required_days=40 ;;
        quarterly) required_days=100 ;;
        yearly) required_days=400 ;;
    esac
    daily_days=$(lite_vnstat_config_value "DailyDays")
    trafficless_entries=$(lite_vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    retention_start=$(cat "$WORK_DIR/vnstat_daily_coverage_start" 2>/dev/null || true)
    retention_num=${retention_start//-/}
    if [ -z "$retention_start" ] && [ -f "$WORK_DIR/vnstat.conf.before-trafficcop-lite" ] \
        && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -ne 0 ]; then
        retention_start="$earliest_num"
        retention_num="$earliest_num"
    fi
    if ! [[ "$created_num" =~ ^[0-9]{8}$ ]] \
        || { [ "$daily_days" != "-1" ] && { ! [[ "$daily_days" =~ ^[0-9]+$ ]] || [ "$daily_days" -lt "$required_days" ]; }; }; then
        return 2
    fi
    if [ "$created_num" -gt "$start_num" ] \
        || { [ "$trafficless_entries" = "0" ] && [ -n "$retention_start" ] && { ! [[ "$retention_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$start_num" ]; }; } \
        || { [ "$trafficless_entries" != "0" ] && { ! [[ "$earliest_num" =~ ^[0-9]+$ ]] || [ "$earliest_num" -eq 0 ] || [ "$earliest_num" -gt "$start_num" ]; }; }; then
        [ "${ALLOW_PARTIAL_HISTORY:-false}" = "true" ] || return 2
    fi

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

    [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && divisor=1000000000 || divisor=1073741824
    awk -v bytes="$usage_bytes" -v divisor="$divisor" 'BEGIN { printf "%.3f", bytes / divisor }'
}

show_traffic_overview() {
    local config_file="$WORK_DIR/traffic_monitor_config.txt"
    local start_date end_date period_label mode_label usage_gb percent usage_color bar limit_text unit_label usage_status
    local available_start available_num start_num retention_start retention_num trafficless_entries

    if [ ! -s "$config_file" ]; then
        echo -e "${CYAN}流量概览:${NC} ${YELLOW}未配置${NC}"
        return
    fi

    if command -v vnstat >/dev/null 2>&1 && [ "$(lite_vnstat_config_value "UseUTC")" = "1" ]; then
        export TZ=UTC
    else
        unset TZ
    fi

    local TRAFFIC_MODE="total"
    local TRAFFIC_PERIOD="monthly"
    local TRAFFIC_LIMIT=""
    local TRAFFIC_UNIT="binary"
    local PERIOD_START_DAY="1"
    local PERIOD_START_MONTH="1"
    local MAIN_INTERFACE=""
    local ALLOW_PARTIAL_HISTORY="false"
    local key value

    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            TRAFFIC_MODE|TRAFFIC_PERIOD|TRAFFIC_LIMIT|TRAFFIC_UNIT|PERIOD_START_DAY|PERIOD_START_MONTH|MAIN_INTERFACE|ALLOW_PARTIAL_HISTORY)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$config_file"

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
    [ "$TRAFFIC_UNIT" = "decimal" ] && unit_label="GB" || unit_label="GiB"

    echo -e "${CYAN}流量周期:${NC} ${WHITE}${period_label} · ${mode_label}${NC}  ${WHITE}${start_date} ~ ${end_date}${NC}"
    if [ "$ALLOW_PARTIAL_HISTORY" = "true" ]; then
        available_start=$(lite_vnstat_available_start 2>/dev/null || true)
        retention_start=$(cat "$WORK_DIR/vnstat_daily_coverage_start" 2>/dev/null || true)
        trafficless_entries=$(lite_vnstat_config_value "TrafficlessEntries")
        trafficless_entries=${trafficless_entries:-1}
        available_num=${available_start//-/}
        retention_num=${retention_start//-/}
        start_num=${start_date//-/}
        if [ "$trafficless_entries" = "0" ] && [[ "$retention_num" =~ ^[0-9]{8}$ ]] \
            && { ! [[ "$available_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$available_num" ]; }; then
            available_start="$retention_start"
            available_num="$retention_num"
        fi
        if { [[ "$available_num" =~ ^[0-9]{8}$ ]] && [ "$available_num" -gt "$start_num" ]; } \
            || { [ -n "$retention_start" ] && [[ "$retention_num" =~ ^[0-9]{8}$ ]] && [ "$retention_num" -gt "$start_num" ]; }; then
            echo -e "${YELLOW}历史提示:${NC} ${YELLOW}仅统计 ${available_start:-现有记录} 以来数据，周期早段流量未计入${NC}"
        fi
    fi

    if [ -z "$TRAFFIC_LIMIT" ]; then
        echo -e "${CYAN}已用/总量:${NC} ${YELLOW}总量配置异常${NC}"
        return
    fi

    limit_text=$(awk -v limit="$TRAFFIC_LIMIT" 'BEGIN { printf "%.3f", limit }')
    usage_gb=$(lite_current_usage_gb "$start_date" "$end_date")
    usage_status=$?
    if [ "$usage_status" -ne 0 ]; then
        if [ "$usage_status" -eq 2 ]; then
            echo -e "${CYAN}已用/总量:${NC} ${YELLOW}历史日数据覆盖不足${NC} / ${WHITE}${limit_text} $unit_label${NC}"
        else
            echo -e "${CYAN}已用/总量:${NC} ${YELLOW}暂无法读取${NC} / ${WHITE}${limit_text} $unit_label${NC}"
        fi
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

    echo -e "${CYAN}已用/总量:${NC} ${usage_color}${usage_gb} $unit_label${NC} / ${WHITE}${limit_text} $unit_label${NC}  ${usage_color}${percent}%${NC} ${bar}"
}

lite_state_value() {
    local file="$1"
    local key="$2"
    if [ -f "$file" ]; then
        grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

show_enforcement_overview() {
    local config_file="$WORK_DIR/traffic_monitor_config.txt"
    local mode until_epoch reason now remaining
    local limit_mode="" boot_grace_minutes=10 key value uptime_seconds

    [ -s "$config_file" ] || return
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            LIMIT_MODE) limit_mode="$value" ;;
            TC_BOOT_GRACE_MINUTES) boot_grace_minutes="$value" ;;
        esac
    done < "$config_file"

    mode=$(lite_state_value "$ENFORCEMENT_STATE_FILE" "MODE")
    until_epoch=$(lite_state_value "$ENFORCEMENT_STATE_FILE" "UNTIL_EPOCH")
    reason=$(lite_state_value "$ENFORCEMENT_STATE_FILE" "REASON")
    now=$(date +%s)
    if [ "$mode" = "grace" ] && [[ "$until_epoch" =~ ^[0-9]+$ ]] && [ "$until_epoch" -gt "$now" ]; then
        remaining=$(( (until_epoch - now + 59) / 60 ))
        echo -e "${CYAN}限制执行:${NC} ${YELLOW}宽限中，约剩余 $remaining 分钟${NC}"
        return
    fi
    if [ "$mode" = "paused" ]; then
        if [ "$reason" = "shutdown_reboot" ]; then
            echo -e "${CYAN}限制执行:${NC} ${RED}关机后重启保护，已暂停再次关机${NC}"
        else
            echo -e "${CYAN}限制执行:${NC} ${YELLOW}已暂停，仅监控流量${NC}"
        fi
        return
    fi

    if [ "$limit_mode" = "tc" ] && [[ "$boot_grace_minutes" =~ ^[0-9]+$ ]] \
        && [ "$boot_grace_minutes" -gt 0 ] && [ "$boot_grace_minutes" -le 1440 ]; then
        uptime_seconds=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || echo 0)
        if [[ "$uptime_seconds" =~ ^[0-9]+$ ]] && [ "$uptime_seconds" -lt $((boot_grace_minutes * 60)) ]; then
            remaining=$(( (boot_grace_minutes * 60 - uptime_seconds + 59) / 60 ))
            echo -e "${CYAN}限制执行:${NC} ${YELLOW}开机宽限中，约剩余 $remaining 分钟${NC}"
            return
        fi
    fi
    echo -e "${CYAN}限制执行:${NC} ${GREEN}正常${NC}"
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
        if ! read -r -p "请输入选项: " choice; then
            echo ""
            return
        fi

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
        if ! read -r -p "请输入选项: " choice; then
            echo ""
            return
        fi

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
    local current_crontab filtered_crontab
    if ! current_crontab="$(read_current_crontab)"; then
        return 1
    fi
    if [ -n "$current_crontab" ]; then
        filtered_crontab="$(printf '%s\n' "$current_crontab" \
            | grep -v -F "$WORK_DIR/$MONITOR_SCRIPT" \
            | grep -v -F "$WORK_DIR/$TELEGRAM_SCRIPT" || true)"
        if ! printf '%s\n' "$filtered_crontab" | crontab - 2>/dev/null; then
            echo -e "${RED}移除独立版 crontab 条目失败，已保留安装目录。${NC}"
            return 1
        fi
    fi
    return 0
}

stop_lite_processes() {
    pkill -f "$WORK_DIR/$MONITOR_SCRIPT" 2>/dev/null || true
    pkill -f "$WORK_DIR/$TELEGRAM_SCRIPT" 2>/dev/null || true
}

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
        [ -f "$TC_STATE_FILE" ] && return 1
        return 0
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
            if "$TC_BIN" qdisc del dev "$state_interface" root 2>/dev/null; then
                echo "✓ 已清理本脚本在接口 $state_interface 上应用的 TC 限速"
            else
                qdisc_line="$("$TC_BIN" qdisc show dev "$state_interface" root 2>/dev/null | head -n 1)"
                if echo "$qdisc_line" | grep -q " tbf "; then
                    echo -e "${RED}清理接口 $state_interface 的 TC 限速失败，已保留状态文件以便重试。${NC}"
                    return 1
                fi
                echo "✓ 接口 $state_interface 已不存在 tbf 规则"
            fi
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
        if "$TC_BIN" qdisc del dev "$interface" root 2>/dev/null; then
            echo "✓ 已清除 TC 规则"
        else
            echo -e "${RED}清除 TC 规则失败，请检查接口和系统 tc 状态。${NC}"
            return 1
        fi
    else
        echo "已保留 TC 规则"
    fi
}

lite_has_pending_shutdown() {
    if shutdown --help 2>&1 | grep -q -- '--show'; then
        shutdown --show >/dev/null 2>&1
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -x shutdown >/dev/null 2>&1
    else
        return 1
    fi
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
        if lite_has_pending_shutdown && ! shutdown -c 2>/dev/null; then
            echo -e "${RED}无法取消本脚本记录的计划关机，已保留状态文件。${NC}"
            return 1
        fi
        rm -f "$SHUTDOWN_STATE_FILE" || return 1
        echo "✓ 已取消本脚本记录的计划关机"
        return
    fi
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
    local has_error=false

    echo -e "${CYAN}正在停止 TrafficCop-Lite 服务...${NC}"
    if ! remove_lite_cron; then
        echo -e "${RED}无法安全移除定时任务，本次未清理 TC 规则。${NC}"
        pause
        return 1
    fi
    echo "✓ 已移除独立版 crontab 条目"

    stop_lite_processes
    if ! acquire_monitor_cleanup_lock; then
        echo -e "${RED}无法取得监控锁，本次未清理 TC 规则。${NC}"
        pause
        return 1
    fi
    stop_lite_processes
    echo "✓ 已停止独立版监控/通知进程"

    clear_lite_tc_rules_interactive || has_error=true
    cancel_shutdown_interactive || has_error=true
    release_monitor_cleanup_lock

    if $has_error; then
        echo -e "${RED}停止流程未完全成功；安装目录和状态文件已保留，请查看上方错误。${NC}"
    else
        echo -e "${GREEN}独立版服务停止流程完成。${NC}"
    fi
    pause
    $has_error && return 1
    return 0
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

    if ! remove_lite_cron; then
        echo -e "${RED}卸载已中止：无法移除独立版 crontab 条目。${NC}"
        pause
        return 1
    fi
    stop_lite_processes
    if ! acquire_monitor_cleanup_lock; then
        echo -e "${RED}卸载已中止：无法取得监控锁。${NC}"
        pause
        return 1
    fi
    stop_lite_processes
    if ! clear_lite_tc_rules_interactive; then
        release_monitor_cleanup_lock
        echo -e "${RED}卸载已中止：TC 限速未能安全清理，状态文件已保留。${NC}"
        pause
        return 1
    fi
    if ! cancel_shutdown_interactive; then
        release_monitor_cleanup_lock
        echo -e "${RED}卸载已中止：本脚本记录的计划关机未能安全取消，状态文件已保留。${NC}"
        pause
        return 1
    fi

    if [ -d "$WORK_DIR" ]; then
        read -r -p "是否先备份配置和日志？[Y/n]: " keep_backup
        if [[ ! "$keep_backup" =~ ^[Nn]$ ]]; then
            local backup_dir
            backup_dir="/etc/trafficcop-lite-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -m 700 "$backup_dir" || {
                release_monitor_cleanup_lock
                echo -e "${RED}创建备份目录失败，卸载已中止。${NC}"
                pause
                return 1
            }
            if ! cp -a "$WORK_DIR/." "$backup_dir/"; then
                release_monitor_cleanup_lock
                echo -e "${RED}配置和日志备份失败，卸载已中止；未删除工作目录。${NC}"
                pause
                return 1
            fi
            chmod 700 "$backup_dir" 2>/dev/null || true
            echo "✓ 已备份到 $backup_dir"
        fi
        if ! rm -rf "$WORK_DIR"; then
            release_monitor_cleanup_lock
            echo -e "${RED}删除 $WORK_DIR 失败，请检查文件系统状态。${NC}"
            pause
            return 1
        fi
        echo "✓ 已删除 $WORK_DIR"
    else
        echo "独立版工作目录不存在，无需删除。"
    fi

    release_monitor_cleanup_lock

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
    show_enforcement_overview
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
            install_status=$?
            [ "$install_status" -eq 0 ] || exit "$install_status"
            echo -e "${GREEN}安装完成。以后可执行：sudo ntc${NC}"
            exit 0
            ;;
        --uninstall)
            uninstall_lite
            exit $?
            ;;
        --stop)
            stop_all_services
            exit $?
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

    install_shortcut || exit 1

    while true; do
        show_main_menu
        if ! read -r -p "请输入选项: " choice; then
            echo ""
            echo -e "${GREEN}输入已结束，退出 TrafficCop-Lite。${NC}"
            exit 0
        fi
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
